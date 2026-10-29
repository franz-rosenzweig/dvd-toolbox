import AppKit
import Foundation
import Observation

/// The DVD in the drive: what HandBrake finds on it, what TMDB says it is, where it goes in the library,
/// and what of it is already on the server.
@Observable @MainActor
final class DiscStore {
    static let shared = DiscStore()

    struct Folders: Equatable { var server: String; var jellyfin: String }

    var disc: DVDDisc?
    var scan: DVDScan?
    var scanning = false
    var looking = false
    var error: String?
    var hint = LabelHint(query: "", season: nil, disc: nil)

    var kind = Kind.movie
    var query = ""
    var year = ""
    var results: [TMDBItem] = []
    var chosen: Int?
    var poster: Data?
    var seasons = 1
    var season = 1
    var firstEpisode = 1
    var episodes: [TMDBEpisode] = []
    /// TV: the titles to rip, by their number on the disc.
    var selected: Set<Int> = []
    /// Movie: the title that is the film.
    var feature: Int?

    var libraries: [Jellyfin.Library] = []
    var movieLibrary = UserDefaults.standard.string(forKey: "movieLibrary") ?? ""
    var tvLibrary = UserDefaults.standard.string(forKey: "tvLibrary") ?? ""
    var folders: [String: Folders] = [:]
    /// The movie's or show's folder when the server already has it.
    var existing: String?
    /// Episodes of this season already on the server.
    var present: Set<Int> = []
    var checking = false
    var serverError: String?
    var jellyfinError: String?

    /// Set by the self-test to show a disc that is not in the drive.
    var frozen = false
    private var started = false
    private var observers: [NSObjectProtocol] = []
    private var scanTask: Task<Void, Never>?

    init() {
        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in await self?.look() } })
        }
    }

    var item: TMDBItem? { results.first { $0.id == chosen } }
    var titles: [DVDTitle] { (scan?.titles ?? []).sorted { $0.index < $1.index } }
    var libraryID: String { kind == .movie ? movieLibrary : tvLibrary }
    var library: Jellyfin.Library? { libraries.first { $0.id == libraryID } }
    var choices: [Jellyfin.Library] { libraries.filter { $0.takes.contains(kind) } }
    /// The rip running for this disc, if one is.
    var job: Job? { disc.flatMap { d in Jobs.shared.list.first { $0.discID == d.id && ($0.state == .ripping || $0.state == .waiting) } } }

    // MARK: the disc

    /// Looks for a disc, and reads a new one.
    func look() async {
        guard !frozen else { return }
        let d = await Task.detached { DVDDisc.find() }.value
        guard d?.id != disc?.id else { started = true; return }
        if d == nil, job != nil { return }
        load(d)
        // a disc that has just been put in (not one already there when the app started)
        if d != nil, started, Prefs.openForDiscs { Nav.shared.arrive(.disc) }
        started = true
    }

    /// Shows a disc (or none) and reads it: HandBrake's titles, then TMDB.
    func load(_ d: DVDDisc?, minimum: Int = 120) {
        scanTask?.cancel()
        disc = d
        scan = nil; results = []; chosen = nil; poster = nil; episodes = []; selected = []; feature = nil; runtime = nil; featureByHand = false
        existing = nil; present = []; error = nil; serverError = nil
        guard let d else { return }
        hint = LabelHint.parse(d.label)
        query = hint.query
        year = ""
        season = hint.season ?? 1
        scanTask = Task {
            scanning = true
            defer { scanning = false }
            do {
                var s = try await HandBrake.scan(d.input, minimum: minimum)
                s.layout = await Task.detached { IFO.layouts(d.volume.appendingPathComponent("VIDEO_TS", isDirectory: true)) }.value
                guard disc?.id == d.id else { return }
                scan = s
                kind = Pick.guess(s, hint: hint)
                pickTitles()
            } catch is CancellationError { return } catch {
                self.error = (error as? AppError)?.detail ?? error.localizedDescription
            }
            await search()
        }
    }

    /// TMDB's running time of the chosen film.
    var runtime: Int?
    /// Set when the owner picks the film's title, so a lookup does not change it back.
    var featureByHand = false

    func pickTitles() {
        guard let scan else { return }
        if !featureByHand { feature = Pick.feature(scan, runtime: runtime)?.index }
        let eps = Pick.episodes(scan.titles, layout: scan.layout)
        selected = Set((eps.isEmpty ? Pick.distinct(scan.titles) : eps).map(\.index))
    }

    func setKind(_ k: Kind) async {
        guard k != kind else { return }
        kind = k
        results = []; chosen = nil; poster = nil; episodes = []; existing = nil; present = []
        await search()
    }

    func eject() async {
        guard let v = disc?.volume, job == nil else { return }
        do { try NSWorkspace.shared.unmountAndEjectDevice(at: v) } catch { self.error = "Couldn’t eject" }
        await look()
    }

    /// Ejects the disc a rip was made from, when it is still the one in the drive.
    func ejectIfStill(_ id: String) async {
        guard let d = disc, d.id == id, !frozen else { return }
        try? NSWorkspace.shared.unmountAndEjectDevice(at: d.volume)
        await look()
    }

    // MARK: TMDB

    func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        looking = true
        defer { looking = false }
        do {
            var r = try await TMDB.search(q, kind: kind, year: year.isEmpty ? nil : year)
            if r.isEmpty, !year.isEmpty { r = try await TMDB.search(q, kind: kind) }
            results = r
            error = r.isEmpty ? "Not on TMDB" : nil
            if let first = r.first { await choose(first.id) } else { chosen = nil; poster = nil }
        } catch {
            self.error = because(error, "Can’t reach TMDB")
        }
    }

    func choose(_ id: Int) async {
        guard let it = results.first(where: { $0.id == id }) else { return }
        chosen = id
        poster = nil
        if it.kind == .tv {
            seasons = max(1, (try? await TMDB.seasons(it.id)) ?? 1)
            season = min(max(1, season), seasons)
            await loadSeason()
        } else {
            // the film's running time picks its title when the disc carries decoys of other lengths
            runtime = await TMDB.runtime(it.id)
            if chosen == id, !featureByHand, let scan { feature = Pick.feature(scan, runtime: runtime)?.index }
            await checkServer()
        }
        if chosen == id, let p = it.poster { poster = await TMDB.poster(p) }
    }

    func setSeason(_ n: Int) async {
        season = n
        await loadSeason()
    }

    private func loadSeason() async {
        guard let it = item, it.kind == .tv else { return }
        episodes = (try? await TMDB.season(it.id, season)) ?? []
        await checkServer()
    }

    // MARK: Jellyfin and the server

    func loadLibraries() async {
        guard let jf = Config.jellyfin else { return }
        do {
            libraries = try await jf.libraries()
            jellyfinError = nil
            for k in Kind.allCases {
                let own = libraries.filter { $0.takes.contains(k) }
                let current = k == .movie ? movieLibrary : tvLibrary
                guard !own.contains(where: { $0.id == current }), let pick = own.first(where: { $0.name == (k == .movie ? "Movies" : "Shows") }) ?? own.first(where: { $0.kind != "" }) ?? own.first else { continue }
                setLibrary(pick.id, for: k)
            }
        } catch {
            jellyfinError = because(error, "Can’t reach Jellyfin")
        }
    }

    func setLibrary(_ id: String, for k: Kind) {
        if k == .movie { movieLibrary = id; UserDefaults.standard.set(id, forKey: "movieLibrary") }
        else { tvLibrary = id; UserDefaults.standard.set(id, forKey: "tvLibrary") }
    }

    /// The library's folder on the server, found from Jellyfin's own path: "/data/media/films" in the
    /// container is "/srv/media/films" when the media folder is "/srv/media".
    func folders(for lib: Jellyfin.Library) async throws -> Folders {
        if let f = folders[lib.id] { return f }
        guard let remote = Config.remote else { throw AppError("No server in Settings") }
        for loc in lib.locations {
            let parts = loc.split(separator: "/").map(String.init)
            var candidates: [String] = []
            for k in 1...max(1, parts.count) { candidates.append(remote.mediaPath + "/" + parts.suffix(k).joined(separator: "/")) }
            candidates.append(loc)
            if let found = try await remote.firstFolder(candidates) {
                let f = Folders(server: found, jellyfin: loc)
                folders[lib.id] = f
                return f
            }
        }
        throw AppError("\(lib.name): folder not found on the server")
    }

    /// The choice the first episode was last worked out for.
    private var numbered: String?
    private var stamp: String { "\(item?.id ?? 0)|\(kind.rawValue)|\(season)|\(library?.id ?? "")" }

    /// What of this title the server already has: its folder, and for a season which episodes.
    func checkServer() async {
        guard let it = item, let lib = library, let remote = Config.remote else { return }
        let want = stamp
        checking = true
        defer { checking = false }
        do {
            let f = try await folders(for: lib)
            let names = try await remote.list(f.server)
            // the choice changed while the server answered: that check is the one that counts
            guard want == stamp else { return }
            existing = Naming.match(names, title: it.title, year: it.year)
            present = []
            if kind == .tv, let top = existing {
                let files = try await remote.list(f.server + "/" + top + "/" + Naming.season(season))
                present = Naming.episodes(in: files, season: season)
            }
            serverError = nil
        } catch {
            serverError = because(error, "Can’t reach the server")
            // asked again while the server is away: a first episode set by hand stays as it is
            if numbered == want { return }
        }
        numbered = want
        if kind == .tv {
            let n = max(1, selected.count)
            if let last = present.max() { firstEpisode = last + 1 }
            else if let d = hint.disc, d > 1 { firstEpisode = (d - 1) * n + 1 }
            else { firstEpisode = 1 }
        }
    }

    // MARK: the plan

    /// The movie's or show's folder in the library.
    var top: String? {
        guard let it = item else { return nil }
        return existing ?? Naming.folder(it.title, it.year)
    }

    /// The episode number each selected title gets.
    var numbers: [Int: Int] {
        var out: [Int: Int] = [:]
        for (k, t) in titles.filter({ selected.contains($0.index) }).enumerated() { out[t.index] = firstEpisode + k }
        return out
    }

    func episodeName(_ n: Int) -> String { episodes.first { $0.number == n }?.name ?? "" }

    var parts: [Job.Part] {
        guard let it = item, let top else { return [] }
        if kind == .movie {
            guard let t = titles.first(where: { $0.index == feature }) else { return [] }
            // a folder the library already has keeps what is in it: this rip goes next to it as the DVD version
            let file = existing == nil ? top + ".mkv" : top + " - DVD.mkv"
            return [Job.Part(id: t.index, seconds: t.seconds, file: top + "/" + file, label: Naming.folder(it.title, it.year), title: t.stored)]
        }
        let nums = numbers
        return titles.filter { selected.contains($0.index) }.map { t in
            let e = nums[t.index] ?? 1
            let name = episodeName(e)
            return Job.Part(id: t.index, seconds: t.seconds,
                            file: top + "/" + Naming.season(season) + "/" + Naming.episodeFile(it.title, season: season, episode: e, name: name),
                            label: Naming.episodeCode(season, e) + (name.isEmpty ? "" : " · " + name), title: t.stored)
        }
    }

    var ready: Bool { disc != nil && scan != nil && item != nil && library != nil && !parts.isEmpty && job == nil }

    func rip(upload: Bool) async {
        guard let d = disc, let it = item, let lib = library, let top else { return }
        let parts = self.parts
        guard !parts.isEmpty else { return }
        do {
            let f = try await folders(for: lib)
            var extras: [String] = []
            var nfo: [String: String] = [:]
            // a new folder gets the NFO that pins it to TMDB, and the poster; one the server has is left as it is
            if existing == nil || kind == .tv {
                let ids = await TMDB.ids(it)
                let name = kind == .movie ? top + "/movie.nfo" : top + "/tvshow.nfo"
                nfo[name] = Naming.nfo(it, ids: ids)
                extras.append(name)
                if poster != nil { extras.append(top + "/poster.jpg") }
            }
            let name = kind == .movie ? top : "\(top) · \(Naming.season(season))"
            let job = Job(name: name, kind: kind, parts: parts, extras: extras,
                          localRoot: Config.ripsFolder.appendingPathComponent(Naming.clean(lib.name), isDirectory: true),
                          library: lib.name, serverFolder: f.server, jellyfinFolder: f.jellyfin, top: top,
                          search: it.title, season: kind == .tv ? season : nil, upload: upload)
            job.input = d.input
            job.discID = d.id
            job.poster = poster
            Jobs.shared.start(job, poster: poster, nfo: nfo)
        } catch {
            self.error = (error as? AppError)?.detail ?? error.localizedDescription
        }
    }
}
