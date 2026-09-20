import SwiftUI

/// The alert itself: a dark capsule centred on screen, ringed in the colour of the
/// urgency and glowing outward, so it reads from across the room.
struct HUDView: View {
    let title: String
    let message: String
    let level: Int
    let urgency: HUDUrgency
    let symbol: String?

    var body: some View {
        HStack(spacing: 20) {
            glyph

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 25, weight: .bold))
                    .foregroundStyle(.white)
                Text(message)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.white.opacity(0.62))
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.leading, 30)
        .padding(.trailing, 38)
        .padding(.vertical, 22)
        .background {
            ZStack {
                Capsule().fill(Color(white: 0.07))
                // Inner hairline, then the bright ring that carries the colour.
                Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1).padding(3)
                Capsule().strokeBorder(urgency.tint, lineWidth: 3.5)
            }
            .compositingGroup()
            .shadow(color: urgency.tint.opacity(0.55), radius: 16)
            .shadow(color: urgency.tint.opacity(0.35), radius: 34)
            .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
        }
        .padding(46) // room for the glow to fall off inside the panel
    }

    @ViewBuilder
    private var glyph: some View {
        if let symbol {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(urgency.tint)
                .frame(width: 46)
        } else {
            BatteryGlyph(level: level, tint: urgency.tint, outlineTint: true)
                .frame(width: 46, height: 23)
        }
    }
}

/// A small iPhone-style battery, filled to `level`.
struct BatteryGlyph: View {
    let level: Int
    var tint: Color = .green
    /// Draw the shell in the tint too, rather than in the label colour.
    var outlineTint: Bool = false

    var body: some View {
        GeometryReader { geo in
            let capWidth = geo.size.width * 0.06
            let bodyWidth = geo.size.width - capWidth - 1.5
            let radius = geo.size.height * 0.32
            let outline = outlineTint ? tint : Color.primary.opacity(0.5)

            HStack(spacing: 1.5) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: radius)
                        .stroke(outline, lineWidth: geo.size.height * 0.09)
                    RoundedRectangle(cornerRadius: max(0, radius - 2))
                        .fill(tint)
                        .padding(geo.size.height * 0.16)
                        .frame(width: max(geo.size.height * 0.4,
                                          bodyWidth * CGFloat(level) / 100))
                }
                .frame(width: bodyWidth)

                RoundedRectangle(cornerRadius: capWidth / 2)
                    .fill(outline)
                    .frame(width: capWidth, height: geo.size.height * 0.36)
            }
        }
    }
}
