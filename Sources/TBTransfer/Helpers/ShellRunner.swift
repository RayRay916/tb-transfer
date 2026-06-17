import Foundation
import Darwin

/// Thin wrapper over Foundation.Process for shelling out. Async-friendly.
enum ShellRunner {
    struct Result: Sendable {
        let exitCode: Int32
        let stdout: String
        let stderr: String

        var ok: Bool { exitCode == 0 }
    }

    /// SIGTERM may be ignored when rsync/ssh is blocked in a syscall. Follow up
    /// with SIGKILL after `afterSec` so cancellation never hangs. Safe to call
    /// when the process is already gone; the kill() will just return -1/ESRCH.
    fileprivate static func escalateTerminate(_ process: Process, afterSec: TimeInterval = 2.0) {
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + afterSec) {
            // Process is class-Sendable in practice (we just read isRunning, which is atomic
            // wrt the kernel). Use kill() directly to avoid touching Foundation from the
            // deadline thread once the kernel reaped the child.
            if process.isRunning {
                _ = kill(pid, SIGKILL)
            }
        }
    }

    /// Run a command-line invocation and collect stdout/stderr as strings.
    /// `args` is a complete argv. Use `env` to inject vars (merged with parent env).
    static func run(
        _ executable: String,
        _ args: [String],
        env: [String: String] = [:],
        currentDirectory: String? = nil,
        stdin: String? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> Result {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Result, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let outPipe = Pipe()
                let errPipe = Pipe()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = args
                process.standardOutput = outPipe
                process.standardError = errPipe
                if !env.isEmpty {
                    var merged = ProcessInfo.processInfo.environment
                    for (k, v) in env { merged[k] = v }
                    process.environment = merged
                }
                if let cwd = currentDirectory {
                    process.currentDirectoryURL = URL(fileURLWithPath: cwd)
                }
                if let stdin {
                    let inPipe = Pipe()
                    process.standardInput = inPipe
                    do {
                        try inPipe.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
                        try inPipe.fileHandleForWriting.close()
                    } catch {
                        cont.resume(throwing: error)
                        return
                    }
                }

                do {
                    try process.run()
                } catch {
                    cont.resume(throwing: error)
                    return
                }

                if let timeout {
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                        if process.isRunning {
                            process.terminate()
                            escalateTerminate(process)
                        }
                    }
                }

                process.waitUntilExit()
                let stdoutData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
                let stderrData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
                cont.resume(returning: Result(
                    exitCode: process.terminationStatus,
                    stdout: String(decoding: stdoutData, as: UTF8.self),
                    stderr: String(decoding: stderrData, as: UTF8.self)
                ))
            }
        }
    }

    /// Run a command and stream stdout lines via the given handler. Returns the final result.
    /// Useful for parsing rsync progress in real time.
    static func runStreaming(
        _ executable: String,
        _ args: [String],
        env: [String: String] = [:],
        currentDirectory: String? = nil,
        onStdoutLine: @escaping @Sendable (String) -> Void,
        onStderrLine: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> Int32 {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let outPipe = Pipe()
                let errPipe = Pipe()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = args
                process.standardOutput = outPipe
                process.standardError = errPipe
                if !env.isEmpty {
                    var merged = ProcessInfo.processInfo.environment
                    for (k, v) in env { merged[k] = v }
                    process.environment = merged
                }
                if let cwd = currentDirectory {
                    process.currentDirectoryURL = URL(fileURLWithPath: cwd)
                }

                let outHandle = outPipe.fileHandleForReading
                let errHandle = errPipe.fileHandleForReading

                outHandle.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty else { return }
                    let text = String(decoding: data, as: UTF8.self)
                    text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
                        .forEach { onStdoutLine(String($0)) }
                }
                errHandle.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty else { return }
                    let text = String(decoding: data, as: UTF8.self)
                    text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
                        .forEach { onStderrLine(String($0)) }
                }

                do { try process.run() } catch {
                    cont.resume(throwing: error)
                    return
                }
                process.waitUntilExit()
                outHandle.readabilityHandler = nil
                errHandle.readabilityHandler = nil
                cont.resume(returning: process.terminationStatus)
            }
        }
    }
}
