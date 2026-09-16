import CryptoKit
import Foundation

enum MapStatus: String, Codable {
    case unknown      // seen, size not asked yet
    case probing      // asking the CDN for the size
    case queued       // will download automatically
    case large        // above the auto-download limit - waits for a click
    case waiting      // auto-download is off - waits for a click
    case downloading
    case checking     // hashing a file that is already on disk
    case done         // downloaded by MapDash
    case present      // was already on disk with the right hash
    case conflict     // a different map with the same file name is on disk; left alone
    case failed       // download failed, retried later
    case invalid      // the CDN does not know the hash (stale or garbled memory)
}

/// One map file the game will look for. The key is sha1 + file name: the game finds maps by name,
/// and hosts share the same map under different names, so each name needs its own file.
struct MapEntry: Codable {
    var sha1: String
    var file: String
    var status: MapStatus = .unknown
    var size: Int64?
    var lobbies: [String] = []
    var lastSeen: Date = Date()
    var listed = false
    var requested = false
    var attempts = 0
    var retryAt: Date?
    var error: String?
    var doneBytes: Int64 = 0
}

enum ScanState: Equatable {
    case starting
    case gameNotRunning
    case noAccess(Int32)
    case reading(Int)
    case failed
}

private struct SavedState: Codable {
    var version = 2
    var maps: [String: MapEntry]
    var hashCache: [String: [String]]
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var maps: [String: MapEntry] = [:]
    @Published private(set) var scan: ScanState = .starting
    @Published private(set) var update: (version: String, page: URL?)?
    @Published private(set) var folderBytes: Int64 = 0
    @Published private(set) var freeBytes: Int64?         // nil until measured, or if it cannot be
    @Published private(set) var gamePID: pid_t = 0
    @Published private(set) var lastFullScan: Date?
    let settings = Settings()

    private var active: [String: Process] = [:]
    private var hashCache: [String: [String]] = [:]   // path -> [size|mtime key, sha1]
    private var readyBatch: [String] = []
    private var pausedForSpace = false
    private var dirty = false
    private var ticks = 0

    init() {
        // SwiftUI may build the model of a second copy too; that copy must not scan or download.
        guard !Instance.isDuplicate else { return }
        try? FileManager.default.createDirectory(at: Paths.appDir, withIntermediateDirectories: true)
        load()
        removeOwnPartFiles()
        Log.write("MapDash \(UpdateCheck.current) started")
        startScanLoop()
        // Common modes: a scheduledTimer sits in the default mode only and stops while an alert
        // is open, which left progress and state saving frozen behind an unanswered start window.
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        checkForUpdate()
        refreshFolderSize()
        refreshFreeSpace()
    }

    /// Downloads stay paused while this is true; the menu says so.
    /// An unknown free space does not block: a volume that cannot report it must not stop MapDash.
    var lowSpace: Bool { freeBytes.map { $0 < settings.minFreeBytes } ?? false }

    // MARK: persistence

    private func load() {
        guard let data = try? Data(contentsOf: Paths.stateFile),
              let saved = try? JSONDecoder().decode(SavedState.self, from: data), saved.version == 2 else { return }
        maps = saved.maps
        hashCache = saved.hashCache
        for (key, entry) in maps {
            // Anything that was in flight when the app quit starts over.
            switch entry.status {
            case .downloading: maps[key]?.status = .queued
            case .probing, .checking: maps[key]?.status = .unknown
            default: break
            }
            maps[key]?.doneBytes = 0
        }
    }

    private func save() {
        guard dirty else { return }
        dirty = false
        let state = SavedState(maps: maps, hashCache: hashCache)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: Paths.stateFile, options: .atomic)
        }
    }

    /// Partial files are MapDash's own (never a map the game placed), so dropping them is safe.
    private func removeOwnPartFiles() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Paths.mapDir.path)) ?? []
        for name in names where name.hasPrefix(".") && name.hasSuffix(".mapdash.part") {
            try? FileManager.default.removeItem(at: Paths.mapDir.appendingPathComponent(name))
        }
    }

    // MARK: scanning

    private func startScanLoop() {
        Task.detached(priority: .background) { [weak self] in
            var round = 0
            var buffer = [md_game_t](repeating: md_game_t(), count: 1024)
            while true {
                let pid = md_find_game()
                if pid == 0 {
                    await self?.scanFinished(state: .gameNotRunning, pid: 0, games: nil, fullScan: false)
                    try? await Task.sleep(nanoseconds: Constants.idleInterval * 1_000_000_000)
                    continue
                }
                round += 1
                var kr: Int32 = 0
                var n = md_scan(pid, 0, &buffer, Int32(buffer.count), &kr)
                var games = n > 0 ? Array(buffer[0..<Int(n)]).map(Lobby.init) : []
                var fullScan = false
                if n >= 0 && round % Constants.fullScanEvery == 0 {
                    // Cross-check the fast region filter against a scan of all memory. A lobby
                    // opened between two scans is not a miss, so the fast scan runs again after
                    // the full one and only what neither fast scan saw is reported.
                    n = md_scan(pid, 1, &buffer, Int32(buffer.count), &kr)
                    fullScan = n >= 0
                    if n > 0 {
                        let full = Array(buffer[0..<Int(n)]).map(Lobby.init)
                        var fast = Set(games.map(\.sha1))
                        var kr2: Int32 = 0
                        let n2 = md_scan(pid, 0, &buffer, Int32(buffer.count), &kr2)
                        if n2 > 0 { fast.formUnion(buffer[0..<Int(n2)].map { Lobby($0).sha1 }) }
                        for lobby in full where !fast.contains(lobby.sha1) {
                            Log.write("fast scan missed \(lobby.sha1) \(lobby.path)")
                        }
                        games = full
                    }
                }
                let state: ScanState = n == -1 ? .noAccess(kr) : n < 0 ? .failed : .reading(games.count)
                await self?.scanFinished(state: state, pid: pid, games: n >= 0 ? games : nil, fullScan: fullScan)
                try? await Task.sleep(nanoseconds: Constants.scanInterval * 1_000_000_000)
            }
        }
    }

    private func scanFinished(state: ScanState, pid: pid_t, games: [Lobby]?, fullScan: Bool) {
        if pid != gamePID { gamePID = pid }
        if fullScan { lastFullScan = Date() }
        if state != scan {
            if case .noAccess(let kr) = state { Log.write("cannot read the game (task_for_pid \(kr))") }
            scan = state
        }
        var seen: [String: (sha1: String, file: String, lobbies: [String])] = [:]
        for lobby in games ?? [] {
            guard lobby.sha1.count == 40, let file = mapFileName(fromHostPath: lobby.path) else { continue }
            seen[lobby.sha1 + "|" + file, default: (lobby.sha1, file, [])].lobbies.append(lobby.name)
        }
        let now = Date()
        for (key, info) in seen {
            var entry = maps[key] ?? MapEntry(sha1: info.sha1, file: info.file)
            entry.lobbies = Array(Set(info.lobbies)).sorted().prefix(5).map { $0 }
            entry.lastSeen = now
            entry.listed = true
            maps[key] = entry
        }
        for key in maps.keys where seen[key] == nil && maps[key]?.listed == true {
            maps[key]?.listed = false
        }
        dirty = true
        step()
    }

    // MARK: downloading

    func fetch(_ key: String) {
        guard maps[key] != nil else { return }
        maps[key]?.requested = true
        resetFailure(key)
        step()
    }

    func retry(_ key: String) {
        resetFailure(key)
        step()
    }

    private func resetFailure(_ key: String) {
        guard let entry = maps[key] else { return }
        maps[key]?.attempts = 0
        maps[key]?.retryAt = nil
        if entry.status == .failed { maps[key]?.status = entry.size == nil ? .unknown : .queued }
    }

    private func tick() {
        ticks += 1
        for key in active.keys {
            let part = partURL(key)
            let bytes = (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? Int64) ?? 0
            maps[key]?.doneBytes = bytes
        }
        step()
        if ticks % 5 == 0 { refreshFreeSpace() }
        if ticks % 30 == 0 { refreshFolderSize() }
        if ticks % 43200 == 0 { checkForUpdate() }
        save()
    }

    private func partURL(_ key: String) -> URL {
        let id = Insecure.SHA1.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return Paths.mapDir.appendingPathComponent(".\(id).mapdash.part")
    }

    private func step() {
        let now = Date()
        for (key, entry) in maps {
            switch entry.status {
            case .downloading, .probing, .checking, .invalid: continue
            default: break
            }
            let target = Paths.mapDir.appendingPathComponent(entry.file)
            if FileManager.default.fileExists(atPath: target.path) {
                if ![.present, .done, .conflict].contains(entry.status) { verifyExisting(key, target) }
                continue
            }
            if [.present, .done, .conflict].contains(entry.status) {
                maps[key]?.status = entry.size == nil ? .unknown : .queued   // the file went away
            }
            if entry.status == .failed {
                if entry.attempts >= Constants.maxAttempts || now < (entry.retryAt ?? now) { continue }
                maps[key]?.status = entry.size == nil ? .unknown : .queued
            }
            guard entry.listed || entry.requested else { continue }
            if maps[key]?.status == .unknown { probe(key) }
        }

        // Logged here, where the decision is made: both the free space and the limit can change.
        if lowSpace != pausedForSpace {
            pausedForSpace = lowSpace
            Log.write(lowSpace ? "downloads paused: \((freeBytes ?? 0) / 1_000_000_000) GB free" : "downloads resumed")
        }

        var candidates: [(requested: Bool, size: Int64, key: String)] = []
        for (key, entry) in maps where [.queued, .large, .waiting].contains(entry.status) {
            let size = entry.size ?? 0
            if entry.requested || (entry.listed && settings.autoAllows(size)) {
                candidates.append((entry.requested, size, key))
            } else if entry.listed {
                maps[key]?.status = settings.auto ? .large : .waiting
            }
            // Unlisted maps keep their status until their lobby comes back.
        }
        // Clicked maps first, then the smallest - the most lobbies become joinable soonest.
        candidates.sort { ($0.requested ? 0 : 1, $0.size) < ($1.requested ? 0 : 1, $1.size) }
        for c in candidates {
            // A full disk is paused, not failed: the maps wait in the queue until space returns.
            if active.count >= settings.parallel || lowSpace {
                maps[c.key]?.status = .queued
            } else {
                startDownload(c.key)
            }
        }

        if !readyBatch.isEmpty && active.isEmpty
            && !maps.values.contains(where: { $0.status == .queued || $0.status == .probing }) {
            // One summary once the automatic queue has drained - a lobby list can hold dozens of
            // missing maps, and one notification each would bury the screen.
            if settings.notify {
                if readyBatch.count == 1 {
                    Notifier.post("Map ready", readyBatch[0])
                } else {
                    Notifier.post("\(readyBatch.count) maps ready", readyBatch.sorted().joined(separator: ", "))
                }
            }
            readyBatch = []
        }

        let stale = maps.filter { now.timeIntervalSince($0.value.lastSeen) > Constants.forgetAfter && active[$0.key] == nil }
        for key in stale.keys { maps[key] = nil }
        dirty = true
    }

    private func verifyExisting(_ key: String, _ target: URL) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: target.path)
        let stamp = "\((attrs?[.size] as? Int64) ?? 0)|\(Int((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0))"
        if let cached = hashCache[target.path], cached.count == 2, cached[0] == stamp {
            maps[key]?.status = cached[1] == maps[key]?.sha1 ? .present : .conflict
            return
        }
        maps[key]?.status = .checking
        Task.detached(priority: .utility) {
            let digest = sha1Hex(of: target) ?? ""
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.hashCache[target.path] = [stamp, digest]
                self.maps[key]?.status = digest == self.maps[key]?.sha1 ? .present : .conflict
                self.dirty = true
            }
        }
    }

    private func probe(_ key: String) {
        guard let hash = maps[key]?.sha1 else { return }
        maps[key]?.status = .probing
        let url = String(format: Constants.cdn, hash)
        _ = run(Constants.curl, ["-sS", "-I", "--max-time", "15", url]) { [weak self] _, out, _ in
            var status: String?
            var size: Int64?
            for line in out.components(separatedBy: "\r\n") {
                let parts = line.split(separator: " ")
                if line.hasPrefix("HTTP/"), parts.count > 1 { status = String(parts[1]) }
                if line.lowercased().hasPrefix("content-length:") {
                    size = Int64(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
                }
            }
            Task { @MainActor in
                guard let self, self.maps[key] != nil else { return }
                switch (status, size) {
                case ("200", let s?) where s > 0:
                    self.maps[key]?.size = s
                    self.maps[key]?.status = .queued
                case ("403", _), ("404", _):
                    self.maps[key]?.status = .invalid
                default:
                    self.maps[key]?.status = .failed
                    self.maps[key]?.error = "size check failed (HTTP \(status ?? "no answer"))"
                    self.maps[key]?.attempts += 1
                    self.maps[key]?.retryAt = Date().addingTimeInterval(Constants.retryAfter)
                }
                self.dirty = true
                self.step()
            }
        }
    }

    private func startDownload(_ key: String) {
        guard let entry = maps[key] else { return }
        // The game creates this folder on its first download; a fresh install may not have it yet.
        do {
            try FileManager.default.createDirectory(at: Paths.mapDir, withIntermediateDirectories: true)
        } catch {
            maps[key]?.status = .failed
            maps[key]?.error = "cannot create the map folder: \(error.localizedDescription)"
            maps[key]?.attempts += 1
            maps[key]?.retryAt = Date().addingTimeInterval(Constants.retryAfter)
            return
        }
        let part = partURL(key)
        let hash = entry.sha1
        // Same map already on disk under another name: copy it (an APFS clone, no extra space).
        if let source = maps.values.first(where: {
            $0.sha1 == hash && [.present, .done].contains($0.status) && $0.file != entry.file
        }) {
            let from = Paths.mapDir.appendingPathComponent(source.file)
            maps[key]?.status = .downloading
            maps[key]?.attempts += 1
            Log.write("copy \(hash) \(source.file) -> \(entry.file)")
            let copying = Process()   // placeholder so the slot counts as busy
            active[key] = copying
            Task.detached(priority: .utility) {
                let err: String
                do { try FileManager.default.copyItem(at: from, to: part); err = "" } catch { err = error.localizedDescription }
                let code: Int32 = err.isEmpty ? 0 : 1
                let digest = code == 0 ? sha1Hex(of: part) : nil
                await MainActor.run { [weak self] in self?.finishDownload(key, code: code, err: err, digest: digest) }
            }
            return
        }
        var args = ["-sS", "--fail", "--retry", "2", "--connect-timeout", "15", "--max-time", "3600",
                    "-o", part.path, String(format: Constants.cdn, hash)]
        if settings.rateLimitMB > 0 { args.insert(contentsOf: ["--limit-rate", "\(settings.rateLimitMB)M"], at: 0) }
        maps[key]?.status = .downloading
        maps[key]?.attempts += 1
        maps[key]?.error = nil
        maps[key]?.doneBytes = 0
        Log.write("download \(hash) \(entry.file) (\(entry.size ?? 0) bytes)")
        let process = run(Constants.curl, args) { [weak self] code, _, err in
            Task.detached(priority: .utility) {
                let digest = code == 0 ? sha1Hex(of: part) : nil
                await MainActor.run { self?.finishDownload(key, code: code, err: err, digest: digest) }
            }
        }
        if let process { active[key] = process }
    }

    private func finishDownload(_ key: String, code: Int32, err: String, digest: String?) {
        active[key] = nil
        let part = partURL(key)
        defer { try? FileManager.default.removeItem(at: part) }
        guard var entry = maps[key] else { return }
        entry.doneBytes = 0
        var problem: String?
        if code != 0 {
            let reason = err.components(separatedBy: ") ").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            problem = "download failed: \(reason.isEmpty ? "curl exit \(code)" : reason)"
        } else if digest != entry.sha1 {
            problem = "downloaded file has the wrong SHA-1"
        } else {
            let target = Paths.mapDir.appendingPathComponent(entry.file)
            do {
                // link() never replaces: if the game finished its own download of the same name
                // meanwhile, that file wins and is left untouched.
                try FileManager.default.linkItem(at: part, to: target)
                entry.status = .done
                Log.write("ready \(entry.sha1) \(entry.file)")
                if entry.requested {
                    if settings.notify { Notifier.post("Map ready", entry.file) }
                } else {
                    readyBatch.append(entry.file)
                }
            } catch CocoaError.fileWriteFileExists {
                entry.status = .unknown   // re-verified against the file on disk in the next step
                maps[key] = entry
                verifyExisting(key, target)
                dirty = true
                return
            } catch {
                problem = "could not place the file: \(error.localizedDescription)"
            }
        }
        if let problem {
            entry.status = .failed
            entry.error = problem
            entry.retryAt = Date().addingTimeInterval(Constants.retryAfter)
            Log.write("failed \(entry.sha1) \(entry.file): \(problem)")
        }
        maps[key] = entry
        dirty = true
        step()
    }

    // MARK: misc

    func refreshFolderSize() {
        Task.detached(priority: .background) {
            let total = folderSize(Paths.mapDir)
            await MainActor.run { [weak self] in self?.folderBytes = total }
        }
    }

    func checkForUpdate() {
        UpdateCheck.latest { [weak self] version, page in
            Task { @MainActor in
                guard let version, UpdateCheck.isNewer(version, than: UpdateCheck.current) else { return }
                self?.update = (version, page)
            }
        }
    }

    func refreshFreeSpace() {
        Task.detached(priority: .background) {
            let free = freeSpace(near: Paths.mapDir)
            await MainActor.run { [weak self] in
                self?.freeBytes = free
            }
        }
    }
}

/// Free space on the volume holding `dir` (or its nearest existing parent - the map folder may not
/// exist yet). "Important usage" counts purgeable space, which is what Finder shows.
private func freeSpace(near dir: URL) -> Int64? {
    var url = dir
    while !FileManager.default.fileExists(atPath: url.path) && url.path != "/" { url.deleteLastPathComponent() }
    return (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
        .volumeAvailableCapacityForImportantUsage
}

private func folderSize(_ dir: URL) -> Int64 {
    var total: Int64 = 0
    guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
    while let url = e.nextObject() as? URL {
        total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
    }
    return total
}

/// Swift copy of one scanner result.
struct Lobby {
    let name: String
    let path: String
    let host: String
    let sha1: String

    init(_ g: md_game_t) {
        var g = g
        name = Lobby.string(&g.name)
        path = Lobby.string(&g.path)
        host = Lobby.string(&g.host)
        sha1 = Lobby.string(&g.sha1)
    }

    private static func string<T>(_ field: inout T) -> String {
        withUnsafeBytes(of: &field) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)   // repairs invalid UTF-8
        }
    }
}
