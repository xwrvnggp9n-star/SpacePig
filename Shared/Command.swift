import Foundation

/// Runs an executable by absolute path with no shell and a timeout.
enum Command {
    struct Output { var status: Int32; var output: String }

    /// - Parameter environment: the full environment for the child. Empty by default.
    static func run(_ path: String, _ args: [String], environment: [String: String] = [:],
                    timeout: TimeInterval) -> Output {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.environment = environment
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return Output(status: -1, output: error.localizedDescription) }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        let text = String(decoding: data.prefix(256 * 1024), as: UTF8.self)
        return Output(status: p.terminationStatus, output: text)
    }
}
