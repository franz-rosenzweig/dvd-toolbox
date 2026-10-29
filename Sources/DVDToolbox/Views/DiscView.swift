import SwiftUI
import AppKit

/// The DVD in the drive: what it is, which titles to rip, and where they go.
struct DiscView: View {
    @Bindable private var store = DiscStore.shared
    @State private var jobs = Jobs.shared
    @AppStorage("ejectWhenDone") private var ejectWhenDone = true

    var body: some View {
        Group {
            if let disc = store.disc { content(disc) }
            else {
                Image(systemName: "opticaldisc").font(.system(size: 56, weight: .light)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(store.disc?.label ?? "Disc")
        .task {
            // Jellyfin or the server may not answer at first (the Mac has just woken, the network is coming up):
            // ask again until they do
            while !Task.isCancelled {
                if store.libraries.isEmpty || store.jellyfinError != nil { await store.loadLibraries() }
                if store.serverError != nil, store.item != nil { await store.checkServer() }
                let fine = !store.libraries.isEmpty && store.jellyfinError == nil && store.serverError == nil
                try? await Task.sleep(for: .seconds(fine ? 30 : 10))
            }
        }
    }

    private func content(_ disc: DVDDisc) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let e = store.error { Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                if let e = store.jellyfinError { Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                if let e = store.serverError { Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                if store.scanning {
                    HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Reading the disc").foregroundStyle(.secondary) }
                } else if !store.titles.isEmpty {
                    titles
                    destination
                }
                actions
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: what it is

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            Poster(data: store.poster, width: 120)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Picker("Kind", selection: Binding(get: { store.kind }, set: { k in Task { await store.setKind(k) } })) {
                        ForEach(Kind.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 160)
                    if store.looking || store.checking { ProgressView().controlSize(.small) }
                    Spacer()
                }
                HStack {
                    TextField("Title", text: $store.query).textFieldStyle(.roundedBorder).font(.title3.weight(.semibold))
                        .onSubmit { Task { await store.search() } }
                    TextField("Year", text: $store.year).textFieldStyle(.roundedBorder).frame(width: 70)
                        .onSubmit { Task { await store.search() } }
                    Button("Search", systemImage: "magnifyingglass") { Task { await store.search() } }.labelStyle(.iconOnly)
                }
                if !store.results.isEmpty {
                    Picker("Match", selection: Binding(get: { store.chosen ?? 0 }, set: { id in Task { await store.choose(id) } })) {
                        ForEach(store.results) { Text($0.summary).tag($0.id) }
                    }
                    .labelsHidden().frame(maxWidth: 420, alignment: .leading)
                }
                HStack(spacing: 16) {
                    if store.kind == .tv {
                        Stepper("Season \(store.season)", value: Binding(get: { store.season }, set: { n in Task { await store.setSeason(n) } }), in: 0...max(1, store.seasons))
                            .fixedSize()
                        Stepper("First Episode \(store.firstEpisode)", value: $store.firstEpisode, in: 1...999).fixedSize()
                    }
                    if !store.choices.isEmpty {
                        Picker("Library", selection: Binding(get: { store.libraryID }, set: { id in
                            store.setLibrary(id, for: store.kind); Task { await store.checkServer() }
                        })) {
                            ForEach(store.choices) { Text($0.name).tag($0.id) }
                        }
                        .fixedSize()
                    }
                }
                if let ex = store.existing {
                    Label(store.kind == .tv && !store.present.isEmpty ? "\(ex) · \(Naming.season(store.season)) · \(store.present.count) on the server" : "\(ex) · in the library",
                          systemImage: "checkmark.circle").foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: the titles

    private var titles: some View {
        let job = store.job
        let nums = store.numbers
        return VStack(spacing: 0) {
            ForEach(store.titles) { t in
                if t.index != store.titles.first?.index { Divider() }
                HStack(spacing: 12) {
                    mark(t, job: job)
                    Text("Title \(t.index)").monospacedDigit().frame(width: 64, alignment: .leading)
                    Text(Fmt.clock(t.seconds)).monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
                    if store.kind == .tv, let n = nums[t.index] {
                        let name = store.episodeName(n)
                        Text(Naming.episodeCode(store.season, n) + (name.isEmpty ? "" : " · " + name)).lineLimit(1)
                        if store.present.contains(n) { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help("On the server") }
                    } else if store.kind == .movie, t.index == store.feature, let it = store.item {
                        Text(Naming.folder(it.title, it.year)).lineLimit(1)
                    }
                    Spacer()
                    Text("\(t.chapters) ch").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    Text(t.languages).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    if !t.subtitles.isEmpty { Label("\(t.subtitles.count)", systemImage: "captions.bubble").font(.callout).foregroundStyle(.secondary).monospacedDigit() }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .contentShape(Rectangle())
                .onTapGesture { if job == nil { toggle(t) } }
            }
        }
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder private func mark(_ t: DVDTitle, job: Job?) -> some View {
        if let job, let p = job.parts.first(where: { $0.id == t.index }) {
            Group {
                switch p.state {
                case .waiting: Image(systemName: "circle").foregroundStyle(.tertiary)
                case .ripping: ProgressView().controlSize(.small)
                case .ripped: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
            }
            .frame(width: 20)
        } else {
            let on = store.kind == .movie ? store.feature == t.index : store.selected.contains(t.index)
            Image(systemName: store.kind == .movie ? (on ? "largecircle.fill.circle" : "circle") : (on ? "checkmark.square.fill" : "square"))
                .foregroundStyle(on ? Color.accentColor : Color.secondary)
                .frame(width: 20)
                .opacity(job == nil ? 1 : 0.4)
        }
    }

    private func toggle(_ t: DVDTitle) {
        if store.kind == .movie { store.feature = t.index }
        else if store.selected.contains(t.index) { store.selected.remove(t.index) }
        else { store.selected.insert(t.index) }
    }

    private var destination: some View {
        let parts = store.parts
        return Group {
            if let lib = store.library, let first = parts.first {
                let path = store.kind == .movie ? first.file : (first.file as NSString).deletingLastPathComponent
                Label("\(lib.name)/\(path)", systemImage: "folder").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
    }

    // MARK: ripping

    private var actions: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let job = store.job {
                ProgressView(value: job.progress)
                HStack {
                    Text(Self.status(job)).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    Button("Cancel") { job.cancel() }
                }
            } else {
                HStack {
                    Button("Rip and Upload") { Task { await store.rip(upload: true) } }.buttonStyle(.borderedProminent).disabled(!store.ready)
                    Button("Rip") { Task { await store.rip(upload: false) } }.disabled(!store.ready)
                    Toggle("Eject When Done", isOn: $ejectWhenDone).toggleStyle(.checkbox).padding(.leading, 8)
                    Spacer()
                    Button("Eject", systemImage: "eject") { Task { await store.eject() } }
                }
            }
        }
    }

    static func status(_ job: Job) -> String {
        guard let c = job.current, let i = job.parts.firstIndex(where: { $0.id == c }) else { return job.state == .waiting ? "Waiting" : "" }
        var s = "\(job.parts[i].label) · \(i + 1) of \(job.parts.count) · \(Int(job.fraction * 100))%"
        if let eta = job.eta, eta > 0 { s += " · " + Fmt.left(Double(eta)) }
        return s
    }
}
