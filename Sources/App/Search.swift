import AppKit
import SwiftUI

/// "Search maps…": every map in the current lobby list, filterable by map or lobby name. The menu
/// cannot hold a text field, and with many large maps its list gets too long to scan by eye.
@MainActor
enum SearchWindow {
    private static var window: NSWindow?
    static let query = SearchQuery()

    static func show(_ model: AppModel) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "Search maps"
            w.isReleasedWhenClosed = false
            w.contentMinSize = NSSize(width: 420, height: 260)
            w.contentView = NSHostingView(rootView: SearchView(model: model, query: query))
            w.center()
            window = w
        }
        // A menu bar app is never active on its own; without this the window opens behind others.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

final class SearchQuery: ObservableObject {
    @Published var text = ""
}

struct SearchView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var query: SearchQuery

    private struct Row: Identifiable {
        let id: String
        let entry: MapEntry
        let name: String
        let lobbies: String
    }

    private var rows: [Row] {
        let needle = query.text.trimmingCharacters(in: .whitespaces)
        return model.maps
            .filter { ($0.value.listed || $0.value.requested) && $0.value.status != .invalid }
            .map { Row(id: $0.key, entry: $0.value, name: cleanName($0.value.file),
                       lobbies: $0.value.lobbies.map(cleanName).joined(separator: ", ")) }
            .filter { needle.isEmpty || $0.name.localizedStandardContains(needle) || $0.lobbies.localizedStandardContains(needle) }
            // Maps that still need a click first, then by name.
            .sorted { (needsClick($0.entry) ? 0 : 1, $0.name.lowercased()) < (needsClick($1.entry) ? 0 : 1, $1.name.lowercased()) }
    }

    private func needsClick(_ e: MapEntry) -> Bool {
        [.large, .waiting, .failed].contains(e.status)
    }

    var body: some View {
        let rows = rows
        VStack(alignment: .leading, spacing: 8) {
            TextField("Map or lobby name", text: $query.text)
                .textFieldStyle(.roundedBorder)
            Text(query.text.isEmpty ? "\(rows.count) maps in the lobby list" : "\(rows.count) matches")
                .font(.caption)
                .foregroundColor(.secondary)
            // ScrollView, not List: List is an NSTableView underneath, and refreshing it while
            // downloads progress logged "reentrant operation in its NSTableView delegate" every
            // few seconds - a warning macOS says will become a crash.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.name).lineLimit(1)
                                Text(row.lobbies.isEmpty ? " " : row.lobbies)
                                    .font(.caption).foregroundColor(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(row.entry.size.map(formatMB) ?? "").foregroundColor(.secondary).monospacedDigit()
                            status(row)
                                .frame(width: 130, alignment: .trailing)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 4)
                        Divider()
                    }
                }
            }
        }
        .padding(12)
    }

    @ViewBuilder private func status(_ row: Row) -> some View {
        let e = row.entry
        switch e.status {
        case .large, .waiting:
            Button("Download") { model.fetch(row.id) }
        case .failed:
            Button("Retry") { model.retry(row.id) }.help(e.error ?? "")
        case .downloading:
            let pct = (e.size ?? 0) > 0 ? Int(100 * e.doneBytes / (e.size ?? 1)) : 0
            Text("Downloading \(pct)%")
        case .queued, .probing, .unknown:
            Text("Queued").foregroundColor(.secondary)
        case .checking:
            Text("Checking").foregroundColor(.secondary)
        case .done, .present:
            Text("Ready").foregroundColor(.green)
        case .conflict:
            Button("Different version") { revealFile(e.file) }
                .help("A different map with this file name is on disk. MapDash never replaces files, "
                      + "so the game downloads this one itself. Click to show the file on disk.")
        case .invalid:
            Text("Unknown map").foregroundColor(.secondary)
        }
    }
}

/// Shows a map file in Finder; used where MapDash leaves a file alone and the user may want to act.
@MainActor
func revealFile(_ file: String) {
    let url = Paths.mapDir.appendingPathComponent(file)
    if FileManager.default.fileExists(atPath: url.path) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    } else {
        NSWorkspace.shared.open(Paths.mapDir)
    }
}
