import AppKit
import Combine
import Foundation

/// Experimental Warcraft III WebSocket feed + V28 verified rescue embedded in MapDash.
/// WebSocket lobby titles/map names never enter AppModel's SHA-1-keyed download queue.
/// Only V28's explicit, verified one-click rescue may write an installed map.
struct LiveWarcraftLobby: Identifiable, Equatable {
    let id: Int
    let title: String
    let map: String
    let players: Int
    let capacity: Int
}

@MainActor
final class RescueController: ObservableObject {
    @Published private(set) var liveLobbies: [LiveWarcraftLobby] = []
    @Published private(set) var liveTotal = 0
    @Published private(set) var socketState = "Connecting to Warcraft…"
    @Published private(set) var rescueStatus = "Ready to rescue a map"
    @Published private(set) var rescueActive = false
    @Published private(set) var rescueSuccess = false
    @Published private(set) var restoring = false
    @Published private(set) var autoEnabled: Bool
    @Published private(set) var autoStatus = "Starting automatic rescue…"
    @Published private(set) var lastAutoMap = ""
    private var autoProcess: Process?
    private var autoPipe: Pipe?
    private var autoBuffer = Data()
    private var stopping = false
    private static let autoPreference = "MapDashV30AutoRescueEnabled"

    private var feed: Process?
    private var rescue: Process?
    private var feedPipe: Pipe?
    private var rescuePipe: Pipe?
    private var feedBuffer = Data()
    private var rescueBuffer = Data()

    init() {
        autoEnabled = UserDefaults.standard.object(forKey: Self.autoPreference) as? Bool ?? true
        if !Instance.isDuplicate {
            startFeed()
            if autoEnabled { startAutomaticRescue() }
        }
    }

    func setAutomaticRescue(_ enabled: Bool) {
        guard enabled != autoEnabled else { return }
        autoEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.autoPreference)
        if enabled {
            autoStatus = "Starting automatic rescue…"
            startAutomaticRescue()
        } else {
            autoStatus = "Automatic rescue paused"
            autoPipe?.fileHandleForReading.readabilityHandler = nil
            if autoProcess?.isRunning == true { autoProcess?.terminate() }
            autoProcess = nil
            autoPipe = nil
        }
    }

    private func startAutomaticRescue() {
        guard autoEnabled, !stopping, autoProcess == nil, let root = Self.bridgeRoot else {
            if Self.bridgeRoot == nil { autoStatus = "Automatic rescue helper missing" }
            return
        }
        autoBuffer = Data()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [root.appendingPathComponent("scripts/v30-auto-rescue.sh").path]
        process.environment = Self.helperEnvironment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        autoPipe = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            Task { @MainActor [weak self] in self?.consumeAuto(bytes) }
        }
        process.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in
                guard let self, self.autoProcess === proc else { return }
                self.autoPipe?.fileHandleForReading.readabilityHandler = nil
                self.autoProcess = nil
                self.autoPipe = nil
                if self.autoEnabled && !self.stopping {
                    self.autoStatus = "Watcher restarting after interruption…"
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    self.startAutomaticRescue()
                }
            }
        }
        do {
            try process.run()
            autoProcess = process
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            autoPipe = nil
            autoStatus = "Automatic rescue could not start"
        }
    }

    private func consumeAuto(_ data: Data) {
        guard !data.isEmpty else { return }
        autoBuffer.append(data)
        if autoBuffer.count > 100_000 { autoBuffer.removeAll(); return }
        while let newline = autoBuffer.firstIndex(of: 10) {
            let line = Data(autoBuffer.prefix(upTo: newline))
            autoBuffer.removeSubrange(...newline)
            guard let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let event = record["event"] as? String else { continue }
            // Only our helper's sanitized JSON statuses are written. No WebSocket
            // frames, session identifiers, or credentials are ever logged.
            if let url = Self.autoLogURL {
                let entry = line + Data([10])
                if FileManager.default.fileExists(atPath: url.path),
                   let handle = try? FileHandle(forWritingTo: url) {
                    defer { try? handle.close() }
                    try? handle.seekToEnd()
                    try? handle.write(contentsOf: entry)
                } else {
                    try? entry.write(to: url, options: .atomic)
                }
            }
            if event == "state", let state = record["status"] as? String {
                switch state {
                case "armed": autoStatus = "Watching Warcraft downloads automatically"
                case "warming_up": autoStatus = "Preparing download watcher…"
                case "waiting_for_game": autoStatus = "Waiting for Warcraft III"
                case "waiting_for_socket": autoStatus = "Waiting for Warcraft's Custom Games browser"
                case "connected": autoStatus = "Connected — preparing watcher…"
                case "python3_missing": autoStatus = "Python 3 required for auto rescue"
                default: autoStatus = "Reconnecting to Warcraft…"
                }
            } else if event == "rescue", let state = record["status"] as? String {
                switch state {
                case "detected": autoStatus = "Download detected — matching CDN hash…"
                case "downloading": autoStatus = "Rescuing map independently…"
                case "verified":
                    let name = record["filename"] as? String ?? "map"
                    lastAutoMap = name
                    let install = record["installed"] as? String ?? ""
                    autoStatus = install == "installed_no_overwrite"
                        ? "Rescued and installed: \(name)"
                        : "Verified backup saved: \(name)"
                case "skipped": autoStatus = "Rescue skipped safely — see auto log"
                case "failed": autoStatus = "Rescue failed — see auto log"
                default: break
                }
            }
        }
    }

    private static var autoLogURL: URL? {
        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        return logDir.appendingPathComponent("MapDash-v30-auto-rescue.log")
    }


    private static var bridgeRoot: URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let root = resources.appendingPathComponent("MapDashBridge", isDirectory: true)
        return FileManager.default.fileExists(atPath: root.appendingPathComponent("scripts/v29-lobbies.sh").path)
            ? root : nil
    }

    private static var helperEnvironment: [String: String] {
        // Finder-launched apps do not usually inherit Homebrew's interactive PATH.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        return env
    }

    private func startFeed() {
        guard let root = Self.bridgeRoot else {
            socketState = "Local lobby helper missing from app"
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [root.appendingPathComponent("scripts/v29-lobbies.sh").path]
        process.environment = Self.helperEnvironment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        feedPipe = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            Task { @MainActor [weak self] in self?.consumeFeed(bytes) }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.feedPipe?.fileHandleForReading.readabilityHandler = nil
                self.feed = nil
                self.socketState = "Lobby connection stopped — reopen MapDash to retry"
                self.liveLobbies = []
                self.liveTotal = 0
            }
        }
        do {
            try process.run()
            feed = process
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            socketState = "Could not start the lobby helper"
        }
    }

    private func consumeFeed(_ data: Data) {
        guard !data.isEmpty else { return }
        feedBuffer.append(data)
        if feedBuffer.count > 2_000_000 { feedBuffer.removeAll(); return }
        while let newline = feedBuffer.firstIndex(of: 10) {
            let line = Data(feedBuffer.prefix(upTo: newline))
            feedBuffer.removeSubrange(...newline)
            guard let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let event = record["event"] as? String else { continue }
            if event == "state", let status = record["status"] as? String {
                switch status {
                case "connected": socketState = "Connected to Warcraft's live lobby list"
                case "waiting_for_game": socketState = "Waiting for Warcraft III"
                case "waiting_for_socket": socketState = "Waiting for Warcraft's Custom Games service"
                case "disconnected": socketState = "Game-list connection interrupted"
                case "python3_missing": socketState = "Python 3 is required for this preview"
                default: socketState = "Lobby helper unavailable"
                }
            } else if event == "lobbies" {
                // Explicitly NOT a content-hash source. Display only; no downloads.
                liveTotal = record["total"] as? Int ?? 0
                let values = record["games"] as? [[String: Any]] ?? []
                liveLobbies = values.compactMap { value in
                    guard let id = value["id"] as? Int,
                          let title = value["name"] as? String,
                          let map = value["map"] as? String else { return nil }
                    return LiveWarcraftLobby(id: id, title: title, map: map,
                        players: value["players"] as? Int ?? 0,
                        capacity: value["capacity"] as? Int ?? 0)
                }
            }
        }
    }

    func rescueNextMap() {
        guard !rescueActive, let root = Self.bridgeRoot else { return }
        rescueActive = true
        rescueSuccess = false
        rescueBuffer = Data()
        rescueStatus = "Starting rescue helper…"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [root.appendingPathComponent("scripts/v28-rescue.sh").path, "--install"]
        process.environment = Self.helperEnvironment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        rescuePipe = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            Task { @MainActor [weak self] in self?.consumeRescue(bytes) }
        }
        process.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.rescuePipe?.fileHandleForReading.readabilityHandler = nil
                self.rescueActive = false
                self.rescue = nil
                if !self.rescueSuccess {
                    self.rescueStatus = proc.terminationStatus == 0
                        ? "Rescue finished — see rescue log for the outcome"
                        : "Rescue unsuccessful — see rescue log"
                }
            }
        }
        do {
            try process.run()
            rescue = process
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            rescueActive = false
            rescueStatus = "Could not launch rescue helper"
        }
    }

    private func consumeRescue(_ data: Data) {
        guard !data.isEmpty else { return }
        rescueBuffer.append(data)
        if rescueBuffer.count > 100_000 { rescueBuffer.removeAll(); return }
        while let newline = rescueBuffer.firstIndex(of: 10) {
            let line = String(decoding: rescueBuffer.prefix(upTo: newline), as: UTF8.self)
            rescueBuffer.removeSubrange(...newline)
            if line.contains("v28_READY=NOW") {
                rescueStatus = "Ready! In Warcraft, right-click a missing map → Download Map"
            } else if line.contains("v28_download_modal=OBSERVED") {
                rescueStatus = "Map selected — finding CDN identifier…"
            } else if line.contains("status=stable_unique_candidate") {
                rescueStatus = "Map identified — downloading independently…"
            } else if line.contains("v28_fetch=downloaded_and_verified") {
                rescueStatus = "Downloaded and SHA-1 verified — installing…"
            } else if line.contains("v28_status=RESCUED_VERIFIED_CONTENT") {
                rescueSuccess = true
                rescueStatus = "Map rescued! Verified copy saved; check install result in log."
            } else if line.contains("v28_status=NOT_RESCUED") {
                rescueStatus = "Rescue unsuccessful — see rescue log"
            } else if line.contains("v28_install=conflict_kept_staged") {
                rescueStatus = "Existing map untouched; verified backup saved"
            }
        }
    }

    func restoreSavedMaps() {
        guard !rescueActive, !restoring, let root = Self.bridgeRoot else { return }
        restoring = true
        rescueStatus = "Restoring SHA-1-verified backups…"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [root.appendingPathComponent("scripts/v28-restore.sh").path]
        process.environment = Self.helperEnvironment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in
                self?.restoring = false
                self?.rescueStatus = proc.terminationStatus == 0
                    ? "Restore complete; original files were never overwritten"
                    : "Restore needs attention; check staging folder"
            }
        }
        do { try process.run() }
        catch { restoring = false; rescueStatus = "Could not launch restore helper" }
    }

    func openRescueLog() {
        let url = Self.autoLogURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MapDash-v28-rescue.log")
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        }
    }

    func shutdown() {
        stopping = true
        autoPipe?.fileHandleForReading.readabilityHandler = nil
        if autoProcess?.isRunning == true { autoProcess?.terminate() }
        feedPipe?.fileHandleForReading.readabilityHandler = nil
        rescuePipe?.fileHandleForReading.readabilityHandler = nil
        if feed?.isRunning == true { feed?.terminate() }
        // Quitting stops the watcher. Verified backups already published remain safe.
        // Keep MapDash open until a rescue completes to avoid cancelling curl.
    }
}
