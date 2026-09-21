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

                VStack(spacing: boxGap) {
                    if snapshot.isCharging {
                        endpoint(symbol: "battery.100percent.bolt", tint: tint)
                            .frame(height: batteryBoxHeight)
                    }
                    endpoint(symbol: "laptopcomputer", tint: Panel.secondary)
                        .frame(maxHeight: .infinity)
                }
                .frame(width: 48)
            }
            .frame(height: flowHeight)

            caption
        }
    }

    // MARK: - Pieces

    /// The adapter when plugged in, the battery when not.
    ///
    /// The headline is what the adapter is actually delivering, which moves with the
    /// load. The figure underneath is the negotiated USB-C contract — the ceiling the
    /// Mac and the charger agreed on, not a claim about what is printed on the brick.
    /// A 140 W charger reports 100 W here unless it negotiates the extended range.
    private var source: some View {
        VStack(spacing: 2) {
            Image(systemName: snapshot.isPluggedIn ? "powerplug.fill" : "battery.75percent")
                .font(.system(size: 15))
                .foregroundStyle(Panel.secondary)

            Text(sourceHeadline)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Panel.label)

            if let detail = sourceDetail {
                Text(detail)
                    .font(.system(size: 8.5))
                    .monospacedDigit()
                    .foregroundStyle(Panel.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.white.opacity(0.05)))
    }

    private var sourceHeadline: String {
        guard snapshot.isPluggedIn else { return "\(snapshot.percentage)%" }
        if let delivered = snapshot.adapterPower, delivered > 0.5 {
            return String(format: "%.0f W", delivered)
        }
        return "AC"
    }

    private var sourceDetail: String? {
        guard snapshot.isPluggedIn, let negotiated = snapshot.adapterWatts else { return nil }
        return "max \(negotiated)W"
    }

    private func endpoint(symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 15))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(tint.opacity(0.10)))
    }

    private let flowHeight: CGFloat = 96
    private let boxGap: CGFloat = 6

    /// Height of the battery box, proportional to its share of the flow so the ribbon
    /// arriving at it is the same thickness as the box itself.
    private var batteryBoxHeight: CGFloat {
        let share = toBattery / total
        let usable = flowHeight - boxGap
        return max(26, min(usable - 26, usable * share))
    }

    private var flow: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            if snapshot.isCharging {
                // The stream leaves the adapter split by share and arrives split by the
                // destination boxes, so the divider sweeps between the two.
                let leftSplit = max(16, min(h - 16, h * (toBattery / total)))
                let rightSplit = batteryBoxHeight

                band(width: w, leftTop: 0, leftBottom: leftSplit,
                     rightTop: 0, rightBottom: rightSplit)
                    .fill(LinearGradient(colors: [tint.opacity(0.32), tint.opacity(0.78)],
                                         startPoint: .leading, endPoint: .trailing))
                    .overlay {
                        // A streak of light along the ribbon, for a bit of depth.
                        band(width: w, leftTop: 0, leftBottom: leftSplit,
                             rightTop: 0, rightBottom: rightSplit)
                            .fill(LinearGradient(colors: [.clear, .white.opacity(0.22), .clear],
                                                 startPoint: .top, endPoint: .bottom))
                    }
                    .overlay(label(String(format: "%.1f W", toBattery),
                                   at: CGPoint(x: w / 2, y: (leftSplit + rightSplit) / 4 + 6),
                                   tint: .white))

                band(width: w, leftTop: leftSplit, leftBottom: h,
                     rightTop: rightSplit + boxGap, rightBottom: h)
                    .fill(LinearGradient(colors: [Color.white.opacity(0.10), Color.white.opacity(0.24)],
                                         startPoint: .leading, endPoint: .trailing))
                    .overlay(label(String(format: "%.1f W", toSystem),
                                   at: CGPoint(x: w / 2,
                                               y: (leftSplit + h + rightSplit + boxGap + h) / 4),
                                   tint: .white))
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
    ///
    /// The control points cross over — the first sits to the right of centre, the
    /// second to the left — which holds each edge flat as it leaves and arrives and
    /// puts all the bend in the middle. Placing both at the midpoint gives a lazy
    /// diagonal instead of the steep S this is after.
    private func band(width: CGFloat, leftTop: CGFloat, leftBottom: CGFloat,
                      rightTop: CGFloat, rightBottom: CGFloat) -> Path {
        var path = Path()
        let near = width * 0.72
        let far = width * 0.28

        path.move(to: CGPoint(x: 0, y: leftTop))
        path.addCurve(to: CGPoint(x: width, y: rightTop),
                      control1: CGPoint(x: near, y: leftTop),
                      control2: CGPoint(x: far, y: rightTop))
        path.addLine(to: CGPoint(x: width, y: rightBottom))
        path.addCurve(to: CGPoint(x: 0, y: leftBottom),
                      control1: CGPoint(x: far, y: rightBottom),
                      control2: CGPoint(x: near, y: leftBottom))
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
