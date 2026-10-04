import Foundation

/// Runs an executable by absolute path with no shell and a timeout.
enum Command {
    struct Output {
        var status: Int32
        /// Standard output only.
        var output: String
        var errors: String
        /// Output followed by any error text, for showing to the user.
        var combined: String { errors.isEmpty ? output : output + (output.isEmpty ? "" : "\n") + errors }
    }

    /// - Parameter environment: the full environment for the child. Empty by default.
    static func run(_ path: String, _ args: [String], environment: [String: String] = [:],
                    timeout: TimeInterval) -> Output {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.environment = environment
        p.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return Output(status: -1, output: error.localizedDescription, errors: "") }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        // Drain stderr concurrently so a chatty tool can't fill the pipe and stall.
        var errData = Data()
        let errDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            errDone.signal()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        errDone.wait()
        p.waitUntilExit()
        killer.cancel()
        return Output(status: p.terminationStatus,
                      output: String(decoding: data.prefix(1024 * 1024), as: UTF8.self),
                      errors: String(decoding: errData.prefix(64 * 1024), as: UTF8.self))
    }
}
