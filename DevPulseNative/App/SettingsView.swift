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
