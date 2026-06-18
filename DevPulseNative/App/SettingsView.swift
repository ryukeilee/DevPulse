import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var scheduler: ScanScheduler
    @State private var newCustomPath: String = ""
    @State private var builtInToggles: [ScanLocationToggle] = ScanLocationProvider.builtInToggles()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Section: Scan Status
                scanStatusSection

                Divider()

                // Section: Default scan locations
                defaultScanLocationsSection

                Divider()

                // Section: Custom scan directories
                customScanDirectoriesSection

                Divider()

                // Section: Actions
                actionsSection

                Divider()

                // Section: Widget Instructions
                widgetInstructionsSection

                Divider()

                // Section: Diagnostics
                diagnosticsSection
            }
            .padding(20)
        }
    }

    // MARK: - Scan Status

    private var scanStatusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Scan Status", systemImage: "info.circle")
                .font(.headline)

            Group {
                HStack {
                    Text("Repositories found:")
                    Spacer()
                    Text("\(scheduler.lastResult.scanSummary.totalRepositories)")
                        .fontWeight(.medium)
                }
                HStack {
                    Text("With changes:")
                    Spacer()
                    Text("\(scheduler.lastResult.scanSummary.changedRepositories)")
                        .fontWeight(.medium)
                }
                HStack {
                    Text("Last scan:")
                    Spacer()
                    if let lastScan = scheduler.lastScanAt {
                        Text(formattedDate(lastScan))
                            .fontWeight(.medium)
                    } else {
                        Text("Never")
                            .foregroundColor(.secondary)
                    }
                }
                if scheduler.lastResult.scanSummary.errorRepositories > 0 {
                    HStack {
                        Text("Scan errors:")
                        Spacer()
                        Text("\(scheduler.lastResult.scanSummary.errorRepositories)")
                            .fontWeight(.medium)
                            .foregroundColor(.red)
                    }
                }
                if !scheduler.gitAvailable {
                    HStack {
                        Image(systemName: "xmark.octagon.fill")
                            .foregroundColor(.red)
                        Text("Git not found. Install Xcode Command Line Tools.")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
                if !scheduler.appGroupAvailable {
                    HStack {
                        Image(systemName: "xmark.octagon.fill")
                            .foregroundColor(.red)
                        Text("App Group unavailable. Check entitlements.")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
            }
            .font(.caption)
            .padding(.leading, 20)
        }
    }

    // MARK: - Default scan locations

    private var defaultScanLocationsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Default Scan Locations", systemImage: "house")
                .font(.headline)

            Text("Toggle built-in directories to include or exclude from scanning.")
                .font(.caption)
                .foregroundColor(.secondary)

            ForEach($builtInToggles) { $toggle in
                Toggle(isOn: $toggle.isEnabled) {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                            .font(.caption)
                        Text(toggle.path)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if !directoryExists(toggle.path) {
                            Text("(not found)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .onChange(of: toggle.isEnabled) { _, newValue in
                    scheduler.toggleBuiltIn(path: toggle.path, enabled: newValue)
                }
            }
        }
    }

    // MARK: - Custom scan directories

    private var customScanDirectoriesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Custom Scan Directories", systemImage: "folder.badge.plus")
                .font(.headline)

            if scheduler.config.customPaths.isEmpty {
                Text("No custom directories added.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(scheduler.config.customPaths, id: \.self) { path in
                    HStack {
                        Image(systemName: "folder")
                            .font(.caption)
                        Text(path)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if !directoryExists(path) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.caption2)
                                .foregroundColor(.yellow)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            scheduler.removeCustomPath(path)
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack {
                TextField("/path/to/projects", text: $newCustomPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                Button("Add") {
                    let trimmed = newCustomPath.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    scheduler.addCustomPath(trimmed)
                    newCustomPath = ""
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(newCustomPath.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Actions", systemImage: "play")
                .font(.headline)

            HStack(spacing: 12) {
                Button(action: { scheduler.rescan() }) {
                    Label(
                        scheduler.isScanning ? "Scanning..." : "Rescan Now",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(scheduler.isScanning)

                Button(action: openWidgetInstructions) {
                    Label("Widget Instructions", systemImage: "questionmark.circle")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Widget Instructions

    private var widgetInstructionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("How to Add Widget", systemImage: "square.text.square")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                instructionRow(number: "1", text: "Right-click on your desktop.")
                instructionRow(number: "2", text: "Select \"Edit Widgets...\" from the context menu.")
                instructionRow(number: "3", text: "In the widget gallery, search for \"DevPulse\".")
                instructionRow(number: "4", text: "Choose a size (Small, Medium, or Large) and drag it onto your desktop.")
                instructionRow(number: "5", text: "Click \"Done\" when finished.")
            }
            .font(.caption)

            Text("The widget updates automatically after each scan. "
                 + "Refresh frequency is managed by macOS.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.top, 4)
        }
    }

    // MARK: - Diagnostics

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Diagnostics", systemImage: "stethoscope")
                    .font(.headline)
                Spacer()
                Button(action: { scheduler.rescan() }) {
                    Label(
                        scheduler.isScanning ? "Refreshing..." : "Refresh Data",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(scheduler.isScanning)
            }

            diagnosticsStatusGrid

            if let widgetSnapshot = scheduler.diagnostics.widgetSnapshot {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Widget snapshot preview")
                        .font(.caption.weight(.semibold))
                    Text("generated \(snapshotTimeLabel(DateFormatting.date(from: widgetSnapshot.generatedAt))) · written \(snapshotTimeLabel(widgetSnapshot.writtenAt))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("repos \(widgetSnapshot.repositories.count) · changed \(widgetSnapshot.scanSummary.changedRepositories) · files \(widgetSnapshot.scanSummary.totalChangedFiles)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    if let firstRepo = widgetSnapshot.repositories.first {
                        Text("\(firstRepo.name) · \(firstRepo.branch) · total \(firstRepo.changedFileCount)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(10)
                .background(Color.secondary.opacity(0.06))
                .cornerRadius(8)
            }

            if !scheduler.diagnostics.validationIssues.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Consistency issues")
                        .font(.caption.weight(.semibold))
                    ForEach(scheduler.diagnostics.validationIssues, id: \.self) { issue in
                        Label(issue, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
                .padding(10)
                .background(Color.red.opacity(0.08))
                .cornerRadius(8)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Current repositories")
                    .font(.caption.weight(.semibold))

                if scheduler.lastResult.repositories.isEmpty {
                    Text("No repositories in the latest snapshot.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(scheduler.lastResult.repositories) { repo in
                            diagnosticsRepositoryRow(repo)
                        }
                    }
                }
            }
            .padding(10)
            .background(Color.secondary.opacity(0.06))
            .cornerRadius(8)

            VStack(alignment: .leading, spacing: 8) {
                Text("Recent events")
                    .font(.caption.weight(.semibold))

                if scheduler.diagnosticEvents.isEmpty {
                    Text("No diagnostic events yet.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(scheduler.diagnosticEvents.reversed())) { event in
                                diagnosticsEventRow(event)
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }
            }
            .padding(10)
            .background(Color.secondary.opacity(0.06))
            .cornerRadius(8)
        }
    }

    private var diagnosticsStatusGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            diagnosticsRow(
                title: "App Group",
                value: scheduler.appGroupAvailable ? "Available" : "Unavailable",
                detail: scheduler.appGroupAvailable ? AppGroupStore.appGroupIdentifier : "Check entitlements",
                isError: !scheduler.appGroupAvailable
            )
            diagnosticsRow(
                title: "Shared read",
                value: sharedReadStatus,
                detail: sharedReadDetail,
                isError: sharedReadStatus == "Failed"
            )
            diagnosticsRow(
                title: "Shared write",
                value: sharedWriteStatus,
                detail: sharedWriteDetail,
                isError: sharedWriteStatus == "Failed"
            )
            diagnosticsRow(
                title: "Widget snapshot",
                value: widgetSnapshotStatus,
                detail: widgetSnapshotDetail,
                isError: widgetSnapshotStatus == "Failed"
            )
            diagnosticsRow(
                title: "Validation",
                value: scheduler.diagnostics.validationIssues.isEmpty ? "Pass" : "Mismatch",
                detail: scheduler.diagnostics.validationIssues.isEmpty ? "Main app, shared data, and widget snapshot match." : scheduler.diagnostics.validationIssues.joined(separator: " "),
                isError: !scheduler.diagnostics.validationIssues.isEmpty
            )
        }
    }

    private var sharedReadStatus: String {
        if scheduler.diagnostics.sharedDataReadError != nil {
            return "Failed"
        }
        if scheduler.diagnostics.sharedDataSnapshot != nil {
            return "Success"
        }
        return "Pending"
    }

    private var sharedReadDetail: String {
        if scheduler.diagnostics.sharedDataReadError != nil {
            return scheduler.diagnostics.sharedDataReadError ?? "Shared data read failed."
        }
        if scheduler.diagnostics.sharedDataSnapshot != nil {
            return snapshotTimeLabel(scheduler.diagnostics.sharedDataReadAt)
        }
        return "No shared snapshot loaded yet."
    }

    private var sharedWriteStatus: String {
        if scheduler.diagnostics.sharedDataWriteError != nil {
            return "Failed"
        }
        if scheduler.diagnostics.lastSharedWriteAt != nil {
            return "Success"
        }
        return "Pending"
    }

    private var sharedWriteDetail: String {
        if scheduler.diagnostics.sharedDataWriteError != nil {
            return scheduler.diagnostics.sharedDataWriteError ?? "Shared data write failed."
        }
        if scheduler.diagnostics.lastSharedWriteAt != nil {
            return snapshotTimeLabel(scheduler.diagnostics.lastSharedWriteAt)
        }
        return "No shared write yet."
    }

    private var widgetSnapshotStatus: String {
        if scheduler.diagnostics.widgetSnapshotReadError != nil {
            return "Failed"
        }
        if scheduler.diagnostics.widgetSnapshot != nil {
            return "Readable"
        }
        return "Pending"
    }

    private var widgetSnapshotDetail: String {
        if scheduler.diagnostics.widgetSnapshotReadError != nil {
            return scheduler.diagnostics.widgetSnapshotReadError ?? "Widget snapshot read failed."
        }
        if scheduler.diagnostics.widgetSnapshot != nil {
            return snapshotTimeLabel(scheduler.diagnostics.widgetSnapshotReadAt)
        }
        return "No widget-readable snapshot yet."
    }

    private func diagnosticsRow(title: String, value: String, detail: String, isError: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 110, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(isError ? .red : .primary)
                Text(detail)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private func diagnosticsRepositoryRow(_ repo: RepositorySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(repo.name)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(repo.branch)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Text(repo.path)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Text("modified \(repo.modifiedFileCount) · added \(repo.addedFileCount) · deleted \(repo.deletedFileCount) · untracked \(repo.untrackedFileCount) · total \(repo.changedFileCount)")
                .font(.caption2)
                .foregroundColor(.secondary)

            HStack(spacing: 8) {
                Text("status \(repo.status.rawValue)")
                if let lastChangedAt = repo.lastChangedAt {
                    Text("changed \(snapshotTimeLabel(DateFormatting.date(from: lastChangedAt)))")
                }
            }
            .font(.caption2)
            .foregroundColor(repo.status == .error ? .red : .secondary)

            Text("scan \(snapshotTimeLabel(DateFormatting.date(from: repo.lastScannedAt)))")
                .font(.caption2)
                .foregroundColor(.secondary)

            if let errorMessage = repo.errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundColor(.red)
            }
        }
        .padding(8)
        .background(Color.white.opacity(0.35))
        .cornerRadius(6)
    }

    private func diagnosticsEventRow(_ event: DiagnosticEvent) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(event.kind.rawValue)
                .font(.caption2.weight(.semibold))
                .foregroundColor(event.kind == .validationFailed || event.kind == .sharedDataWriteFailed || event.kind == .sharedDataReadFailed ? .red : .secondary)
                .frame(width: 120, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.message)
                    .font(.caption)
                Text(snapshotTimeLabel(DateFormatting.date(from: event.timestamp)))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func snapshotTimeLabel(_ date: Date?) -> String {
        guard let date else { return "unknown" }
        return formattedDate(date)
    }

    private func snapshotTimeLabel(_ iso: String?) -> String {
        guard let iso, let date = DateFormatting.date(from: iso) else { return "unknown" }
        return formattedDate(date)
    }

    // MARK: - Helpers

    private func instructionRow(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(number)
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.accentColor))
            Text(text)
                .font(.caption)
        }
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func directoryExists(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private func openWidgetInstructions() {
        // Scroll the view? For now this is in the same view.
    }
}
