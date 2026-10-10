// Graph axes, layout, and drawing for the temperature and fan graphs.
import SwiftUI

/// A graph's value axis: from a round `bottom` up to a round `top`, in equal round steps.
struct GraphScale: Equatable {
    /// Lowest value on the axis, and its first tick.
    let bottom: Double
    /// Highest value on the axis, and its last tick.
    let top: Double
    let step: Double
    /// From zero up to at least `peak`. `minimum` keeps idle noise near the bottom instead of filling the graph.
    init(peak: Double, minimum: Double, intervals: Int = 3) {
        self.init(low: 0, high: peak, span: minimum, intervals: intervals)
    }
    /// The smallest step of 1, 2, 2.5, or 5 × 10ⁿ that fits `low` to `high` in at most `intervals` steps, with every tick
    /// on a multiple of the step. `span` is the least range shown above `low`.
    init(low: Double, high: Double, span: Double, intervals: Int = 3) {
        // Kept far inside Double's range, so round steps above them, and the range itself, never overflow to infinity.
        let limit = Double.greatestFiniteMagnitude / 1e6
        let low = min(max(low.isFinite ? low : 0, -limit), limit)
        let high = min(max(high.isFinite ? high : low, low + max(span.isFinite ? span : 0, 0)), limit)
        let intervals = Double(max(intervals, 1))
        var magnitude = pow(10, floor(log10(max(high - low, .leastNormalMagnitude) / intervals)))
        // Bounded, so the search always ends: no round step fits a range around zero in one interval.
        while magnitude > 0 && magnitude.isFinite {
            for multiple in [1, 2, 2.5, 5] {
                let step = multiple * magnitude
                // The tolerance stops float error from skipping a step that fits exactly.
                let bottom = floor(low / step + 1e-9) * step
                let top = max(ceil(high / step - 1e-9) * step, bottom + step)
                // A step too small to change `bottom` would leave an axis with no height.
                if top > bottom, (top - bottom) / step <= intervals + 1e-9 {
                    self.bottom = bottom; self.top = top; self.step = step
                    return
                }
            }
            magnitude *= 10
        }
        // No round step fits: show the range as it is, in one step.
        bottom = low; step = high > low ? high - low : 1; top = bottom + step
    }
    var ticks: [Double] { (0...Int(((top - bottom) / step).rounded())).map { bottom + Double($0) * step } }
}

/// A label on a graph's time axis, `age` seconds before now.
struct TimeTick: Equatable {
    let age: TimeInterval
    let label: String
    /// Ticks on a round step for a graph that ends now and starts `span` seconds ago, at most six of them.
    static func ticks(span: TimeInterval) -> [TimeTick] {
        let span = max(span.isFinite ? span : 0, 1)
        let steps: [TimeInterval] = [5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 14400]
        let step = steps.first { span / $0 <= 5 + 1e-9 } ?? (span / 5).rounded(.up)
        return stride(from: 0, through: span + 1e-9, by: step).map { age in
            let whole = Int(age.rounded())
            return TimeTick(age: age, label: whole == 0 ? "Now" : step < 60 ? "\(whole) s" : "\(whole / 60) min")
        }
    }
    /// How long ago a hovered sample was: "Now", "25 s ago", "3 min 5 s ago".
    static func ago(_ seconds: TimeInterval) -> String {
        let whole = Int(max(0, seconds.isFinite ? seconds : 0).rounded())
        if whole < 3 { return "Now" }
        if whole < 60 { return "\(whole) s ago" }
        return "\(whole / 60) min" + (whole % 60 == 0 ? "" : " \(whole % 60) s") + " ago"
    }
}

/// Maps values and ages to points in a graph's plot area. The newest value sits at the right edge.
struct GraphGeometry {
    let plot: CGRect
    let scale: GraphScale
    /// Seconds the plot spans, from its left edge to now.
    let span: TimeInterval
    func x(age: TimeInterval) -> CGFloat { plot.maxX - CGFloat(age / span) * plot.width }
    func y(_ value: Double) -> CGFloat {
        plot.maxY - CGFloat(min(max((value - scale.bottom) / (scale.top - scale.bottom), 0), 1)) * plot.height
    }
    /// Index of the sample nearest `x`, for samples `interval` seconds apart with the last one now.
    func index(at x: CGFloat, count: Int, interval: TimeInterval) -> Int? {
        guard count > 0 else { return nil }
        let age = Double((plot.maxX - x) / plot.width) * span
        return min(max(count - 1 - Int((age / interval).rounded()), 0), count - 1)
    }
    func age(_ index: Int, count: Int, interval: TimeInterval) -> TimeInterval { Double(count - 1 - index) * interval }
    /// Points for samples `interval` seconds apart with the last one now; nil where a sample has no value.
    func points(_ values: [Double?], interval: TimeInterval) -> [CGPoint?] {
        values.enumerated().map { index, value in
            value.map { CGPoint(x: x(age: age(index, count: values.count, interval: interval)), y: y($0)) }
        }
    }
}

/// Grid lines with value labels on the right and, optionally, time labels below, around a plot drawn by `content`.
struct GraphFrame<Content: View>: View {
    let scale: GraphScale
    let span: TimeInterval
    /// Room for the value labels. Graphs shown together use the same gutter so their plot areas line up.
    let gutter: CGFloat
    /// Off for a graph stacked over another with the same span, which shows the times for both.
    var timeAxis = true
    let label: (Double) -> String
    @ViewBuilder let content: (GraphGeometry) -> Content
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            // Room above for the top label, and below for the bottom label or the time labels.
            let below: CGFloat = timeAxis ? 22 : 8
            let layout = GraphGeometry(plot: CGRect(x: 0, y: 6, width: max(size.width - gutter, 1), height: max(size.height - 6 - below, 1)),
                                       scale: scale, span: span)
            let plot = layout.plot
            let times = timeAxis ? TimeTick.ticks(span: span) : []
            ZStack(alignment: .topLeading) {
                Path { path in
                    for tick in scale.ticks.dropFirst() {
                        path.move(to: CGPoint(x: plot.minX, y: layout.y(tick))); path.addLine(to: CGPoint(x: plot.maxX, y: layout.y(tick)))
                    }
                    for tick in times.dropFirst() where tick.age < span {
                        let x = layout.x(age: tick.age)
                        path.move(to: CGPoint(x: x, y: plot.minY)); path.addLine(to: CGPoint(x: x, y: plot.maxY))
                    }
                }
                .stroke(Color.secondary.opacity(0.18), style: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
                Path { $0.move(to: CGPoint(x: plot.minX, y: plot.maxY)); $0.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY)) }
                    .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
                content(layout)
                ForEach(scale.ticks, id: \.self) { tick in
                    axisText(label(tick)).frame(width: gutter - 6, alignment: .leading)
                        .position(x: plot.maxX + gutter / 2 + 3, y: layout.y(tick))
                }
                ForEach(times, id: \.age) { tick in
                    // The oldest label lines up with the plot's left edge instead of hanging past it.
                    let x = layout.x(age: tick.age)
                    axisText(tick.label).frame(width: 48, alignment: x - 24 < plot.minX ? .leading : .center)
                        .position(x: max(x, plot.minX + 24), y: plot.maxY + 9)
                }
            }
        }
    }
    private func axisText(_ text: String) -> some View {
        Text(text).font(.system(size: 9.5)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
    }
}

extension StrokeStyle {
    /// Every graph line.
    static let graphLine = StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round)
}

/// A line through `points` that breaks at each nil. A point with gaps on both sides is drawn as a dot.
func graphLine(_ points: [CGPoint?]) -> Path {
    Path { path in
        var drawing = false
        for (index, point) in points.enumerated() {
            guard let point else { drawing = false; continue }
            if drawing { path.addLine(to: point) } else { path.move(to: point) }
            let next = points.indices.contains(index + 1) ? points[index + 1] : nil
            if !drawing && next == nil { path.addEllipse(in: CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2)) }
            drawing = true
        }
    }
}
/// Vertical hover line across the plot, at the sample under the pointer.
func hoverLine(_ x: CGFloat, in plot: CGRect) -> some View {
    Path { $0.move(to: CGPoint(x: x, y: plot.minY)); $0.addLine(to: CGPoint(x: x, y: plot.maxY)) }
        .stroke(Color.secondary.opacity(0.6), lineWidth: 1)
}
func hoverMarker(_ center: CGPoint, _ color: Color) -> some View {
    Circle().fill(color)
        .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
        .frame(width: 8, height: 8).position(center)
}

/// A short line in a series' color, naming it next to its reading.
struct GraphSwatch: View {
    let color: Color
    var body: some View { RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 10, height: 3).accessibilityHidden(true) }
}

extension View {
    /// Tracks the sample under the pointer, for samples `interval` seconds apart with the last one now.
    func graphHover(_ layout: GraphGeometry, count: Int, interval: TimeInterval, hovered: Binding<Int?>) -> some View {
        contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): hovered.wrappedValue = layout.index(at: location.x, count: count, interval: interval)
                case .ended: hovered.wrappedValue = nil
                }
            }
    }
}
