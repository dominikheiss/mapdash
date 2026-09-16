import AppKit
import ServiceManagement
import SwiftUI

@main
struct MapDashApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        // A second copy never builds its model (no scanning, no downloads) and shows no icon; its
        // delegate points at the running copy and quits.
        MenuBarExtra(isInserted: .constant(!Instance.isDuplicate)) {
            if !Instance.isDuplicate { MenuContent(model: model, settings: model.settings) }
        } label: {
            if !Instance.isDuplicate { MenuLabel(model: model) }
        }
        .menuBarExtraStyle(.menu)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Read before anything else handles the launch event.
        StartWindow.launchedAtLogin = StartWindow.isLoginLaunch()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Instance.isDuplicate {
            Instance.explainAndQuit()
            return
        }
        if FirstRun.showIfNeeded() || Updater.announceIfJustUpdated() { return }
        StartWindow.showIfWanted()
    }
}

/// Only one MapDash may run: two copies would download the same maps into the same folder.
enum Instance {
    static let isDuplicate: Bool = {
        let me = NSRunningApplication.current
        guard let id = Bundle.main.bundleIdentifier else { return false }
        // The older copy wins; on an exact tie the lower PID does, so two copies started together
        // never both quit.
        return NSRunningApplication.runningApplications(withBundleIdentifier: id).contains { other in
            guard other.processIdentifier != me.processIdentifier, !other.isTerminated else { return false }
            let a = other.launchDate ?? .distantPast, b = me.launchDate ?? .distantFuture
            return a < b || (a == b && other.processIdentifier < me.processIdentifier)
        }
    }()

    static func explainAndQuit() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "MapDash is already running"
        alert.informativeText = StartWindow.whereToFind
        alert.addButton(withTitle: "OK")
        alert.runModal()
        NSApp.terminate(nil)
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

    private func clean(_ s: String) -> String { cleanName(s) }

    var body: some View {
        if model.installingUpdate {
            Text("Installing update…")
            Divider()
        } else if let update = model.update {
            Button("Update available: \(update.version)…") { Updater.offer(update, model: model) }
            Divider()
        }

        status
        Button("Search maps…") { SearchWindow.show(model) }
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
            Menu("Different version on disk (\(conflict.count))") {
                Text("A file with the same name but different content is already in your map folder.")
                Text("MapDash never replaces files, so the game downloads these itself when you join.")
                Text("Click one to show the old file in Finder.")
                Divider()
                ForEach(conflict, id: \.0) { _, e in
                    Button(clean(e.file)) { revealFile(e.file) }
                }
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
        Button("Unused maps…") { UnusedMapsWindow.show() }
        Button("Open log") { NSWorkspace.shared.open(Paths.logFile) }
        Button("Copy diagnostics") { Diagnostics.copy(model) }
        Button("Report a problem…") { Diagnostics.report(model, title: "") }
        Button("About MapDash \(UpdateCheck.current)") { FirstRun.show() }
        Divider()
        Button("Quit MapDash") {
            model.stopDownloads()
            NSApp.terminate(nil)
        }
    }

    @ViewBuilder private var status: some View {
        if let suspect = model.gameUpdateSuspect {
            // Replaces the usual status lines: after a game patch they would only say "0 lobbies".
            Text("Warcraft III was updated (\(suspect.old) → \(suspect.new))")
            if case .reading = model.scan {
                Text("MapDash finds no lobbies, not even with a full scan.")
                Text(model.update == nil
                     ? "If the Custom Games list is open, MapDash needs an update for this game version."
                     : "If the Custom Games list is open, install the MapDash update above.")
            } else {
                Text("MapDash can no longer read the game.")
                Text(model.update == nil ? "MapDash needs an update for this game version." : "Install the MapDash update above.")
            }
            if model.update == nil {
                Button("Report this on GitHub…") {
                    Diagnostics.report(model, title: "Not working with Warcraft III \(suspect.new)")
                }
            }
        } else {
            scanStatus
        }
        if !settings.auto { Text("Auto-download is off") }
        if model.lowSpace {
            Text("Downloads paused: less than \(settings.minFreeBytes / 1_000_000_000) GB free")
        }
        Text("Map folder: \(formatSize(model.folderBytes))")
        if let today = model.stats.todayLine() { Text(today) }
        // On the first day both lines would say the same.
        if let total = model.stats.totalLine(), model.stats.totalMaps != model.stats.todayMaps || model.stats.todayLine() == nil {
            Text(total)
        }
    }

    @ViewBuilder private var scanStatus: some View {
        switch model.scan {
        case .starting:
            Text("Starting…")
        case .gameNotRunning:
            Text("Warcraft III is not running")
        case .noAccess(let kr):
            Text("MapDash cannot read the game (error \(kr))")
            if Account.isAdmin == false {
                Text("MapDash needs an administrator account.")
            } else {
                Button("Report this on GitHub…") { Diagnostics.report(model, title: "Cannot read the game (error \(kr))") }
            }
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
    /// True if the notice was shown (it already says where the icon is).
    static func showIfNeeded() -> Bool {
        if UserDefaults.standard.bool(forKey: "acceptedNotice") { return false }
        show()
        return true
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

        MapDash never deletes or replaces map files.

        \(StartWindow.whereToFind)

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

/// A menu bar app has no window, so a double-click seems to do nothing. This says where it went.
enum StartWindow {
    static let whereToFind = """
    MapDash has no window. It runs in the menu bar at the top right of the screen (box icon). \
    On MacBooks with a notch, a full menu bar can hide it behind the notch - quit a few other \
    menu bar apps to make room.
    """

    static var launchedAtLogin = false

    static func showIfWanted() {
        let d = UserDefaults.standard
        if launchedAtLogin || d.bool(forKey: "hideStartWindow") { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "MapDash is running"
        alert.informativeText = whereToFind
        alert.addButton(withTitle: "OK")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't show this again"
        alert.runModal()
        if alert.suppressionButton?.state == .on { d.set(true, forKey: "hideStartWindow") }
    }

    /// No window at login. The launch Apple event carries this flag for login items; whether
    /// macOS sets it for SMAppService launches is not verified, hence the uptime fallback: a
    /// login item starts within seconds of the session, a double-click practically never does.
    static func isLoginLaunch() -> Bool {
        let event = NSAppleEventManager.shared().currentAppleEvent
        if event?.eventID == kAEOpenApplication,
           event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem {
            return true
        }
        guard SMAppService.mainApp.status == .enabled, let login = sessionStart() else { return false }
        return Date().timeIntervalSince(login) < 120
    }

    /// When the current user logged in on the console, from utmpx.
    private static func sessionStart() -> Date? {
        var latest: Date?
        setutxent()
        defer { endutxent() }
        while let entry = getutxent() {
            let e = entry.pointee
            guard e.ut_type == USER_PROCESS else { continue }
            let user = withUnsafeBytes(of: e.ut_user) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let line = withUnsafeBytes(of: e.ut_line) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard user == NSUserName(), line == "console" else { continue }
            let date = Date(timeIntervalSince1970: TimeInterval(e.ut_tv.tv_sec))
            if latest == nil || date > latest! { latest = date }
        }
        return latest
    }
}
