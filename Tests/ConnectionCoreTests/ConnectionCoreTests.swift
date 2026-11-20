import XCTest
@testable import ConnectionCore

final class ConnectionCoreTests: XCTestCase {
    func testPlaintextRequiresExplicitConsent() throws {
        let request = try LaunchRequest.parse(arguments: ["--host", "localhost", "--port", "5900"])
        XCTAssertThrowsError(try request.resolveConnection())
        let allowed = try LaunchRequest.parse(arguments: ["--host", "localhost", "--port", "5900", "--insecure"])
        XCTAssertTrue(try XCTUnwrap(allowed.resolveConnection()).insecure)
    }

    func testVVPreservesSecurityAndUnescapesCA() throws {
        let file = """
        [virt-viewer]
        type=spice
        host=vm.example
        port=-1
        tls-port=5901
        password=secret
        ca=one\\ntwo\\n
        host-subject=CN=vm.example
        secure-channels=all
        delete-this-file=1
        """
        let options = try ConnectionOptions.fromVV(data: Data(file.utf8))
        try options.validate()
        XCTAssertEqual(options.caPEM, "one\ntwo\n")
        XCTAssertNil(options.port)
        XCTAssertEqual(options.tlsPort, 5901)
        XCTAssertEqual(options.certificateSubject, "CN=vm.example")
        XCTAssertFalse(String(decoding: try options.redactedJSON(), as: UTF8.self).contains("secret"))
    }

    func testVVRejectsUnknownSecurityOptionsAndDuplicateKeys() {
        for extra in ["host=other", "disable-channels=main", "username=admin", "secure-channels=main", "ca=bad\\x"] {
            let file = "[virt-viewer]\ntype=spice\nhost=example\ntls-port=5901\n\(extra)\n"
            XCTAssertThrowsError(try ConnectionOptions.fromVV(data: Data(file.utf8)), extra)
        }
    }

    func testHostileFilesRejected() {
        XCTAssertThrowsError(try ConnectionOptions.fromVV(data: Data(repeating: 65, count: 1_048_577)))
        XCTAssertThrowsError(try ConnectionOptions.fromVV(data: Data([0xff])))
        XCTAssertThrowsError(try ConnectionOptions.fromVV(data: Data("[virt-viewer]\ntype=vnc\nhost=x\n".utf8)))
    }

    func testURIAndIPv6() throws {
        let request = try LaunchRequest.parse(arguments: ["spice://[::1]?tls-port=5901"])
        let options = try XCTUnwrap(request.resolveConnection())
        XCTAssertEqual(options.host, "::1")
        XCTAssertEqual(options.tlsPort, 5901)
        for uri in ["spice://user:secret@host:5900", "spice://host?password=secret", "spice://host?tls-port=5901&tls-port=5902", "spice://host/path"] {
            XCTAssertThrowsError(try ConnectionOptions.fromURI(uri))
        }
    }

    func testSecretPipeAndRoundTrip() throws {
        let request = try LaunchRequest.parse(arguments: ["--host", "example", "--tls-port", "5901", "--password-stdin"])
        let options = try XCTUnwrap(request.resolveConnection(stdin: Data("secret\r\n".utf8)))
        XCTAssertEqual(options.password, "secret")
        let child = try LaunchRequest.parse(arguments: ["--connection-stdin", "--timeout", "5", "--exit-after-connect"])
        XCTAssertEqual(try child.resolveConnection(stdin: JSONEncoder().encode(options)), options)
        XCTAssertEqual(child.forwardedArguments, ["--timeout", "5", "--exit-after-connect"])
        XCTAssertThrowsError(try child.resolveConnection(stdin: Data("{}".utf8)))
    }

    func testConflictingAndInvalidArguments() {
        for args in [["--host"], ["--host", "a", "--host", "b"], ["--host", "x", "--port", "65536"], ["--connection-stdin", "--host", "x"], ["--timeout", "nan"], ["--timeout", "-1"], ["--password", "secret"], ["--validate"]] {
            XCTAssertThrowsError(try LaunchRequest.parse(arguments: args), args.joined(separator: " "))
        }
        XCTAssertThrowsError(try ConnectionOptions(host: "x", tlsPort: 5901, insecure: true).validate())
    }

    func testProxyRejectsCredentialsAndPaths() {
        for url in ["http://user:secret@proxy:3128", "http://proxy/command", "file:///tmp/a", "http://proxy?q=a"] {
            XCTAssertThrowsError(try ConnectionOptions(host: "x", tlsPort: 5901, proxy: url).validate())
        }
    }

    func testSessionDefaultsAndOptOut() throws {
        let args = ["--host", "localhost", "--port", "5900", "--insecure"]
        let request = try LaunchRequest.parse(arguments: args)
        let defaults = try XCTUnwrap(request.resolveConnection())
        XCTAssertTrue(request.wait)
        XCTAssertTrue(defaults.clipboard)
        XCTAssertTrue(defaults.audio)
        let disabled = try LaunchRequest.parse(arguments: args + ["--no-clipboard", "--no-audio", "--no-auto-resize"])
        XCTAssertFalse(try XCTUnwrap(disabled.resolveConnection()).clipboard)
        XCTAssertFalse(try XCTUnwrap(disabled.resolveConnection()).audio)
        XCTAssertEqual(disabled.forwardedArguments, ["--no-auto-resize"])
        let vv = try ConnectionOptions.fromVV(data: Data("[virt-viewer]\ntype=spice\nhost=example\ntls-port=5901\n".utf8))
        XCTAssertTrue(vv.clipboard)
        XCTAssertTrue(vv.audio)
    }

    func testBoundedReader() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(repeating: 65, count: 12).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        XCTAssertThrowsError(try readLimited(file: path, limit: 10))
        XCTAssertEqual(try readLimited(file: path, limit: 12).count, 12)
    }
}
