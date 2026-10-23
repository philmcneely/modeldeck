import SwiftUI
import ModelDeckMacCore

// Issue #771 — the "This week" graph, drawn from `WeeklyUsageGraph` (Core),
// which decides everything it claims. Matches the phone prototype Tim liked,
// in the deck's own type scale and colors.

/// The card's way into its graph: one of its own numbers, the one the card's
/// offer names (`DeckPopoverModel.weeklyGraphOffer`). A click anywhere else on
/// the card still expands it, and the trigger adds no width (an icon beside
/// the number cut long card titles short, PR #773 review). On hover it shows
/// a pointing hand and a faint halo drawn outside the layout. Either way it
/// opens on the first click into an inactive window, as the card does.
struct WeeklyGraphTrigger: ViewModifier {
    /// The card's offer; nil when the card has no graph.
    let offer: WeeklyUsageGraph.Offer?
    /// Which number this modifier sits on. Anywhere but the offer's trigger,
    /// the number stays exactly as it was.
    let slot: WeeklyUsageGraph.Offer.Trigger
    let open: () -> Void
    @State private var isHovered = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if offer?.trigger == slot {
            switch slot {
            case .headline:
                // Inside the card's expand Button: a tap gesture on the
                // deepest view, the card markers' rule (nested Buttons are
                // unsupported). The card's Button takes the first click into
                // an inactive window, so this number opens on it too.
                decorated(content.contentShape(Rectangle()).onTapGesture(perform: open))
            case .row:
                // Outside any Button, a tap gesture spends the first click into
                // an inactive window (a floating deck behind another app) on
                // bringing the deck forward. A plain Button takes that click,
                // as the card's own Button does.
                decorated(
                    Button(action: open) { content.contentShape(Rectangle()) }
                        .buttonStyle(.plain)
                )
            }
        } else {
            content
        }
    }

    /// What both kinds of trigger share: the hover halo and pointing hand,
    /// the help text, the VoiceOver action, and the report the placement
    /// tests read.
    private func decorated(_ trigger: some View) -> some View {
        trigger
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? 0.1 : 0))
                    .padding(.horizontal, -4)
                    .padding(.vertical, -2)
            )
            .onHover { inside in
                guard inside != isHovered else { return }
                isHovered = inside
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            // Keeps the cursor stack balanced if the number goes away under
            // the pointer.
            .onDisappear {
                if isHovered {
                    isHovered = false
                    NSCursor.pop()
                }
            }
            .help("Show this week's usage graph")
            .accessibilityAction(named: "Show this week's usage graph") { open() }
            .preference(key: WeeklyGraphTriggerSlots.self, value: [slot])
    }
}

/// Which of a card's numbers open its graph right now. Nothing in the app
/// reads it; the tests that pin the trigger's place do.
struct WeeklyGraphTriggerSlots: PreferenceKey {
    static let defaultValue: [WeeklyUsageGraph.Offer.Trigger] = []

    static func reduce(
        value: inout [WeeklyUsageGraph.Offer.Trigger],
        nextValue: () -> [WeeklyUsageGraph.Offer.Trigger]
    ) {
        value += nextValue()
    }
}

/// The popover beside a card. It asks for the window's history when it opens
/// (the model keeps a read a few minutes) and never polls.
struct WeeklyGraphPopoverView: View {
    let accountID: String
    let accountLabel: String
    let window: DeckWindow
    @ObservedObject var model: WeeklyUsageGraphModel

    var body: some View {
        let now = Date()
        let request = WeeklyUsageGraph.request(accountID: accountID, window: window, now: now)
        VStack(alignment: .leading, spacing: 8) {
            Text(accountLabel)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            WeeklyUsageChartView(
                windowTitle: window.title,
                content: WeeklyUsageGraph.content(
                    window: window,
                    load: request.flatMap { model.load(for: $0) },
                    now: now
                )
            )
        }
        .padding(12)
        .frame(width: 290, alignment: .leading)
        // Keyed so a reset that only drifts between polls is the same week:
        // no restart, no spinner, no second read.
        .task(id: request.map { model.key(for: $0) }) {
            if let request { await model.open(request) }
        }
    }
}

/// The "This week" block: title row, chart, start and reset times, and the
/// pace sentence. Free of the popover so it can move into the card later.
struct WeeklyUsageChartView: View {
    let windowTitle: String
    let content: WeeklyUsageGraph.Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("This week")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 8)
                Text(windowTitle)
                    .font(DeckType.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            switch content {
            case .loading:
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: WeeklyUsagePlot.height)
                    .padding(.top, 7)
            case .message(let text):
                Text(text)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            case .chart(let chart):
                WeeklyUsagePlot(chart: chart)
                    .padding(.top, 7)
                HStack(spacing: 8) {
                    Text(chart.startText)
                    Spacer(minLength: 8)
                    Text(chart.resetText)
                }
                .font(DeckType.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.top, 5)
                HStack(spacing: 6) {
                    EvenPaceKey()
                    Text(chart.pace.sentence)
                        .font(.system(size: 11))
                }
                .padding(.top, 6)
            }
        }
    }
}

/// The chart itself: % left as a filled line for each run of readings (a gap
/// stays a gap), the dashed even-pace diagonal, and a dot at the latest
/// reading. Every position comes from `Chart.location`, the mapping the
/// tests hold the pace sentence against.
struct WeeklyUsagePlot: View {
    static let height: CGFloat = 70
    let chart: WeeklyUsageGraph.Chart

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: size.height / 2))
                    path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                }
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                ForEach(Array(chart.segments.enumerated()), id: \.offset) { _, segment in
                    let points = segment.map { chart.location(of: $0, in: size) }
                    Self.area(points, floor: size.height)
                        .fill(LinearGradient(
                            colors: [Color.blue.opacity(0.35), Color.blue.opacity(0)],
                            startPoint: .top,
                            endPoint: .bottom
                        ))
                    Self.line(points)
                        .stroke(Color.blue, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                Path { path in
                    path.move(to: chart.location(of: .init(date: chart.period.start, remainingPercent: 100), in: size))
                    path.addLine(to: chart.location(of: .init(date: chart.period.end, remainingPercent: 0), in: size))
                }
                .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1.25, dash: [3, 4]))
                Circle()
                    .fill(Color.blue)
                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                    .frame(width: 8, height: 8)
                    .position(chart.location(of: chart.latest, in: size))
            }
        }
        .frame(height: Self.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(chart.accessibilityLabel)
    }

    /// A lone reading between two gaps strokes as a round dot.
    private static func line(_ points: [CGPoint]) -> Path {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
            if points.count == 1 { path.addLine(to: first) }
        }
    }

    private static func area(_ points: [CGPoint], floor: CGFloat) -> Path {
        Path { path in
            guard points.count > 1, let first = points.first, let last = points.last else { return }
            path.move(to: CGPoint(x: first.x, y: floor))
            for point in points { path.addLine(to: point) }
            path.addLine(to: CGPoint(x: last.x, y: floor))
            path.closeSubpath()
        }
    }
}

/// The sentence's key: a short dash like the even-pace line.
private struct EvenPaceKey: View {
    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: 1))
            path.addLine(to: CGPoint(x: 14, y: 1))
        }
        .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
        .frame(width: 14, height: 2)
        .accessibilityHidden(true)
    }
}
