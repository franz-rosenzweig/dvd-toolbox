import SwiftUI
import AppKit

/// Every rip: ripping, uploading, in Jellyfin, or what went wrong.
struct RipsView: View {
    @State private var jobs = Jobs.shared

    var body: some View {
        Group {
            if jobs.list.isEmpty {
                Image(systemName: "film.stack").font(.system(size: 56, weight: .light)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(jobs.list) { job in JobRow(job: job) }
                }
            }
        }
        .navigationTitle("Rips")
    }
}

struct JobRow: View {
    let job: Job
    @State private var jobs = Jobs.shared

    var body: some View {
        HStack(spacing: 14) {
            Poster(data: job.poster, width: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.name).font(.headline).lineLimit(1)
                HStack(spacing: 6) {
                    state
                    Text("· \(job.library) · \(job.parts.count == 1 ? Fmt.clock(job.parts[0].seconds) : "\(job.parts.count) episodes")")
                        .foregroundStyle(.secondary)
                    if job.bytes > 0 { Text("· \(Fmt.size(job.bytes))").foregroundStyle(.secondary) }
                }
                .font(.callout).lineLimit(1)
                if let e = job.error, job.state != .waiting { Label(e, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange).lineLimit(2) }
                if job.state == .ripping { ProgressView(value: job.progress) }
                if job.state == .uploading { ProgressView(value: job.sent) }
            }
            Spacer()
            if job.active {
                Button("Cancel") { job.cancel() }
            } else if job.state == .ripped || job.state == .sent {
                Button(job.state == .sent ? "Upload Again" : "Upload", systemImage: "arrow.up.circle") { jobs.upload(job) }
            }
            Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([job.folder]) }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                .disabled(!FileManager.default.fileExists(atPath: job.folder.path))
        }
        .padding(.vertical, 6)
        .contextMenu {
            Button("Remove from List") { jobs.remove(job.id) }.disabled(job.active)
        }
    }

    @ViewBuilder private var state: some View {
        switch job.state {
        case .waiting: Text("Waiting").foregroundStyle(.secondary)
        case .ripping: Text(DiscView.status(job)).foregroundStyle(.secondary).monospacedDigit()
        case .ripped: Text("Ripped").foregroundStyle(.secondary)
        case .queued: Text("Ripped · Waiting to Upload").foregroundStyle(.secondary)
        case .uploading:
            Text("Uploading \(Int(job.sent * 100))%" + (job.rate > 0 ? " · " + Fmt.rate(job.rate) : "")).foregroundStyle(.secondary).monospacedDigit()
        case .checking: Text("Checking Jellyfin").foregroundStyle(.secondary)
        case .done: Label("In Jellyfin", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .sent: Label("Uploaded", systemImage: "checkmark.circle").foregroundStyle(.secondary)
        case .failed: Label("Failed", systemImage: "xmark.circle.fill").foregroundStyle(.red)
        case .cancelled: Text("Cancelled").foregroundStyle(.secondary)
        }
    }
}
