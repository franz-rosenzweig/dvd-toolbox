import SwiftUI
import AppKit
import Observation

/// DVD Toolbox: rips the DVD in the drive into the Jellyfin library on the server.
@main
struct DVDToolboxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("DVD Toolbox", id: "main") {
            RootView()
                .frame(minWidth: 820, minHeight: 560)
        }
        .defaultSize(width: 980, height: 680)
        .commands {
            CommandMenu("Go") {
                Button("Disc") { Nav.shared.place = .disc }.keyboardShortcut("1", modifiers: .command)
                Button("Rips") { Nav.shared.place = .rips }.keyboardShortcut("2", modifiers: .command)
            }
        }

        Settings {
            SettingsForm().frame(width: 500).padding(.vertical, 8)
        }
    }
}

enum Place: Hashable {
    case disc
    case rips
}

@Observable @MainActor
final class Nav {
    static let shared = Nav()
    var place: Place? = .disc
    var toast: Toast?
    /// Counts the times Settings were saved, so views that read the Keychain read it again.
    var saved = 0
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let out = ProcessInfo.processInfo.environment["DVD_SELFTEST"] {
            QuietExit.install(log: out)
            Task { @MainActor in await SelfTest.run(out: URL(fileURLWithPath: out)) }
        } else {
            Task { @MainActor in
                await DiscStore.shared.look()
                await DiscStore.shared.loadLibraries()
            }
        }
    }

    /// With "Open for DVDs" on, the app keeps running with its window closed, to open it when one comes in.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !Prefs.openForDiscs }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { true }

    /// Quitting stops a rip or an upload; the window asks first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let busy = MainActor.assumeIsolated { Jobs.shared.running }
        guard busy > 0, ProcessInfo.processInfo.environment["DVD_SELFTEST"] == nil else { return .terminateNow }
        let a = NSAlert()
        a.messageText = "Stop \(busy == 1 ? "the rip" : "\(busy) rips")?"
        a.addButton(withTitle: "Quit")
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}

/// A test copy that hits an exception writes it down and leaves quietly: no crash report, no dialog
/// asking whether to reopen windows on the owner's screen.
enum QuietExit {
    nonisolated(unsafe) static var path = ""

    nonisolated(unsafe) static var signalPath: UnsafeMutablePointer<CChar>?

    static func install(log: String) {
        path = log + "/crash.txt"
        NSSetUncaughtExceptionHandler { e in
            try? "\(e.name.rawValue): \(e.reason ?? "")\n\(e.callStackSymbols.joined(separator: "\n"))".write(toFile: QuietExit.path, atomically: true, encoding: .utf8)
            _exit(70)
        }
        // a Swift trap is a signal, not an exception: note it and leave before the crash reporter sees a crash
        signalPath = strdup(path)
        for s in [SIGTRAP, SIGILL, SIGSEGV, SIGBUS, SIGABRT] {
            signal(s) { n in
                if let p = QuietExit.signalPath {
                    let fd = open(p, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
                    if fd >= 0 { var msg: [UInt8] = Array("signal ".utf8) + [UInt8(48 + n / 10), UInt8(48 + n % 10), 10]; _ = write(fd, &msg, msg.count); close(fd) }
                }
                _exit(70)
            }
        }
    }
}
