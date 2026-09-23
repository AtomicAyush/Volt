import SwiftUI

/// A ribbon from a span on the left edge to a span on the right edge, as fractions of
/// the height so it can animate.
///
/// The control points cross over — the first to the right of centre, the second to the
/// left — which holds each edge flat as it leaves and arrives and puts all the bend in
/// the middle. Both at the midpoint gives a lazy diagonal instead.
struct FlowBand: Shape {
    var leftTop: CGFloat
    var leftBottom: CGFloat
    var rightTop: CGFloat
    var rightBottom: CGFloat

    /// Lets SwiftUI interpolate the four edges, so the ribbon flows to a new shape
    /// instead of jumping when the wattage changes.
    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>,
                                       AnimatablePair<CGFloat, CGFloat>> {
        get {
            AnimatablePair(AnimatablePair(leftTop, leftBottom),
                           AnimatablePair(rightTop, rightBottom))
        }
        set {
            leftTop = newValue.first.first
            leftBottom = newValue.first.second
            rightTop = newValue.second.first
            rightBottom = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let h = rect.height, w = rect.width
        let near = w * 0.72, far = w * 0.28
        let lt = h * leftTop, lb = h * leftBottom
        let rt = h * rightTop, rb = h * rightBottom

        var path = Path()
        path.move(to: CGPoint(x: 0, y: lt))
        path.addCurve(to: CGPoint(x: w, y: rt),
                      control1: CGPoint(x: near, y: lt),
                      control2: CGPoint(x: far, y: rt))
        path.addLine(to: CGPoint(x: w, y: rb))
        path.addCurve(to: CGPoint(x: 0, y: lb),
                      control1: CGPoint(x: far, y: rb),
                      control2: CGPoint(x: near, y: lb))
        path.closeSubpath()
        return path
    }
}

/// Where the watts are going, drawn as ribbons whose thickness is their share.
///
/// Plugged in, the adapter's output splits between charging the pack and running the
/// Mac. On battery it is the pack doing the running, so there is a single ribbon going
/// the other way. Everything animates: the readings move continuously, and a diagram
/// that snapped between them would be harder to read than one that flows.
struct PowerFlowView: View {
    let snapshot: BatterySnapshot

    private let flowHeight: CGFloat = 96
    private let boxGap: CGFloat = 6

    private var tint: Color {
        BatteryTint.swiftUIColor(percentage: snapshot.percentage, charging: snapshot.isCharging)
    }

    private var toBattery: Double { snapshot.chargePower }
    private var toSystem: Double { snapshot.load }
    private var total: Double { max(0.1, toBattery + toSystem) }

    /// Share of the left edge the battery ribbon takes, kept off the extremes so the
    /// thinner ribbon never collapses to nothing.
    private var split: CGFloat {
        guard snapshot.isCharging else { return 1 }
        return max(0.17, min(0.83, CGFloat(toBattery / total)))
    }

    /// The destination boxes are the same size, so the ribbons converge to fixed ends
    /// and the proportion is carried by their thickness at the source.
    private var midpoint: CGFloat { 0.5 }

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
                source.frame(width: 58)

                flow
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    // Above the clip: the rolling digits travel a little past their own
                    // bounds as they change, and inside the clip that got cut off.
                    .overlay { labels }

                VStack(spacing: boxGap) {
                    if snapshot.isCharging {
                        endpoint(symbol: "battery.100percent.bolt", tint: tint)
                    }
                    endpoint(symbol: "laptopcomputer", tint: Panel.secondary)
                }
                .frame(width: 48)
            }
            .frame(height: flowHeight)

            caption
        }
        .animation(.easeInOut(duration: 0.55), value: split)
        .animation(.easeInOut(duration: 0.55), value: snapshot.isCharging)
    }

    // MARK: - Pieces

    /// The adapter when plugged in, the battery when not.
    ///
    /// The headline is what the adapter is actually delivering, which moves with the
    /// load. The figure underneath is the negotiated USB-C contract — the ceiling the
    /// Mac and charger agreed on, not a claim about what is printed on the brick. A
    /// 140W charger reports 100W there unless it negotiates the extended range.
    private var source: some View {
        VStack(spacing: 2) {
            Image(systemName: snapshot.isPluggedIn ? "powerplug.fill" : "battery.75percent")
                .font(.system(size: 15))
                .foregroundStyle(Panel.secondary)

            Text(sourceHeadline)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
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

    private var flow: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let gapFraction = boxGap / h

            ZStack {
                if snapshot.isCharging {
                    FlowBand(leftTop: 0, leftBottom: split,
                             rightTop: 0, rightBottom: midpoint - gapFraction / 2)
                        .fill(LinearGradient(colors: [tint.opacity(0.32), tint.opacity(0.78)],
                                             startPoint: .leading, endPoint: .trailing))
                        .overlay {
                            // A streak of light down the ribbon, for a bit of depth.
                            FlowBand(leftTop: 0, leftBottom: split,
                                     rightTop: 0, rightBottom: midpoint - gapFraction / 2)
                                .fill(LinearGradient(colors: [.clear, .white.opacity(0.20), .clear],
                                                     startPoint: .top, endPoint: .bottom))
                        }

                    FlowBand(leftTop: split, leftBottom: 1,
                             rightTop: midpoint + gapFraction / 2, rightBottom: 1)
                        .fill(LinearGradient(colors: [Color.white.opacity(0.10),
                                                      Color.white.opacity(0.24)],
                                             startPoint: .leading, endPoint: .trailing))

                } else {
                    FlowBand(leftTop: 0, leftBottom: 1, rightTop: 0, rightBottom: 1)
                        .fill(LinearGradient(colors: [tint.opacity(0.30), tint.opacity(0.65)],
                                             startPoint: .leading, endPoint: .trailing))
                }
            }
        }
    }

    /// The wattage labels, centred on each ribbon where it crosses the middle of the
    /// diagram rather than at its left edge, where the thinner ribbon is thinnest.
    private var labels: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let centreX = geo.size.width / 2
            // With the control points level with their endpoints, the divider crosses
            // the middle exactly halfway between where it starts and where it ends.
            let gap = boxGap / h
            let divider = h * (split + (midpoint - gap / 2)) / 2
            let margin: CGFloat = 12

            if snapshot.isCharging {
                watts(toBattery, at: CGPoint(x: centreX,
                                             y: min(max(divider / 2, margin), h - margin)))
                watts(toSystem, at: CGPoint(x: centreX,
                                            y: min(max((divider + h) / 2, margin), h - margin)))
            } else {
                watts(toSystem, at: CGPoint(x: centreX, y: h / 2))
            }
        }
    }

    private func watts(_ value: Double, at point: CGPoint) -> some View {
        Text(String(format: "%.1f W", value))
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .monospacedDigit()
            .contentTransition(.numericText())
            .foregroundStyle(.white)
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
                    .monospacedDigit()
                    .contentTransition(.numericText())
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
        case ..<28: return "Normal workload: comfortably within range"
        case ..<45: return "Heavy load: something is working hard"
        default: return "Very heavy load"
        }
    }
}
