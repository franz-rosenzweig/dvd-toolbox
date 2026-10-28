import Foundation

/// Names and folders the way Jellyfin reads them, and the way Radarr and Sonarr already wrote the library:
/// `Title (Year)/Title (Year).mkv` and `Show (Year)/Season 1/Show - S01E01 - Episode.mkv`.
enum Naming {
    /// A name that is safe in a file name on the Mac and on the server: "Mission: Impossible" becomes
    /// "Mission - Impossible", as Radarr writes it.
    static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: ": ", with: " - ").replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "\\", with: "-")
        let bad = CharacterSet(charactersIn: "?*\"<>|").union(.controlCharacters)
        t = t.components(separatedBy: bad).joined()
        t = t.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return t.isEmpty ? "Untitled" : String(t.prefix(150)).precomposedStringWithCanonicalMapping
    }

    static func folder(_ title: String, _ year: String) -> String {
        let y = year.trimmingCharacters(in: .whitespaces)
        return y.isEmpty ? clean(title) : "\(clean(title)) (\(y))"
    }

    static func movieFile(_ title: String, _ year: String) -> String { folder(title, year) + ".mkv" }

    static func season(_ n: Int) -> String { "Season \(n)" }

    static func episodeCode(_ season: Int, _ episode: Int) -> String { String(format: "S%02dE%02d", season, episode) }

    static func episodeFile(_ show: String, season: Int, episode: Int, name: String) -> String {
        let n = name.trimmingCharacters(in: .whitespaces)
        let base = "\(clean(show)) - \(episodeCode(season, episode))"
        return (n.isEmpty || n.lowercased() == "episode \(episode)" ? base : base + " - " + clean(n)) + ".mkv"
    }

    /// The episode numbers in a season folder's file names ("… - S01E04 - …", "S01E04E05").
    static func episodes(in names: [String], season: Int) -> Set<Int> {
        var out = Set<Int>()
        for n in names where !n.hasPrefix("._") {
            for m in n.matches(of: #/[Ss](\d{1,2})[Ee](\d{1,3})(?:-?[Ee](\d{1,3}))?/#) where Int(m.1) == season {
                if let a = Int(m.2) { out.insert(a); if let b = m.3.flatMap({ Int($0) }), b >= a, b - a < 10 { for e in a...b { out.insert(e) } } }
            }
            // "[S8.Ep9] Show - Title.mp4", as some of the library is named
            for m in n.matches(of: #/\[S(\d{1,2})\.Ep(\d{1,3})\]/#) where Int(m.1) == season { if let a = Int(m.2) { out.insert(a) } }
        }
        return out
    }

    /// The folder already on the server for this title, so a second season lands next to the first even
    /// when Sonarr spelled the name a little differently: "The Office (US) (2005)" is The Office, 2005.
    static func match(_ names: [String], title: String, year: String) -> String? {
        let want = key(title), y = Int(year)
        var best: String?
        for n in names where !n.hasPrefix(".") {
            let (k, ny) = split(n)
            guard k == want else { continue }
            if let y, let ny {
                if ny == y { return n }
                if abs(ny - y) == 1 { best = best ?? n }
            } else { best = best ?? n }
        }
        return best
    }

    private static func split(_ name: String) -> (String, Int?) {
        var year: Int?
        if let m = name.firstMatch(of: #/\((\d{4})\)\s*$/#) { year = Int(m.1) }
        let bare = name.replacing(#/\([^)]*\)/#, with: "")
        return (key(bare), year)
    }

    private static func key(_ s: String) -> String {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).replacingOccurrences(of: "&", with: "and")
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    static func xml(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// The NFO that pins the folder to its TMDB entry, so Jellyfin cannot match it to another film or show.
    static func nfo(_ item: TMDBItem, ids: TMDBIds) -> String {
        let root = item.kind == .movie ? "movie" : "tvshow"
        var lines = ["<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>", "<\(root)>", "  <title>\(xml(item.title))</title>"]
        if !item.year.isEmpty { lines.append("  <year>\(item.year)</year>") }
        lines.append("  <uniqueid type=\"tmdb\" default=\"true\">\(item.id)</uniqueid>")
        if let i = ids.imdb { lines.append("  <uniqueid type=\"imdb\">\(xml(i))</uniqueid>") }
        if let t = ids.tvdb { lines.append("  <uniqueid type=\"tvdb\">\(t)</uniqueid>") }
        lines.append("  <tmdbid>\(item.id)</tmdbid>")
        if let i = ids.imdb { lines.append("  <imdbid>\(xml(i))</imdbid>") }
        if let t = ids.tvdb { lines.append("  <tvdbid>\(t)</tvdbid>") }
        lines.append("</\(root)>")
        return lines.joined(separator: "\n") + "\n"
    }
}
