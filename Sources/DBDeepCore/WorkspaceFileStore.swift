import Foundation

public struct WorkspaceFileStore {
    public let directory: URL
    private var file: URL { directory.appendingPathComponent("workspace.json") }

    public init(directory: URL) {
        self.directory = directory
    }

    public func load() throws -> WorkspaceState? {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(WorkspaceState.self, from: Data(contentsOf: file))
    }

    public func save(_ state: WorkspaceState) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: file, options: .atomic)
    }
}
