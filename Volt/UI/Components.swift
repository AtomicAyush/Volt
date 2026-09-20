import SwiftUI

/// Panel palette. The popover draws its own dark surface rather than using the
/// system material, so the cards keep the same contrast in light and dark mode.
enum Panel {
    static let background = Color(red: 0.07, green: 0.07, blue: 0.075)
    static let card = Color(red: 0.13, green: 0.13, blue: 0.137)
    static let hairline = Color.white.opacity(0.07)
    static let label = Color.white
    static let secondary = Color.white.opacity(0.55)
    static let tertiary = Color.white.opacity(0.35)

    static let green = Color(red: 0.20, green: 0.82, blue: 0.40)
    static let amber = Color(red: 1.00, green: 0.72, blue: 0.11)
    static let red = Color(red: 1.00, green: 0.31, blue: 0.27)
    static let blue = Color(red: 0.25, green: 0.56, blue: 1.00)
}

/// A rounded container; every block in the popover sits in one.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Panel.card))
    }
}

/// The titled header at the top of a panel, with a tinted glyph.
struct SectionHeader: View {
    let symbol: String
    let tint: Color
    let title: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 18, height: 18)

            Text(title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(Panel.label)

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

/// A flat progress bar. `segments` draws the notches the status bar uses.
struct MeterBar: View {
    let fraction: Double
    let tint: Color
    var segments: Int = 0
    var height: CGFloat = 7

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1))
                Capsule()
                    .fill(tint)
                    .frame(width: max(height, geo.size.width * min(1, max(0, fraction))))

                if segments > 1 {
                    HStack(spacing: 0) {
                        ForEach(1..<segments, id: \.self) { _ in
                            Spacer()
                            Rectangle()
                                .fill(Panel.card)
                                .frame(width: 1.5)
                        }
                        Spacer()
                    }
                }
            }
        }
        .frame(height: height)
    }
}

/// Label above, value below — the unit is typeset separately so the number reads first.
struct StatBlock: View {
    let label: String
    let value: String
    var unit: String?
    var tint: Color = Panel.label
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: 1) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Panel.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                if let unit {
                    Text(unit)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Panel.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
    }
}

/// A single "name … value" line, as used by Capacity Details.
struct ValueRow: View {
    let label: String
    let value: String
    var unit: String?
    var tint: Color = Panel.label

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Panel.secondary)
            Spacer()
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                if let unit {
                    Text(unit)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Panel.tertiary)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

extension View {
    /// A hairline between sections inside a card.
    func sectionDivider() -> some View {
        overlay(alignment: .bottom) {
            Rectangle().fill(Panel.hairline).frame(height: 1).padding(.horizontal, 14)
        }
    }
}

/// Grouped thousands, the way the capacity figures read best.
func grouped(_ value: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
}

/// A small segmented control. AppKit's `.segmented` picker style does not tint
/// correctly against the panel's own dark cards, so this draws its own.
struct Segments<T: Hashable & Identifiable>: View {
    let options: [T]
    let title: (T) -> String
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let isSelected = option == selection
                Text(title(option))
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Panel.label : Panel.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isSelected ? Color.white.opacity(0.14) : .clear)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { selection = option }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.black.opacity(0.28)))
    }
}
