import AppKit

/// Draws the status item image.
///
/// macOS renders template images in the menu bar's own colour, which is what you want
/// most of the time. When the user asks for colour, the image is drawn non-template
/// so the fill can go amber and red as the battery falls.
enum MenuBarIcon {
    static let height: CGFloat = 18

    static func image(for snapshot: BatterySnapshot,
                      style: IconStyle,
                      colored: Bool) -> NSImage {
        switch style {
        case .numberOnly:
            return textOnly(snapshot: snapshot, colored: colored)
        case .ring:
            return ring(snapshot: snapshot, colored: colored)
        case .pill, .pillNumber:
            return pill(snapshot: snapshot, showNumber: style == .pillNumber, colored: colored)
        }
    }

    static func fillColor(for percent: Int, charging: Bool, colored: Bool) -> NSColor {
        guard colored else { return .labelColor }
        if charging { return NSColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1) }
        switch percent {
        case ..<11: return NSColor(red: 1.00, green: 0.27, blue: 0.23, alpha: 1)
        case ..<21: return NSColor(red: 1.00, green: 0.72, blue: 0.11, alpha: 1)
        default: return .labelColor
        }
    }

    // MARK: - Styles

    /// iPhone-style horizontal battery, optionally preceded by the percentage.
    ///
    /// The number sits outside the shell rather than inside it. Inside, it would have to
    /// straddle the edge of the charge fill at middling levels and render half knocked-out,
    /// half solid — which reads as a glitch. Outside, it is legible at every level.
    private static func pill(snapshot: BatterySnapshot, showNumber: Bool, colored: Bool) -> NSImage {
        let bodyWidth: CGFloat = 24
        let bodyHeight: CGFloat = 12.5
        let capWidth: CGFloat = 2
        let capGap: CGFloat = 1.5

        let numberFont = NSFont.systemFont(ofSize: 11, weight: .medium)
        let numberText = "\(snapshot.percentage)"
        let numberAttributes: [NSAttributedString.Key: Any] = [
            .font: numberFont,
            .foregroundColor: NSColor.labelColor
        ]
        let numberSize = showNumber ? numberText.size(withAttributes: numberAttributes) : .zero
        let numberGap: CGFloat = showNumber ? 4 : 0

        let left = ceil(numberSize.width) + numberGap
        let width = left + bodyWidth + capGap + capWidth

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()

        if showNumber {
            numberText.draw(at: NSPoint(x: 0, y: (height - numberSize.height) / 2),
                            withAttributes: numberAttributes)
        }

        let outlineColor = NSColor.labelColor.withAlphaComponent(0.45)
        let fill = fillColor(for: snapshot.percentage, charging: snapshot.isCharging, colored: colored)
        let midY = (height - bodyHeight) / 2

        // Shell
        let shell = NSRect(x: left + 0.75, y: midY, width: bodyWidth - 1.5, height: bodyHeight)
        let shellPath = NSBezierPath(roundedRect: shell, xRadius: 3.6, yRadius: 3.6)
        shellPath.lineWidth = 1.2
        outlineColor.setStroke()
        shellPath.stroke()

        // Cap
        let cap = NSRect(x: left + bodyWidth + capGap - 0.75, y: (height - 5) / 2,
                         width: capWidth, height: 5)
        outlineColor.setFill()
        NSBezierPath(roundedRect: cap, xRadius: 1, yRadius: 1).fill()

        // Charge level
        let inset = shell.insetBy(dx: 2, dy: 2)
        let fraction = max(0, min(1, CGFloat(snapshot.percentage) / 100))
        var levelRect = NSRect(x: inset.minX, y: inset.minY, width: 0, height: inset.height)
        if fraction > 0 {
            levelRect.size.width = max(1.5, inset.width * fraction)
            fill.setFill()
            NSBezierPath(roundedRect: levelRect, xRadius: 2, yRadius: 2).fill()
        }

        if snapshot.isCharging {
            let boltRect = NSRect(x: shell.midX - 2.5, y: shell.midY - 4.5, width: 5, height: 9)
            overlay(in: levelRect, shell: shell) { knockout in
                (knockout ? NSColor.black : NSColor.labelColor).setFill()
                boltPath(in: boltRect).fill()
            }
        }

        image.unlockFocus()
        image.isTemplate = !colored
        return image
    }

    /// Draws something twice: punched out of the charge fill, and solid over the empty
    /// part of the shell. Either half alone would disappear at some charge levels.
    private static func overlay(in fillRect: NSRect, shell: NSRect,
                                _ render: (_ knockout: Bool) -> Void) {
        if fillRect.width > 0 {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: fillRect).addClip()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            render(true)
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSGraphicsContext.restoreGraphicsState()
        }

        let empty = NSRect(x: fillRect.maxX, y: shell.minY,
                           width: max(0, shell.maxX - fillRect.maxX), height: shell.height)
        guard empty.width > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: empty).addClip()
        render(false)
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func boltPath(in rect: NSRect) -> NSBezierPath {
        let w = rect.width, h = rect.height, x = rect.minX, y = rect.minY
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x + w * 0.70, y: y + h))
        path.line(to: NSPoint(x: x + w * 0.02, y: y + h * 0.46))
        path.line(to: NSPoint(x: x + w * 0.42, y: y + h * 0.46))
        path.line(to: NSPoint(x: x + w * 0.30, y: y))
        path.line(to: NSPoint(x: x + w * 0.98, y: y + h * 0.54))
        path.line(to: NSPoint(x: x + w * 0.58, y: y + h * 0.54))
        path.close()
        return path
    }

    private static func textOnly(snapshot: BatterySnapshot, colored: Bool) -> NSImage {
        let text = "\(snapshot.percentage)%" + (snapshot.isPluggedIn ? "" : "")
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let color = fillColor(for: snapshot.percentage, charging: snapshot.isCharging, colored: colored)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = text.size(withAttributes: attributes)

        let image = NSImage(size: NSSize(width: ceil(size.width) + 2, height: height))
        image.lockFocus()
        text.draw(at: NSPoint(x: 1, y: (height - size.height) / 2), withAttributes: attributes)
        image.unlockFocus()
        image.isTemplate = !colored
        return image
    }

    private static func ring(snapshot: BatterySnapshot, colored: Bool) -> NSImage {
        let diameter: CGFloat = 16
        let image = NSImage(size: NSSize(width: diameter + 2, height: height))
        image.lockFocus()

        let center = NSPoint(x: (diameter + 2) / 2, y: height / 2)
        let radius = diameter / 2 - 1.2
        let fill = fillColor(for: snapshot.percentage, charging: snapshot.isCharging, colored: colored)

        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = 1.8
        NSColor.labelColor.withAlphaComponent(0.22).setStroke()
        track.stroke()

        if snapshot.percentage > 0 {
            let sweep = 360 * CGFloat(snapshot.percentage) / 100
            let progress = NSBezierPath()
            progress.appendArc(withCenter: center, radius: radius,
                               startAngle: 90, endAngle: 90 - sweep, clockwise: true)
            progress.lineWidth = 1.8
            progress.lineCapStyle = .round
            fill.setStroke()
            progress.stroke()
        }

        if snapshot.isCharging {
            NSColor.labelColor.setFill()
            boltPath(in: NSRect(x: center.x - 2.2, y: center.y - 4, width: 4.4, height: 8)).fill()
        } else {
            let text = "\(snapshot.percentage)"
            // Three digits need a smaller face to clear the ring.
            let font = NSFont.systemFont(ofSize: text.count > 2 ? 5.8 : 7.2, weight: .bold)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2),
                      withAttributes: attributes)
        }

        image.unlockFocus()
        image.isTemplate = !colored
        return image
    }
}
