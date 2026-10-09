import SwiftUI
import FeedReadiness

/// One screen: the readiness window around the cursor, the budgets it is
/// spending, and the port-contract checks, with controls in a bottom bar.
struct ConsoleView: View {
    let model: FeedConsoleModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ConditionsRow(conditions: model.conditions, viewer: model.viewer)
                    if let snapshot = model.snapshot {
                        MetricsGrid(snapshot: snapshot, hardware: model.hardware)
                        WindowCard(snapshot: snapshot)
                        ContractCard(snapshot: snapshot, hardware: model.hardware, violations: model.violations)
                        StatsCard(stats: snapshot.stats)
                    } else {
                        ProgressView("Planning…").frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
            .navigationTitle("Feed Readiness")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) {
                Text(model.scenario.title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(.bar)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ControlBar(model: model)
            }
        }
    }
}

// MARK: - Sections

private struct ConditionsRow: View {
    let conditions: DeviceConditions
    let viewer: FeedConsoleModel.Viewer

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Chip(text: network, symbol: "antenna.radiowaves.left.and.right",
                     tint: conditions.network == .wifi ? .green : (conditions.network == .offline ? .red : .orange))
                Chip(text: "\(conditions.throughputKbps / 1_000) Mbps", symbol: "speedometer", tint: .blue)
                Chip(text: thermal, symbol: "thermometer.medium",
                     tint: conditions.thermal >= .serious ? .red : .green)
                if conditions.lowPowerMode { Chip(text: "Low Power", symbol: "battery.25", tint: .yellow) }
                if conditions.memory != .normal { Chip(text: "Memory \(memory)", symbol: "memorychip", tint: .red) }
                Chip(text: viewer == .skipper ? "Skipper" : "Watcher", symbol: "person", tint: .purple)
            }
        }
    }

    private var network: String {
        switch conditions.network {
        case .wifi: "Wi-Fi"
        case .cellular: "Cellular"
        case .constrained: "Constrained"
        case .offline: "Offline"
        }
    }

    private var thermal: String {
        switch conditions.thermal {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        }
    }

    private var memory: String { conditions.memory == .warning ? "warning" : "critical" }
}

private struct MetricsGrid: View {
    let snapshot: FeedEngine.Snapshot
    let hardware: SimulatedPlayer.Report

    var body: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                Metric(title: "Decoders", value: "\(snapshot.decodersInUse) / \(snapshot.decoderCapacity)",
                       detail: "hardware peak \(hardware.maxLiveDecoders)")
                Metric(title: "Disk cache", value: megabytes(snapshot.cacheBytes),
                       detail: "of \(megabytes(snapshot.cacheBudgetBytes)) · \(megabytes(snapshot.cacheReservedBytes)) reserved")
            }
            GridRow {
                Metric(title: "Quality cap", value: mbps(snapshot.qualityCapKbps),
                       detail: "ladder level \(snapshot.qualityLevel)")
                Metric(title: "P(skip next)", value: String(format: "%.2f", snapshot.skipProbability),
                       detail: snapshot.skipProbability >= snapshot.skipThreshold
                           ? "≥ \(String(format: "%.2f", snapshot.skipThreshold)): first segment only"
                           : "below \(String(format: "%.2f", snapshot.skipThreshold)): full prefetch")
            }
        }
    }
}

private struct WindowCard: View {
    let snapshot: FeedEngine.Snapshot

    private var title: String {
        let shape = snapshot.shape
        return "Window · prepared +\(shape.preparedAhead)/−\(shape.preparedBehind) · "
            + "prefetch +\(shape.prefetchAhead) × \(seconds(snapshot.prefetchSecondsInUse))"
    }

    var body: some View {
        Card(title: title) {
            VStack(spacing: 4) {
                ForEach(snapshot.rows) { row in
                    HStack(spacing: 8) {
                        Text("\(row.index)")
                            .font(.caption.monospacedDigit())
                            .frame(width: 24, alignment: .trailing)
                            .foregroundStyle(.secondary)
                        TierBadge(tier: row.tier)
                        Text(row.item.raw).font(.caption.monospaced()).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(row.decoder == .idle ? "" : row.decoder.rawValue)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(row.decoder == .playing ? .green : .secondary)
                        // During a quality switch the decoder still holds the old
                        // rendition: show both ("1080p→540p").
                        Text(row.rendition == row.plannedRendition ? row.rendition
                                                                    : "\(row.rendition)→\(row.plannedRendition)")
                            .font(.caption2.monospaced())
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(width: 64, alignment: .trailing)
                        Text(row.cachedSeconds > 0 ? seconds(row.cachedSeconds) : "–")
                            .font(.caption2.monospacedDigit())
                            .frame(width: 40, alignment: .trailing)
                    }
                    .padding(.vertical, 3)
                    .padding(.horizontal, 6)
                    .background(row.index == snapshot.cursor ? Color.accentColor.opacity(0.12) : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
                }
                if snapshot.rows.isEmpty {
                    Text("Empty feed").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct ContractCard: View {
    let snapshot: FeedEngine.Snapshot
    let hardware: SimulatedPlayer.Report
    let violations: [String]

    var body: some View {
        Card(title: "Port contract & invariants") {
            VStack(alignment: .leading, spacing: 4) {
                Check(label: "Releases while still preparing", value: hardware.releasesDuringPrepare)
                Check(label: "Leaked decoders", value: hardware.leakedDecoders)
                Check(label: "Hardware peak above budget",
                      value: max(0, hardware.maxLiveDecoders - snapshot.decoderCapacity))
                Check(label: "Two clips playing at once", value: max(0, hardware.maxSimultaneouslyPlaying - 1))
                Check(label: "Commands to released players", value: hardware.commandsForDeadLeases)
                Check(label: "Engine invariant violations", value: violations.count)
                HStack {
                    Text("Deferred releases (fling absorbed)").font(.caption)
                    Spacer()
                    Text("\(snapshot.stats.deferredReleases)").font(.caption.monospacedDigit().weight(.semibold))
                }
            }
        }
    }
}

private struct StatsCard: View {
    let stats: FeedEngine.Stats

    var body: some View {
        Card(title: "Counters") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                row("Prepares started / failed", "\(stats.preparesStarted) / \(stats.preparesFailed)")
                row("Pool full (decoder busy)", "\(stats.decoderBusy)")
                row("Prefetch started / cancelled", "\(stats.prefetchesStarted) / \(stats.prefetchesCancelled)")
                row("Stale fetch completions ignored", "\(stats.staleFetchCompletions)")
                row("Bytes fetched / cancelled", "\(megabytes(stats.bytesFetched)) / \(megabytes(stats.bytesCancelled))")
                row("Evictions / cache refusals", "\(stats.evictions) / \(stats.cacheRefusals)")
                row("Quality up / down", "\(stats.qualityUps) / \(stats.qualityDowns)")
                row("Make-before-break hand-offs", "\(stats.handOffs)")
                row("Pre-emptions / break-before-make", "\(stats.preemptions) / \(stats.breakBeforeMakeFallbacks)")
            }
            .font(.caption)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }
}

private struct ControlBar: View {
    let model: FeedConsoleModel

    var body: some View {
        HStack(spacing: 10) {
            Button { Task { await model.swipe(by: -1) } } label: { Image(systemName: "chevron.up") }
                .accessibilityLabel("Previous item")
            Button { Task { await model.swipe(by: 1) } } label: { Image(systemName: "chevron.down") }
                .accessibilityLabel("Next item")
            Button("Fling ×10") { Task { await model.fling(count: 10) } }
            Menu("Conditions") {
                Button("Wi-Fi, 12 Mbps") { Task { await model.setConditions { $0.network = .wifi; $0.throughputKbps = 12_000 } } }
                Button("Cellular, 3 Mbps") { Task { await model.setConditions { $0.network = .cellular; $0.throughputKbps = 3_000 } } }
                Button("Constrained, 1 Mbps") { Task { await model.setConditions { $0.network = .constrained; $0.throughputKbps = 1_000 } } }
                Button("Offline") { Task { await model.setConditions { $0.network = .offline } } }
                Divider()
                Button("Toggle Low Power Mode") { Task { await model.setConditions { $0.lowPowerMode.toggle() } } }
                Button("Thermal: nominal") { Task { await model.setConditions { $0.thermal = .nominal } } }
                Button("Thermal: serious") { Task { await model.setConditions { $0.thermal = .serious } } }
                Button("Thermal: critical") { Task { await model.setConditions { $0.thermal = .critical } } }
                Button("Memory: normal") { Task { await model.setConditions { $0.memory = .normal } } }
                Button("Memory: warning") { Task { await model.setConditions { $0.memory = .warning } } }
            }
            Menu("Train") {
                Button("10 swipes as a skipper") { Task { await model.train(.skipper) } }
                Button("10 swipes as a watcher") { Task { await model.train(.watcher) } }
            }
        }
        .buttonStyle(.bordered)
        .disabled(model.busy)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }
}

// MARK: - Building blocks

private struct Card<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct Metric: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6)
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct Chip: View {
    let text: String
    let symbol: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.15), in: Capsule())
    }
}

private struct TierBadge: View {
    let tier: ReadinessTier

    var body: some View {
        Text(label)
            .font(.caption2.weight(.bold))
            .frame(width: 64)
            .padding(.vertical, 2)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
    }

    private var label: String {
        switch tier {
        case .playing: "PLAYING"
        case .prepared: "PREPARED"
        case .prefetched: "PREFETCH"
        case .cold: "cold"
        }
    }

    private var color: Color {
        switch tier {
        case .playing: .green
        case .prepared: .blue
        case .prefetched: .orange
        case .cold: .gray
        }
    }
}

private struct Check: View {
    let label: String
    let value: Int

    var body: some View {
        HStack {
            Image(systemName: value == 0 ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(value == 0 ? .green : .red)
            Text(label).font(.caption)
            Spacer()
            Text("\(value)").font(.caption.monospacedDigit().weight(.semibold))
        }
    }
}

private func megabytes(_ bytes: Int64) -> String {
    String(format: "%.1f MB", Double(bytes) / 1_048_576)
}

private func mbps(_ kbps: Int) -> String {
    String(format: "%.1f Mbps", Double(kbps) / 1_000)
}

private func seconds(_ value: Double) -> String {
    String(format: "%.1f s", value)
}
