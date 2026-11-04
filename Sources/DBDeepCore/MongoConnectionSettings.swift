import Foundation

struct MongoSeed {
    let host: String
    let port: Int?

    var address: String { host.contains(":") ? "[\(host)]" : host }
    var value: String { address + (port.map { ":\($0)" } ?? "") }

    static func parse(_ hosts: String, srv: Bool) throws -> [MongoSeed] {
        let seeds = try hosts.split(separator: ",", omittingEmptySubsequences: false).map { raw -> MongoSeed in
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, !value.contains(where: { $0.isWhitespace || "/?@#%\\".contains($0) }) else {
                throw DatabaseError("Enter hostnames or IP addresses, separated by commas. Paste a full URI using Import URI.")
            }
            let host: String
            let portText: String?
            if value.hasPrefix("[") {
                guard let close = value.firstIndex(of: "]") else { throw DatabaseError("Close the IPv6 address with ].") }
                host = String(value[value.index(after: value.startIndex)..<close])
                let suffix = value[value.index(after: close)...]
                guard suffix.isEmpty || suffix.hasPrefix(":") else { throw DatabaseError("Use [IPv6]:port for an IPv6 address.") }
                portText = suffix.isEmpty ? nil : String(suffix.dropFirst())
            } else if value.filter({ $0 == ":" }).count > 1 {
                guard !hosts.contains(","), value.allSatisfy({ $0.isHexDigit || ":.".contains($0) }) else {
                    throw DatabaseError("Use [IPv6]:port when entering multiple hosts.")
                }
                host = value; portText = nil
            } else {
                let parts = value.split(separator: ":", omittingEmptySubsequences: false)
                host = String(parts[0]); portText = parts.count == 2 ? String(parts[1]) : nil
            }
            guard !host.isEmpty, !host.contains("["), !host.contains("]") else { throw DatabaseError("Enter a valid hostname or IP address.") }
            var port: Int?
            if let portText {
                guard let number = Int(portText), portText.allSatisfy(\.isNumber), (1...65535).contains(number) else {
                    throw DatabaseError("Each port must be between 1 and 65535.")
                }
                port = number
            }
            return MongoSeed(host: host, port: port)
        }
        if srv && (seeds.count != 1 || seeds[0].port != nil || seeds[0].host.contains(":")) {
            throw DatabaseError("SRV requires one DNS hostname without a port.")
        }
        return seeds
    }
}

public struct MongoConnectionURI {
    public let host: String
    public let port: Int
    public let database: String
    public let authSource: String
    public let tls: Bool
    public let srv: Bool
    public let replicaSet: String
    public let username: String?
    public let password: String?

    public init(_ text: String) throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        srv = text.hasPrefix("mongodb+srv://")
        let prefix = srv ? "mongodb+srv://" : "mongodb://"
        guard text.hasPrefix(prefix), !text.contains("#") else { throw DatabaseError("Enter a mongodb:// or mongodb+srv:// connection URI.") }
        let parts = text.dropFirst(prefix.count).split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = parts[0].split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        var authority = String(path[0])
        var importedUsername: String?
        var importedPassword: String?
        func decode(_ value: String) throws -> String {
            guard let decoded = value.removingPercentEncoding else { throw DatabaseError("The URI contains invalid percent encoding.") }
            return decoded
        }
        if let at = authority.lastIndex(of: "@") {
            let credentials = authority[..<at].split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            importedUsername = try decode(String(credentials[0]))
            importedPassword = credentials.count == 2 ? try decode(String(credentials[1])) : nil
            authority = String(authority[authority.index(after: at)...])
        }
        username = importedUsername; password = importedPassword
        let seeds = try MongoSeed.parse(authority, srv: srv)
        host = seeds.count == 1 ? seeds[0].address : seeds.map(\.value).joined(separator: ",")
        port = seeds.count == 1 ? seeds[0].port ?? 27017 : 27017
        database = path.count == 2 ? try decode(String(path[1])) : ""
        var options: [String: String] = [:]
        if parts.count == 2 {
            for item in parts[1].split(separator: "&", omittingEmptySubsequences: true) {
                let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = try decode(String(pair[0])).lowercased()
                guard ["authsource", "tls", "ssl", "replicaset"].contains(key) else {
                    throw DatabaseError("This URI option is not supported by the connection form: \(key). The settings were not imported.")
                }
                guard pair.count == 2, options[key] == nil else { throw DatabaseError("Use each URI option once with a value.") }
                options[key] = try decode(String(pair[1]))
            }
        }
        if let tls = options["tls"], let ssl = options["ssl"], tls != ssl { throw DatabaseError("tls and ssl must have the same value.") }
        if options["authsource"] == "" || options["replicaset"] == "" { throw DatabaseError("authSource and replicaSet must have a value when included in the URI.") }
        let tlsValue = options["tls"] ?? options["ssl"]
        if let tlsValue, !["true", "false"].contains(tlsValue) { throw DatabaseError("TLS must be true or false.") }
        if srv && tlsValue == "false" { throw DatabaseError("SRV connections in this app require TLS.") }
        tls = tlsValue == "true" || srv
        authSource = options["authsource"] ?? ""
        replicaSet = options["replicaset"] ?? ""
    }
}

public extension DBConnection {
    var effectiveMongoAuthSource: String { mongoAuthSource.isEmpty ? (service.isEmpty ? "admin" : service) : mongoAuthSource }

    var mongoURI: String {
        let seeds = (try? MongoSeed.parse(host, srv: mongoSRV)) ?? []
        let addresses = seeds.map { mongoSRV ? $0.host : $0.address + ":\($0.port ?? port)" }.joined(separator: ",")
        func escaped(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "" }
        var options = ["tls=\(mongoTLS || mongoSRV)"]
        if !mongoAuthSource.isEmpty { options.append("authSource=\(escaped(mongoAuthSource))") }
        if !mongoReplicaSet.isEmpty { options.append("replicaSet=\(escaped(mongoReplicaSet))") }
        return "mongodb\(mongoSRV ? "+srv" : "")://\(addresses)/\(escaped(service))?\(options.joined(separator: "&"))"
    }

    var configurationError: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter a connection name." }
        if kind == .mongodb {
            do { _ = try MongoSeed.parse(host, srv: mongoSRV) }
            catch { return error.localizedDescription }
        } else if host.isEmpty || host.contains(where: { $0.isWhitespace || "/?@#,".contains($0) }) {
            return "Enter a hostname or IP address, without a URI or credentials."
        }
        if !(1...65535).contains(port) { return "Port must be between 1 and 65535." }
        if service.isEmpty { return kind == .mongodb ? "Enter a database name." : "Enter a service name or SID." }
        if kind == .oracle && username.isEmpty { return "Enter an Oracle username." }
        if kind == .mongodb && service.contains(where: { "/\\. \"$*<>:|?".contains($0) }) { return "Enter a valid MongoDB database name." }
        return nil
    }
}
