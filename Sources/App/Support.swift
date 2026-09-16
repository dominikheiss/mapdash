import AppKit
import CryptoKit
import Foundation
import ServiceManagement

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
    static let bundleID = "io.github.dominikheiss.mapdash"
    static let newIssue = URL(string: "https://github.com/dominikheiss/mapdash/issues/new")!
    // The game's own download speed on the Mac, measured at 245 KB/s (200-270). Used only for the
    // "time saved" estimate in the menu.
    static let gameBytesPerSecond = 250_000.0
    static let mapExtensions = [".w3x", ".w3m"]
    static let scanInterval: UInt64 = 4          // seconds between scans while the game runs
    static let idleInterval: UInt64 = 5          // seconds between looks for the game
    // Every n-th scan also reads all memory to cross-check the fast region filter. A full scan
    // walks all of the game's readable memory; on 8 GB Macs that pressure is spaced out further.
    // (A judgement call, not a measurement - no 8 GB Mac was available to test on.)
    static let fullScanEvery = ProcessInfo.processInfo.physicalMemory <= 8 << 30 ? 45 : 15
    static let retryAfter: TimeInterval = 300
    static let maxAttempts = 3
    static let forgetAfter: TimeInterval = 7 * 86400
}

/// Downloads MapDash did itself. Copies of maps already on disk do not count.
struct Stats: Codable, Equatable {
    var day = ""                 // local yyyy-MM-dd the "today" numbers belong to
    var todayMaps = 0
    var todayBytes: Int64 = 0
    var todaySeconds = 0.0
    var totalMaps = 0
    var totalBytes: Int64 = 0
    var totalSeconds = 0.0

    static func dayString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    mutating func add(bytes: Int64, seconds: Double, at date: Date = Date()) {
        let today = Stats.dayString(date)
        if day != today {
            day = today
            todayMaps = 0; todayBytes = 0; todaySeconds = 0
        }
        todayMaps += 1; todayBytes += bytes; todaySeconds += seconds
        totalMaps += 1; totalBytes += bytes; totalSeconds += seconds
    }

    /// Nil if nothing was downloaded today.
    func todayLine(now: Date = Date()) -> String? {
        guard day == Stats.dayString(now), todayMaps > 0 else { return nil }
        return "Today: " + Stats.describe(todayMaps, todayBytes, todaySeconds)
    }

    func totalLine() -> String? {
        totalMaps > 0 ? "All time: " + Stats.describe(totalMaps, totalBytes, totalSeconds) : nil
    }

    /// "3 maps, 120 MB, about 8 min saved". Saved = the game's time for these bytes minus MapDash's.
    static func describe(_ maps: Int, _ bytes: Int64, _ seconds: Double) -> String {
        let saved = max(0, Double(bytes) / Constants.gameBytesPerSecond - seconds)
        let minutes = Int((saved / 60).rounded())
        let time = minutes < 1 ? "under a minute"
            : minutes < 90 ? "about \(minutes) min"
            : "about \(Int((saved / 3600).rounded())) h"
        return "\(maps) \(maps == 1 ? "map" : "maps"), \(formatSize(bytes)), \(time) saved"
    }
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
        d.register(defaults: ["auto": true, "thresholdMB": 50, "parallel": 2, "rateLimitMB": 0, "notify": true,
                              "minFreeGB": 5, "hideStartWindow": false])
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

    /// No new download starts below this much free space. Not in the menu; `defaults write` only.
    var minFreeBytes: Int64 { Int64(Settings.defaultsRegistered.integer(forKey: "minFreeGB")) * 1_000_000_000 }

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

/// Menu and list titles are plain text; WC3 names carry |cffRRGGBB colour codes.
func cleanName(_ s: String) -> String {
    s.replacingOccurrences(of: #"\|c[0-9a-fA-F]{8}|\|r"#, with: "", options: .regularExpression)
}

/// MB up to 10 GB, GB above.
func formatSize(_ bytes: Int64) -> String {
    bytes >= 10_000_000_000 ? String(format: "%.1f GB", Double(bytes) / 1_000_000_000) : formatMB(bytes)
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

/// A GitHub release, as far as the updater needs it.
struct Release: Equatable {
    let version: String
    let page: URL?
    let notes: String
    let zip: URL?
    let sha256: String?   // GitHub's asset digest, lower-case hex
}

/// Once a day: is there a newer GitHub release?
enum UpdateCheck {
    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Test copies (another bundle id) may read releases from `defaults write <id> updateFeed <url>`.
    /// The released app always asks GitHub.
    private static var feed: URL? {
        if Bundle.main.bundleIdentifier != Constants.bundleID,
           let custom = UserDefaults.standard.string(forKey: "updateFeed") {
            return URL(string: custom)
        }
        return URL(string: "https://api.github.com/repos/\(Constants.repo)/releases/latest")
    }

    static func latest(completion: @escaping (Release?) -> Void) {
        guard let url = feed else { return }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: request) { data, response, _ in
            guard (response as? HTTPURLResponse)?.statusCode == 200, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else { completion(nil); return }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let assets = json["assets"] as? [[String: Any]] ?? []
            let zip = assets.first { ($0["name"] as? String) == "MapDash-\(version).zip" }
            let digest = zip?["digest"] as? String
            completion(Release(
                version: version,
                page: (json["html_url"] as? String).flatMap(URL.init(string:)),
                notes: json["body"] as? String ?? "",
                zip: (zip?["browser_download_url"] as? String).flatMap(URL.init(string:)),
                sha256: digest.flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)).lowercased() : nil }))
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

/// MapDash supports admin accounts only: macOS lets members of _developer take the game's task
/// port, and _developer nests the admin group by default. Asked once per launch.
enum Account {
    static let isAdmin: Bool? = {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/dsmemberutil")
        p.arguments = ["checkmembership", "-U", NSUserName(), "-G", "admin"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        if text.contains("is not a member") { return false }
        if text.contains("is a member") { return true }
        return nil
    }()
}
