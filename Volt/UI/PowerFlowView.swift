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
/// Mac. On battery it is the pack doing the running. Either way, anything charging from
/// the Mac's own ports gets a ribbon of its own. Everything animates: the readings move
/// continuously, and a diagram that snapped between them would be harder to read than
/// one that flows.
struct PowerFlowView: View {
    let snapshot: BatterySnapshot

    private let boxGap: CGFloat = 6

    private var tint: Color {
        BatteryTint.swiftUIColor(percentage: snapshot.percentage, charging: snapshot.isCharging)
    }

    private var toBattery: Double { snapshot.chargePower }
    private var toSystem: Double { snapshot.load }

    /// One ribbon's destination.
    private struct Destination: Identifiable {
        enum Kind { case battery, mac, port }
        let id: String
        let kind: Kind
        let watts: Double
        let symbol: String
        let name: String
    }

    private var destinations: [Destination] {
        var list: [Destination] = []
        if snapshot.isCharging {
            list.append(.init(id: "battery", kind: .battery, watts: toBattery,
                              symbol: "battery.100percent.bolt", name: "Battery"))
        }
        list.append(.init(id: "mac", kind: .mac, watts: snapshot.macLoad,
                          symbol: "laptopcomputer", name: "This Mac"))
        for output in snapshot.portOutputs {
            list.append(.init(id: "port\(output.port)", kind: .port, watts: output.watts,
                              symbol: output.symbol, name: output.name))
        }
        return list
    }

    /// Each ribbon's span on the left edge, as fractions of the height: a small sliver
    /// each, so a 3 W accessory next to 56 W of charging still shows, and the rest in
    /// proportion to watts, so thickness always follows the figures. A hairline separates
    /// them, since several can share a colour.
    private func sourceSpans(_ list: [Destination], height: CGFloat) -> [ClosedRange<CGFloat>] {
        guard list.count > 1 else { return [0...1] }
        let n = CGFloat(list.count)
        let total = max(0.1, list.reduce(0) { $0 + max(0, $1.watts) })
        let base = min(0.08, 0.5 / n)
        let hairline = 1 / height
        let usable = 1 - hairline * (n - 1)
        var top: CGFloat = 0
        return list.map { destination in
            let share = base + (1 - base * n) * CGFloat(max(0, destination.watts) / total)
            let span = top...(top + usable * share)
            top = span.upperBound + hairline
            return span
        }
    }

    /// The destination boxes are the same size, so the ribbons converge to fixed ends
    /// and the proportion is carried by their thickness at the source.
    private func destinationSpans(count: Int, height: CGFloat) -> [ClosedRange<CGFloat>] {
        let gap = boxGap / height
        let box = (1 - gap * CGFloat(count - 1)) / CGFloat(count)
        return (0..<count).map { i in
            let top = CGFloat(i) * (box + gap)
            return top...(top + box)
        }
    }

    /// Boxes, labels and caption rows are laid out at the final size, so one that is added
    /// waits for the diagram to grow before appearing, and one that goes fades out quickly
    /// as the diagram starts to shrink.
    private static let placedAtFinalSize = AnyTransition.asymmetric(
        insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.45)),
        removal: .opacity.animation(.easeIn(duration: 0.12)))

    /// Taller when there are more than two ribbons, so their labels do not crowd.
    private func flowHeight(for count: Int) -> CGFloat {
        96 + CGFloat(max(0, count - 2)) * 30
    }

    var body: some View {
        let list = destinations
        let height = flowHeight(for: list.count)
        let left = sourceSpans(list, height: height)
        let right = destinationSpans(count: list.count, height: height)

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

                flow(list, left: left, right: right)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    // Above the clip: the rolling digits travel a little past their own
                    // bounds as they change, and inside the clip that got cut off.
                    .overlay { labels(list, left: left, right: right) }

                VStack(spacing: boxGap) {
                    ForEach(list) { destination in
                        endpoint(destination)
                            .transition(Self.placedAtFinalSize)
                    }
                }
                .frame(width: 48)
            }
            .frame(height: height)

            caption
        }
        .animation(.easeInOut(duration: 0.55), value: left.map(\.upperBound))
        .animation(.easeInOut(duration: 0.55), value: list.map(\.id))
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

    private func endpoint(_ destination: Destination) -> some View {
        let color = color(for: destination)
        return Image(systemName: destination.symbol)
            .font(.system(size: 15))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(color.opacity(0.10)))
            .help(destination.name)
            .accessibilityLabel("\(destination.name), \(String(format: "%.1f", destination.watts)) watts")
    }

    private func color(for destination: Destination) -> Color {
        switch destination.kind {
        case .battery: return tint
        case .mac: return Panel.secondary
        case .port: return Panel.blue
        }
    }

    private func fill(for destination: Destination, alone: Bool) -> LinearGradient {
        let colors: [Color]
        switch destination.kind {
        case .battery: colors = [tint.opacity(0.32), tint.opacity(0.78)]
        // Alone, the Mac's ribbon carries the battery's colour, as it always has.
        case .mac: colors = alone ? [tint.opacity(0.30), tint.opacity(0.65)]
                                  : [Color.white.opacity(0.10), Color.white.opacity(0.24)]
        case .port: colors = [Panel.blue.opacity(0.28), Panel.blue.opacity(0.70)]
        }
        return LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }

    private func flow(_ list: [Destination], left: [ClosedRange<CGFloat>],
                      right: [ClosedRange<CGFloat>]) -> some View {
        ZStack {
            ForEach(Array(list.enumerated()), id: \.element.id) { index, destination in
                let band = FlowBand(leftTop: left[index].lowerBound,
                                    leftBottom: left[index].upperBound,
                                    rightTop: right[index].lowerBound,
                                    rightBottom: right[index].upperBound)
                band.fill(fill(for: destination, alone: list.count == 1))
                    .overlay {
                        if destination.kind == .battery {
                            // A streak of light down the ribbon, for a bit of depth.
                            band.fill(LinearGradient(colors: [.clear, .white.opacity(0.20), .clear],
                                                     startPoint: .top, endPoint: .bottom))
                        }
                    }
                    .transition(.opacity)
            }
        }
    }

    /// The wattage labels, centred on each ribbon where it crosses the middle of the
    /// diagram rather than at its left edge, where a thin ribbon is thinnest. With the
    /// control points level with their endpoints, a ribbon's centre line crosses the
    /// middle exactly halfway between where it starts and where it ends. With three or
    /// more ribbons they sit beside the boxes instead.
    private func labels(_ list: [Destination], left: [ClosedRange<CGFloat>],
                        right: [ClosedRange<CGFloat>]) -> some View {
        GeometryReader { geo in
            let h = geo.size.height
            let margin: CGFloat = 12
            ForEach(Array(list.enumerated()), id: \.element.id) { index, destination in
                let start = (left[index].lowerBound + left[index].upperBound) / 2
                let end = (right[index].lowerBound + right[index].upperBound) / 2
                // With three or more ribbons the thin ones cross each other mid-way, so
                // the labels go beside the boxes, where every ribbon is flat and a box high.
                let crowded = list.count > 2
                watts(destination.watts,
                      at: CGPoint(x: crowded ? geo.size.width - 30 : geo.size.width / 2,
                                  y: min(max(h * (crowded ? end : (start + end) / 2), margin), h - margin)))
                    .transition(Self.placedAtFinalSize)
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
                    .frame(width: 14)
                Text(headline)
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(Panel.label)
            }
            // A different kind of headline is a new row, which enters once the card has
            // resized; a changing number just rolls.
            .id(headlineKind)
            .transition(Self.placedAtFinalSize)
            Text(loadDescription)
                .font(.system(size: 10.5))
                .foregroundStyle(Panel.secondary)
            ForEach(snapshot.portOutputs) { output in
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: output.symbol)
                        .font(.system(size: 10))
                        .foregroundStyle(Panel.blue)
                        .frame(width: 14)
                    // Wraps rather than cutting the name short: the panel is narrow, and a
                    // device name can be long.
                    Text("\(output.name) · \(String(format: "%.1f", output.watts)) W from this Mac")
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(Panel.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 2)
                .transition(Self.placedAtFinalSize)
            }
        }
        // Left-aligned with the header: centred, the whole block shifted sideways
        // whenever its longest line changed.
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headlineKind: Int {
        if snapshot.isCharging { return 0 }
        if snapshot.isPluggedIn { return snapshot.watts < -0.5 ? 1 : 2 }
        return 3
    }

    private var headline: String {
        if snapshot.isCharging { return String(format: "Charging at %.0f W", toBattery) }
        if snapshot.isPluggedIn {
            // The adapter is not keeping up and the battery is making up the rest, so say
            // so; otherwise the system figure would exceed the plug's with no source.
            if snapshot.watts < -0.5 {
                return String(format: "On AC · battery adding %.0f W", -snapshot.watts)
            }
            return String(format: "Running on AC at %.0f W", toSystem)
        }
        return String(format: "On battery · %.0f W", toSystem)
    }

    private var loadDescription: String {
        switch snapshot.macLoad {
        case ..<6: return "Idle: little more than the display"
        case ..<14: return "Light use: typical for web and docs"
        case ..<28: return "Normal workload: comfortably within range"
        case ..<45: return "Heavy load: something is working hard"
        default: return "Very heavy load"
        }
    }
}
