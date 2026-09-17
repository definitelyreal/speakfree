// ai-suggestion:unverified · session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 · 2026-09-08
import Foundation
import Darwin

/// A bounded runner for direct CLI tools. Nonblocking reads drain both pipes without
/// allocating reader threads that could remain stuck after a child inherits a pipe.
enum BoundedProcess {
    struct Output {
        let stdout: Data
        let stderr: Data
        let status: Int32
    }
    enum Failure: LocalizedError {
        case timedOut, outputTooLarge, pipeFailed(Int32)
        var errorDescription: String? {
            switch self {
            case .timedOut: return "Transcription helper timed out"
            case .outputTooLarge: return "Transcription helper exceeded its output limit"
            case .pipeFailed(let code): return "Transcription helper pipe failed (\(code))"
            }
        }
    }

    static func run(executable: URL, arguments: [String], timeout: TimeInterval,
                    maxOutputBytes: Int = 8 * 1024 * 1024) throws -> Output {
        guard timeout.isFinite, timeout > 0 else { throw Failure.timedOut }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let readers = [out.fileHandleForReading, err.fileHandleForReading]
        defer {
            for handle in readers { try? handle.close() }
            try? out.fileHandleForWriting.close()
            try? err.fileHandleForWriting.close()
        }
        for reader in readers {
            let fd = reader.fileDescriptor
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                throw Failure.pipeFailed(errno)
            }
        }
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        // Only the child should keep the write ends open, otherwise EOF never arrives.
        try? out.fileHandleForWriting.close()
        try? err.fileHandleForWriting.close()
        defer {
            if process.isRunning {
                process.terminate()
                if exited.wait(timeout: .now() + 0.2) == .timedOut, process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                    _ = exited.wait(timeout: .now() + 1)
                }
            }
        }
        var descriptors = readers.map { pollfd(fd: $0.fileDescriptor, events: Int16(POLLIN), revents: 0) }
        var data = [Data(), Data()]
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while process.isRunning || descriptors.contains(where: { $0.fd >= 0 }) {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw Failure.timedOut }
            let result = poll(&descriptors, nfds_t(descriptors.count), Int32(min(50, max(1, remaining * 1000))))
            if result < 0 {
                if errno == EINTR { continue }
                throw Failure.pipeFailed(errno)
            }
            for index in descriptors.indices where descriptors[index].fd >= 0 && descriptors[index].revents != 0 {
                // Bound each drain too: a continuously writing child must not prevent
                // the outer deadline check or starve the other pipe.
                for _ in 0..<16 {
                    let count = read(descriptors[index].fd, &buffer, buffer.count)
                    if count == 0 { descriptors[index].fd = -1; break }
                    if count < 0 {
                        if errno == EAGAIN || errno == EINTR { break }
                        throw Failure.pipeFailed(errno)
                    }
                    guard data[0].count + data[1].count + count <= maxOutputBytes else {
                        throw Failure.outputTooLarge
                    }
                    data[index].append(contentsOf: buffer.prefix(count))
                }
            }
        }
        return Output(stdout: data[0], stderr: data[1], status: process.terminationStatus)
    }
}
