import Foundation
import ConnectionCore
import Darwin

func locateApp(_ explicit: String?) throws -> URL {
    let fm = FileManager.default
    var candidates: [URL] = []
    if let explicit { candidates = [URL(fileURLWithPath: explicit)] }
    else {
        let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).standardizedFileURL.resolvingSymlinksInPath()
        let folder = executable.deletingLastPathComponent()
        candidates = [folder.appendingPathComponent("Spice4Mac.app"),
                      folder.deletingLastPathComponent().appendingPathComponent("Spice4Mac.app"),
                      URL(fileURLWithPath: "/Applications/Spice4Mac.app"),
                      fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Spice4Mac.app")]
    }
    for app in candidates {
        let binary = app.appendingPathComponent("Contents/MacOS/Spice4MacApp")
        if fm.isExecutableFile(atPath: binary.path) { return binary }
    }
    throw ConnectionError.invalid("Spice4Mac.app was not found. Place it beside this launcher or use --app PATH.")
}

do {
    let request = try LaunchRequest.parse(arguments: Array(CommandLine.arguments.dropFirst()))
    if request.help { print(LaunchRequest.helpText); exit(0) }
    if request.version { print("spice4mac \(AppVersion.current)"); exit(0) }
    let input: Data? = request.passwordFromStdin || request.connectionFromStdin
        ? try readLimited(handle: .standardInput, limit: request.passwordFromStdin ? 4096 : 1_048_576) : nil
    let options = try request.resolveConnection(stdin: input)
    if request.validateOnly {
        guard let options else { throw ConnectionError.invalid("A connection is required for validation.") }
        FileHandle.standardOutput.write(try options.redactedJSON()); print(""); exit(0)
    }
    let process = Process()
    process.executableURL = try locateApp(request.appPath)
    var arguments = request.forwardedArguments
    if !arguments.contains("--exit-on-disconnect") { arguments.append("--exit-on-disconnect") }
    let pipe = Pipe()
    let payload: Data?
    if let options {
        arguments.insert("--connection-stdin", at: 0)
        payload = try JSONEncoder().encode(options)
        process.standardInput = pipe
    } else { payload = nil; process.standardInput = FileHandle.nullDevice }
    process.arguments = arguments
    try process.run()
    if let payload {
        try pipe.fileHandleForReading.close()
        try pipe.fileHandleForWriting.write(contentsOf: payload)
        try pipe.fileHandleForWriting.close()
    }
    process.waitUntilExit()
    exit(process.terminationReason == .exit ? process.terminationStatus : 128 + process.terminationStatus)
} catch {
    FileHandle.standardError.write(Data("spice4mac: \(error.localizedDescription)\n".utf8))
    exit(64)
}
