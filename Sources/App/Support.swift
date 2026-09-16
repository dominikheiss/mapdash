import AppKit
import CryptoKit
import Foundation
import ServiceManagement
import UserNotifications

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let mapDir = home.appendingPathComponent("Library/Application Support/Blizzard/Warcraft III/Maps/Download")
    static let appDir = home.appendingPathComponent("Library/Application Support/MapDash")
    static let stateFile = appDir.appendingPathComponent("state.json")
    static let logFile = home.appendingPathComponent("Library/Logs/MapDash.log")
}

enum Constants {
    static let cdn = "https://ugc.cdn.warcraft3-prod.battle.net/W3-maps-user/%@.map"
    static let curl = "/usr/bin/curl"
    static let repo = "dominikheiss/mapdash"
    static let mapExtensions = [".w3x", ".w3m"]
    static let scanInterval: UInt64 = 4          // seconds between scans while the game runs
    static let idleInterval: UInt64 = 5          // seconds between looks for the game
    static let fullScanEvery = 15                // every n-th scan also reads all memory
    static let retryAfter: TimeInterval = 300
    static let maxAttempts = 3
    static let forgetAfter: TimeInterval = 7 * 86400
}

/// User settings. The allowed values are fixed lists so the menu can show them as choices.
final class Settings: ObservableObject {
    static let thresholds = [25, 50, 100, 150, 250, 500, 0]   // MB, 0 = no limit
    static let parallels = [1, 2, 3]
    static let rateLimits = [0, 5, 10, 20]                    // MB/s, 0 = none

    private let d = UserDefaults.standard

    // The defaults must be registered before the first read. Property initialisers run before
    // init's body, so reading there returned false/0 on a fresh install (auto-download off).
    private static let defaultsRegistered: UserDefaults = {
        let d = UserDefaults.standard
        d.register(defaults: ["auto": true, "thresholdMB": 50, "parallel": 2, "rateLimitMB": 0, "notify": true])
        return d
    }()

    @Published var auto: Bool = Settings.defaultsRegistered.bool(forKey: "auto") { didSet { d.set(auto, forKey: "auto") } }
    @Published var thresholdMB: Int = Settings.defaultsRegistered.integer(forKey: "thresholdMB") { didSet { d.set(thresholdMB, forKey: "thresholdMB") } }
    @Published var parallel: Int = Settings.defaultsRegistered.integer(forKey: "parallel") { didSet { d.set(parallel, forKey: "parallel") } }
    @Published var rateLimitMB: Int = Settings.defaultsRegistered.integer(forKey: "rateLimitMB") { didSet { d.set(rateLimitMB, forKey: "rateLimitMB") } }
    @Published var notify: Bool = Settings.defaultsRegistered.bool(forKey: "notify") { didSet { d.set(notify, forKey: "notify") } }

    // No SwiftUI @State here on purpose: the Command Line Tools ship without the SwiftUI macro
    // plugin, so the login item lives in this ObservableObject instead.
    @Published var startAtLogin: Bool = SMAppService.mainApp.status == .enabled {
        didSet {
            let wanted = startAtLogin
            do {
                if wanted { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                Log.write("login item change failed: \(error.localizedDescription)")
            }
            let actual = SMAppService.mainApp.status == .enabled
            if actual != wanted { DispatchQueue.main.async { self.startAtLogin = actual } }
        }
    }

    /// True when a map of this size should download without a click.
    func autoAllows(_ size: Int64) -> Bool {
        auto && (thresholdMB == 0 || size <= Int64(thresholdMB) * 1_000_000)
    }
}

enum Log {
    private static let queue = DispatchQueue(label: "mapdash.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            let url = Paths.logFile
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}

func sha1Hex(of url: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    var hasher = Insecure.SHA1()
    while true {
        let chunk = autoreleasepool { handle.readData(ofLength: 1 << 20) }
        if chunk.isEmpty { break }
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

/// The game always looks for Maps/Download/<file name>, whatever folder the host keeps the map in
/// (measured: list entry "Maps/0/X.w3x" resolves to ".../Maps/Download/X.w3x").
func mapFileName(fromHostPath path: String) -> String? {
    guard path.lowercased().hasPrefix("maps/") else { return nil }
    let name = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? ""
    guard !name.isEmpty, !name.hasPrefix("."), !name.contains(":"),
          Constants.mapExtensions.contains(where: { name.lowercased().hasSuffix($0) }) else { return nil }
    return name
}

func formatMB(_ bytes: Int64) -> String {
    let mb = Double(bytes) / 1_000_000
    return mb >= 1 ? String(format: "%.0f MB", mb) : String(format: "%.1f MB", mb)
}

/// Runs a command and hands back its exit code and output. Never blocks the caller.
func run(_ launchPath: String, _ args: [String], completion: @escaping (Int32, String, String) -> Void) -> Process? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = args
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    p.terminationHandler = { proc in
        let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        completion(proc.terminationStatus, o, e)
    }
    do {
        try p.run()
        return p
    } catch {
        completion(-1, "", error.localizedDescription)
        return nil
    }
}

enum Notifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error { Log.write("notification permission error: \(error.localizedDescription)") }
            else if !granted { Log.write("notifications not allowed by the user") }
        }
    }

    static func post(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { Log.write("notification failed: \(error.localizedDescription)") }
        }
    }
}

/// Once a day: is there a newer GitHub release?
enum UpdateCheck {
    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static func latest(completion: @escaping (String?, URL?) -> Void) {
        guard let url = URL(string: "https://api.github.com/repos/\(Constants.repo)/releases/latest") else { return }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            guard (response as? HTTPURLResponse)?.statusCode == 200, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else { completion(nil, nil); return }
            let page = (json["html_url"] as? String).flatMap(URL.init(string:))
            completion(tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, page)
        }.resume()
    }

    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = installed.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

/// Non-admin accounts are not in _developer and cannot read the game. Adding them needs an admin
/// password once; macOS asks for it through the standard dialog.
enum Access {
    static func grant(completion: @escaping (Bool, String) -> Void) {
        let user = NSUserName()
        let script = "do shell script \"/usr/sbin/dseditgroup -o edit -a \(user) -t user _developer\" with administrator privileges"
        DispatchQueue.global().async {
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            let message = (error?[NSAppleScript.errorMessage] as? String) ?? ""
            DispatchQueue.main.async { completion(error == nil, message) }
        }
    }
}
