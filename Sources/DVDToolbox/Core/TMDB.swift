import Foundation

/// A movie or a show on TMDB.
struct TMDBItem: Identifiable, Hashable, Sendable {
    var id: Int
    var kind: Kind
    var title: String
    var year: String
    var poster: String?
    var overview: String

    var summary: String { year.isEmpty ? title : "\(title) · \(year)" }
}

struct TMDBEpisode: Hashable, Sendable {
    var number: Int
    var name: String
    var minutes: Int?
}

/// The ids Jellyfin and the others know an item by, for the NFO.
struct TMDBIds: Sendable {
    var imdb: String?
    var tvdb: Int?
}

/// TMDB, the source Jellyfin's Movies and Shows libraries and Radarr use. The key is either the v3 API
/// key (sent as api_key) or the v4 read access token (sent as a bearer token); the app tells them apart.
enum TMDB {
    static var base: String { Config.env("DVD_TMDB_URL") ?? "https://api.themoviedb.org/3" }
    static var images: String { Config.env("DVD_TMDB_IMAGES") ?? "https://image.tmdb.org/t/p" }

    static func request(_ path: String, _ query: [String: String] = [:], key: String = Config.tmdbKey) throws -> URLRequest {
        guard !key.isEmpty else { throw AppError("No TMDB key") }
        var c = URLComponents(string: base + path)!
        var items = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        let bearer = key.hasPrefix("eyJ")
        if !bearer { items.append(URLQueryItem(name: "api_key", value: key)) }
        c.queryItems = items
        var r = URLRequest(url: c.url!)
        r.timeoutInterval = 20
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if bearer { r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        return r
    }

    static func get(_ path: String, _ query: [String: String] = [:], key: String = Config.tmdbKey) async throws -> [String: Any] {
        let (data, resp) = try await URLSession.shared.data(for: request(path, query, key: key))
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw AppError("TMDB key not accepted") }
        guard status == 200, let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw AppError("TMDB answered \(status)") }
        return o
    }

    /// Checks a key before it is saved.
    static func check(_ key: String) async throws {
        _ = try await get("/configuration", key: key)
    }

    static func parseSearch(_ o: [String: Any], kind: Kind) -> [TMDBItem] {
        (o["results"] as? [[String: Any]] ?? []).compactMap { r in
            guard let id = r["id"] as? Int, let title = (kind == .movie ? r["title"] : r["name"]) as? String else { return nil }
            let date = (kind == .movie ? r["release_date"] : r["first_air_date"]) as? String ?? ""
            return TMDBItem(id: id, kind: kind, title: title, year: String(date.prefix(4)), poster: r["poster_path"] as? String, overview: r["overview"] as? String ?? "")
        }
    }

    static func search(_ query: String, kind: Kind, year: String? = nil) async throws -> [TMDBItem] {
        var q = ["query": query, "include_adult": "false"]
        if let year, !year.isEmpty { q[kind == .movie ? "year" : "first_air_date_year"] = year }
        return parseSearch(try await get(kind == .movie ? "/search/movie" : "/search/tv", q), kind: kind)
    }

    static func parseSeason(_ o: [String: Any]) -> [TMDBEpisode] {
        (o["episodes"] as? [[String: Any]] ?? []).compactMap { e in
            guard let n = e["episode_number"] as? Int else { return nil }
            return TMDBEpisode(number: n, name: e["name"] as? String ?? "", minutes: e["runtime"] as? Int)
        }
    }

    static func season(_ show: Int, _ number: Int) async throws -> [TMDBEpisode] {
        parseSeason(try await get("/tv/\(show)/season/\(number)"))
    }

    /// How many seasons a show has (specials, season 0, not counted).
    static func seasons(_ show: Int) async throws -> Int {
        let o = try await get("/tv/\(show)")
        return o["number_of_seasons"] as? Int ?? 1
    }

    /// A film's running time in minutes, which picks the title on a disc that carries decoys.
    static func runtime(_ movie: Int) async -> Int? {
        (try? await get("/movie/\(movie)"))?["runtime"] as? Int
    }

    static func ids(_ item: TMDBItem) async -> TMDBIds {
        guard let o = try? await get(item.kind == .movie ? "/movie/\(item.id)/external_ids" : "/tv/\(item.id)/external_ids") else { return TMDBIds() }
        return TMDBIds(imdb: (o["imdb_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }, tvdb: o["tvdb_id"] as? Int)
    }

    static func poster(_ path: String, size: String = "w500") async -> Data? {
        guard let url = URL(string: images + "/" + size + path) else { return nil }
        var r = URLRequest(url: url)
        r.timeoutInterval = 25
        guard let (data, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200, data.count > 1000 else { return nil }
        return data
    }
}
