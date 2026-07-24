import SwiftUI

// MARK: - Time Filter

enum TimeFilter: String, CaseIterable, Sendable {
    case lastHour
    case today
    case all

    var label: String {
        switch self {
        case .lastHour: return "Last Hour"
        case .today: return "Today"
        case .all: return "All"
        }
    }
}

// MARK: - Diagnostic Dashboard

struct DiagnosticDashboardView: View {
    let observations: [RefreshObservation]
    @State private var selectedRunID: String? = nil
    @State private var timeFilter: TimeFilter = .all
    @State private var isCompareMode = false
    @State private var compareRunID1: String? = nil
    @State private var compareRunID2: String? = nil

    private var filteredObservations: [RefreshObservation] {
        let now = Date()
        return observations.filter { obs in
            guard let date = ISO8601DateFormatter().date(from: obs.startedAt) else {
                return timeFilter == .all
            }
            switch timeFilter {
            case .lastHour: return now.timeIntervalSince(date) <= 3600
            case .today: return Calendar.current.isDateInToday(date)
            case .all: return true
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if filteredObservations.isEmpty {
                Text("No diagnostic data yet. Perform a refresh to collect measurements.")
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                Text("\(filteredObservations.count) refresh run(s) recorded")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                List(filteredObservations, id: \.runID) { obs in
                    Button(action: { selectRun(obs) }) {
                        DiagnosticRunRow(
                            observation: obs,
                            isSelected: isCompareMode && (obs.runID == compareRunID1 || obs.runID == compareRunID2)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding()
        .sheet(isPresented: detailSheetBinding) {
            if let id = selectedRunID, let obs = observations.first(where: { $0.runID == id }) {
                RunDetailView(observation: obs, previousObservation: previousObservation(for: obs))
            }
        }
        .sheet(isPresented: compareSheetBinding) {
            if let id1 = compareRunID1, let id2 = compareRunID2,
               let obs1 = observations.first(where: { $0.runID == id1 }),
               let obs2 = observations.first(where: { $0.runID == id2 }) {
                CompareRunsView(observation1: obs1, observation2: obs2)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Diagnostic Dashboard")
                .font(.title2.weight(.semibold))
            Spacer()

            Picker("Time Range", selection: $timeFilter) {
                ForEach(TimeFilter.allCases, id: \.self) { filter in
                    Text(filter.label).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 240)

            Toggle(isOn: $isCompareMode) {
                Label("Compare", systemImage: "rectangle.split.2x1")
            }
            .toggleStyle(.button)
            .help("Compare two runs side by side")
        }
    }

    // MARK: - Helpers

    private var detailSheetBinding: Binding<Bool> {
        Binding(
            get: { selectedRunID != nil },
            set: { if !$0 { selectedRunID = nil } }
        )
    }

    private var compareSheetBinding: Binding<Bool> {
        Binding(
            get: { compareRunID2 != nil },
            set: { if !$0 { compareRunID1 = nil; compareRunID2 = nil } }
        )
    }

    private func selectRun(_ obs: RefreshObservation) {
        if isCompareMode {
            if compareRunID1 == nil {
                compareRunID1 = obs.runID
            } else if compareRunID2 == nil, obs.runID != compareRunID1 {
                compareRunID2 = obs.runID
            } else {
                compareRunID1 = obs.runID
                compareRunID2 = nil
            }
        } else {
            selectedRunID = obs.runID
        }
    }

    private func previousObservation(for obs: RefreshObservation) -> RefreshObservation? {
        guard let index = observations.firstIndex(where: { $0.runID == obs.runID }),
              index + 1 < observations.count else { return nil }
        return observations[index + 1]
    }
}

// MARK: - Diagnostic Run Row

struct DiagnosticRunRow: View {
    let observation: RefreshObservation
    var isSelected: Bool = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Run \(String(observation.runID.prefix(8)))...")
                    .font(.callout.weight(.medium))
                Text(observation.startedAt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: "%.1fs", observation.overallElapsed))
                    .font(.callout.monospacedDigit())
                Text("\(observation.repositoryCount) repos")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if observation.wasCancelled {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.orange)
            }
            if observation.wasTimedOut {
                Image(systemName: "clock.badge.exclamationmark")
                    .foregroundStyle(.red)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 1)
        )
    }
}

// MARK: - Stage Waterfall View

struct StageWaterfallView: View {
    let observation: RefreshObservation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Stage Waterfall")
                .font(.headline)

            if observation.stageSpans.isEmpty {
                Text("No stage data available")
                    .foregroundStyle(.secondary)
            } else {
                let maxDuration = observation.stageSpans.values
                    .flatMap { $0 }
                    .map(\.duration)
                    .max() ?? 1

                ForEach(Array(observation.stageSpans.keys.sorted()), id: \.self) { stage in
                    if let spans = observation.stageSpans[stage] {
                        ForEach(spans.indices, id: \.self) { idx in
                            let span = spans[idx]
                            StageSpanRow(
                                stage: stage,
                                span: span,
                                maxDuration: maxDuration,
                                overallElapsed: observation.overallElapsed
                            )
                        }
                    }
                }
            }
        }
        .padding()
    }
}

struct StageSpanRow: View {
    let stage: String
    let span: ObservationSpan
    let maxDuration: Double
    let overallElapsed: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(stage)
                    .font(.caption.weight(.medium))
                    .frame(width: 100, alignment: .leading)

                GeometryReader { geo in
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.3))
                        .frame(width: max(4, geo.size.width * span.duration / maxDuration))
                        .cornerRadius(3)
                }
                .frame(height: 12)

                Text(String(format: "%.2fs", span.duration))
                    .font(.caption.monospacedDigit())
                    .frame(width: 50, alignment: .trailing)
            }

            HStack(spacing: 12) {
                Label("\(span.callCount) calls", systemImage: "arrow.triangle.branch")
                    .font(.caption2)
                if span.timeoutCount > 0 {
                    Label("\(span.timeoutCount) timeouts", systemImage: "clock")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                if span.cancellationCount > 0 {
                    Label("\(span.cancellationCount) cancelled", systemImage: "xmark")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
                if span.cacheHitCount > 0 {
                    Label("\(span.cacheHitCount) cached", systemImage: "bolt")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
                if span.mainThreadStallUs > 0 {
                    Label("\(span.mainThreadStallUs)us stall", systemImage: "exclamationmark")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}

// MARK: - Repository Timing View

struct RepositoryTimingView: View {
    let observation: RefreshObservation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Repository Timing")
                .font(.headline)

            if observation.repositoryTiming.isEmpty {
                Text("No per-repository timing data")
                    .foregroundStyle(.secondary)
            } else {
                let maxTime = observation.repositoryTiming.values.max() ?? 1
                let sorted = observation.repositoryTiming.sorted { $0.value > $1.value }

                ForEach(Array(sorted.prefix(20).enumerated()), id: \.offset) { _, entry in
                    HStack {
                        Text(entry.key)
                            .font(.caption)
                            .lineLimit(1)
                            .frame(width: 120, alignment: .leading)

                        GeometryReader { geo in
                            Rectangle()
                                .fill(Color.blue.opacity(0.3))
                                .frame(width: max(4, geo.size.width * entry.value / maxTime))
                                .cornerRadius(3)
                        }
                        .frame(height: 10)

                        Text(String(format: "%.2fs", entry.value))
                            .font(.caption.monospacedDigit())
                            .frame(width: 50, alignment: .trailing)
                    }
                }
            }
        }
        .padding()
    }
}

// MARK: - Delta Tag

struct DeltaTag: View {
    let current: Double
    let previous: Double?
    let format: String
    let suffix: String

    var body: some View {
        if let prev = previous {
            let delta = current - prev
            if delta != 0 {
                HStack(spacing: 2) {
                    Image(systemName: delta > 0 ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                        .font(.caption2)
                    Text(String(format: format, abs(delta)) + suffix)
                        .font(.caption.monospacedDigit())
                }
                .foregroundStyle(delta > 0 ? .red : .green)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill((delta > 0 ? Color.red : Color.green).opacity(0.1))
                )
            }
        }
    }
}

// MARK: - Run Detail View

struct RunDetailView: View {
    let observation: RefreshObservation
    var previousObservation: RefreshObservation? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent("Run ID", value: observation.runID)
                        LabeledContent("Started", value: observation.startedAt)
                        LabeledContent("Source", value: observation.source)

                        Divider()

                        labeledDeltaRow(
                            label: "Duration",
                            value: String(format: "%.2fs", observation.overallElapsed),
                            current: observation.overallElapsed,
                            previous: previousObservation?.overallElapsed,
                            format: "%.2f",
                            suffix: "s"
                        )

                        labeledDeltaRow(
                            label: "Git Calls",
                            value: "\(observation.totalGitCalls)",
                            current: Double(observation.totalGitCalls),
                            previous: previousObservation.map { Double($0.totalGitCalls) },
                            format: "%.0f",
                            suffix: ""
                        )

                        LabeledContent("Repositories", value: "\(observation.repositoryCount)")
                        LabeledContent("Current", value: "\(observation.currentRepositoryCount)")
                        LabeledContent("Reused Snapshots", value: "\(observation.reusedSnapshotCount)")

                        Divider()

                        LabeledContent("CPU", value: String(format: "%.1f s", observation.totalCPU))
                        LabeledContent("Peak Memory", value: "\(observation.peakMemoryMB) MB")
                        LabeledContent("Disk Writes", value: "\(observation.totalDiskWritesKB) KB")

                        if observation.wasCancelled {
                            Label("Cancelled", systemImage: "xmark.octagon")
                                .foregroundStyle(.orange)
                        }
                        if observation.wasTimedOut {
                            Label("Timed Out", systemImage: "clock.badge.exclamationmark")
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(4)
                }

                StageWaterfallView(observation: observation)
                RepositoryTimingView(observation: observation)
            }
            .padding()
        }
    }

    private func labeledDeltaRow(label: String, value: String, current: Double, previous: Double?, format: String, suffix: String) -> some View {
        HStack {
            Text(label + ":")
                .foregroundStyle(.secondary)
            Text(value)
                .frame(maxWidth: .infinity, alignment: .leading)
            DeltaTag(current: current, previous: previous, format: format, suffix: suffix)
        }
    }
}

// MARK: - Compare Runs View

struct CompareRunsView: View {
    let observation1: RefreshObservation
    let observation2: RefreshObservation

    var body: some View {
        HSplitView {
            CompareRunColumn(observation: observation1, label: "Run A",
                             other: observation2)
                .frame(minWidth: 280, idealWidth: 350)

            CompareRunColumn(observation: observation2, label: "Run B",
                             other: observation1)
                .frame(minWidth: 280, idealWidth: 350)
        }
        .frame(minWidth: 600, minHeight: 400)
    }
}

private struct CompareRunColumn: View {
    let observation: RefreshObservation
    let label: String
    let other: RefreshObservation

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(label)
                    .font(.headline)
                    .foregroundStyle(.secondary)

                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent("Run ID", value: observation.runID)
                        LabeledContent("Started", value: observation.startedAt)
                        LabeledContent("Source", value: observation.source)

                        Divider()

                        compareDeltaRow(
                            label: "Duration",
                            value: String(format: "%.2fs", observation.overallElapsed),
                            current: observation.overallElapsed,
                            other: other.overallElapsed
                        )

                        compareDeltaRow(
                            label: "Git Calls",
                            value: "\(observation.totalGitCalls)",
                            current: Double(observation.totalGitCalls),
                            other: Double(other.totalGitCalls)
                        )

                        compareDeltaRow(
                            label: "Repos",
                            value: "\(observation.repositoryCount)",
                            current: Double(observation.repositoryCount),
                            other: Double(other.repositoryCount)
                        )

                        compareDeltaRow(
                            label: "Reused",
                            value: "\(observation.reusedSnapshotCount)",
                            current: Double(observation.reusedSnapshotCount),
                            other: Double(other.reusedSnapshotCount)
                        )

                        compareDeltaRow(
                            label: "CPU",
                            value: String(format: "%.1fs", observation.totalCPU),
                            current: observation.totalCPU,
                            other: other.totalCPU
                        )

                        compareDeltaRow(
                            label: "Peak Mem",
                            value: "\(observation.peakMemoryMB) MB",
                            current: Double(observation.peakMemoryMB),
                            other: Double(other.peakMemoryMB)
                        )
                    }
                    .padding(4)
                }

                if !observation.stageSpans.isEmpty {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Stage Spans")
                                .font(.subheadline.weight(.medium))

                            let allStages = Set(observation.stageSpans.keys)
                                .union(other.stageSpans.keys)
                                .sorted()

                            ForEach(allStages, id: \.self) { stage in
                                let dur1 = observation.stageSpans[stage]?.reduce(0) { $0 + $1.duration } ?? 0
                                let dur2 = other.stageSpans[stage]?.reduce(0) { $0 + $1.duration } ?? 0
                                HStack {
                                    Text(stage)
                                        .font(.caption)
                                        .frame(width: 80, alignment: .leading)
                                    Text(String(format: "%.2fs", dur1))
                                        .font(.caption.monospacedDigit())
                                    DeltaTag(current: dur1, previous: dur2, format: "%.2f", suffix: "s")
                                }
                            }
                        }
                        .padding(4)
                    }
                }
            }
            .padding()
        }
    }

    private func compareDeltaRow(label: String, value: String, current: Double, other: Double) -> some View {
        HStack {
            Text(label + ":")
                .foregroundStyle(.secondary)
            Text(value)
                .frame(maxWidth: .infinity, alignment: .leading)
            DeltaTag(current: current, previous: other, format: "%.1f", suffix: "")
        }
    }
}
