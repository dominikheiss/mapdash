import AppKit
import CryptoKit
import Foundation

/// "Update available": downloads the release zip, checks it, swaps the app bundle and restarts.
///
/// A file curl downloads carries no quarantine flag, so the new version starts without the
/// "Open Anyway" step a browser download needs. The zip is only used if its SHA-256 matches the
/// digest GitHub publishes for the asset, the bundle id and version match, and the signature is
/// intact. The previous version is kept in Application Support/MapDash/previous.
@MainActor
enum Updater {
    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ text: String) { description = text }
    }

    private static let workDir = Paths.appDir.appendingPathComponent("update")
    private static let previousDir = Paths.appDir.appendingPathComponent("previous")
    static let updatedFromKey = "updatedFrom"

    static func offer(_ release: Release, model: AppModel) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "MapDash \(release.version) is available"
        var notes = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if notes.count > 700 { notes = String(notes.prefix(700)) + " …" }
        let problem = installProblem(release)
        alert.informativeText = "You have \(UpdateCheck.current).\n\n\(notes)\n\n"
            + (problem ?? "MapDash downloads the update, replaces itself and restarts. Running map downloads start again afterwards.")
        if problem == nil { alert.addButton(withTitle: "Install and Restart") }
        alert.addButton(withTitle: "Open Release Page")
        alert.addButton(withTitle: "Later")
        let answer = alert.runModal()
        let installChosen = problem == nil && answer == .alertFirstButtonReturn
        let pageChosen = answer == (problem == nil ? .alertSecondButtonReturn : .alertFirstButtonReturn)
        if installChosen {
            install(release, model: model)
        } else if pageChosen, let page = release.page {
            NSWorkspace.shared.open(page)
        }
    }

    /// Why this copy cannot replace itself, or nil.
    private static func installProblem(_ release: Release) -> String? {
        let app = Bundle.main.bundleURL
        if release.zip == nil || release.sha256 == nil {
            return "This release has no update file MapDash can check. Download it from the release page."
        }
        // macOS runs apps that were opened straight from Downloads from a read-only copy.
        if app.path.contains("/AppTranslocation/") {
            return "Move MapDash to your Applications folder and open it from there, then MapDash can update itself."
        }
        if !FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path) {
            return "MapDash cannot write to \(app.deletingLastPathComponent().path). Download the update from the release page."
        }
        return nil
    }

    private static func install(_ release: Release, model: AppModel) {
        model.setInstalling(true)
        Log.write("update \(UpdateCheck.current) -> \(release.version): downloading")
        let expectedID = Bundle.main.bundleIdentifier ?? ""
        Task.detached(priority: .userInitiated) {
            do {
                let newApp = try prepare(release, bundleID: expectedID)
                await MainActor.run { finish(newApp, release: release, model: model) }
            } catch {
                await MainActor.run { fail("\(error)", release: release, model: model) }
            }
        }
    }

    /// Download, verify and unpack. Runs off the main thread.
    nonisolated private static func prepare(_ release: Release, bundleID: String) throws -> URL {
        guard let url = release.zip, let digest = release.sha256 else { throw Failure("no update file") }
        let fm = FileManager.default
        let work = Paths.appDir.appendingPathComponent("update")
        try? fm.removeItem(at: work)   // MapDash's own scratch folder from an earlier attempt
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let zip = work.appendingPathComponent("MapDash.zip")

        let get = runAndWait(Constants.curl, ["-sS", "--fail", "-L", "--connect-timeout", "15",
                                              "--max-time", "600", "-o", zip.path, url.absoluteString])
        guard get.code == 0 else { throw Failure("download failed: \(get.err.trimmingCharacters(in: .whitespacesAndNewlines))") }
        guard let actual = sha256Hex(of: zip), actual == digest else {
            throw Failure("the downloaded file does not match the checksum GitHub publishes")
        }

        let unpacked = work.appendingPathComponent("unpacked")
        let unzip = runAndWait("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
        guard unzip.code == 0 else { throw Failure("could not unpack the update: \(unzip.err)") }
        let app = unpacked.appendingPathComponent("MapDash.app")
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else {
            throw Failure("the update contains no MapDash.app")
        }
        guard info["CFBundleIdentifier"] as? String == bundleID else {
            throw Failure("the update is a different app (\(info["CFBundleIdentifier"] ?? "?"))")
        }
        guard info["CFBundleShortVersionString"] as? String == release.version else {
            throw Failure("the update says it is version \(info["CFBundleShortVersionString"] ?? "?"), expected \(release.version)")
        }
        let sign = runAndWait("/usr/bin/codesign", ["--verify", "--strict", "--deep", app.path])
        guard sign.code == 0 else { throw Failure("the update's signature is broken: \(sign.err)") }
        return app
    }

    private static func finish(_ newApp: URL, release: Release, model: AppModel) {
        let fm = FileManager.default
        let current = Bundle.main.bundleURL
        let backup = previousDir.appendingPathComponent(current.lastPathComponent)
        do {
            // MapDash's own copy of the version before the last update; replaced each time.
            try? fm.removeItem(at: previousDir)
            try fm.createDirectory(at: previousDir, withIntermediateDirectories: true)
            // Moving a running app's bundle is fine: the process keeps its open files, and it
            // quits right below.
            try fm.moveItem(at: current, to: backup)
            do {
                try fm.moveItem(at: newApp, to: current)
            } catch {
                try? fm.moveItem(at: backup, to: current)
                throw error
            }
        } catch {
            fail("could not replace the app: \(error.localizedDescription)", release: release, model: model)
            return
        }
        try? fm.removeItem(at: workDir)
        Log.write("update installed: \(release.version), previous version kept in \(backup.path)")
        UserDefaults.standard.set(UpdateCheck.current, forKey: updatedFromKey)
        relaunch(current)
        model.stopDownloads()
        NSApp.terminate(nil)
    }

    private static func fail(_ reason: String, release: Release, model: AppModel) {
        model.setInstalling(false)
        Log.write("update to \(release.version) failed: \(reason)")
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The update could not be installed"
        alert.informativeText = "\(reason.prefix(1).uppercased() + reason.dropFirst()).\n\nMapDash \(UpdateCheck.current) keeps running. You can download the update from the release page."
        alert.addButton(withTitle: "Open Release Page")
        alert.addButton(withTitle: "Close")
        if alert.runModal() == .alertFirstButtonReturn, let page = release.page {
            NSWorkspace.shared.open(page)
        }
    }

    /// A small shell waits for this process to exit, then opens the new app. Only one MapDash may
    /// run, so starting it earlier would make it quit as a duplicate.
    private static func relaunch(_ app: URL) {
        // `open` starts apps without the caller's environment. Test copies run with a redirected
        // home (CFFIXED_USER_HOME); that must survive the restart, or the test copy would work on
        // the real map folder.
        var openArgs: [String] = []
        if let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] {
            openArgs = ["--env", "CFFIXED_USER_HOME=\(home)"]
        }
        let script = "pid=$1; shift; while /bin/kill -0 \"$pid\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$@\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier)] + openArgs + [app.path]
        try? p.run()
    }

    /// Shown once after an update restart instead of the start window.
    static func announceIfJustUpdated() -> Bool {
        let d = UserDefaults.standard
        guard let from = d.string(forKey: updatedFromKey) else { return false }
        d.removeObject(forKey: updatedFromKey)
        Log.write("running \(UpdateCheck.current) after update from \(from)")
        Toast.show(title: "MapDash updated to \(UpdateCheck.current)", body: "Previous version: \(from)",
                   hint: "Click to see what's new") {
            if let url = URL(string: "https://github.com/\(Constants.repo)/releases/tag/v\(UpdateCheck.current)") {
                NSWorkspace.shared.open(url)
            }
        }
        return true
    }
}

private func runAndWait(_ path: String, _ args: [String]) -> (code: Int32, err: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let err = Pipe()
    p.standardOutput = FileHandle.nullDevice
    p.standardError = err
    do { try p.run() } catch { return (-1, error.localizedDescription) }
    let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    return (p.terminationStatus, text)
}

private func sha256Hex(of url: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
        let chunk = autoreleasepool { handle.readData(ofLength: 1 << 20) }
        if chunk.isEmpty { break }
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}
