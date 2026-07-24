import SwiftUI

// MARK: - Backup management view

struct BackupManagementView: View {
    @StateObject private var viewModel = BackupViewModel()
    @State private var selectedBackup: BackupSummary?
    @State private var showDeleteConfirmation = false
    @State private var showRestorePrecheck = false
    @State private var showCreateBackupSheet = false
    @State private var showImportPicker = false

    var body: some View {
        VStack(spacing: 0) {
            headerSection

            Divider()
                .overlay(DevPulseVisualStyle.separator)

            if viewModel.isLoading {
                Spacer()
                ProgressView("加载备份…")
                    .controlSize(.large)
                Spacer()
            } else if viewModel.backups.isEmpty {
                emptyStateView
            } else {
                backupListView
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showCreateBackupSheet) {
            CreateBackupView(viewModel: viewModel)
        }
        .sheet(isPresented: $showRestorePrecheck) {
            if let backup = selectedBackup {
                RestorePreviewView(
                    backup: backup,
                    viewModel: viewModel
                )
            }
        }
        .fileImporter(
            isPresented: $showImportPicker,
            allowedContentTypes: [.archive],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                viewModel.importBackup(from: url)
            }
        }
        .alert(item: $viewModel.alertItem) { item in
            Alert(
                title: Text(item.title),
                message: Text(item.message),
                dismissButton: .default(Text("确定"))
            )
        }
        .confirmationDialog(
            "确认删除备份？",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let backup = selectedBackup {
                    viewModel.deleteBackup(backup)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后无法恢复。备份文件将被永久移除。")
        }
        .onAppear {
            viewModel.refresh()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            Image(systemName: "externaldrive.badge.checkmark")
                .font(.title3)
                .foregroundStyle(.tint)
            Text("数据备份")
                .font(.headline)
            Spacer()

            backupCountLabel

            Button {
                showCreateBackupSheet = true
            } label: {
                Label("新建备份", systemImage: "plus.circle")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help("创建完整数据备份")

            Button {
                showImportPicker = true
            } label: {
                Label("导入", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("导入备份文件")

            Button {
                viewModel.refresh()
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(DevPulseVisualStyle.pageInset)
    }

    private var backupCountLabel: some View {
        Text("\(viewModel.backups.count) 个备份")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(DevPulseVisualStyle.surface)
            .clipShape(Capsule())
    }

    // MARK: - Empty state

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "externaldrive")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("还没有备份")
                .font(.title3.weight(.medium))

            Text("创建备份以保护你的仓库设置、工作空间和偏好。\n备份存储在本地，不会上传到任何网络服务。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)

            Button {
                showCreateBackupSheet = true
            } label: {
                Label("创建第一个备份", systemImage: "externaldrive.badge.plus")
                    .font(.callout)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)

            Spacer()
        }
        .padding()
    }

    // MARK: - Backup list

    private var backupListView: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(viewModel.backups) { backup in
                    BackupRowView(
                        backup: backup,
                        isSelected: selectedBackup?.id == backup.id,
                        onSelect: { selectedBackup = backup },
                        onVerify: { viewModel.verifyBackup(backup) },
                        onDelete: {
                            selectedBackup = backup
                            showDeleteConfirmation = true
                        },
                        onExport: { viewModel.exportBackup(backup) },
                        onRestore: {
                            selectedBackup = backup
                            showRestorePrecheck = true
                        }
                    )
                    .padding(.horizontal, DevPulseVisualStyle.pageInset)
                }
            }
            .padding(.vertical, 8)
        }
    }
}

// MARK: - Backup row

struct BackupRowView: View {
    let backup: BackupSummary
    let isSelected: Bool
    let onSelect: () -> Void
    let onVerify: () -> Void
    let onDelete: () -> Void
    let onExport: () -> Void
    let onRestore: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                // Status icon
                Image(systemName: statusIcon)
                    .font(.title3)
                    .foregroundStyle(statusColor)
                    .frame(width: 28)

                // Info
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(formattedDate)
                            .font(.callout.weight(.medium))
                        if backup.isIncremental {
                            Text("增量")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.orange.opacity(0.1))
                                .clipShape(Capsule())
                        }
                    }
                    HStack(spacing: 12) {
                        Label("\(backup.entryCount) 项", systemImage: "doc.on.doc")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Label(formattedSize, systemImage: "arrow.down.circle.dotted")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if !backup.isCompatible {
                            Text("不兼容")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.red)
                        }
                    }
                }

                Spacer()

                // Actions
                HStack(spacing: 4) {
                    Button(action: onRestore) {
                        Image(systemName: "arrow.uturn.backward.circle")
                    }
                    .buttonStyle(.plain)
                    .help("恢复")
                    .disabled(!backup.isCompatible)

                    Button(action: onVerify) {
                        Image(systemName: "checkmark.shield")
                    }
                    .buttonStyle(.plain)
                    .help("验证完整性")

                    Button(action: onExport) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .buttonStyle(.plain)
                    .help("导出")

                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .help("删除")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(isSelected ? Color.accentColor.opacity(0.06) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .background(DevPulseVisualStyle.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(DevPulseVisualStyle.separator, lineWidth: 0.5)
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
    }

    private var statusIcon: String {
        if !backup.integrityVerified { return "externaldrive" }
        return backup.integrityError == nil ? "externaldrive.badge.checkmark" : "externaldrive.badge.exclamationmark"
    }

    private var statusColor: Color {
        if !backup.integrityVerified { return .secondary }
        return backup.integrityError == nil ? .green : .red
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: backup.createdAt)
    }

    private var formattedSize: String {
        let bytes = backup.totalSizeBytes
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1_048_576 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }
}

// MARK: - Create backup sheet

struct CreateBackupView: View {
    @ObservedObject var viewModel: BackupViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var notes: String = ""
    @State private var isCreating = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "externaldrive.badge.plus")
                .font(.system(size: 40))
                .foregroundStyle(.tint)

            Text("新建备份")
                .font(.title2.weight(.semibold))

            Text("备份将包含当前所有仓库数据、工作空间配置、\n待处理事项和偏好设置。存储在本地。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            TextField("添加备注（可选）", text: $notes)
                .textFieldStyle(.plain)
                .padding(10)
                .background(DevPulseVisualStyle.strongerSurface)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 12) {
                Button("取消") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.escape)

                Button {
                    createBackup()
                } label: {
                    if isCreating {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("开始备份")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isCreating)
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    private func createBackup() {
        isCreating = true
        viewModel.createBackup(notes: notes.isEmpty ? nil : notes) {
            isCreating = false
            dismiss()
        }
    }
}

// MARK: - Restore preview

struct RestorePreviewView: View {
    let backup: BackupSummary
    @ObservedObject var viewModel: BackupViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var precheckResult: RestorePrecheckResult?
    @State private var isPrechecking = true
    @State private var confirmRestore = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "arrow.uturn.backward.circle")
                    .font(.title3)
                Text("从备份恢复")
                    .font(.headline)
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding()

            Divider()

            if isPrechecking {
                Spacer()
                ProgressView("正在检查备份兼容性…")
                    .controlSize(.large)
                Spacer()
            } else if let result = precheckResult {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Compatibility
                        compatibilitySection(result)

                        // Diff summary
                        diffSummarySection(result)

                        // Conflict list
                        if !result.entriesInConflict.isEmpty {
                            conflictSection(result)
                        }

                        // Action buttons
                        HStack(spacing: 12) {
                            Spacer()
                            Button("取消") { dismiss() }
                                .buttonStyle(.bordered)

                            Button(role: .destructive) {
                                confirmRestore = true
                            } label: {
                                Text("开始恢复")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!result.isCompatible)
                            .tint(result.isCompatible ? .accentColor : .gray)
                        }
                    }
                    .padding()
                }
            }

            Divider()
            Text("恢复前将自动备份当前数据，失败时可回滚。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(8)
        }
        .frame(width: 500, height: 450)
        .onAppear {
            viewModel.precheckRestore(backup: backup) { result in
                precheckResult = result
                isPrechecking = false
            }
        }
        .confirmationDialog(
            "确认恢复？",
            isPresented: $confirmRestore,
            titleVisibility: .visible
        ) {
            Button("确认恢复") {
                viewModel.executeRestore(backup: backup)
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            if let result = precheckResult {
                Text("将恢复 \(result.entriesToCreate.count + result.entriesToOverwrite.count + result.entriesToMerge.count) 项数据，跳过 \(result.entriesToSkip.count) 项。当前数据将被覆盖。")
            }
        }
    }

    private func compatibilitySection(_ result: RestorePrecheckResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("兼容性检查", systemImage: "checkmark.shield")
                .font(.callout.weight(.semibold))

            HStack {
                Image(systemName: result.isCompatible ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(result.isCompatible ? .green : .red)
                Text(result.isCompatible ? "备份兼容当前 App 版本" : (result.incompatibleReason ?? "不兼容"))
                    .font(.caption)
            }

            if let source = result.sourceDeviceName, let target = result.targetDeviceName {
                Text("来源设备：\(source) → 当前设备：\(target)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if result.requiresMigration, let desc = result.migrationDescription {
                Label(desc, systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(12)
        .background(DevPulseVisualStyle.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func diffSummarySection(_ result: RestorePrecheckResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("变更预览", systemImage: "doc.text.magnifyingglass")
                .font(.callout.weight(.semibold))

            HStack(spacing: 16) {
                DiffBadge(count: result.entriesToCreate.count, label: "新增", color: .green)
                DiffBadge(count: result.entriesToOverwrite.count, label: "覆盖", color: .orange)
                DiffBadge(count: result.entriesToMerge.count, label: "合并", color: .blue)
                DiffBadge(count: result.entriesToSkip.count, label: "跳过", color: .secondary)
            }
        }
        .padding(12)
        .background(DevPulseVisualStyle.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func conflictSection(_ result: RestorePrecheckResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("需关注的冲突", systemImage: "exclamationmark.triangle")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)

            ForEach(Array(result.entriesInConflict.values).flatMap { $0 }) { conflict in
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Text(conflict.displayDescription)
                        .font(.caption)
                    Spacer()
                    Text(conflict.resolution?.displayName ?? "待决定")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .background(Color.orange.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(12)
        .background(DevPulseVisualStyle.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct DiffBadge: View {
    let count: Int
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text("\(count)")
                .font(.title3.weight(.semibold))
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 48)
        .padding(8)
        .background(color.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Alert item

struct BackupAlertItem: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

// MARK: - ViewModel

final class BackupViewModel: ObservableObject {
    @Published var backups: [BackupSummary] = []
    @Published var isLoading = true
    @Published var alertItem: BackupAlertItem?

    private let backupManager = BackupManager()
    private let restoreManager: RestoreManager
    private let config: BackupIntegrationConfiguration = .default

    init() {
        self.restoreManager = RestoreManager(backupManager: backupManager)
    }

    func refresh() {
        isLoading = true
        weak var wSelf = self
        DispatchQueue.global(qos: .utility).async {
            guard let s = wSelf else { return }
            let listing = s.backupManager.listBackups(config: s.config)
            DispatchQueue.main.async {
                guard let s = wSelf else { return }
                s.backups = listing.backups
                s.isLoading = false
            }
        }
    }

    func createBackup(notes: String?, completion: @escaping () -> Void) {
        weak var wSelf = self
        DispatchQueue.global(qos: .utility).async {
            guard let s = wSelf else { completion(); return }
            let stores = s.gatherCurrentStores()
            do {
                let summary = try s.backupManager.createBackup(
                    config: s.config,
                    stores: stores,
                    notes: notes,
                    isIncremental: false
                )
                DispatchQueue.main.async {
                    guard let s = wSelf else { completion(); return }
                    s.backups.insert(summary, at: 0)
                    completion()
                }
            } catch {
                DispatchQueue.main.async {
                    guard let s = wSelf else { completion(); return }
                    s.alertItem = BackupAlertItem(
                        title: "备份失败",
                        message: error.localizedDescription
                    )
                    completion()
                }
            }
        }
    }

    func verifyBackup(_ backup: BackupSummary) {
        weak var wSelf = self
        DispatchQueue.global(qos: .utility).async {
            guard let s = wSelf else { return }
            let result = s.backupManager.verifyIntegrity(backupID: backup.id, config: s.config)
            DispatchQueue.main.async {
                guard let s = wSelf else { return }
                if result.overallIntegrity {
                    s.alertItem = BackupAlertItem(
                        title: "完整性验证通过",
                        message: "备份 \(backup.id) 所有文件完整且校验一致。"
                    )
                } else {
                    s.alertItem = BackupAlertItem(
                        title: "完整性验证失败",
                        message: result.errors.joined(separator: "\n")
                    )
                }
            }
        }
    }

    func deleteBackup(_ backup: BackupSummary) {
        weak var wSelf = self
        DispatchQueue.global(qos: .utility).async {
            guard let s = wSelf else { return }
            try? s.backupManager.deleteBackup(backupID: backup.id, config: s.config)
            DispatchQueue.main.async {
                guard let s = wSelf else { return }
                s.backups.removeAll { $0.id == backup.id }
            }
        }
    }

    func exportBackup(_ backup: BackupSummary) {
        let bm = backupManager
        let backupID = backup.id
        let cfg = config
        DispatchQueue.main.async {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "\(backupID).zip"
            panel.allowedContentTypes = [.archive]
            panel.canCreateDirectories = true

            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                DispatchQueue.global(qos: .utility).async {
                    do {
                        try bm.exportBackup(backupID: backupID, to: url, config: cfg)
                        DispatchQueue.main.async {
                            print("导出成功：\(url.lastPathComponent)")
                        }
                    } catch {
                        DispatchQueue.main.async {
                            print("导出失败：\(error.localizedDescription)")
                        }
                    }
                }
            }
        }
    }

    func importBackup(from url: URL) {
        weak var wSelf = self
        DispatchQueue.global(qos: .utility).async {
            guard let s = wSelf else { return }
            do {
                let summary = try s.backupManager.importBackup(from: url, config: s.config)
                DispatchQueue.main.async {
                    guard let s = wSelf else { return }
                    s.refresh()
                    s.alertItem = BackupAlertItem(
                        title: "导入成功", message: "备份「\(summary.id)」已导入。"
                    )
                }
            } catch {
                DispatchQueue.main.async {
                    guard let s = wSelf else { return }
                    s.alertItem = BackupAlertItem(
                        title: "导入失败", message: error.localizedDescription
                    )
                }
            }
        }
    }

    func precheckRestore(backup: BackupSummary, completion: @escaping (RestorePrecheckResult) -> Void) {
        weak var wSelf = self
        DispatchQueue.global(qos: .utility).async {
            guard let s = wSelf else { return }
            let currentStores = s.gatherCurrentStores()
            let result = s.restoreManager.precheck(backupID: backup.id, config: s.config, currentStores: currentStores)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    func executeRestore(backup: BackupSummary) {
        weak var wSelf = self
        DispatchQueue.global(qos: .utility).async {
            guard let s = wSelf else { return }
            let currentStores = s.gatherCurrentStores()
            let storeWriters: [BackupStoreType: (Data) throws -> Void] = [:]
            do {
                let result = try s.restoreManager.executeRestore(
                    backupID: backup.id, config: s.config,
                    currentStores: currentStores, storeWriters: storeWriters,
                    resolveConflicts: [:]
                )
                DispatchQueue.main.async {
                    guard let s = wSelf else { return }
                    s.alertItem = BackupAlertItem(
                        title: "恢复完成",
                        message: "已恢复 \(result.restoredEntries.count)/\(result.totalEntries) 项数据。"
                    )
                    s.refresh()
                }
            } catch {
                DispatchQueue.main.async {
                    guard let s = wSelf else { return }
                    s.alertItem = BackupAlertItem(
                        title: "恢复失败", message: error.localizedDescription
                    )
                }
            }
        }
    }

    private func gatherCurrentStores() -> [BackupStoreType: (data: Data, schemaVersion: Int)] {
        [:] // Will be wired with actual store data
    }
}
