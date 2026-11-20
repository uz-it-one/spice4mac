import Foundation

public enum ConnectionError: Error, LocalizedError, Equatable {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

public struct ConnectionOptions: Codable, Sendable, Equatable {
    public var host: String
    public var port: Int?
    public var tlsPort: Int?
    public var password: String?
    public var caFile: String?
    public var caPEM: String?
    public var certificateSubject: String?
    public var proxy: String?
    public var insecure: Bool
    public var clipboard: Bool
    public var audio: Bool

    public init(host: String, port: Int? = nil, tlsPort: Int? = nil, password: String? = nil,
                caFile: String? = nil, caPEM: String? = nil, certificateSubject: String? = nil,
                proxy: String? = nil, insecure: Bool = false, clipboard: Bool = true, audio: Bool = true) {
        self.host = host; self.port = port; self.tlsPort = tlsPort; self.password = password
        self.caFile = caFile; self.caPEM = caPEM; self.certificateSubject = certificateSubject
        self.proxy = proxy; self.insecure = insecure; self.clipboard = clipboard; self.audio = audio
    }

    public func validate() throws {
        guard !host.isEmpty, host.utf8.count <= 253,
              !host.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
              !host.contains("/"), !host.contains("@"), !host.contains("?") else {
            throw ConnectionError.invalid("A valid SPICE host name or IP address is required.")
        }
        for value in [port, tlsPort].compactMap({ $0 }) {
            guard (1...65535).contains(value) else { throw ConnectionError.invalid("Ports must be between 1 and 65535.") }
        }
        guard port != nil || tlsPort != nil else { throw ConnectionError.invalid("Specify --tls-port, or --port with --insecure.") }
        guard tlsPort != nil || insecure else { throw ConnectionError.invalid("Plaintext SPICE requires explicit --insecure consent.") }
        guard !(insecure && tlsPort != nil) else { throw ConnectionError.invalid("--insecure cannot be combined with a TLS port.") }
        guard !(caFile != nil && caPEM != nil) else { throw ConnectionError.invalid("Supply only one CA source.") }
        for text in [password, caFile, caPEM, certificateSubject, proxy].compactMap({ $0 }) {
            guard text.utf8.count <= 262144, !text.contains("\0") else { throw ConnectionError.invalid("A connection field is too large or contains a NUL character.") }
        }
        if let proxy {
            guard let u = URLComponents(string: proxy), ["http", "https"].contains(u.scheme?.lowercased() ?? ""),
                  let h = u.host, !h.isEmpty, u.user == nil, u.password == nil,
                  u.query == nil, u.fragment == nil, u.path.isEmpty || u.path == "/",
                  u.port.map({ (1...65535).contains($0) }) ?? true else {
                throw ConnectionError.invalid("Proxy must be an HTTP(S) URL without embedded credentials, query, or path.")
            }
        }
    }

    public func redactedJSON() throws -> Data {
        var copy = self
        copy.password = password == nil ? nil : "<redacted>"
        copy.caPEM = caPEM == nil ? nil : "<certificate>"
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(copy)
    }

    public static func fromURI(_ text: String) throws -> ConnectionOptions {
        guard text.utf8.count <= 8192, let u = URLComponents(string: text), u.scheme?.lowercased() == "spice",
              let host = u.host, !host.isEmpty, u.user == nil, u.password == nil,
              u.path.isEmpty || u.path == "/", u.fragment == nil else {
            throw ConnectionError.invalid("Expected spice://host:port; embedded credentials and paths are not supported.")
        }
        var result = ConnectionOptions(host: host.hasPrefix("[") ? String(host.dropFirst().dropLast()) : host, port: u.port)
        var seen = Set<String>()
        for item in u.queryItems ?? [] {
            guard seen.insert(item.name).inserted, let value = item.value else { throw ConnectionError.invalid("Duplicate or empty URI parameter.") }
            switch item.name {
            case "tls-port": result.tlsPort = try parsePort(value)
            case "port":
                guard result.port == nil else { throw ConnectionError.invalid("Port supplied twice.") }
                result.port = try parsePort(value)
            default: throw ConnectionError.invalid("Unsupported SPICE URI parameter.")
            }
        }
        if result.port == nil && result.tlsPort == nil { result.port = 5900 }
        return result
    }

    public static func fromVV(data: Data) throws -> ConnectionOptions {
        guard data.count <= 1_048_576, let contents = String(data: data, encoding: .utf8), !contents.contains("\0") else {
            throw ConnectionError.invalid("Connection file must be UTF-8 and no larger than 1 MiB.")
        }
        var values: [String: String] = [:]
        var inSection = false
        var sawSection = false
        let accepted: Set<String> = ["type", "host", "port", "tls-port", "password", "ca", "host-subject", "proxy", "secure-channels", "title", "fullscreen", "delete-this-file"]
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") {
                guard line == "[virt-viewer]", !sawSection else { throw ConnectionError.invalid("Only one [virt-viewer] section is supported.") }
                sawSection = true; inSection = true; continue
            }
            guard inSection, let equal = line.firstIndex(of: "=") else { throw ConnectionError.invalid("Malformed connection file entry.") }
            let key = String(line[..<equal]).trimmingCharacters(in: .whitespaces)
            guard accepted.contains(key) else { throw ConnectionError.invalid("Unsupported connection file option: \(key.prefix(64)).") }
            guard values[key] == nil else { throw ConnectionError.invalid("Duplicate connection file option: \(key).") }
            let value = String(line[line.index(after: equal)...])
            guard value.utf8.count <= 262144 else { throw ConnectionError.invalid("Connection field exceeds 256 KiB.") }
            values[key] = try unescape(value)
        }
        guard values["type"] == "spice", let host = values["host"] else { throw ConnectionError.invalid("Connection file must specify type=spice and host.") }
        if let secure = values["secure-channels"], secure != "all" { throw ConnectionError.invalid("Only secure-channels=all is supported.") }
        func port(_ key: String) throws -> Int? {
            guard let value = values[key], value != "-1" else { return nil }
            return try parsePort(value)
        }
        let tlsPort = try port("tls-port")
        if values["secure-channels"] != nil && tlsPort == nil { throw ConnectionError.invalid("secure-channels requires a TLS port.") }
        return ConnectionOptions(host: host, port: try port("port"), tlsPort: tlsPort, password: values["password"],
                                 caPEM: values["ca"], certificateSubject: values["host-subject"], proxy: values["proxy"])
    }

    static func parsePort(_ text: String) throws -> Int {
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }), let value = Int(text), (1...65535).contains(value) else {
            throw ConnectionError.invalid("Ports must be integers between 1 and 65535.")
        }
        return value
    }

    private static func unescape(_ value: String) throws -> String {
        var result = ""; var escaped = false
        for c in value {
            if escaped {
                switch c {
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                case "s": result.append(" ")
                case "\\": result.append("\\")
                default: throw ConnectionError.invalid("Invalid escape sequence in connection file.")
                }
                escaped = false
            } else if c == "\\" { escaped = true } else { result.append(c) }
        }
        guard !escaped else { throw ConnectionError.invalid("Incomplete escape sequence in connection file.") }
        return result
    }
}
