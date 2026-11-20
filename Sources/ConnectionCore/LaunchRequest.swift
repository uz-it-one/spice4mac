import Foundation

public struct LaunchRequest: Sendable {
    public var options: ConnectionOptions?
    public var passwordFromStdin = false
    public var connectionFromStdin = false
    public var wait = true
    public var appPath: String?
    public var validateOnly = false
    public var help = false
    public var version = false
    public var forwardedArguments: [String] = []

    public static let helpText = """
    Usage: spice4mac [connection.vv | spice://host:port | --host HOST] [options]
      --tls-port PORT         Connect with TLS on every channel
      --port PORT --insecure  Explicitly allow plaintext SPICE
      --ca-file PATH          CA certificate file
      --cert-subject SUBJECT  Expected certificate subject
      --proxy URL             HTTP(S) SPICE proxy, without credentials
      --password-stdin        Read ticket from stdin (not process arguments)
      --no-clipboard         Disable text clipboard sharing (default: enabled)
      --no-audio             Disable audio output (default: enabled)
      --no-auto-resize       Disable automatic guest resolution
      --fullscreen           Start the session fullscreen
      --timeout SECONDS      Automation connection timeout
      --screenshot PATH      Save the remote framebuffer PNG
      --window-screenshot PATH Save the app window view for UI inspection
      --exit-after-connect   Exit after the automation connection check
      --validate             Validate settings and print redacted JSON
      --app PATH             Explicit Spice4Mac.app path (launcher only)
      --wait                 Compatibility flag; the launcher always waits
      --help / --version
    The launcher waits until the GUI exits and closes it when the session ends.
    Without a connection, opens the connection manager. Plaintext requires --insecure.
    """

    public static func parse(arguments: [String]) throws -> LaunchRequest {
        var request = LaunchRequest()
        var host: String?, port: Int?, tls: Int?, ca: String?, subject: String?, proxy: String?
        var insecure = false
        var clipboard: Bool?, audio: Bool?
        var source: String?
        var seen = Set<String>()
        var i = 0
        while i < arguments.count {
            let arg = arguments[i]; i += 1
            func next() throws -> String {
                guard i < arguments.count else { throw ConnectionError.invalid("Missing value for \(arg).") }
                defer { i += 1 }; return arguments[i]
            }
            if arg.hasPrefix("--") {
                guard seen.insert(arg).inserted else { throw ConnectionError.invalid("Duplicate option: \(arg).") }
            }
            switch arg {
            case "--help", "-h": request.help = true
            case "--version": request.version = true
            case "--host": host = try next()
            case "--port": port = try ConnectionOptions.parsePort(next())
            case "--tls-port": tls = try ConnectionOptions.parsePort(next())
            case "--ca-file": ca = try next()
            case "--cert-subject": subject = try next()
            case "--proxy": proxy = try next()
            case "--insecure": insecure = true
            case "--clipboard": clipboard = true
            case "--audio": audio = true
            case "--no-clipboard": clipboard = false
            case "--no-audio": audio = false
            case "--password-stdin": request.passwordFromStdin = true
            case "--connection-stdin": request.connectionFromStdin = true
            case "--wait": request.wait = true
            case "--app": request.appPath = try next()
            case "--validate": request.validateOnly = true
            case "--fullscreen", "--exit-after-connect", "--exit-on-disconnect", "--no-auto-resize": request.forwardedArguments.append(arg)
            case "--screenshot", "--window-screenshot": request.forwardedArguments += [arg, try next()]
            case "--timeout":
                let value = try next()
                guard let seconds = Double(value), seconds.isFinite, seconds > 0, seconds <= 86400 else { throw ConnectionError.invalid("Timeout must be greater than 0 and at most 86400 seconds.") }
                request.forwardedArguments += [arg, value]
            default:
                guard !arg.hasPrefix("-"), source == nil else { throw ConnectionError.invalid("Unknown option or multiple connection targets.") }
                source = arg
            }
        }
        if request.help || request.version { return request }
        guard !(request.connectionFromStdin && (source != nil || host != nil || port != nil || tls != nil || request.passwordFromStdin || insecure || ca != nil || subject != nil || proxy != nil || clipboard != nil || audio != nil)) else {
            throw ConnectionError.invalid("--connection-stdin cannot be combined with connection options.")
        }
        guard !(source != nil && host != nil) else { throw ConnectionError.invalid("Choose either a host or a connection file/URI.") }
        if let source {
            if source.hasPrefix("spice:") { request.options = try ConnectionOptions.fromURI(source) }
            else { request.options = try ConnectionOptions.fromVV(data: readLimited(file: URL(fileURLWithPath: source))) }
        } else if let host { request.options = ConnectionOptions(host: host) }
        if request.options != nil {
            if let port { request.options?.port = port }
            if let tls { request.options?.tlsPort = tls }
            if let ca { request.options?.caFile = ca; request.options?.caPEM = nil }
            if let subject { request.options?.certificateSubject = subject }
            if let proxy { request.options?.proxy = proxy }
            request.options?.insecure = insecure
            if let clipboard { request.options?.clipboard = clipboard }
            if let audio { request.options?.audio = audio }
        } else if !request.connectionFromStdin && (port != nil || tls != nil || ca != nil || subject != nil || proxy != nil || insecure || clipboard != nil || audio != nil || request.passwordFromStdin || request.validateOnly) {
            throw ConnectionError.invalid("A connection host, URI, or .vv file is required.")
        }
        return request
    }

    public func resolveConnection(stdin data: Data? = nil) throws -> ConnectionOptions? {
        var options = self.options
        if connectionFromStdin {
            guard let data, data.count <= 1_048_576 else { throw ConnectionError.invalid("Missing or oversized connection input.") }
            do { options = try JSONDecoder().decode(ConnectionOptions.self, from: data) }
            catch { throw ConnectionError.invalid("Invalid connection JSON on stdin.") }
        } else if passwordFromStdin {
            guard let data, data.count <= 4096, let ticket = String(data: data, encoding: .utf8), !ticket.contains("\0") else {
                throw ConnectionError.invalid("Ticket must be UTF-8 and no larger than 4096 bytes.")
            }
            var bytes = Array(ticket.utf8)
            if bytes.last == 10 { bytes.removeLast(); if bytes.last == 13 { bytes.removeLast() } }
            let ticketValue = String(decoding: bytes, as: UTF8.self)
            options?.password = ticketValue
        }
        try options?.validate()
        return options
    }
}

public func readLimited(handle: FileHandle, limit: Int = 1_048_576) throws -> Data {
    var data = Data()
    while true {
        let chunk = try handle.read(upToCount: min(16384, limit - data.count + 1)) ?? Data()
        if chunk.isEmpty { return data }
        data.append(chunk)
        guard data.count <= limit else { throw ConnectionError.invalid("Input exceeds the size limit.") }
    }
}

public func readLimited(file: URL, limit: Int = 1_048_576) throws -> Data {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    return try readLimited(handle: handle, limit: limit)
}
