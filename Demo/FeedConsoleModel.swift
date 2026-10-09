import Foundation
import Observation
import FeedReadiness

/// Drives a `FeedEngine` wired to simulated ports and publishes snapshots
/// for the console. No real video is decoded: `SimulatedPlayer` stands in
/// for AVPlayer (120 ms to "prepare" a decoder) and checks the port
/// contract; `SimulatedTransport` stands in for the network (6 MB/s).
@MainActor
@Observable
final class FeedConsoleModel {
    enum Viewer: String { case watcher, skipper }

    private(set) var snapshot: FeedEngine.Snapshot?
    private(set) var hardware = SimulatedPlayer.Report()
    private(set) var violations: [String] = []
    /// True while an action runs. Actions started meanwhile are ignored, so
    /// a double tap cannot interleave two actions.
    private(set) var busy = false
    private(set) var conditions: DeviceConditions
    private(set) var viewer: Viewer = .watcher
    let scenario: DemoScenario

    private let engine: FeedEngine
    private let player: SimulatedPlayer
    private var booted = false

    /// Rows shown around the cursor: one behind, six ahead (the prefetch
    /// window reaches five ahead, so its far edge is visible).
    static let rowsBehind = 1
    static let rowsAhead = 6

    init(items: [FeedItem], configuration: FeedEngine.Configuration, scenario: DemoScenario) {
        let player = SimulatedPlayer(prepareLatency: .milliseconds(120))
        let conditions = DeviceConditions(network: .wifi, throughputKbps: 12_000)
        self.player = player
        self.scenario = scenario
        self.conditions = conditions
        self.engine = FeedEngine(items: items, conditions: conditions, configuration: configuration,
                                 player: player,
                                 transport: SimulatedTransport(bytesPerSecond: 6_000_000))
    }

    /// Starts the engine and plays the launch scenario.
    func boot() async {
        guard !booted, !busy else { return }
        booted = true
        busy = true
        defer { busy = false }
        await engine.start()
        await settle()
        switch scenario {
        case .steady:
            await doSwipe(by: 1)
            await doSwipe(by: 1)
        case .fling:
            await doFling(count: 10)
        case .hot:
            await doSwipe(by: 1)
            await doSetConditions { $0.thermal = .critical }
        case .offline:
            await doSwipe(by: 1)
            await doSetConditions { $0.network = .offline }
            await doSwipe(by: 1)
        case .skipper:
            await doTrain(.skipper)
        case .cellularLowPower:
            await doSetConditions {
                $0.network = .cellular
                $0.throughputKbps = 3_000
                $0.lowPowerMode = true
            }
            await doSwipe(by: 1)
        }
    }

    // MARK: Actions (ignored while another action runs)

    func swipe(by delta: Int) async {
        guard begin() else { return }
        defer { busy = false }
        await doSwipe(by: delta)
    }

    func fling(count: Int) async {
        guard begin() else { return }
        defer { busy = false }
        await doFling(count: count)
    }

    func train(_ kind: Viewer) async {
        guard begin() else { return }
        defer { busy = false }
        await doTrain(kind)
    }

    func setConditions(_ change: (inout DeviceConditions) -> Void) async {
        guard begin() else { return }
        defer { busy = false }
        await doSetConditions(change)
    }

    private func begin() -> Bool {
        guard booted, !busy else { return false }
        busy = true
        return true
    }

    // MARK: Implementations

    private func doSwipe(by delta: Int) async {
        // `move(by:)` is relative to the engine's own cursor, never to a
        // snapshot that may be one swipe old.
        await engine.move(by: delta, leaving: observation(for: viewer))
        await settle()
    }

    /// `count` swipes with no pause between them: every prepare is still in
    /// flight when the user leaves its clip.
    private func doFling(count: Int) async {
        // A fling is what a skipper does; the viewer chip follows.
        viewer = .skipper
        for _ in 0 ..< max(1, count) {
            await engine.move(by: 1, leaving: observation(for: .skipper))
            await refresh()
        }
        await settle()
    }

    /// Ten unhurried swipes as one kind of viewer (each settles before the
    /// next), so the skip model learns it without a fling in the way.
    private func doTrain(_ kind: Viewer) async {
        viewer = kind
        for _ in 0 ..< 10 {
            await engine.move(by: 1, leaving: observation(for: kind))
            await settle()
        }
    }

    private func doSetConditions(_ change: (inout DeviceConditions) -> Void) async {
        var next = conditions
        change(&next)
        conditions = next
        await engine.update(conditions: next)
        await settle()
    }

    private func observation(for kind: Viewer) -> SkipPredictor.Observation {
        switch kind {
        case .watcher: SkipPredictor.Observation(watchFraction: 0.92, swipeVelocity: 350)
        case .skipper: SkipPredictor.Observation(watchFraction: 0.04, swipeVelocity: 2_600)
        }
    }

    // MARK: Snapshots

    /// Refreshes until every in-flight port call has landed (bounded, so a
    /// stuck port cannot spin the UI forever).
    private func settle() async {
        for _ in 0 ..< 60 {
            await refresh()
            if (snapshot?.pending ?? 0) == 0 { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        await refresh()
    }

    private func refresh() async {
        snapshot = await engine.snapshot(behind: Self.rowsBehind, ahead: Self.rowsAhead)
        hardware = await player.currentReport()
        violations = await engine.invariantViolations()
    }
}
