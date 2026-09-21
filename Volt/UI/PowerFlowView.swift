import SwiftUI

/// Where the watts are going, drawn as two bands whose thickness is their share.
///
/// Plugged in, the adapter's output splits between charging the battery and running
/// the Mac. On battery it is the pack doing the running, so there is a single band
/// flowing the other way. The numbers come from the gauge, which reports both what the
/// adapter is delivering and what the machine is drawing.
struct PowerFlowView: View {
    let snapshot: BatterySnapshot

    private var tint: Color {
        BatteryTint.swiftUIColor(percentage: snapshot.percentage, charging: snapshot.isCharging)
    }

    private var toBattery: Double { snapshot.chargePower }
    private var toSystem: Double { snapshot.load }
    private var total: Double { max(0.1, toBattery + toSystem) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.horizontal.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(Panel.secondary)
                Text("Power Flow")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Panel.secondary)
            }

            HStack(spacing: 7) {
                source
                    .frame(width: 58)

                flow
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(spacing: 6) {
                    if snapshot.isCharging {
                        endpoint(symbol: "battery.100percent.bolt", tint: tint)
                            .frame(height: batteryBoxHeight)
                    }
                    endpoint(symbol: "laptopcomputer", tint: Panel.secondary)
                        .frame(maxHeight: .infinity)
                }
                .frame(width: 48)
            }
            .frame(height: 96)

            caption
        }
    }

    // MARK: - Pieces

    /// The adapter when plugged in, the battery when not.
    private var source: some View {
        VStack(spacing: 4) {
            Image(systemName: snapshot.isPluggedIn ? "powerplug.fill" : "battery.75percent")
                .font(.system(size: 17))
                .foregroundStyle(Panel.secondary)
            Text(sourceLabel)
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Panel.label)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.white.opacity(0.05)))
    }

    private var sourceLabel: String {
        if snapshot.isPluggedIn, let watts = snapshot.adapterWatts { return "\(watts)W" }
        if snapshot.isPluggedIn { return "AC" }
        return "\(snapshot.percentage)%"
    }

    private func endpoint(symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 15))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(tint.opacity(0.10)))
    }

    /// Height of the battery box, proportional to its share of the flow.
    private var batteryBoxHeight: CGFloat {
        let share = toBattery / total
        return max(28, min(62, 96 * share))
    }

    private var flow: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            if snapshot.isCharging {
                let split = max(18, min(h - 18, h * (toBattery / total)))
                // Battery band on top, sized to its share; the Mac's share below it.
                band(width: w, leftTop: 0, leftBottom: split,
                     rightTop: 0, rightBottom: batteryBoxHeight)
                    .fill(LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0.75)],
                                         startPoint: .leading, endPoint: .trailing))
                    .overlay(label(String(format: "%.1f W", toBattery),
                                   at: CGPoint(x: w / 2, y: split / 2), tint: .white))

                band(width: w, leftTop: split, leftBottom: h,
                     rightTop: batteryBoxHeight + 6, rightBottom: h)
                    .fill(LinearGradient(colors: [Color.white.opacity(0.10), Color.white.opacity(0.22)],
                                         startPoint: .leading, endPoint: .trailing))
                    .overlay(label(String(format: "%.1f W", toSystem),
                                   at: CGPoint(x: w / 2, y: (split + h) / 2), tint: .white))
            } else {
                band(width: w, leftTop: 0, leftBottom: h, rightTop: 0, rightBottom: h)
                    .fill(LinearGradient(colors: [tint.opacity(0.30), tint.opacity(0.65)],
                                         startPoint: .leading, endPoint: .trailing))
                    .overlay(label(String(format: "%.1f W", toSystem),
                                   at: CGPoint(x: w / 2, y: h / 2), tint: .white))
            }
        }
    }

    /// A ribbon from a span on the left edge to a span on the right edge.
    private func band(width: CGFloat, leftTop: CGFloat, leftBottom: CGFloat,
                      rightTop: CGFloat, rightBottom: CGFloat) -> Path {
        var path = Path()
        let mid = width * 0.5
        path.move(to: CGPoint(x: 0, y: leftTop))
        path.addCurve(to: CGPoint(x: width, y: rightTop),
                      control1: CGPoint(x: mid, y: leftTop),
                      control2: CGPoint(x: mid, y: rightTop))
        path.addLine(to: CGPoint(x: width, y: rightBottom))
        path.addCurve(to: CGPoint(x: 0, y: leftBottom),
                      control1: CGPoint(x: mid, y: rightBottom),
                      control2: CGPoint(x: mid, y: leftBottom))
        path.closeSubpath()
        return path
    }

    private func label(_ text: String, at point: CGPoint, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(tint)
            .shadow(color: .black.opacity(0.45), radius: 2)
            .position(point)
    }

    // MARK: - Caption

    private var caption: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Image(systemName: snapshot.isCharging ? "bolt.fill"
                      : (snapshot.isPluggedIn ? "powerplug.fill" : "battery.50percent"))
                    .font(.system(size: 10))
                    .foregroundStyle(snapshot.isCharging ? tint : Panel.secondary)
                Text(headline)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Panel.label)
            }
            Text(loadDescription)
                .font(.system(size: 10.5))
                .foregroundStyle(Panel.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var headline: String {
        if snapshot.isCharging { return String(format: "Charging at %.0f W", toBattery) }
        if snapshot.isPluggedIn { return String(format: "Running on AC at %.0f W", toSystem) }
        return String(format: "On battery · %.0f W", toSystem)
    }

    private var loadDescription: String {
        switch toSystem {
        case ..<6: return "Idle: little more than the display"
        case ..<14: return "Light use: typical for web and docs"
        case ..<28: return "Moderate load"
        case ..<45: return "Heavy load: something is working hard"
        default: return "Very heavy load"
        }
    }
}
