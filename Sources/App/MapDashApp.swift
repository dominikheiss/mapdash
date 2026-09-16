import AppKit
import ServiceManagement
import SwiftUI

@main
struct MapDashApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model, settings: model.settings)
        } label: {
            MenuLabel(model: model)
        }
        .menuBarExtraStyle(.menu)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Notifier.requestPermission()
        FirstRun.showIfNeeded()
    }
}

struct MenuLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let downloading = model.maps.values.filter { $0.status == .downloading }
        if case .noAccess = model.scan {
            Image(systemName: "exclamationmark.triangle")
        } else if !downloading.isEmpty {
            let done = downloading.reduce(Int64(0)) { $0 + $1.doneBytes }
            let total = max(downloading.reduce(Int64(0)) { $0 + ($1.size ?? 0) }, 1)
            HStack(spacing: 2) {
                Image(systemName: "arrow.down.circle")
                Text("\(Int(100 * done / total))%")
            }
        } else {
            Image(systemName: "shippingbox")
        }
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: Settings

    private func entries(_ statuses: [MapStatus], listedOnly: Bool = true) -> [(String, MapEntry)] {
        model.maps
            .filter { statuses.contains($0.value.status) && (!listedOnly || $0.value.listed || $0.value.requested) }
            .sorted { ($0.value.size ?? 0, $0.value.file) < ($1.value.size ?? 0, $1.value.file) }
    }

    /// Menu titles are plain text; WC3 names carry |cffRRGGBB colour codes.
    private func clean(_ s: String) -> String {
        s.replacingOccurrences(of: #"\|c[0-9a-fA-F]{8}|\|r"#, with: "", options: .regularExpression)
    }

    var body: some View {
        if let update = model.update {
            Button("Update available: \(update.version)") {
                if let page = update.page { NSWorkspace.shared.open(page) }
            }
            Divider()
        }

        status
        Divider()

        let downloading = entries([.downloading])
        if !downloading.isEmpty {
            Section("Downloading") {
                ForEach(downloading, id: \.0) { _, e in
                    let pct = (e.size ?? 0) > 0 ? Int(100 * e.doneBytes / (e.size ?? 1)) : 0
                    Text("\(clean(e.file)) — \(pct)% of \(formatMB(e.size ?? 0))")
                }
            }
        }
        let queued = entries([.queued, .probing, .unknown])
        if !queued.isEmpty {
            Menu("Queued (\(queued.count))") {
                ForEach(queued, id: \.0) { _, e in
                    Text(e.size.map { "\(clean(e.file)) — \(formatMB($0))" } ?? clean(e.file))
                }
            }
        }
        let large = entries([.large, .waiting])
        if !large.isEmpty {
            Section(settings.auto ? "Large maps — click to download" : "Missing maps — click to download") {
                ForEach(large, id: \.0) { key, e in
                    Button("\(clean(e.file)) — \(formatMB(e.size ?? 0))") { model.fetch(key) }
                        .help("Lobby: \(e.lobbies.map(clean).joined(separator: ", "))")
                }
            }
        }
        let failed = entries([.failed])
        if !failed.isEmpty {
            Section("Failed — click to retry") {
                ForEach(failed, id: \.0) { key, e in
                    Button("\(clean(e.file)) — \(e.error ?? "error")") { model.retry(key) }
                }
            }
        }
        let conflict = entries([.conflict])
        if !conflict.isEmpty {
            Menu("Other version already on disk (\(conflict.count))") {
                ForEach(conflict, id: \.0) { _, e in Text(clean(e.file)) }
                Divider()
                Text("Left untouched — the game handles these itself.")
            }
        }
        let ready = entries([.present, .done, .checking])
        Menu("Ready (\(ready.count))") {
            ForEach(ready.sorted { $0.1.file.lowercased() < $1.1.file.lowercased() }, id: \.0) { _, e in
                Text(clean(e.file))
            }
        }

        Divider()
        settingsMenu
        Button("Open map folder") { NSWorkspace.shared.open(Paths.mapDir) }
        Button("Open log") { NSWorkspace.shared.open(Paths.logFile) }
        Button("About MapDash \(UpdateCheck.current)") { FirstRun.show() }
        Divider()
        Button("Quit MapDash") { NSApp.terminate(nil) }
    }

    @ViewBuilder private var status: some View {
        switch model.scan {
        case .starting:
            Text("Starting…")
        case .gameNotRunning:
            Text("Warcraft III is not running")
        case .noAccess:
            Text("MapDash may not read the game")
            Button("Grant access… (admin password)") { model.grantAccess() }
            Text("Needed once on accounts without admin rights.")
        case .reading(let count):
            if count == 0 {
                Text("No lobbies found — open the Custom Games list")
                Text("If it stays at 0 there, a game patch may have broken MapDash.")
            } else {
                Text("\(count) lobbies in the list")
            }
        case .failed:
            Text("Reading the game list failed")
        }
        if !settings.auto { Text("Auto-download is off") }
        Text("Map folder: \(formatMB(model.folderBytes))")
    }

    private var settingsMenu: some View {
        Menu("Settings") {
            Toggle("Download small maps automatically", isOn: $settings.auto)
            Picker("Automatic up to", selection: $settings.thresholdMB) {
                ForEach(Settings.thresholds, id: \.self) { Text($0 == 0 ? "No limit" : "\($0) MB").tag($0) }
            }
            Picker("Downloads at once", selection: $settings.parallel) {
                ForEach(Settings.parallels, id: \.self) { Text("\($0)").tag($0) }
            }
            Picker("Speed limit per download", selection: $settings.rateLimitMB) {
                ForEach(Settings.rateLimits, id: \.self) { Text($0 == 0 ? "None" : "\($0) MB/s").tag($0) }
            }
            Toggle("Notify when maps are ready", isOn: $settings.notify)
            Divider()
            Toggle("Start at login", isOn: $settings.startAtLogin)
        }
    }
}

/// The risk notice. Shown once on first start and from "About".
enum FirstRun {
    static func showIfNeeded() {
        if !UserDefaults.standard.bool(forKey: "acceptedNotice") { show() }
    }

    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "MapDash \(UpdateCheck.current)"
        alert.informativeText = """
        MapDash reads the custom game list out of the running Warcraft III (read-only) and \
        downloads missing maps from Blizzard's map server before you join, so the game's own slow \
        download never starts.

        Reading another program's memory is very likely against Blizzard's terms of service. \
        Blizzard could act against your account. You use MapDash at your own risk.

        MapDash never deletes or replaces map files. It lives in the menu bar (box icon).

        Not affiliated with or endorsed by Blizzard Entertainment.
        """
        alert.addButton(withTitle: "I understand")
        alert.addButton(withTitle: "Quit")
        if alert.runModal() == .alertFirstButtonReturn {
            UserDefaults.standard.set(true, forKey: "acceptedNotice")
        } else {
            NSApp.terminate(nil)
        }
    }
}
