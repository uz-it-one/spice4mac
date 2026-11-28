import Foundation

/// Text fields of the connection screen. Converting here keeps the GUI, saved profiles and
/// their tests on one set of parsing and validation rules.
public struct ConnectionForm: Equatable, Sendable {
    public var host = ""
    public var port = "5900"
    public var tls = true
    public var ticket = ""
    public var caFile = ""
    /// Inline CA from an imported .vv file; used only while no CA path is entered.
    public var importedCA: String?
    public var subject = ""
    public var proxy = ""
    public var clipboard = true
    public var audio = true

    public init() {}

    public init(_ options: ConnectionOptions) {
        host = options.host
        port = String(options.tlsPort ?? options.port ?? 5900)
        tls = options.tlsPort != nil
        ticket = options.password ?? ""
        caFile = options.caFile ?? ""
        importedCA = options.caPEM
        subject = options.certificateSubject ?? ""
        proxy = options.proxy ?? ""
        clipboard = options.clipboard
        audio = options.audio
    }

    /// Validated options; throws `ConnectionError` with a user-facing message.
    public func connectionOptions() throws -> ConnectionOptions {
        let number = try ConnectionOptions.parsePort(port)
        let options = ConnectionOptions(host: host, port: tls ? nil : number, tlsPort: tls ? number : nil,
                                        password: ticket.nilIfEmpty, caFile: caFile.nilIfEmpty,
                                        caPEM: caFile.isEmpty ? importedCA : nil,
                                        certificateSubject: subject.nilIfEmpty, proxy: proxy.nilIfEmpty,
                                        insecure: !tls, clipboard: clipboard, audio: audio)
        try options.validate()
        return options
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
