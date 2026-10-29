import SwiftUI

/// TMDB, Jellyfin and the server. Saved only when Connect is pressed, so half a typed address never counts.
struct SettingsForm: View {
    var firstRun = false

    @AppStorage("jellyfinURL") private var storedJellyfin = ""
    @AppStorage("sshTarget") private var storedSSH = ""
    @AppStorage("mediaPath") private var storedMedia = ""
    @AppStorage("ripsFolder") private var storedRips = ""
    @AppStorage("encoder") private var encoder = Encoder.h265.rawValue
    @AppStorage("keepRips") private var keepRips = true
    @AppStorage("openForDiscs") private var openForDiscs = true
    @State private var atLogin = LoginItem.enabled
    @State private var loginError: String?

    @State private var tmdb = ""
    @State private var jellyfin = ""
    @State private var jellyfinKey = ""
    @State private var ssh = ""
    @State private var media = ""
    @State private var rips = ""
    @State private var tmdbResult: String?
    @State private var jellyfinResult: String?
    @State private var sshResult: String?
    @State private var testing = false

    var body: some View {
        Form {
            Section("TMDB") {
                SecureField("Key", text: $tmdb)
                if let r = tmdbResult { status(r, ok: r == "Connected") }
            }
            Section("Jellyfin") {
                TextField("Server", text: $jellyfin, prompt: Text("http://…:8096"))
                SecureField("API Key", text: $jellyfinKey)
                if let r = jellyfinResult { status(r, ok: r.hasPrefix("Connected")) }
            }
            Section("Library Server") {
                TextField("SSH", text: $ssh, prompt: Text("user@host"))
                TextField("Media folder", text: $media, prompt: Text("/srv/media"))
                if let r = sshResult { status(r, ok: r == "Connected") }
            }
            Section("Rip") {
                TextField("Rips folder", text: $rips, prompt: Text("~/Movies/DVD Rips"))
                Picker("Video", selection: $encoder) {
                    ForEach(Encoder.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Toggle("Keep After Upload", isOn: $keepRips)
            }
            Section("When Connected") {
                Toggle("Open for DVDs", isOn: $openForDiscs)
                Toggle("Open at Login", isOn: Binding(get: { atLogin }, set: { on in
                    do { try LoginItem.set(on); atLogin = LoginItem.enabled; loginError = nil } catch { atLogin = LoginItem.enabled; loginError = "Can’t change the login item" }
                }))
                if let e = loginError { Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            }
            Section {
                HStack {
                    Spacer()
                    if testing { ProgressView().controlSize(.small) }
                    Button("Connect") { Task { await connect() } }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(testing || tmdb.isEmpty || jellyfin.isEmpty || jellyfinKey.isEmpty || ssh.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            tmdb = Keychain.get("tmdb") ?? ""
            jellyfin = storedJellyfin; jellyfinKey = Keychain.get("jellyfin") ?? ""
            ssh = storedSSH; media = storedMedia; rips = storedRips
        }
    }

    private func status(_ text: String, ok: Bool) -> some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(ok ? .green : .red)
    }

    private func connect() async {
        testing = true
        defer { testing = false }
        let key = tmdb.trimmingCharacters(in: .whitespacesAndNewlines), jkey = jellyfinKey.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.set(key, for: "tmdb")
        Keychain.set(jkey, for: "jellyfin")
        storedJellyfin = jellyfin.trimmingCharacters(in: .whitespaces)
        storedSSH = ssh.trimmingCharacters(in: .whitespaces)
        storedMedia = media.trimmingCharacters(in: .whitespaces)
        storedRips = rips.trimmingCharacters(in: .whitespaces)
        tmdbResult = nil; jellyfinResult = nil; sshResult = nil
        do { try await TMDB.check(key); tmdbResult = "Connected" } catch { tmdbResult = because(error, "Can’t reach TMDB") }
        if let jf = Config.jellyfin {
            do {
                let name = try await jf.info()
                _ = try await jf.libraries()
                jellyfinResult = name.isEmpty ? "Connected" : "Connected · \(name)"
            } catch { jellyfinResult = because(error, "Can’t reach Jellyfin") }
        } else {
            jellyfinResult = "Not a valid address"
        }
        if let remote = Config.remote {
            let o = try? await remote.script("test -d \(Remote.quote(remote.mediaPath))\n")
            sshResult = o == nil ? "Can’t run ssh" : o!.status == 0 ? "Connected" : o!.status == 255 ? (o!.errText.split(separator: "\n").first.map(String.init) ?? "ssh failed") : "Media folder not found"
        }
        DiscStore.shared.folders = [:]
        await DiscStore.shared.loadLibraries()
        Nav.shared.saved += 1
        if DiscStore.shared.item != nil { await DiscStore.shared.checkServer() }
    }
}
