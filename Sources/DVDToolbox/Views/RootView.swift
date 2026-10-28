import SwiftUI

struct RootView: View {
    @State private var nav = Nav.shared
    @State private var jobs = Jobs.shared
    @State private var store = DiscStore.shared
    @AppStorage("jellyfinURL") private var jellyfinURL = ""
    @AppStorage("sshTarget") private var sshTarget = ""

    /// Reads the stored settings (so the view follows Save), or the environment's.
    private var configured: Bool {
        _ = (jellyfinURL, sshTarget, nav.saved)
        return Config.configured
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $nav.place) {
                Label(store.disc?.label ?? "Disc", systemImage: "opticaldisc").tag(Place.disc)
                Label("Rips", systemImage: "film.stack")
                    .badge(jobs.running)
                    .tag(Place.rips)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            if !configured {
                SettingsForm(firstRun: true)
                    .frame(maxWidth: 500)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch nav.place {
                case .disc, nil: DiscView()
                case .rips: RipsView()
                }
            }
        }
        .overlay(alignment: .bottom) { ToastView() }
    }
}

struct ToastView: View {
    @Bindable private var nav = Nav.shared

    var body: some View {
        if let t = nav.toast {
            HStack(spacing: 14) {
                Text(t.message)
                Button { nav.toast = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .shadow(radius: 8, y: 2)
            .padding(.bottom, 24)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// A poster, or the disc symbol in its place.
struct Poster: View {
    var data: Data?
    var width: CGFloat

    var body: some View {
        Group {
            if let data, let img = NSImage(data: data) { Image(nsImage: img).resizable().scaledToFill() }
            else { Image(systemName: "opticaldisc").font(.system(size: width / 3, weight: .light)).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary) }
        }
        .frame(width: width, height: width * 1.5)
        .clipShape(RoundedRectangle(cornerRadius: width / 12))
    }
}
