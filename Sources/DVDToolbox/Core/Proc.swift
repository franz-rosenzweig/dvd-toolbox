import Foundation

/// Runs a program and waits for it; cancelling the task stops the program.
enum Proc {
    struct Output: Sendable {
        var status: Int32
        var stdout: Data
        var stderr: Data
        var text: String { String(decoding: stdout, as: UTF8.self) }
        var errText: String { String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func add(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
        var value: Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    static func run(_ exe: String, _ args: [String], input: Data? = nil, env: [String: String] = [:],
                    onStdout: (@Sendable (Data) -> Void)? = nil, onStderr: (@Sendable (Data) -> Void)? = nil) async throws -> Output {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if !env.isEmpty { p.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new } }
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = input == nil ? FileHandle.nullDevice : inp
        let outSink = Sink(), errSink = Sink()
        let group = DispatchGroup()
        func pump(_ fh: FileHandle, _ sink: Sink, _ also: (@Sendable (Data) -> Void)?) {
            group.enter()
            DispatchQueue.global().async {
                while true {
                    let d = fh.availableData
                    if d.isEmpty { break }
                    sink.add(d)
                    also?(d)
                }
                group.leave()
            }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Output, Error>) in
                p.terminationHandler = { proc in
                    // the pipes close with the program; a stray child that keeps one open must not hold us
                    _ = group.wait(timeout: .now() + 2)
                    cont.resume(returning: Output(status: proc.terminationStatus, stdout: outSink.value, stderr: errSink.value))
                }
                do { try p.run() } catch { cont.resume(throwing: error); return }
                pump(out.fileHandleForReading, outSink, onStdout)
                pump(err.fileHandleForReading, errSink, onStderr)
                if let input {
                    inp.fileHandleForWriting.write(input)
                    try? inp.fileHandleForWriting.close()
                }
            }
        } onCancel: {
            if p.isRunning { p.terminate() }
        }
    }
}

/// Cuts a stream into lines at \n and \r (HandBrake and rsync redraw their progress with \r).
final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func feed(_ d: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        buffer.append(d)
        var lines: [String] = []
        while let i = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let line = buffer[buffer.startIndex..<i]
            buffer = Data(buffer[buffer.index(after: i)...])
            if !line.isEmpty { lines.append(String(decoding: line, as: UTF8.self)) }
        }
        return lines
    }
}

/// The library on the server, reached with ssh and rsync. Names travel on stdin, never in arguments:
/// Foundation turns an argument like "Amélie" into decomposed Unicode, and the server has the composed one.
struct Remote: Sendable {
    var target: String
    var mediaPath: String

    static var sshExe: String { ProcessInfo.processInfo.environment["DVD_SSH"] ?? "/usr/bin/ssh" }

    /// BatchMode: the app cannot answer a password prompt, so a key must do the work.
    static let sshOptions = ["-o", "BatchMode=yes", "-o", "ControlMaster=auto", "-o", "ControlPath=/tmp/dt-%C",
                             "-o", "ControlPersist=120", "-o", "ConnectTimeout=10"]

    var sshCommand: String { ([Remote.sshExe] + Remote.sshOptions).joined(separator: " ") }

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Runs a shell script on the server, sent on stdin so the names in it stay as they are.
    func script(_ text: String) async throws -> Proc.Output {
        try await Proc.run(Remote.sshExe, Remote.sshOptions + [target, "sh -s"], input: Data(text.utf8))
    }

    /// The names in a folder on the server (none when it is not there).
    func list(_ folder: String) async throws -> [String] {
        let o = try await script("cd \(Remote.quote(folder)) 2>/dev/null && ls -1A\n")
        guard o.status == 0 || o.status == 1 else { throw AppError(o.errText.isEmpty ? "ssh exit \(o.status)" : o.errText) }
        return o.text.split(separator: "\n").map(String.init)
    }

    /// The first of these folders that is there.
    func firstFolder(_ candidates: [String]) async throws -> String? {
        let body = candidates.map { "if [ -d \(Remote.quote($0)) ]; then echo \(Remote.quote($0)); exit 0; fi" }.joined(separator: "\n")
        let o = try await script(body + "\nexit 0\n")
        guard o.status == 0 else { throw AppError(o.errText.isEmpty ? "ssh exit \(o.status)" : o.errText) }
        let s = o.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    /// Free space where the library is, in bytes.
    func free(_ folder: String) async throws -> Int64 {
        let o = try await script("df -Pk \(Remote.quote(folder)) | awk 'NR==2 {print $4}'\n")
        return (Int64(o.text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) * 1024
    }
}

/// rsync 3.1 or newer: Homebrew's. Apple's openrsync has neither --info nor octal --chmod.
enum Rsync {
    nonisolated(unsafe) private static var found: String??

    static func locate() async -> String? {
        if let found { return found }
        var candidates = ["/opt/homebrew/bin/rsync", "/usr/local/bin/rsync"]
        if let e = ProcessInfo.processInfo.environment["DVD_RSYNC"] { candidates.insert(e, at: 0) }
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            guard let o = try? await Proc.run(c, ["--version"]),
                  let m = o.text.firstMatch(of: #/version (\d+)\.(\d+)/#), let major = Int(m.1), let minor = Int(m.2) else { continue }
            if major > 3 || (major == 3 && minor >= 1) { found = .some(c); return c }
        }
        found = .some(nil)
        return nil
    }

    /// "  1,234,567  45%  12.34MB/s  0:00:12 (xfr#3, to-chk=7/20)"
    static func progress(_ line: String) -> (bytes: Int64, percent: Int)? {
        guard let m = line.firstMatch(of: #/^\s*([\d,]+)\s+(\d+)%/#) else { return nil }
        return (Int64(m.1.replacingOccurrences(of: ",", with: "")) ?? 0, Int(m.2) ?? 0)
    }
}
