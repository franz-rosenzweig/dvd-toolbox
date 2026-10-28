import AppKit
import Foundation
import Observation

/// One disc's worth of work: its titles encoded into the library's layout on this Mac, then sent to the
/// server and found in Jellyfin.
@Observable @MainActor
final class Job: Identifiable {
    struct Part: Identifiable, Codable, Equatable {
        enum State: String, Codable { case waiting, ripping, ripped, failed }
        var id: Int            // the title on the disc
        var seconds: Int
        var file: String       // relative to the library folder
        var label: String
        var title: DVDTitle.Stored
        var state = State.waiting
        var bytes: Int64 = 0
    }

    enum State: String, Codable { case waiting, ripping, ripped, queued, uploading, checking, done, sent, failed, cancelled }

    struct Record: Codable {
        var id: UUID
        var name: String
        var kind: String
        var parts: [Part]
        var extras: [String]
        var localRoot: String
        var library: String
        var serverFolder: String
        var jellyfinFolder: String
        var top: String
        var search: String
        var season: Int?
        var state: State
        var error: String?
        var upload: Bool
        var created: Date
    }

    let id: UUID
    var name: String
    var kind: Kind
    var parts: [Part]
    /// NFO and poster files, relative to the library folder.
    var extras: [String]
    var localRoot: URL
    var library: String
    var serverFolder: String
    var jellyfinFolder: String
    /// The movie's or show's folder, relative to the library folder.
    var top: String
    /// What Jellyfin is searched for to see the item arrive.
    var search: String
    var season: Int?
    var poster: Data?
    var input = ""
    var discID = ""
    var upload: Bool
    var created: Date

    var state = State.waiting
    var error: String?
    var current: Int?
    var fraction = 0.0
    var eta: Int?
    var sent = 0.0
    var rate = 0.0
    var tasks: [Task<Void, Never>] = []

    init(name: String, kind: Kind, parts: [Part], extras: [String], localRoot: URL, library: String, serverFolder: String,
         jellyfinFolder: String, top: String, search: String, season: Int?, upload: Bool) {
        id = UUID(); self.name = name; self.kind = kind; self.parts = parts; self.extras = extras; self.localRoot = localRoot
        self.library = library; self.serverFolder = serverFolder; self.jellyfinFolder = jellyfinFolder; self.top = top
        self.search = search; self.season = season; self.upload = upload; created = Date()
    }

    init(_ r: Record) {
        id = r.id; name = r.name; kind = Kind(rawValue: r.kind) ?? .movie; parts = r.parts; extras = r.extras
        localRoot = URL(fileURLWithPath: r.localRoot, isDirectory: true); library = r.library; serverFolder = r.serverFolder
        jellyfinFolder = r.jellyfinFolder; top = r.top; search = r.search; season = r.season; upload = r.upload; created = r.created
        error = r.error
        // what was running when the app quit stops where it was: a rip has to start again, an upload can go on
        switch r.state {
        case .waiting, .ripping: state = .cancelled
        case .queued, .uploading, .checking: state = .ripped
        default: state = r.state
        }
        poster = try? Data(contentsOf: localRoot.appendingPathComponent(top).appendingPathComponent("poster.jpg"))
    }

    var record: Record {
        Record(id: id, name: name, kind: kind.rawValue, parts: parts, extras: extras, localRoot: localRoot.path, library: library,
               serverFolder: serverFolder, jellyfinFolder: jellyfinFolder, top: top, search: search, season: season,
               state: state, error: error, upload: upload, created: created)
    }

    var active: Bool { [.waiting, .ripping, .queued, .uploading, .checking].contains(state) }
    var ripped: Int { parts.filter { $0.state == .ripped }.count }
    var bytes: Int64 { parts.reduce(0) { $0 + $1.bytes } }
    var folder: URL { localRoot.appendingPathComponent(top, isDirectory: true) }
    var files: [String] { parts.map(\.file) + extras }

    /// The overall share done: ripping is most of the time, the upload the rest.
    var progress: Double {
        let total = parts.reduce(0) { $0 + $1.seconds }
        guard total > 0 else { return 0 }
        let done = parts.filter { $0.state == .ripped }.reduce(0) { $0 + $1.seconds }
        let now = current.flatMap { c in parts.first { $0.id == c } }.map { Double($0.seconds) * fraction } ?? 0
        return (Double(done) + now) / Double(total)
    }

    func cancel() { for t in tasks { t.cancel() } }
}

extension DVDTitle {
    /// The title as a job keeps it, for a rip that is started again.
    struct Stored: Codable, Equatable {
        var index: Int
        var audio: [Int]
        var subtitles: [Int]
    }

    var stored: Stored { Stored(index: index, audio: audio.map(\.number), subtitles: subtitles.map(\.number)) }
}

/// The rips, one at a time off the one drive, and their uploads, one at a time, next to them.
@Observable @MainActor
final class Jobs {
    static let shared = Jobs()

    var list: [Job] = []
    private var ripTail: Task<Void, Never>?
    private var upTail: Task<Void, Never>?

    static var saved: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "xyz.tiresia.dvdtoolbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("jobs.json")
    }

    init() {
        if let d = try? Data(contentsOf: Self.saved), let rs = try? JSONDecoder().decode([Job.Record].self, from: d) {
            list = rs.map(Job.init)
        }
    }

    func save() {
        let rs = list.prefix(40).map(\.record)
        if let d = try? JSONEncoder().encode(Array(rs)) { try? d.write(to: Self.saved, options: .atomic) }
    }

    var running: Int { list.filter(\.active).count }

    func job(_ id: UUID) -> Job? { list.first { $0.id == id } }

    func remove(_ id: UUID) {
        guard let j = job(id), !j.active else { return }
        list.removeAll { $0.id == id }
        save()
    }

    /// Queues a rip; the upload follows it when asked for.
    func start(_ job: Job, poster: Data?, nfo: [String: String]) {
        list.insert(job, at: 0)
        let prevRip = ripTail, prevUp = upTail
        let rip = Task { @MainActor in
            await prevRip?.value
            await self.rip(job, poster: poster, nfo: nfo)
        }
        ripTail = rip
        let up = Task { @MainActor in
            await rip.value
            await prevUp?.value
            guard job.state == .queued else { return }
            if Task.isCancelled { job.state = .ripped; self.save() } else { await self.send(job) }
        }
        upTail = up
        job.tasks = [rip, up]
        save()
    }

    /// Sends a job that was ripped (or whose upload failed) again.
    func upload(_ job: Job) {
        guard !job.active else { return }
        job.upload = true
        job.error = nil
        job.state = .queued
        let prevUp = upTail
        let up = Task { @MainActor in
            await prevUp?.value
            if Task.isCancelled { job.state = .ripped; self.save() } else { await self.send(job) }
        }
        upTail = up
        job.tasks = [up]
    }

    // MARK: ripping

    private func rip(_ job: Job, poster: Data?, nfo: [String: String]) async {
        guard !Task.isCancelled else { job.state = .cancelled; save(); return }
        guard let hb = HandBrake.locate() else { return fail(job, "HandBrakeCLI is missing (brew install handbrake)") }
        job.state = .ripping
        Awake.shared.hold("Ripping a DVD")
        defer { Awake.shared.release() }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: job.folder, withIntermediateDirectories: true)
            if let poster { try poster.write(to: job.folder.appendingPathComponent("poster.jpg")) }
            for (file, text) in nfo { try Data(text.utf8).write(to: job.localRoot.appendingPathComponent(file)) }
            for i in job.parts.indices where job.parts[i].state != .ripped {
                try Task.checkCancellation()
                let p = job.parts[i]
                let dest = job.localRoot.appendingPathComponent(p.file)
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                let partial = dest.deletingLastPathComponent().appendingPathComponent("." + dest.lastPathComponent + ".part")
                try? fm.removeItem(at: partial)
                job.parts[i].state = .ripping
                job.current = p.id
                job.fraction = 0
                job.eta = nil
                let args = HandBrake.args(input: job.input, title: p.title, output: partial.path, encoder: Config.encoder)
                let split = LineSplitter()
                let o: Proc.Output
                do {
                    o = try await Proc.run(hb, args, onStdout: { data in
                        let lines = split.feed(data)
                        Task { @MainActor in
                            for l in lines { if let pr = HandBrake.progress(l) { job.fraction = pr.fraction; job.eta = pr.eta } }
                        }
                    })
                } catch {
                    try? fm.removeItem(at: partial)
                    throw error
                }
                if Task.isCancelled { try? fm.removeItem(at: partial); throw CancellationError() }
                let size = (try? fm.attributesOfItem(atPath: partial.path)[.size] as? Int64) ?? 0
                guard o.status == 0, size > 0 else {
                    try? fm.removeItem(at: partial)
                    job.parts[i].state = .failed
                    let why = o.errText.split(separator: "\n").last { $0.localizedCaseInsensitiveContains("error") || $0.contains("libdvd") }
                    throw AppError("\(p.label): " + (why.map(String.init) ?? "HandBrake exit \(o.status)"))
                }
                if Config.env("DVD_TEST_STOP_AT") == nil, let got = await Self.duration(partial), abs(got - Double(p.seconds)) > max(10, Double(p.seconds) * 0.03) {
                    try? fm.removeItem(at: partial)
                    job.parts[i].state = .failed
                    throw AppError("\(p.label): \(Fmt.clock(Int(got))) of \(Fmt.clock(p.seconds))")
                }
                try? fm.removeItem(at: dest)
                try fm.moveItem(at: partial, to: dest)
                job.parts[i].state = .ripped
                job.parts[i].bytes = size
                save()
            }
            job.current = nil
            job.state = job.upload ? .queued : .ripped
            save()
            if Prefs.ejectWhenDone { await DiscStore.shared.ejectIfStill(job.discID) }
            Nav.shared.notify("Ripped \(job.name)")
        } catch is CancellationError {
            job.current = nil
            job.state = .cancelled
            for i in job.parts.indices where job.parts[i].state == .ripping { job.parts[i].state = .waiting }
            save()
        } catch {
            job.current = nil
            fail(job, (error as? AppError)?.detail ?? error.localizedDescription)
        }
    }

    /// How long a file plays, by ffprobe.
    nonisolated static func duration(_ file: URL) async -> Double? {
        guard let probe = ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
              let o = try? await Proc.run(probe, ["-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", file.path]) else { return nil }
        return Double(o.text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func fail(_ job: Job, _ why: String) {
        job.state = .failed
        job.error = why
        save()
    }

    // MARK: sending

    private func send(_ job: Job) async {
        guard let remote = Config.remote else { return fail(job, "No server in Settings") }
        guard let rsync = await Rsync.locate() else { return fail(job, "rsync 3.1 or newer is missing (brew install rsync)") }
        job.state = .uploading
        job.error = nil
        job.sent = 0
        save()
        Awake.shared.hold("Uploading a rip")
        defer { Awake.shared.release() }
        do {
            let fm = FileManager.default
            let files = job.files.filter { fm.fileExists(atPath: job.localRoot.appendingPathComponent($0).path) }
            let need = files.reduce(Int64(0)) { $0 + ((try? fm.attributesOfItem(atPath: job.localRoot.appendingPathComponent($1).path)[.size] as? Int64) ?? 0) }
            let free = try await remote.free(job.serverFolder)
            guard free == 0 || free > need + 2_000_000_000 else { throw AppError("Server: \(Fmt.size(free)) free, \(Fmt.size(need)) needed") }
            // names on stdin; nothing already on the server is replaced (a second season leaves the show's NFO and poster as they are)
            let args = ["-rt", "--perms", "--chmod=D775,F664", "--files-from=-", "--partial", "--ignore-existing", "--info=progress2",
                        "--exclude=._*", "--exclude=.DS_Store", "-s", "-8", "-e", remote.sshCommand,
                        job.localRoot.path + "/", "\(remote.target):\(job.serverFolder)/"]
            let split = LineSplitter()
            let started = Date()
            let o = try await Proc.run(rsync, args, input: Data(files.map { $0 + "\n" }.joined().utf8), onStdout: { data in
                let lines = split.feed(data)
                Task { @MainActor in
                    for l in lines {
                        if let p = Rsync.progress(l), need > 0 {
                            job.sent = min(1, Double(p.bytes) / Double(need))
                            job.rate = Double(p.bytes) / max(1, Date().timeIntervalSince(started))
                        }
                    }
                }
            })
            try Task.checkCancellation()
            guard o.status == 0 else { throw AppError(o.errText.split(separator: "\n").first.map(String.init) ?? "rsync exit \(o.status)") }
            job.sent = 1
            job.state = .checking
            save()
            try await check(job)
            if !(UserDefaults.standard.object(forKey: "keepRips") as? Bool ?? true), job.state == .done {
                for f in job.parts.map(\.file) { try? fm.removeItem(at: job.localRoot.appendingPathComponent(f)) }
            }
        } catch is CancellationError {
            job.state = .ripped
            job.error = "Upload cancelled"
            save()
        } catch {
            job.state = .ripped
            job.error = (error as? AppError)?.detail ?? error.localizedDescription
            save()
        }
    }

    /// Tells Jellyfin about the folder, then waits for the movie or the episodes to show up there.
    private func check(_ job: Job) async throws {
        guard let jf = Config.jellyfin else { job.state = .sent; return }
        let folder = job.jellyfinFolder + "/" + job.top
        do { try await jf.created([folder]) } catch { try await jf.refreshAll() }
        let want = Set(job.parts.map { job.jellyfinFolder + "/" + $0.file })
        let wait = Double(Config.env("DVD_JELLYFIN_WAIT") ?? "") ?? 240
        let end = Date().addingTimeInterval(wait)
        var asked = false
        while Date() < end {
            try Task.checkCancellation()
            if try await arrived(job, jf: jf, folder: folder, want: want) { job.state = .done; save(); return }
            // a scan that did not pick it up within a minute: ask for a whole one, once
            if !asked, Date() > end.addingTimeInterval(-wait + 60) { asked = true; try? await jf.refreshAll() }
            try await Task.sleep(for: .seconds(4))
        }
        job.state = .sent
        save()
    }

    private func arrived(_ job: Job, jf: Jellyfin, folder: String, want: Set<String>) async throws -> Bool {
        if job.kind == .movie {
            let items = try await jf.items("Movie", search: job.search)
            return !want.isDisjoint(with: Set(items.map { $0.path.precomposedStringWithCanonicalMapping }))
        }
        guard let show = try await jf.items("Series", search: job.search).first(where: { $0.path.precomposedStringWithCanonicalMapping == folder }) else { return false }
        let eps = try await jf.episodes(series: show.id, season: job.season ?? 1)
        return want.isSubset(of: Set(eps.map { $0.path.precomposedStringWithCanonicalMapping }))
    }
}
