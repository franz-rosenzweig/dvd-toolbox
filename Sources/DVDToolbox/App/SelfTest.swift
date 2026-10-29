import SwiftUI
import AppKit

/// The self-test (selftest.sh): DVD_SELFTEST=<folder>. It drives the same calls the buttons make,
/// against a stand-in for TMDB and Jellyfin (their documented answers, over a pretend library), a
/// pretend server for rsync (a folder, and an ssh that runs on this Mac), and folders of video files
/// HandBrake reads as discs. The shell script then checks the files.
/// Env: DVD_TEST_TV and DVD_TEST_MOVIE (folders HandBrake scans as a TV disc and a movie disc),
/// DVD_TEST_SERVER (the pretend server's media folder), DVD_TEST_REAL (the disc in the drive instead:
/// read, matched and the first minute ripped, never uploaded).
@MainActor
enum SelfTest {
    static var failures = 0
    static var out = URL(fileURLWithPath: NSTemporaryDirectory())
    static let env = ProcessInfo.processInfo.environment

    static func run(out folder: URL) async {
        out = folder
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try? "".write(to: out.appendingPathComponent("log.txt"), atomically: true, encoding: .utf8)
        log("SELFTEST")
        guard await until(15, { window != nil }) else { check(false, "the window opens"); return finish() }
        window?.setContentSize(NSSize(width: 980, height: 680))
        window?.center()
        UserDefaults.standard.set(false, forKey: "ejectWhenDone")      // a test never ejects the owner's disc
        DiscStore.shared.frozen = true
        units()
        if env["DVD_TEST_REAL"] != nil { await real(); return finish() }
        if let tv = env["DVD_TEST_TV"], let movie = env["DVD_TEST_MOVIE"], let server = env["DVD_TEST_SERVER"] {
            await libraries()
            await television(tv, server: URL(fileURLWithPath: server))
            await film(movie, server: URL(fileURLWithPath: server))
            await saved()
        }
        finish()
    }

    // MARK: the parts that need no disc

    static func units() {
        let labels: [(String, String, Int?, Int?)] = [
            ("FRIENDS_S1_D2", "Friends", 1, 2), ("SEINFELD_SEASON_3_DISC_1", "Seinfeld", 3, 1), ("THE_LORD_OF_THE_RINGS_WS", "The Lord of the Rings", nil, nil),
            ("AMELIE", "Amelie", nil, nil), ("BAND_OF_BROTHERS_D3", "Band of Brothers", nil, 3), ("ANDOR_S1D2", "Andor", 1, 2),
            ("MISSION_IMPOSSIBLE_16X9", "Mission Impossible", nil, nil), ("<THE_SHACK>", "The Shack", nil, nil), ("INTO_THE_WILD_D1", "Into the Wild", nil, 1),
        ]
        for (label, q, s, d) in labels {
            let h = LabelHint.parse(label)
            check(h.query == q && h.season == s && h.disc == d, "the label \(label) reads as \(h.query), season \(h.season.map(String.init) ?? "-"), disc \(h.disc.map(String.init) ?? "-")")
        }
        func t(_ i: Int, _ s: Int, _ ch: Int = 5) -> DVDTitle { DVDTitle(index: i, seconds: s, chapters: ch, width: 720, height: 480, audio: [], subtitles: []) }
        let movie = DVDScan(titles: [t(1, 7200, 28), t(2, 1500), t(3, 1400), t(4, 120)], main: 1)
        check(Pick.guess(movie, hint: LabelHint.parse("AMADEUS")) == .movie && Pick.feature(movie)?.index == 1, "a film with two extras is a movie, title 1")
        let tv = DVDScan(titles: [t(1, 10800, 20), t(2, 2700), t(3, 2650), t(4, 2720), t(5, 2690), t(6, 300)], main: 1)
        check(Pick.guess(tv, hint: LabelHint.parse("SHOW")) == .tv, "four 45-minute titles and their play-all are TV")
        check(Pick.episodes(tv.titles).map(\.index) == [2, 3, 4, 5], "the episodes are titles 2 to 5, the play-all left out (\(Pick.episodes(tv.titles).map(\.index)))")
        let copies = DVDScan(titles: [t(1, 1320), t(2, 1320), t(3, 1300), t(4, 1330)], main: 1)
        check(Pick.episodes(copies.titles).map(\.index) == [1, 3, 4], "a title that is a copy of another is left out (\(Pick.episodes(copies.titles).map(\.index)))")
        let bonus = DVDScan(titles: [t(1, 5700, 18), t(2, 1440), t(3, 1500)], main: nil)
        check(Pick.guess(bonus, hint: LabelHint.parse("FILM")) == .movie && Pick.feature(bonus)?.index == 1, "a 95-minute film with two 25-minute extras is a movie")
        check(Pick.guess(DVDScan(titles: [t(1, 2700), t(2, 2600)], main: 1), hint: LabelHint.parse("SHOW_S2_D1")) == .tv, "two episodes and a season in the label are TV")

        let mounted = DVDDisc(volume: URL(fileURLWithPath: "/Volumes/X"), label: "X", device: "/dev/disk8", id: "x")
        check(mounted.input == "/dev/rdisk8", "HandBrake reads the raw drive, /dev/rdisk8, not the mounted /dev/disk8")
        check(DVDDisc(volume: URL(fileURLWithPath: "/tmp/f"), label: "F", device: "", id: "f").input == "/tmp/f", "a folder is read as it is")
        check(Naming.clean("Mission: Impossible") == "Mission - Impossible", "a colon becomes a dash (\(Naming.clean("Mission: Impossible")))")
        check(Naming.clean("AC/DC?  Live*") == "AC-DC Live", "characters a file name cannot have are dropped or dashed (\(Naming.clean("AC/DC?  Live*")))")
        let amelie = Naming.folder("Ame\u{301}lie", "2001")
        check(amelie == "Amélie (2001)" && amelie.unicodeScalars.count == 13, "names are composed Unicode: \(amelie)")
        check(Naming.episodeFile("Test Show", season: 1, episode: 2, name: "Café: Two") == "Test Show - S01E02 - Café - Two.mkv", "an episode's file name (\(Naming.episodeFile("Test Show", season: 1, episode: 2, name: "Café: Two")))")
        check(Naming.episodeFile("Show", season: 10, episode: 3, name: "") == "Show - S10E03.mkv", "an episode without a name")
        let eps = Naming.episodes(in: ["The Agency - S01E07 - Hard Landing.mkv", "x - S01E08E09.mkv", "._y - S01E10.mkv", "z - S02E01.mkv", "[S1.Ep11] Show - Title.mp4"], season: 1)
        check(eps == [7, 8, 9, 11], "episodes already in a season folder: \(eps.sorted())")
        check(Naming.match(["The Office (US) (2005)", "Andor (2022)"], title: "The Office", year: "2005") == "The Office (US) (2005)", "Sonarr's \"The Office (US) (2005)\" is The Office")
        check(Naming.match(["Andor (2022)", "Amélie (2001)"], title: "Andor", year: "2016") == nil, "a folder from another year is not the same show")
        check(Naming.match(["Ame\u{301}lie (2001)"], title: "Amélie", year: "2001") != nil, "an accented folder matches however it is written")
        let nfo = Naming.nfo(TMDBItem(id: 194, kind: .movie, title: "Amélie & Co", year: "2001", poster: nil, overview: ""), ids: TMDBIds(imdb: "tt0211915", tvdb: nil))
        check(nfo.contains("<uniqueid type=\"tmdb\" default=\"true\">194</uniqueid>") && nfo.contains("<imdbid>tt0211915</imdbid>") && nfo.contains("Amélie &amp; Co") && nfo.hasPrefix("<?xml"), "the movie NFO pins it to TMDB 194")

        let hbline = "Encoding: task 1 of 1, 42.50 % (158.95 fps, avg 165.31 fps, ETA 00h12m05s)"
        let pr = HandBrake.progress(hbline)
        check(pr?.fraction == 0.425 && pr?.eta == 725, "HandBrake's progress line reads as 42.5%, 12 min left")
        let a = HandBrake.args(input: "/Volumes/X", title: DVDTitle.Stored(index: 3, audio: [1, 2], subtitles: [1, 2, 3]), output: "/tmp/o.mkv", encoder: .h265)
        check(a.contains("-a") && a[a.firstIndex(of: "-a")! + 1] == "1,2" && a[a.firstIndex(of: "-E")! + 1] == "copy,copy" && a[a.firstIndex(of: "-s")! + 1] == "1,2,3" && a.contains("--markers"),
              "every audio track is copied and every subtitle kept")
        let k3 = try? TMDB.request("/search/movie", ["query": "x"], key: "0123456789abcdef0123456789abcdef")
        let k4 = try? TMDB.request("/search/movie", ["query": "x"], key: "eyJhbGciOiJIUzI1NiJ9.test")
        check(k3?.url?.query?.contains("api_key=0123") == true && k3?.value(forHTTPHeaderField: "Authorization") == nil, "an API key goes in the address")
        check(k4?.value(forHTTPHeaderField: "Authorization") == "Bearer eyJhbGciOiJIUzI1NiJ9.test" && k4?.url?.query?.contains("api_key") == false, "a read access token goes in the header")
        Nav.shared.place = .rips
        Nav.shared.arrive(.disc)
        check(Nav.shared.place == .disc && Prefs.openForDiscs, "a disc coming in opens the Disc page")
    }

    // MARK: against the stand-ins

    static func libraries() async {
        let s = DiscStore.shared
        // Jellyfin not answering when the app starts: the reason shows, and the Disc page asks again until it does
        // (on another page, so the Disc page's own asking does not answer for it meanwhile)
        let jf = env["DVD_JELLYFIN_URL"] ?? ""
        Nav.shared.place = .rips
        await pause(0.5)
        setenv("DVD_JELLYFIN_URL", "http://127.0.0.1:9/jf", 1)
        await s.loadLibraries()
        check(s.jellyfinError?.hasPrefix("Can’t reach Jellyfin · ") == true, "Jellyfin not answering shows why: \(s.jellyfinError ?? "-")")
        setenv("DVD_JELLYFIN_URL", jf, 1)
        Nav.shared.place = .disc
        check(await until(15, { !s.libraries.isEmpty && s.jellyfinError == nil }), "and the Disc page asks again until it answers")
        await s.loadLibraries()
        check(s.libraries.map(\.name) == ["Movies", "Shows", "Music"], "Jellyfin's libraries: \(s.libraries.map(\.name))")
        check(s.library?.name == "Movies" && s.choices.map(\.name) == ["Movies"], "a movie goes to Movies")
        if let lib = s.libraries.first(where: { $0.name == "Shows" }) {
            let f = try? await s.folders(for: lib)
            check(f?.server.hasSuffix("/server/media/shows") == true && f?.jellyfin == "/data/media/shows", "Jellyfin's /data/media/shows is the server's \(f?.server ?? "-")")
        }
    }

    static func television(_ input: String, server: URL) async {
        let s = DiscStore.shared
        s.load(DVDDisc(volume: URL(fileURLWithPath: input), label: "TEST_SHOW_S1_D1", device: "", id: "test-tv"), minimum: 1)
        Nav.shared.place = .disc
        check(await until(90, { s.scan != nil && !s.scanning && !s.looking }), "HandBrake reads the pretend disc: \(s.titles.map { "\($0.index) \($0.seconds)s" })")
        check(s.titles.count == 3 && s.titles.allSatisfy { $0.audio.count == 2 }, "three titles, two audio tracks each")
        await s.setKind(.tv)
        check(await until(30, { s.item != nil && !s.looking && !s.checking }), "TMDB knows it: \(s.item?.summary ?? s.error ?? "-")")
        check(s.item?.id == 100 && s.season == 1 && s.episodes.count == 6, "Test Show, season 1 from the label, 6 episodes")
        check(s.existing == "Test Show (2020)" && s.present == [1], "the server has the show, with episode 1 (\(s.existing ?? "-"), \(s.present.sorted()))")
        check(s.firstEpisode == 2, "so this disc starts at episode 2")
        s.selected = [1, 2, 3]
        let files = s.parts.map(\.file)
        check(files == ["Test Show (2020)/Season 1/Test Show - S01E02 - Café - Two.mkv", "Test Show (2020)/Season 1/Test Show - S01E03 - Three-Four.mkv",
                        "Test Show (2020)/Season 1/Test Show - S01E04 - Four.mkv"],
              "the episodes' names: \(files.map { ($0 as NSString).lastPathComponent })")
        await pause(1.5)
        capture("disc-tv")
        await s.rip(upload: true)
        guard let job = Jobs.shared.list.first else { return check(false, "the rip starts") }
        check(await until(60, { job.state == .ripping && job.fraction > 0 }), "it rips, with progress (\(Int(job.fraction * 100))%)")
        await pause(0.5)
        capture("ripping")
        check(await until(240, { !job.active }), "and finishes: \(job.state.rawValue) \(job.error ?? "")")
        check(job.state == .done, "the episodes are in Jellyfin")
        let season = server.appendingPathComponent("shows/Test Show (2020)/Season 1")
        for f in files {
            let p = server.appendingPathComponent("shows").appendingPathComponent(f).path
            let attrs = try? FileManager.default.attributesOfItem(atPath: p)
            let perms = (attrs?[.posixPermissions] as? Int).map { String($0, radix: 8) } ?? "-"
            check(attrs != nil && perms == "664", "on the server: \((f as NSString).lastPathComponent) (\(perms))")
        }
        let nfo = (try? String(contentsOf: server.appendingPathComponent("shows/Test Show (2020)/tvshow.nfo"), encoding: .utf8)) ?? ""
        check(nfo == "original\n", "the show's NFO on the server is left as it was")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: season.path)) ?? []
        check(!names.contains { $0.hasPrefix(".") }, "no partial or ._ files on the server (\(names.filter { $0.hasPrefix(".") }))")
        Nav.shared.place = .rips
        await pause(1.0)
        capture("rips")
    }

    static func film(_ input: String, server: URL) async {
        let s = DiscStore.shared
        Nav.shared.place = .disc
        s.load(DVDDisc(volume: URL(fileURLWithPath: input), label: "AMELIE", device: "", id: "test-movie"), minimum: 1)
        check(await until(90, { s.scan != nil && !s.scanning && !s.looking && !s.checking && s.item != nil }), "the movie disc: \(s.item?.summary ?? s.error ?? "-")")
        check(s.kind == .movie && s.item?.title == "Amélie" && s.existing == nil, "is a movie, Amélie, not in the library yet")
        check(s.parts.first?.file == "Amélie (2001)/Amélie (2001).mkv", "named \(s.parts.first?.file ?? "-")")
        await pause(1.0)
        capture("disc-movie")

        // cancelled while it rips: nothing is left behind and nothing is sent
        await s.rip(upload: true)
        guard let first = Jobs.shared.list.first, first.kind == .movie else { return check(false, "the movie rip starts") }
        check(await until(60, { first.fraction > 0.05 }), "the movie rips (\(Int(first.fraction * 100))%)")
        first.cancel()
        check(await until(20, { !first.active }), "Cancel stops it")
        check(first.state == .cancelled, "as cancelled (\(first.state.rawValue))")
        let local = first.folder
        let left = ((try? FileManager.default.contentsOfDirectory(atPath: local.path)) ?? []).filter { $0.hasSuffix(".part") || $0.hasSuffix(".mkv") }
        check(left.isEmpty, "no part file is left (\(left))")
        check(!FileManager.default.fileExists(atPath: server.appendingPathComponent("films/Amélie (2001)").path), "and nothing went to the server")

        await s.rip(upload: true)
        guard let job = Jobs.shared.list.first, job.id != first.id else { return check(false, "the second rip starts") }
        check(await until(240, { !job.active }), "ripped and sent: \(job.state.rawValue) \(job.error ?? "")")
        check(job.state == .done, "the movie is in Jellyfin")
        let dir = server.appendingPathComponent("films/Amélie (2001)")
        let got = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
        check(got == ["Amélie (2001).mkv", "movie.nfo", "poster.jpg"], "the folder on the server: \(got)")
        check(got.first?.unicodeScalars.count == 17, "with its name composed, as the library writes it")
        if let d = await Jobs.duration(dir.appendingPathComponent("Amélie (2001).mkv")) { check(abs(d - 12) < 1.5, "the film plays \(String(format: "%.1f", d)) s") }
    }

    static func saved() async {
        Jobs.shared.save()
        let rs = (try? Data(contentsOf: Jobs.saved)).flatMap { try? JSONDecoder().decode([Job.Record].self, from: $0) } ?? []
        check(rs.count == 3 && rs.filter { $0.state == .done }.count == 2 && rs.contains { $0.state == .cancelled }, "the rips are remembered: \(rs.map(\.state.rawValue))")
        let back = Job(rs.first { $0.kind == "tv" }!)
        check(back.parts.count == 3 && back.state == .done && back.season == 1, "and read back")
    }

    // MARK: the disc in the drive

    /// Reads the real disc, shows what it found, and rips the first minute of one title.
    static func real() async {
        guard let d = DVDDisc.find() else { return log("INFO no DVD in the drive") }
        log("INFO disc \(d.label) at \(d.device), id \(d.id)")
        let s = DiscStore.shared
        let started = Date()
        s.load(d)
        Nav.shared.place = .disc
        check(await until(300, { !s.scanning && (s.scan != nil || s.error != nil) }), "HandBrake reads it in \(Int(Date().timeIntervalSince(started))) s")
        guard let scan = s.scan else { return check(false, "titles: \(s.error ?? "-")") }
        for t in s.titles { log("INFO title \(t.index): \(Fmt.clock(t.seconds)), \(t.chapters) ch, \(t.width)x\(t.height), audio \(t.audio.map { "\($0.code) \($0.codec) \($0.channels)" }), subs \(t.subtitles.map(\.code))") }
        log("INFO main feature \(scan.main.map(String.init) ?? "-"), guess \(s.kind.label), label \(s.hint.query) s\(s.hint.season.map(String.init) ?? "-") d\(s.hint.disc.map(String.init) ?? "-"), episodes \(Pick.episodes(scan.titles).map(\.index))")
        try? JSONSerialization.data(withJSONObject: s.titles.map { ["index": $0.index, "seconds": $0.seconds, "chapters": $0.chapters, "audio": $0.audio.count, "subs": $0.subtitles.count] })
            .write(to: out.appendingPathComponent("titles.json"))
        await pause(2)
        capture("real-disc")
        guard let dest = env["DVD_TEST_RIP_DEST"], let t = (s.kind == .movie ? s.titles.first { $0.index == s.feature } : s.titles.first { s.selected.contains($0.index) }) ?? s.titles.first,
              let hb = HandBrake.locate() else { return }
        let o = URL(fileURLWithPath: dest).appendingPathComponent("title-\(t.index).mkv")
        let secs = env["DVD_TEST_STOP_AT"] ?? "60"
        let begin = Date()
        let r = try? await Proc.run(hb, HandBrake.args(input: d.input, title: t.stored, output: o.path, encoder: Config.encoder))
        let took = Date().timeIntervalSince(begin)
        check(r?.status == 0 && FileManager.default.fileExists(atPath: o.path), "title \(t.index), first \(secs) s, ripped in \(Int(took)) s")
        if let got = await Jobs.duration(o) { log("INFO ripped \(String(format: "%.1f", got)) s of video, \(Fmt.size((try? FileManager.default.attributesOfItem(atPath: o.path)[.size] as? Int64) ?? 0)); \(String(format: "%.1f", got / max(1, took)))x real time") }
    }

    // MARK: helpers

    static var window: NSWindow? { NSApp.windows.first { $0.isVisible && $0.canBecomeMain } }

    static func capture(_ name: String) {
        guard let w = window else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", String(w.windowNumber), out.appendingPathComponent(name + ".png").path]
        try? p.run()
        p.waitUntilExit()
    }

    static func until(_ seconds: Double, _ cond: @MainActor () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return cond()
    }

    static func pause(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }

    static func check(_ ok: Bool, _ what: String) {
        if !ok { failures += 1 }
        log((ok ? "PASS " : "FAIL ") + what)
    }

    static func log(_ line: String) {
        print(line)
        if let h = try? FileHandle(forWritingTo: out.appendingPathComponent("log.txt")) {
            h.seekToEndOfFile()
            h.write(Data((line + "\n").utf8))
            try? h.close()
        }
    }

    static func finish() {
        log(failures == 0 ? "SELFTEST passed" : "SELFTEST failed: \(failures)")
        fflush(stdout)
        exit(failures == 0 ? 0 : 1)
    }
}
