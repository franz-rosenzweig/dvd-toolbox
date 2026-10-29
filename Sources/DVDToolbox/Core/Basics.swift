import AppKit
import Foundation
import Security
import ServiceManagement

/// Sizes and times.
enum Fmt {
    private static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()

    static func size(_ n: Int64) -> String { bytes.string(fromByteCount: max(0, n)) }

    static func rate(_ bytesPerSecond: Double) -> String { size(Int64(bytesPerSecond)) + "/s" }

    static func left(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s > 5400 ? "\(Int((Double(s) / 3600).rounded())) h" : s > 90 ? "\(Int((Double(s) / 60).rounded())) min" : "\(s) s"
    }

    static func clock(_ seconds: Int) -> String {
        seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds % 3600 / 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// The keys live in the Keychain; everything else the app is told is in UserDefaults.
enum Keychain {
    static let service = Bundle.main.bundleIdentifier ?? "xyz.tiresia.dvdtoolbox"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func get(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func set(_ value: String, for account: String) {
        SecItemDelete(query(account) as CFDictionary)
        guard !value.isEmpty else { return }
        var q = query(account)
        q[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }
}

/// What the app has been told about TMDB, Jellyfin and the server. DVD_* environment variables win, for
/// the self-test; nothing about the owner's server is built into the app.
enum Config {
    static let defaults = UserDefaults.standard

    /// Read live, so the self-test can change one while the app runs.
    static func env(_ key: String) -> String? {
        getenv(key).map { String(cString: $0) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func saved(_ key: String) -> String {
        (defaults.string(forKey: key) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var tmdbKey: String { (env("DVD_TMDB_KEY") ?? Keychain.get("tmdb") ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

    static var jellyfinURL: URL? {
        var s = env("DVD_JELLYFIN_URL") ?? saved("jellyfinURL")
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s)
    }

    static var jellyfinKey: String { (env("DVD_JELLYFIN_KEY") ?? Keychain.get("jellyfin") ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

    static var jellyfin: Jellyfin? {
        guard let url = jellyfinURL, !jellyfinKey.isEmpty else { return nil }
        return Jellyfin(base: url, key: jellyfinKey)
    }

    static var remote: Remote? {
        let target = env("DVD_SSH_TARGET") ?? saved("sshTarget")
        guard !target.isEmpty else { return nil }
        let media = env("DVD_MEDIA_PATH") ?? saved("mediaPath")
        return Remote(target: target, mediaPath: media.isEmpty ? "/srv/media" : media)
    }

    static var configured: Bool { !tmdbKey.isEmpty && jellyfin != nil && remote != nil }

    /// Where rips are kept on this Mac, laid out the way they go to the server.
    static var ripsFolder: URL {
        let s = saved("ripsFolder")
        if !s.isEmpty { return URL(fileURLWithPath: (s as NSString).expandingTildeInPath, isDirectory: true) }
        return FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("DVD Rips", isDirectory: true)
    }

    static var encoder: Encoder { Encoder(rawValue: saved("encoder")) ?? .h265 }
}

/// The video encoders on offer. H.265 by x265 is the default; the hardware one is several times faster
/// and makes bigger files.
enum Encoder: String, CaseIterable, Identifiable {
    case h265 = "x265", h264 = "x264", hardware = "vt_h265"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .h265: "H.265"
        case .h264: "H.264"
        case .hardware: "H.265 (Hardware)"
        }
    }
    var args: [String] {
        switch self {
        case .h265: ["-e", "x265", "--encoder-preset", "medium", "-q", "20"]
        case .h264: ["-e", "x264", "--encoder-preset", "slow", "-q", "19"]
        case .hardware: ["-e", "vt_h265", "-q", "62"]
        }
    }
}

/// What to do when a DVD comes in.
enum Prefs {
    static var openForDiscs: Bool { UserDefaults.standard.object(forKey: "openForDiscs") as? Bool ?? true }
    static var ejectWhenDone: Bool { UserDefaults.standard.object(forKey: "ejectWhenDone") as? Bool ?? true }
}

/// Starting the app at login, so it is there to be shown when a disc comes in. It is a login item the
/// owner can also remove in System Settings.
enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

/// Keeps the Mac awake while something long runs.
@MainActor
final class Awake {
    private var token: NSObjectProtocol?
    private var users = 0

    static let shared = Awake()

    func hold(_ reason: String) {
        users += 1
        if token == nil { token = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: reason) }
    }

    func release() {
        users = max(0, users - 1)
        if users == 0, let t = token { ProcessInfo.processInfo.endActivity(t); token = nil }
    }
}

struct Toast: Identifiable {
    let id = UUID()
    var message: String
}

extension Nav {
    /// Says what just happened, for ten seconds.
    func notify(_ message: String) {
        let t = Toast(message: message)
        toast = t
        Task {
            try? await Task.sleep(for: .seconds(10))
            if toast?.id == t.id { toast = nil }
        }
    }

    /// Something has just come in: show the app on it, opening the window if it was closed.
    func arrive(_ place: Place) {
        self.place = place
        NSApp.activate(ignoringOtherApps: true)
        if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
            NSWorkspace.shared.open(Bundle.main.bundleURL)
        }
    }
}

/// Runs `work` on a thread of its own and gives up waiting after `seconds` (nil). For reads from the disc:
/// a drive that has stopped answering leaves the call waiting in the kernel, and it must not hold the
/// threads the rest of the app runs on.
func offThread<T: Sendable>(within seconds: Double, _ work: @escaping @Sendable () -> T) async -> T? {
    await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
        let once = Once()
        Thread.detachNewThread { let r = work(); if once.claim() { cont.resume(returning: r) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { if once.claim() { cont.resume(returning: nil) } }
    }
}

/// True the first time only: whichever of the work and the timer comes first resumes the caller.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}

/// What to show for a failure: the app's own message, or "Can’t reach X · why" for a network error.
func because(_ error: Error, _ fallback: String) -> String {
    if let e = error as? AppError { return e.detail }
    guard let u = error as? URLError else { return fallback }
    let why = u.localizedDescription.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    return why.isEmpty ? fallback : "\(fallback) · \(why)"
}

struct AppError: LocalizedError {
    var detail: String
    init(_ detail: String) { self.detail = detail }
    var errorDescription: String? { detail.split(separator: "\n").first.map(String.init) ?? detail }
}
