import AppKit
import SwiftUI

enum HUDUrgency {
    case normal, warning, critical

    var tint: Color {
        switch self {
        case .normal: return Color(red: 0.20, green: 0.78, blue: 0.35)
        case .warning: return Color(red: 1.00, green: 0.72, blue: 0.11)
        case .critical: return Color(red: 1.00, green: 0.27, blue: 0.23)
        }
    }

    var nsTint: NSColor {
        switch self {
        case .normal: return NSColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1)
        case .warning: return NSColor(red: 1.00, green: 0.72, blue: 0.11, alpha: 1)
        case .critical: return NSColor(red: 1.00, green: 0.27, blue: 0.23, alpha: 1)
        }
    }
}

/// Shows Volt's own notification pill near the top of the active screen, with an
/// optional glow around the display edges for the alerts you must not miss.
@MainActor
final class HUDPresenter {
    static let shared = HUDPresenter()

    private var panel: NSPanel?
    private var glowWindows: [NSWindow] = []
    private var dismissTask: DispatchWorkItem?

    private init() {}

    func show(title: String, body: String, level: Int, accent: AlertColor,
              symbol: String?, duration: Double, glow: Bool) {
        dismissTask?.cancel()
        tearDown(animated: false)

        guard let screen = NSScreen.main else { return }

        let content = HUDView(title: title, message: body, level: level,
                              accent: accent, symbol: symbol)
        let hosting = NSHostingView(rootView: content)
        hosting.layout()
        let size = hosting.fittingSize

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = hosting
        panel.alphaValue = 0

        // Centred on the active screen, a little above the midpoint so it does not
        // land on whatever the user is reading.
        let frame = screen.frame
        let origin = NSPoint(x: frame.midX - size.width / 2,
                             y: frame.midY - size.height / 2 + frame.height * 0.08)
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        self.panel = panel

        if glow { showGlow(tint: accent.nsColor) }

        // Rise slightly and fade in.
        panel.setFrameOrigin(NSPoint(x: origin.x, y: origin.y - 14))
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.32
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrameOrigin(origin)
        }

        let task = DispatchWorkItem { [weak self] in self?.tearDown(animated: true) }
        dismissTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: task)
    }

    func dismiss() {
        dismissTask?.cancel()
        tearDown(animated: true)
    }

    // MARK: - Glow

    private func showGlow(tint: NSColor) {
        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: screen.frame,
                                  styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

            let view = GlowView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.tint = tint
            window.contentView = view
            window.setFrame(screen.frame, display: true)
            window.alphaValue = 0
            window.orderFrontRegardless()
            glowWindows.append(window)

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.45
                window.animator().alphaValue = 1
            }
        }
    }

    private func tearDown(animated: Bool) {
        let panel = self.panel
        let glows = self.glowWindows
        self.panel = nil
        self.glowWindows = []

        guard animated else {
            panel?.orderOut(nil)
            glows.forEach { $0.orderOut(nil) }
            return
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel?.animator().alphaValue = 0
            glows.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: {
            panel?.orderOut(nil)
            glows.forEach { $0.orderOut(nil) }
        })
    }
}

/// A soft coloured bloom hugging the edges of the display, transparent in the middle
/// so nothing you are working on is obscured.
final class GlowView: NSView {
    var tint: NSColor = .systemGreen { didSet { needsDisplay = true } }

    override var isFlipped: Bool { false }
    override var allowsVibrancy: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let inset: CGFloat = min(bounds.width, bounds.height) * 0.22

        // Four linear gradients, one per edge, fading to clear toward the centre.
        let edges: [(NSRect, CGPoint, CGPoint)] = [
            (NSRect(x: 0, y: 0, width: bounds.width, height: inset),
             CGPoint(x: 0, y: 0), CGPoint(x: 0, y: inset)),
            (NSRect(x: 0, y: bounds.height - inset, width: bounds.width, height: inset),
             CGPoint(x: 0, y: bounds.height), CGPoint(x: 0, y: bounds.height - inset)),
            (NSRect(x: 0, y: 0, width: inset, height: bounds.height),
             CGPoint(x: 0, y: 0), CGPoint(x: inset, y: 0)),
            (NSRect(x: bounds.width - inset, y: 0, width: inset, height: bounds.height),
             CGPoint(x: bounds.width, y: 0), CGPoint(x: bounds.width - inset, y: 0))
        ]

        let strong = tint.withAlphaComponent(0.5)
        let clear = tint.withAlphaComponent(0)
        guard let gradient = NSGradient(starting: strong, ending: clear) else { return }

        for (rect, start, end) in edges {
            context.saveGState()
            NSBezierPath(rect: rect).addClip()
            gradient.draw(from: start, to: end, options: [])
            context.restoreGState()
        }
    }
}
