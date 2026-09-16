import AppKit
import Foundation

/// Plain-text report for "Copy diagnostics". Meant to be pasted into a GitHub issue, so the home
/// folder is shortened to "~" and nothing identifies the account beyond what the log already has.
@MainActor
enum Diagnostics {
    static func copy(_ model: AppModel) {
        let text = report(model)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Copies the report and opens a new GitHub issue that asks for it to be pasted. The report
    /// is not put into the URL: it can be longer than GitHub accepts there, and the user should
    /// see what is sent.
    static func report(_ model: AppModel, title: String) {
        copy(model)
        var parts = URLComponents(url: Constants.newIssue, resolvingAgainstBaseURL: false)
        parts?.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "body", value: "What happened:\n\n\nDiagnostics (MapDash copied them to the clipboard - paste them below, and remove anything you do not want to share):\n\n```\n\n```\n"),
        ]
        if let url = parts?.url { NSWorkspace.shared.open(url) }
    }

    static func report(_ model: AppModel) -> String {
        let s = model.settings
        var lines: [String] = []
        func add(_ label: String, _ value: String) { lines.append("\(label): \(value)") }

        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        add("MapDash", "\(UpdateCheck.current) (\(build))\(sysctlInt("sysctl.proc_translated") == 1 ? ", under Rosetta" : "")")
        add("macOS", ProcessInfo.processInfo.operatingSystemVersionString)
        add("Chip", sysctlString("machdep.cpu.brand_string") ?? "?")
        add("Memory", "\(ProcessInfo.processInfo.physicalMemory >> 30) GB")
        add("Admin account", Account.isAdmin.map { $0 ? "yes" : "no" } ?? "unknown")

        if model.gamePID != 0, let app = NSRunningApplication(processIdentifier: model.gamePID) {
            let bundle = app.bundleURL.flatMap(Bundle.init(url:))
            let version = bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
            let arch: String
            switch app.executableArchitecture {
            case NSBundleExecutableArchitectureARM64: arch = "arm64"
            case NSBundleExecutableArchitectureX86_64: arch = "x86_64"
            default: arch = "?"
            }
            add("Game", "\(tilde(app.bundleURL?.path ?? "?")) \(version) \(arch)")
            add("Lobbies last found in", model.lastWorkingGameVersion ?? "never")
        } else {
            add("Game", "not running")
        }
        switch model.scan {
        case .starting: add("Reading", "starting")
        case .gameNotRunning: add("Reading", "game not running")
        case .noAccess(let kr): add("Reading", "refused (task_for_pid \(kr))")
        case .reading(let n): add("Reading", "ok, \(n) lobbies")
        case .failed: add("Reading", "region walk failed")
        }
        add("Last full scan", (model.lastFullScan.map { stamp($0) } ?? "none yet") + ", empty in a row: \(model.emptyFullScans)")
        add("Free space", model.freeBytes.map { "\($0 / 1_000_000_000) GB" } ?? "unknown")
        add("Map folder", "\(tilde(Paths.mapDir.path)) (\(FileManager.default.fileExists(atPath: Paths.mapDir.path) ? formatMB(model.folderBytes) : "missing"))")
        add("Settings", "auto=\(s.auto) limit=\(s.thresholdMB)MB parallel=\(s.parallel) rate=\(s.rateLimitMB)MB/s "
            + "notify=\(s.notify) login=\(s.startAtLogin) minFree=\(s.minFreeBytes / 1_000_000_000)GB")
        var counts: [String: Int] = [:]
        for e in model.maps.values { counts[e.status.rawValue, default: 0] += 1 }
        add("Downloads", [model.stats.todayLine(), model.stats.totalLine()].compactMap { $0 }.joined(separator: "; ").nonEmpty ?? "none")
        add("Maps", counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))

        lines.append("")
        lines.append("Last log lines:")
        lines.append(contentsOf: logTail(30))
        return lines.joined(separator: "\n")
    }

    private static func tilde(_ path: String) -> String {
        let home = Paths.home.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }

    private static func logTail(_ count: Int) -> [String] {
        guard let text = try? String(contentsOf: Paths.logFile, encoding: .utf8) else { return ["(no log)"] }
        return text.split(separator: "\n").suffix(count).map { tilde(String($0)) }
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func sysctlInt(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
