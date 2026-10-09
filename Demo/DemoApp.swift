import SwiftUI
import FeedReadiness

@main
struct DemoApp: App {
    @State private var model = FeedConsoleModel(
        items: DemoCatalog.items(count: 80),
        configuration: DemoCatalog.engineConfiguration,
        scenario: DemoScenario(arguments: ProcessInfo.processInfo.arguments)
    )

    var body: some Scene {
        WindowGroup {
            ConsoleView(model: model)
                .task { await model.boot() }
        }
    }
}

/// The compiled-in feed and budgets. In a shipping app the items come from
/// the feed API and the budgets from remote config; here they are fixed so
/// every launch (and every CI screenshot) is reproducible.
enum DemoCatalog {
    /// A four-rung ladder, the shape of a typical short-video HLS manifest.
    static let ladder: [Rendition] = [
        Rendition(id: "360", height: 360, bitrateKbps: 600),
        Rendition(id: "540", height: 540, bitrateKbps: 1_200),
        Rendition(id: "720", height: 720, bitrateKbps: 2_500),
        Rendition(id: "1080", height: 1_080, bitrateKbps: 5_000),
    ]

    static let engineConfiguration = FeedEngine.Configuration(
        decoderCapacity: 4,
        cacheBudgetBytes: 48 * 1_024 * 1_024,
        startLevel: 3
    )

    static func items(count: Int) -> [FeedItem] {
        let durations: [Double] = [15, 22, 9, 31, 45, 18, 12, 27]
        return (0 ..< max(0, count)).map { index in
            // Every 17th item ships with a broken manifest (no renditions),
            // to show the engine skipping it instead of crashing.
            let renditions = index % 17 == 16 ? [] : ladder
            return FeedItem(id: ItemID("clip-\(index)"), renditions: renditions,
                            durationSeconds: durations[index % durations.count])
        }
    }
}

/// What the app does on launch, chosen with `-scenario <name>`. Used by the
/// CI screenshot script so each screenshot shows one behaviour.
enum DemoScenario: String, CaseIterable {
    case steady, fling, hot, offline, skipper, cellularLowPower = "cellular-low-power"

    init(arguments: [String]) {
        guard let flag = arguments.firstIndex(of: "-scenario"),
              arguments.indices.contains(flag + 1),
              let scenario = DemoScenario(rawValue: arguments[flag + 1]) else {
            self = .steady
            return
        }
        self = scenario
    }

    var title: String {
        switch self {
        case .steady: "Steady scroll on Wi-Fi"
        case .fling: "Fling: 10 swipes during prepare"
        case .hot: "Thermal critical"
        case .offline: "Offline after warming the cache"
        case .skipper: "Learned skipper: shallow prefetch"
        case .cellularLowPower: "Cellular + Low Power Mode"
        }
    }
}
