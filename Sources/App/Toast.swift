import AppKit
import SwiftUI

/// MapDash's own "maps ready" banner at the top right of the main screen.
///
/// macOS notifications are not an option: for an app without an Apple signature the permission
/// request fails without a prompt and posted notifications are stored but never shown (measured,
/// also with a fresh test app and with the legacy NSUserNotification API). The osascript
/// workaround showed them under Script Editor, and clicking one opened Script Editor instead of
/// the maps. This banner needs no permission and a click reveals the maps in Finder.
@MainActor
enum Toast {
    private static var panel: NSPanel?
    private static var hideTimer: Timer?
    static let width: CGFloat = 340
    static let visibleFor: TimeInterval = 8
    static let visibleAfterHover: TimeInterval = 3

    static func show(title: String, body: String, reveal files: [URL]) {
        show(title: title, body: body, hint: "Click to show in Finder") { Toast.reveal(files) }
    }

    static func show(title: String, body: String, hint: String, action: @escaping () -> Void) {
        let view = ToastView(title: title, message: body, hint: hint,
                             open: { hide(); action() },
                             close: { hide() })
        let host = NSHostingView(rootView: view)
        let height = host.fittingSize.height
        let p = panel ?? makePanel()
        panel = p
        // While the pointer is on the banner it stays; it goes a moment after the pointer leaves.
        let container = HoverView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        container.onEnter = { cancelTimer() }
        container.onExit = { scheduleHide(after: visibleAfterHover) }
        p.contentView = container
        // The first screen is the one with the menu bar, where the MapDash icon is.
        let area = (NSScreen.screens.first ?? NSScreen.main)?.visibleFrame ?? .zero
        p.setFrame(NSRect(x: area.maxX - width - 12, y: area.maxY - height - 12, width: width, height: height),
                   display: true)
        p.alphaValue = 1
        p.orderFrontRegardless()
        scheduleHide(after: visibleFor)
    }

    static func hide() {
        cancelTimer()
        panel?.orderOut(nil)
    }

    private static func cancelTimer() {
        hideTimer?.invalidate()
        hideTimer = nil
    }

    private static func scheduleHide(after seconds: TimeInterval) {
        cancelTimer()
        // Common modes, so the banner also goes away while a menu is open.
        let timer = Timer(timeInterval: seconds, repeats: false) { _ in
            Task { @MainActor in hide() }
        }
        RunLoop.main.add(timer, forMode: .common)
        hideTimer = timer
    }

    private static func reveal(_ files: [URL]) {
        let existing = files.filter { FileManager.default.fileExists(atPath: $0.path) }
        if existing.isEmpty {
            NSWorkspace.shared.open(Paths.mapDir)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(existing)
        }
    }

    private static func makePanel() -> NSPanel {
        // Non-activating: the banner must never take focus away from the game.
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        return p
    }
}

/// Reports the pointer entering and leaving. `.activeAlways`: MapDash is never the active app, and
/// the default tracking only works for the active app.
private final class HoverView: NSView {
    var onEnter: () -> Void = {}
    var onExit: () -> Void = {}

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { nil }

    override func mouseEntered(with event: NSEvent) { onEnter() }
    override func mouseExited(with event: NSEvent) { onExit() }
}

private struct ToastView: View {
    let title: String
    let message: String
    let hint: String
    let open: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "shippingbox.fill")
                .font(.title2)
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(message).font(.callout).foregroundColor(.secondary).lineLimit(3)
                Text(hint).font(.caption).foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
            Button(action: close) { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("Close")
        }
        .padding(12)
        .frame(width: Toast.width, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
    }
}
