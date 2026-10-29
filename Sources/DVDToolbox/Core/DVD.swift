import Foundation

/// A video DVD in the drive, as macOS mounts it: a volume with a VIDEO_TS folder.
struct DVDDisc: Equatable, Sendable {
    var volume: URL
    var label: String
    var device: String
    /// The label and the sizes of the disc's IFO files: the same disc gives the same id each time.
    var id: String

    /// What HandBrake reads: the raw drive. Given the volume, HandBrake opens /dev/diskN, which macOS
    /// keeps busy while the disc is mounted; libdvdcss then cannot open the drive, and libdvdread falls
    /// back to reading through the file system, which fails on some discs ("Encode failed (error 5)").
    var input: String { device.hasPrefix("/dev/disk") ? "/dev/r" + device.dropFirst(5) : volume.path }

    /// `find` on a thread of its own, given up after `seconds` (nil): see `offThread`.
    static func find(within seconds: Double) async -> DVDDisc?? {
        await offThread(within: seconds) { find() }
    }

    static func find() -> DVDDisc? {
        let fm = FileManager.default
        for v in fm.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey], options: [.skipHiddenVolumes]) ?? [] {
            if let d = at(v, fm: fm) { return d }
        }
        return nil
    }

    static func at(_ v: URL, fm: FileManager = .default) -> DVDDisc? {
        guard let names = try? fm.contentsOfDirectory(atPath: v.path), let ts = names.first(where: { $0.uppercased() == "VIDEO_TS" }) else { return nil }
        let dir = v.appendingPathComponent(ts, isDirectory: true)
        let ifos = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
            .filter { $0.pathExtension.uppercased() == "IFO" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !ifos.isEmpty else { return nil }
        let sizes = ifos.map { "\($0.lastPathComponent):\((try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)" }.joined(separator: ",")
        let label = (try? v.resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? v.lastPathComponent
        var sfs = statfs()
        let device = statfs(v.path, &sfs) == 0 ? withUnsafeBytes(of: sfs.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } : ""
        var h: UInt64 = 1469598103934665603
        for b in (label + "|" + sizes).utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return DVDDisc(volume: v, label: label, device: device, id: String(h, radix: 16))
    }
}

/// One title on the disc, as HandBrake's scan reports it.
struct DVDTitle: Identifiable, Equatable, Hashable, Sendable {
    struct Track: Equatable, Hashable, Sendable {
        var number: Int
        var language: String
        var code: String
        var codec: String
        var channels: String
    }

    var index: Int
    var seconds: Int
    var chapters: Int
    var width: Int
    var height: Int
    var audio: [Track]
    var subtitles: [Track]
    var id: Int { index }

    var languages: String {
        let codes = audio.map { $0.code == "und" ? "?" : $0.code }
        var seen = Set<String>()
        return codes.filter { seen.insert($0).inserted }.joined(separator: " ")
    }
}

/// What HandBrake found on a disc.
struct DVDScan: Equatable, Sendable {
    var titles: [DVDTitle]
    var main: Int?
    /// How each title's pieces lie on the disc, from its IFO files (none for a folder of files).
    var layout: [Int: IFO.Layout] = [:]

    func inOrder(_ t: DVDTitle) -> Bool { layout[t.index].map { $0.backward == 0 } ?? true }
}

/// The disc's own tables: VIDEO_TS.IFO and VTS_nn_0.IFO, which are not encrypted. They say where each
/// title's pieces (cells) lie. A film plays its cells in disc order; the decoy titles a protected disc
/// carries to confuse rippers jump back and forth.
enum IFO {
    struct Layout: Equatable, Sendable {
        var cells: Int
        var backward: Int
    }

    static func layouts(_ videoTS: URL) -> [Int: Layout] {
        func file(_ name: String) -> [UInt8]? {
            let fm = FileManager.default
            let match = (try? fm.contentsOfDirectory(atPath: videoTS.path))?.first { $0.uppercased() == name }
            return match.flatMap { try? Data(contentsOf: videoTS.appendingPathComponent($0)) }.map { [UInt8]($0) }
        }
        guard let vmg = file("VIDEO_TS.IFO") else { return [:] }
        var vts: [Int: [UInt8]] = [:]
        var out: [Int: Layout] = [:]
        let tt = Int(u32(vmg, 0xC4) ?? 0) * 2048
        guard let count = u16(vmg, tt) else { return [:] }
        for i in 0..<Int(count) {
            let e = tt + 8 + i * 12
            guard e + 8 <= vmg.count else { break }
            let n = Int(vmg[e + 6]), ttn = Int(vmg[e + 7])
            if vts[n] == nil { vts[n] = file(String(format: "VTS_%02d_0.IFO", n)) ?? [] }
            if let l = layout(vts[n]!, ttn: ttn) { out[i + 1] = l }
        }
        return out
    }

    /// The cells of a title's first program chain, read from its VTS IFO.
    static func layout(_ v: [UInt8], ttn: Int) -> Layout? {
        guard let p = u32(v, 0xC8), let g = u32(v, 0xCC), ttn >= 1 else { return nil }
        let ptt = Int(p) * 2048, pgcit = Int(g) * 2048
        guard let off = u32(v, ptt + 8 + (ttn - 1) * 4), let pgcn = u16(v, ptt + Int(off)), pgcn >= 1,
              let start = u32(v, pgcit + 8 + (Int(pgcn) - 1) * 8 + 4) else { return nil }
        let pgc = pgcit + Int(start)
        guard pgc + 0xEA <= v.count, let table = u16(v, pgc + 0xE8) else { return nil }
        let cells = Int(v[pgc + 3])
        var last: UInt32?
        var backward = 0
        for c in 0..<cells {
            let ce = pgc + Int(table) + c * 24
            guard let first = u32(v, ce + 8), let end = u32(v, ce + 20) else { return nil }
            if let last, first < last { backward += 1 }
            last = end
        }
        return Layout(cells: cells, backward: backward)
    }

    private static func u16(_ b: [UInt8], _ o: Int) -> UInt16? {
        o >= 0 && o + 2 <= b.count ? UInt16(b[o]) << 8 | UInt16(b[o + 1]) : nil
    }

    private static func u32(_ b: [UInt8], _ o: Int) -> UInt32? {
        o >= 0 && o + 4 <= b.count ? UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3]) : nil
    }
}

enum HandBrake {
    static func locate() -> String? {
        let env = ProcessInfo.processInfo.environment["DVD_HANDBRAKE"]
        return ([env].compactMap { $0 } + ["/opt/homebrew/bin/HandBrakeCLI", "/usr/local/bin/HandBrakeCLI"]).first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Every title of at least `minimum` seconds, read with `--scan --json`.
    static func scan(_ input: String, minimum: Int = 120) async throws -> DVDScan {
        guard let hb = locate() else { throw AppError("HandBrakeCLI is missing (brew install handbrake)") }
        let o = try await Proc.run(hb, ["-i", input, "-t", "0", "--scan", "--json", "--min-duration", String(minimum)])
        try Task.checkCancellation()
        guard let s = parse(o.stdout) else {
            let why = o.errText.split(separator: "\n").last { $0.contains("libdvdread") || $0.contains("libdvdcss") || $0.contains("No title") }
            throw AppError(why.map(String.init) ?? "HandBrake read no titles")
        }
        return s
    }

    /// The object after "JSON Title Set:" in HandBrake's output.
    static func parse(_ out: Data) -> DVDScan? {
        let text = String(decoding: out, as: UTF8.self)
        guard let r = text.range(of: "JSON Title Set:"), let body = object(in: text[r.upperBound...]),
              let root = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let list = root["TitleList"] as? [[String: Any]] else { return nil }
        func track(_ t: [String: Any], _ i: Int) -> DVDTitle.Track {
            DVDTitle.Track(number: t["TrackNumber"] as? Int ?? i + 1, language: t["Language"] as? String ?? "",
                           code: t["LanguageCode"] as? String ?? "und", codec: (t["CodecName"] as? String ?? t["SourceName"] as? String ?? "").uppercased(),
                           channels: t["ChannelLayoutName"] as? String ?? t["ChannelLayout"] as? String ?? "")
        }
        let titles: [DVDTitle] = list.compactMap { t in
            guard let index = t["Index"] as? Int, let d = t["Duration"] as? [String: Any] else { return nil }
            let secs = (d["Hours"] as? Int ?? 0) * 3600 + (d["Minutes"] as? Int ?? 0) * 60 + (d["Seconds"] as? Int ?? 0)
            let g = t["Geometry"] as? [String: Any]
            return DVDTitle(index: index, seconds: secs, chapters: (t["ChapterList"] as? [Any])?.count ?? 0,
                            width: g?["Width"] as? Int ?? 0, height: g?["Height"] as? Int ?? 0,
                            audio: (t["AudioList"] as? [[String: Any]] ?? []).enumerated().map { track($1, $0) },
                            subtitles: (t["SubtitleList"] as? [[String: Any]] ?? []).enumerated().map { track($1, $0) })
        }
        guard !titles.isEmpty else { return nil }
        let main = root["MainFeature"] as? Int
        return DVDScan(titles: titles, main: titles.contains { $0.index == main } ? main : nil)
    }

    /// The first balanced {…} in the text, minding strings.
    private static func object(in s: Substring) -> String? {
        guard let start = s.firstIndex(of: "{") else { return nil }
        var depth = 0, inString = false, escaped = false
        var i = start
        while i < s.endIndex {
            let c = s[i]
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
            } else if c == "\"" { inString = true }
            else if c == "{" { depth += 1 }
            else if c == "}" { depth -= 1; if depth == 0 { return String(s[start...i]) } }
            i = s.index(after: i)
        }
        return nil
    }

    /// "Encoding: task 1 of 1, 12.34 % (85.12 fps, avg 90.01 fps, ETA 00h23m10s)"
    static func progress(_ line: String) -> (fraction: Double, eta: Int?)? {
        guard let m = line.firstMatch(of: #/Encoding: task \d+ of \d+, ([\d.]+) %/#), let p = Double(m.1) else { return nil }
        var eta: Int?
        if let e = line.firstMatch(of: #/ETA (\d+)h(\d+)m(\d+)s/#) { eta = (Int(e.1) ?? 0) * 3600 + (Int(e.2) ?? 0) * 60 + (Int(e.3) ?? 0) }
        return (p / 100, eta)
    }

    /// The arguments for one title: MKV with chapters, the video encoded, every audio track copied as it is
    /// (encoded to AC3 only when MKV cannot carry it) and every subtitle track.
    /// `navigate: false` reads the title's cells in order (HandBrake's libdvdread reader) instead of
    /// following the disc's navigation, which on some protected discs leads nowhere.
    static func args(input: String, title: DVDTitle.Stored, output: String, encoder: Encoder, navigate: Bool = true) -> [String] {
        var a = ["-i", input, "-t", String(title.index), "-o", output, "-f", "av_mkv", "--markers"]
        if !navigate { a.append("--no-dvdnav") }
        a += encoder.args + ["--vfr", "--crop-mode", "conservative", "--comb-detect", "--decomb"]
        if title.audio.isEmpty { a += ["-a", "none"] }
        else {
            a += ["-a", title.audio.map(String.init).joined(separator: ","),
                  "-E", title.audio.map { _ in "copy" }.joined(separator: ","), "--audio-fallback", "ac3"]
        }
        if !title.subtitles.isEmpty { a += ["-s", title.subtitles.map(String.init).joined(separator: ","), "--subtitle-default=none"] }
        // the self-test's real-disc run rips the first minutes only
        if let stop = Config.env("DVD_TEST_STOP_AT") { a += ["--stop-at", "seconds:\(stop)"] }
        return a
    }
}

enum Kind: String, CaseIterable, Identifiable, Sendable {
    case movie, tv
    var id: String { rawValue }
    var label: String { self == .movie ? "Movie" : "TV" }
}

/// What a disc's label says: "FRIENDS_S1_D2" is Friends, season 1, disc 2.
struct LabelHint: Equatable {
    var query: String
    var season: Int?
    var disc: Int?

    static let noise: Set<String> = ["WS", "FS", "WIDESCREEN", "FULLSCREEN", "16X9", "4X3", "NTSC", "PAL", "DVD", "DVD9", "DVD5",
                                     "R1", "R2", "R4", "SE", "CE", "UK", "US", "EU", "NA", "PS", "LB", "AC3", "DTS"]

    static func parse(_ label: String) -> LabelHint {
        // only letters, digits and & count: "<THE_SHACK>" is The Shack
        let kept = String(label.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "&" ? Character($0) : "_" })
        var words = kept.uppercased()
            .split(whereSeparator: { $0 == "_" || $0 == " " }).map(String.init)
        var season: Int?, disc: Int?
        var keep: [String] = []
        var i = 0
        while i < words.count {
            let w = words[i]
            let next = i + 1 < words.count ? Int(words[i + 1]) : nil
            if let m = w.firstMatch(of: #/^S(?:EASON|EA)?(\d{1,2})(?:D(?:ISC)?(\d{1,2}))?$/#) {
                season = Int(m.1); if let d = m.2 { disc = Int(d) }
            } else if let m = w.firstMatch(of: #/^D(?:IS[CK])?(\d{1,2})$/#) {
                disc = Int(m.1)
            } else if (w == "SEASON" || w == "SERIES"), let n = next {
                season = n; i += 1
            } else if (w == "DISC" || w == "DISK" || w == "VOL" || w == "VOLUME"), let n = next {
                disc = n; i += 1
            } else if !noise.contains(w) {
                keep.append(w)
            }
            i += 1
        }
        if keep.isEmpty { keep = words; words = [] }
        let small: Set<String> = ["A", "AN", "AND", "OF", "THE", "IN", "ON", "AT", "TO", "FOR", "OR"]
        let query = keep.enumerated().map { i, w in
            i > 0 && small.contains(w) ? w.lowercased() : w.prefix(1) + w.dropFirst().lowercased()
        }.joined(separator: " ")
        return LabelHint(query: query, season: season, disc: disc)
    }
}

/// Which titles are the movie, or the episodes.
enum Pick {
    /// Titles that play the same thing twice (a "play all", or copies a disc carries to confuse rippers) left out.
    static func distinct(_ titles: [DVDTitle], minimum: Int = 600) -> [DVDTitle] {
        let long = titles.filter { $0.seconds >= minimum }
        var out: [DVDTitle] = []
        for t in long where !out.contains(where: { abs($0.seconds - t.seconds) <= 2 && $0.chapters == t.chapters }) { out.append(t) }
        // a title as long as two or more of the others together is them, played one after another
        return out.filter { t in
            let others = out.filter { $0.index != t.index && $0.seconds < t.seconds }
            return !playsAll(t.seconds, others.map(\.seconds))
        }
    }

    private static func playsAll(_ total: Int, _ parts: [Int]) -> Bool {
        guard parts.count >= 2 else { return false }
        let episodes = parts.filter { $0 >= 900 && $0 <= 4200 }
        guard episodes.count >= 2 else { return false }
        let sum = episodes.reduce(0, +)
        return abs(sum - total) <= max(30, total / 50)
    }

    /// Episodes: two or more titles of 15 to 70 minutes, close to one another in length.
    static func episodes(_ titles: [DVDTitle], layout: [Int: IFO.Layout] = [:]) -> [DVDTitle] {
        let d = distinct(titles).filter { $0.seconds >= 900 && $0.seconds <= 4200 && (layout[$0.index]?.backward ?? 0) == 0 }
        guard d.count >= 2 else { return [] }
        let lengths = d.map(\.seconds).sorted()
        let median = lengths[lengths.count / 2]
        return d.filter { abs($0.seconds - median) <= median / 4 }.sorted { $0.index < $1.index }
    }

    static func guess(_ scan: DVDScan, hint: LabelHint) -> Kind {
        let eps = episodes(scan.titles, layout: scan.layout)
        let longest = distinct(scan.titles).map(\.seconds).max() ?? 0
        if hint.season != nil, eps.count >= 1 { return .tv }
        if eps.count >= 3 && longest <= 4500 { return .tv }
        if eps.count >= 2 && longest <= 4200 { return .tv }
        return .movie
    }

    /// The movie: HandBrake's main feature, else the longest title.
    /// The film: among the long titles, the ones whose pieces are in order; of those HandBrake's main
    /// feature when its length fits TMDB's running time, else the one closest to it, else the longest.
    static func feature(_ scan: DVDScan, runtime: Int? = nil) -> DVDTitle? {
        let longest = scan.titles.map(\.seconds).max() ?? 0
        var c = scan.titles.filter { Double($0.seconds) >= Double(longest) * 0.6 }
        let ordered = c.filter(scan.inOrder)
        if !ordered.isEmpty { c = ordered }
        let want = (runtime ?? 0) * 60
        let main = c.first { $0.index == scan.main }
        if let main, want == 0 || abs(main.seconds - want) <= want / 10 { return main }
        if want > 0 { return c.min { (abs($0.seconds - want), $0.index) < (abs($1.seconds - want), $1.index) } }
        return main ?? c.max { $0.seconds < $1.seconds }
    }
}
