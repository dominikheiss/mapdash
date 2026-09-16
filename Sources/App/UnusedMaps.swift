import AppKit
import SwiftUI

/// "Unused maps…": the map folder, oldest use first, so large maps nobody plays any more are easy
/// to find. MapDash never deletes maps; this window only shows them in Finder.
///
/// "Last used" is the file's access date. macOS updates it when a file is read, but at most once a
/// day (measured: a read left a same-day access date unchanged, and updated one from January).
@MainActor
enum UnusedMapsWindow {
    private static var window: NSWindow?
    static let state = UnusedMapsState()

    static func show() {
        if window == nil {
            let w = EscapeClosingWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
                                        styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                        backing: .buffered, defer: false)
            w.title = "Unused maps"
            w.isReleasedWhenClosed = false
            w.contentMinSize = NSSize(width: 420, height: 260)
            w.contentView = NSHostingView(rootView: UnusedMapsView(state: state))
            w.center()
            window = w
        }
        state.reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct MapFile: Identifiable {
    let url: URL
    let bytes: Int64
    let lastUsed: Date
    var id: String { url.lastPathComponent }
}

final class UnusedMapsState: ObservableObject {
    static let ages: [(label: String, days: Int)] = [("1 month", 30), ("3 months", 91), ("6 months", 182), ("1 year", 365)]

    @Published var files: [MapFile] = []
    @Published var loading = false
    @Published var days = 91

    func reload() {
        loading = true
        Task.detached(priority: .userInitiated) {
            let found = UnusedMapsState.read()
            await MainActor.run {
                self.files = found
                self.loading = false
            }
        }
    }

    private static func read() -> [MapFile] {
        let keys: [URLResourceKey] = [.contentAccessDateKey, .contentModificationDateKey, .creationDateKey,
                                      .fileSizeKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: Paths.mapDir, includingPropertiesForKeys: keys,
                                                                 options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                  Constants.mapExtensions.contains(where: { url.lastPathComponent.lowercased().hasSuffix($0) }) else { return nil }
            // A copied file can carry an access date older than its arrival here; never count
            // a map as unused before it existed in the folder.
            let dates = [v.contentAccessDate, v.contentModificationDate, v.creationDate].compactMap { $0 }
            return MapFile(url: url, bytes: Int64(v.fileSize ?? 0), lastUsed: dates.max() ?? Date())
        }
        .sorted { $0.lastUsed < $1.lastUsed }
    }
}

struct UnusedMapsView: View {
    @ObservedObject var state: UnusedMapsState

    private static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    var body: some View {
        let cutoff = Date().addingTimeInterval(-Double(state.days) * 86400)
        let old = state.files.filter { $0.lastUsed < cutoff }
        let oldBytes = old.reduce(Int64(0)) { $0 + $1.bytes }
        let allBytes = state.files.reduce(Int64(0)) { $0 + $1.bytes }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Not used for", selection: $state.days) {
                    ForEach(UnusedMapsState.ages, id: \.days) { Text($0.label).tag($0.days) }
                }
                .fixedSize()   // keeps the picker from stretching across the window
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(old.map(\.url)) }
                    .disabled(old.isEmpty)
                    .help("Selects these maps in Finder. To free space, move them to the Trash there.")
            }
            Text(state.loading ? "Reading the map folder…"
                 : "\(old.count) of \(state.files.count) maps, \(formatSize(oldBytes)) of \(formatSize(allBytes))")
                .font(.caption)
                .foregroundColor(.secondary)
            HStack(spacing: 12) {
                Text("Map")
                Spacer()
                Text("Size").frame(width: 70, alignment: .trailing)
                Text("Last used").frame(width: 110, alignment: .trailing)
                Text("").frame(width: 60)
            }
            .font(.caption.weight(.semibold))
            .foregroundColor(.secondary)
            .padding(.horizontal, 4)
            Divider()
            // ScrollView, not List - see SearchView.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(old) { file in
                        HStack(spacing: 12) {
                            Text(cleanName(file.id)).lineLimit(1)
                            Spacer()
                            Text(formatMB(file.bytes)).foregroundColor(.secondary).monospacedDigit()
                                .frame(width: 70, alignment: .trailing)
                            Text(Self.dateFormat.string(from: file.lastUsed))
                                .foregroundColor(.secondary)
                                .frame(width: 110, alignment: .trailing)
                            Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                                .frame(width: 60)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 4)
                        Divider()
                    }
                }
            }
            Text("MapDash never deletes maps. A map you delete is downloaded again when a lobby needs it.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(12)
    }
}
