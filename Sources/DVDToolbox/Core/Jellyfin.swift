import Foundation

/// Jellyfin's API, with an API key made in its Dashboard. The app uses it to list the libraries, to tell
/// Jellyfin about new folders, and to see that they arrived.
struct Jellyfin: Sendable {
    struct Library: Identifiable, Hashable, Sendable {
        var id: String
        var name: String
        var kind: String
        var locations: [String]

        var takes: [Kind] {
            switch kind {
            case "movies": [.movie]
            case "tvshows": [.tv]
            case "", "mixed": [.movie, .tv]
            default: []
            }
        }
    }

    struct Item: Sendable {
        var id: String
        var name: String
        var path: String
    }

    var base: URL
    var key: String

    private func request(_ method: String, _ path: String, _ query: [String: String] = [:], body: Any? = nil) -> URLRequest {
        var c = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var r = URLRequest(url: c.url!)
        r.httpMethod = method
        r.timeoutInterval = 20
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        r.setValue("MediaBrowser Client=\"DVD Toolbox\", Device=\"Mac\", DeviceId=\"dvd-toolbox\", Version=\"\(version)\", Token=\"\(key)\"", forHTTPHeaderField: "Authorization")
        if let body {
            r.httpBody = try? JSONSerialization.data(withJSONObject: body)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    private func send(_ r: URLRequest) async throws -> Data {
        let (data, resp) = try await URLSession.shared.data(for: r)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw AppError("Jellyfin key not accepted") }
        guard (200..<300).contains(status) else { throw AppError("Jellyfin answered \(status)") }
        return data
    }

    /// The server's name and version, which needs a key it accepts.
    func info() async throws -> String {
        let d = try await send(request("GET", "System/Info"))
        let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
        return [o["ServerName"] as? String, o["Version"] as? String].compactMap { $0 }.joined(separator: " ")
    }

    func libraries() async throws -> [Library] {
        let d = try await send(request("GET", "Library/VirtualFolders"))
        return Self.parseLibraries(d)
    }

    static func parseLibraries(_ d: Data) -> [Library] {
        ((try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] ?? []).compactMap { f in
            guard let name = f["Name"] as? String else { return nil }
            return Library(id: f["ItemId"] as? String ?? name, name: name, kind: f["CollectionType"] as? String ?? "", locations: f["Locations"] as? [String] ?? [])
        }
    }

    /// Tells Jellyfin these folders (its own paths) are new, so it scans just them.
    func created(_ paths: [String]) async throws {
        _ = try await send(request("POST", "Library/Media/Updated", body: ["Updates": paths.map { ["Path": $0, "UpdateType": "Created"] }]))
    }

    /// Scans every library.
    func refreshAll() async throws {
        _ = try await send(request("POST", "Library/Refresh"))
    }

    /// Items of a type whose name matches, with their paths.
    func items(_ type: String, search: String) async throws -> [Item] {
        let d = try await send(request("GET", "Items", ["recursive": "true", "includeItemTypes": type, "searchTerm": search, "fields": "Path", "limit": "50"]))
        return Self.parseItems(d)
    }

    func episodes(series: String, season: Int) async throws -> [Item] {
        let d = try await send(request("GET", "Shows/\(series)/Episodes", ["season": String(season), "fields": "Path"]))
        return Self.parseItems(d)
    }

    static func parseItems(_ d: Data) -> [Item] {
        (((try? JSONSerialization.jsonObject(with: d)) as? [String: Any])?["Items"] as? [[String: Any]] ?? []).compactMap { i in
            guard let id = i["Id"] as? String else { return nil }
            return Item(id: id, name: i["Name"] as? String ?? "", path: i["Path"] as? String ?? "")
        }
    }
}
