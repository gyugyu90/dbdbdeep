import Foundation
import Darwin

public typealias QueryExportProgressHandler = @Sendable (Int) -> Void

public struct QueryExportSummary: Codable, Equatable, Sendable {
    public let rows: Int
    public let bytes: Int64
    public let elapsed: Double

    public init(rows: Int, bytes: Int64, elapsed: Double) {
        self.rows = rows; self.bytes = bytes; self.elapsed = elapsed
    }
}

struct AtomicQueryExport {
    let destination: URL
    let temporary: URL

    init(destination: URL) throws {
        guard destination.isFileURL else { throw DatabaseError("Choose a local CSV file.") }
        self.destination = destination
        temporary = destination.deletingLastPathComponent().appendingPathComponent(".dbdbdeep-export-\(UUID().uuidString).part")
    }

    func finish() throws {
        let status = temporary.path.withCString { source in
            destination.path.withCString { target in Darwin.rename(source, target) }
        }
        guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    func discard() { try? FileManager.default.removeItem(at: temporary) }
}

final class CSVStreamWriter {
    private let handle: FileHandle
    private var buffer = Data()
    private(set) var bytes: Int64 = 0

    init(url: URL) throws {
        try Data().write(to: url, options: .withoutOverwriting)
        handle = try FileHandle(forWritingTo: url)
    }

    func row(_ values: [String?]) throws {
        for (index, value) in values.enumerated() {
            if index > 0 { buffer.append(44) }
            if let value {
                buffer.append(34)
                for byte in value.utf8 {
                    buffer.append(byte)
                    if byte == 34 { buffer.append(34) }
                    if buffer.count >= 65536 { try flush() }
                }
                buffer.append(34)
            }
        }
        buffer.append(contentsOf: [13, 10])
        if buffer.count >= 65536 { try flush() }
    }

    private func flush() throws {
        try handle.write(contentsOf: buffer)
        bytes += Int64(buffer.count)
        buffer.removeAll(keepingCapacity: true)
    }

    func close() throws {
        try flush()
        try handle.synchronize()
        try handle.close()
    }

    deinit { try? handle.close() }
}

enum QueryExportFrame {
    case progress(Int)
    case complete(QueryExportSummary)
    case failure(OracleConnectionFailure)

    static func decode(_ data: Data) throws -> Self {
        struct Progress: Decodable { let exportProgress: Int }
        struct Complete: Decodable { let exportComplete: QueryExportSummary }
        let decoder = JSONDecoder()
        if let value = try? decoder.decode(Progress.self, from: data), value.exportProgress >= 0 { return .progress(value.exportProgress) }
        if let value = try? decoder.decode(Complete.self, from: data), value.exportComplete.rows >= 0, value.exportComplete.bytes >= 0 { return .complete(value.exportComplete) }
        if let failure = try? decoder.decode(OracleConnectionFailure.self, from: data) { return .failure(failure) }
        throw DatabaseError("Unexpected CSV export response.")
    }
}
