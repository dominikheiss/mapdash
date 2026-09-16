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

    static func show(title: String, body: String, reveal files: [URL]) {
        let view = ToastView(title: title, message: body,
                             open: { hide(); Toast.reveal(files) },
                             close: { hide() })
        let host = NSHostingView(rootView: view)
        let height = host.fittingSize.height
        let p = panel ?? makePanel()
        panel = p
        p.contentView = host
        // The first screen is the one with the menu bar, where the MapDash icon is.
        let area = (NSScreen.screens.first ?? NSScreen.main)?.visibleFrame ?? .zero
        p.setFrame(NSRect(x: area.maxX - width - 12, y: area.maxY - height - 12, width: width, height: height),
                   display: true)
        p.alphaValue = 1
        p.orderFrontRegardless()
        hideTimer?.invalidate()
        // Common modes, so the banner also goes away while a menu is open.
        let timer = Timer(timeInterval: visibleFor, repeats: false) { _ in
            Task { @MainActor in hide() }
        }
        RunLoop.main.add(timer, forMode: .common)
        hideTimer = timer
    }

    static func hide() {
        hideTimer?.invalidate()
        hideTimer = nil
        panel?.orderOut(nil)
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

private struct ToastView: View {
    let title: String
    let message: String
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
                Text("Click to show in Finder").font(.caption).foregroundColor(.secondary)
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
