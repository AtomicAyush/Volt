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

    /// In the numbered style the interior is filled solid and the colour alone carries
    /// the level, so it steps through a wider range than the simple three-way warning
    /// tint the other styles use.
    static func levelColor(for percent: Int, charging: Bool) -> NSColor {
        if charging { return NSColor(red: 0.20, green: 0.80, blue: 0.36, alpha: 1) }
        switch percent {
        case ..<10: return NSColor(red: 0.96, green: 0.24, blue: 0.21, alpha: 1)  // red
        case ..<20: return NSColor(red: 0.98, green: 0.45, blue: 0.13, alpha: 1)  // orange
        case ..<35: return NSColor(red: 1.00, green: 0.72, blue: 0.11, alpha: 1)  // amber
        case ..<60: return NSColor(red: 0.80, green: 0.80, blue: 0.14, alpha: 1)  // lime
        default: return NSColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1)     // green
        }
    }

    /// Black or white, whichever stands out against the fill. Picked from relative
    /// luminance rather than fixed per colour, so the digits stay readable if the
    /// palette above is ever retuned.
    private static func contrasting(with color: NSColor) -> NSColor {
        guard let rgb = color.usingColorSpace(.sRGB) else { return .black }
        let luminance = 0.2126 * rgb.redComponent
            + 0.7152 * rgb.greenComponent
            + 0.0722 * rgb.blueComponent
        return luminance > 0.55 ? .black : .white
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

    /// iPhone-style horizontal battery with the percentage inside the shell.
    ///
    /// The digits are punched out of the fill rather than drawn on top of it. For that
    /// to read at every charge level the whole interior carries a faint track, so the
    /// knockout lands on something solid even where the battery is nearly empty —
    /// otherwise a number straddling the edge of the fill renders half dark, half light.
    private static func pill(snapshot: BatterySnapshot, showNumber: Bool, colored: Bool) -> NSImage {
        let bodyWidth: CGFloat = showNumber ? 32 : 24
        let bodyHeight: CGFloat = 13.5
        let capWidth: CGFloat = 2
        let capGap: CGFloat = 1.5
        let boltGap: CGFloat = snapshot.isCharging && showNumber ? 6.5 : 0
        let width = bodyWidth + capGap + capWidth + boltGap

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()

        // A brighter shell than the other styles use: the numbered icon is busier, so
        // the outline has to hold it together.
        let outlineColor = NSColor.labelColor.withAlphaComponent(showNumber ? 0.7 : 0.45)
        let fill = showNumber && colored
            ? levelColor(for: snapshot.percentage, charging: snapshot.isCharging)
            : fillColor(for: snapshot.percentage, charging: snapshot.isCharging, colored: colored)
        let midY = (height - bodyHeight) / 2

        // Shell
        let shell = NSRect(x: 0.75, y: midY, width: bodyWidth - 1.5, height: bodyHeight)
        let shellPath = NSBezierPath(roundedRect: shell, xRadius: 3.8, yRadius: 3.8)
        shellPath.lineWidth = 1.2
        outlineColor.setStroke()
        shellPath.stroke()

        // Cap
        let cap = NSRect(x: bodyWidth + capGap - 0.75, y: (height - 5) / 2,
                         width: capWidth, height: 5)
        outlineColor.setFill()
        NSBezierPath(roundedRect: cap, xRadius: 1, yRadius: 1).fill()

        let inset = shell.insetBy(dx: 1.9, dy: 1.9)
        let interior = NSBezierPath(roundedRect: inset, xRadius: 2.1, yRadius: 2.1)

        let fraction = max(0, min(1, CGFloat(snapshot.percentage) / 100))

        if showNumber {
            // Solid interior: the colour is the level indicator, so there is no
            // proportional bar and the digits always sit on one even surface.
            fill.setFill()
            interior.fill()
        } else if fraction > 0 {
            let levelRect = NSRect(x: inset.minX, y: inset.minY,
                                   width: max(1.5, inset.width * fraction), height: inset.height)
            NSGraphicsContext.saveGraphicsState()
            interior.addClip()
            fill.setFill()
            NSBezierPath(rect: levelRect).fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        if showNumber {
            let text = "\(snapshot.percentage)"
            let size: CGFloat = text.count > 2 ? 9 : 10
            let font = NSFont.systemFont(ofSize: size, weight: .bold)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: colored ? contrasting(with: fill) : NSColor.black
            ]
            let bounds = text.size(withAttributes: attributes)
            let origin = NSPoint(x: shell.midX - bounds.width / 2,
                                 y: shell.midY - bounds.height / 2)

            if colored {
                text.draw(at: origin, withAttributes: attributes)
            } else {
                // A template icon is a single colour plus alpha, so the digits are
                // punched out of the solid fill instead of drawn on top of it.
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                text.draw(at: origin, withAttributes: attributes)
                NSGraphicsContext.current?.compositingOperation = .sourceOver
            }
        } else if snapshot.isCharging {
            // With no number to make room for, the bolt sits inside the shell.
            let boltRect = NSRect(x: shell.midX - 2.5, y: shell.midY - 4.5, width: 5, height: 9)
            let levelRect = NSRect(x: inset.minX, y: inset.minY,
                                   width: max(1.5, inset.width * fraction), height: inset.height)
            overlay(in: levelRect, shell: shell) { knockout in
                (knockout ? NSColor.black : NSColor.labelColor).setFill()
                boltPath(in: boltRect).fill()
            }
        }

        // When the number is inside, the charging bolt goes after the cap.
        if snapshot.isCharging && showNumber {
            fill.setFill()
            boltPath(in: NSRect(x: bodyWidth + capGap + capWidth + 0.8,
                                y: height / 2 - 5, width: 5, height: 10)).fill()
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
