import AppKit
import SwiftUI

struct RepositoryDetailChangeItem: Identifiable, Equatable {
    enum Kind: String, CaseIterable {
        case modified
        case added
        case deleted
        case untracked
        case staged
        case unstaged
        case conflicted
    }

    let kind: Kind
    let count: Int?

    var id: Kind { kind }

    var title: String {
        switch kind {
        case .modified: return "修改"
        case .added: return "新增"
        case .deleted: return "删除"
        case .untracked: return "未跟踪"
        case .staged: return "已暂存"
        case .unstaged: return "未暂存"
        case .conflicted: return "冲突"
        }
    }
}

struct RepositoryDetailPresentation: Equatable {
    let dataSource: RepositoryDataSourcePresentation
    let branch: String
    let latestCommit: String
    let localSummary: String
    let synchronization: String
    let changeItems: [RepositoryDetailChangeItem]
    let changedFileNames: [String]
    let remainingChangedFileCount: Int
    let nextAction: String
    let diagnosticMessage: String?

    var isCurrent: Bool {
        dataSource.source == .current
    }
}

enum RepositoryDetailPresentationBuilder {
    static func build(snapshot: RepositorySnapshot, now: Date = Date()) -> RepositoryDetailPresentation {
        let listPresentation = RepositoryListItemPresentationBuilder.build(snapshot: snapshot, now: now)
        let countsAreAvailable = snapshot.resolvedDataSource == .lastSuccessful
            || (snapshot.resolvedDataSource == .current && snapshot.status != .error)
        let fileNames = countsAreAvailable
            ? privacySafeBasenames(snapshot.changedFilesPreview)
            : []

        return RepositoryDetailPresentation(
            dataSource: listPresentation.dataSource,
            branch: snapshot.branchDisplayLabel,
            latestCommit: listPresentation.latestCommit,
            localSummary: snapshot.statusSummary,
            synchronization: listPresentation.synchronization,
            changeItems: changeItems(snapshot: snapshot, countsAreAvailable: countsAreAvailable),
            changedFileNames: fileNames,
            remainingChangedFileCount: countsAreAvailable
                ? max(snapshot.changedFileCount - fileNames.count, 0)
                : 0,
            nextAction: snapshot.nextActionHint,
            diagnosticMessage: diagnosticMessage(snapshot.errorMessage)
        )
    }

    private static func diagnosticMessage(_ message: String?) -> String? {
        guard let message else { return nil }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func changeItems(
        snapshot: RepositorySnapshot,
        countsAreAvailable: Bool
    ) -> [RepositoryDetailChangeItem] {
        let counts = snapshot.changeCounts
        let values: [RepositoryDetailChangeItem.Kind: Int] = [
            .modified: counts.modified,
            .added: counts.added,
            .deleted: counts.deleted,
            .untracked: counts.untracked,
            .staged: counts.staged,
            .unstaged: counts.unstaged,
            .conflicted: counts.conflicted
        ]

        return RepositoryDetailChangeItem.Kind.allCases.map { kind in
            RepositoryDetailChangeItem(
                kind: kind,
                count: countsAreAvailable ? values[kind] : nil
            )
        }
    }

    /// The shared snapshot may contain relative Git paths. The UI contract is
    /// basename-only: no parent directory is disclosed and no file is opened.
    static func privacySafeBasenames(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.compactMap { rawPath in
            let normalized = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { return nil }
            let basename = (normalized as NSString).lastPathComponent
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !basename.isEmpty, basename != ".", seen.insert(basename).inserted else {
                return nil
            }
            return basename
        }
    }
}

enum RepositoryExternalOpenAction: String, CaseIterable, Hashable {
    case finder
    case terminal

    var title: String {
        switch self {
        case .finder: return "在 Finder 中打开"
        case .terminal: return "在终端中打开"
        }
    }

    var systemImage: String {
        switch self {
        case .finder: return "folder"
        case .terminal: return "terminal"
        }
    }
}

struct RepositoryExternalOpenRequest: Equatable {
    let action: RepositoryExternalOpenAction
    let repositoryURL: URL
    let applicationURL: URL?
}

enum RepositoryExternalOpenRequestBuilder {
    static let terminalApplicationURL = URL(
        fileURLWithPath: "/System/Applications/Utilities/Terminal.app",
        isDirectory: true
    )

    static func build(
        action: RepositoryExternalOpenAction,
        repositoryPath: String
    ) -> RepositoryExternalOpenRequest? {
        guard repositoryPath.hasPrefix("/"), !repositoryPath.contains("\0") else {
            return nil
        }
        let canonicalPath = RepositoryIdentity.canonicalPath(repositoryPath)
        guard canonicalPath.hasPrefix("/") else {
            return nil
        }
        let repositoryURL = URL(fileURLWithPath: canonicalPath, isDirectory: true)
            .standardizedFileURL
        return RepositoryExternalOpenRequest(
            action: action,
            repositoryURL: repositoryURL,
            applicationURL: action == .terminal ? terminalApplicationURL : nil
        )
    }
}

enum RepositoryExternalOpener {
    @discardableResult
    static func open(
        action: RepositoryExternalOpenAction,
        repositoryPath: String,
        workspace: NSWorkspace = .shared
    ) -> Bool {
        guard let request = RepositoryExternalOpenRequestBuilder.build(
            action: action,
            repositoryPath: repositoryPath
        ) else { return false }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: request.repositoryURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else { return false }

        switch request.action {
        case .finder:
            return workspace.open(request.repositoryURL)
        case .terminal:
            guard let applicationURL = request.applicationURL,
                  FileManager.default.fileExists(atPath: applicationURL.path) else {
                return false
            }
            workspace.open(
                [request.repositoryURL],
                withApplicationAt: applicationURL,
                configuration: NSWorkspace.OpenConfiguration()
            )
            return true
        }
    }
}

struct RepositoryDetailView: View {
    let repository: RepositorySnapshot
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var scheduler: ScanScheduler

    private var presentation: RepositoryDetailPresentation {
        RepositoryDetailPresentationBuilder.build(snapshot: repository)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()
                .overlay(DevPulseVisualStyle.separator)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    trustNotice
                    overviewSection
                    recentActivitySection
                    localChangesSection
                    changedFilesSection
                    nextActionSection
                }
                .padding(20)
            }

            Divider()
                .overlay(DevPulseVisualStyle.separator)

            footer
        }
        .frame(minWidth: 540, idealWidth: 580, minHeight: 560, idealHeight: 660)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(repository.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text("只读仓库详情")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            dataSourceBadge

            Button("关闭") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var trustNotice: some View {
        if !presentation.isCurrent || presentation.diagnosticMessage != nil {
            VStack(alignment: .leading, spacing: 5) {
                Label(presentation.dataSource.label, systemImage: trustSystemImage)
                    .font(.callout.weight(.semibold))
                Text(presentation.dataSource.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let diagnosticMessage = presentation.diagnosticMessage {
                    Text("扫描信息：\(diagnosticMessage)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(trustTint.opacity(0.1))
            )
        }
    }

    private var overviewSection: some View {
        detailCard(title: "仓库状态") {
            detailRow(title: "当前分支", value: presentation.branch, systemImage: "arrow.triangle.branch")
            detailRow(title: "最近提交", value: presentation.latestCommit, systemImage: "clock")
            detailRow(title: "同步状态", value: presentation.synchronization, systemImage: "arrow.up.arrow.down")
        }
    }

    private var localChangesSection: some View {
        detailCard(title: "本地改动") {
            Text(presentation.localSummary)
                .font(.callout)
                .foregroundStyle(.secondary)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4),
                spacing: 8
            ) {
                ForEach(presentation.changeItems) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.count.map(String.init) ?? "—")
                            .font(.headline.monospacedDigit())
                        Text(item.title)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(DevPulseVisualStyle.strongerSurface)
                    )
                }
            }
        }
    }

    private var recentActivitySection: some View {
        detailCard(title: "近期活动") {
            if recentEvents.isEmpty {
                Text("尚未记录该仓库的增量活动")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(recentEvents.prefix(12))) { event in
                    ActivityEventRow(event: event)
                    if event.id != recentEvents.prefix(12).last?.id {
                        Divider().overlay(DevPulseVisualStyle.separator)
                    }
                }
            }
        }
    }

    private var recentEvents: [ActivityEvent] {
        scheduler.activityEvents.filter { $0.repositoryID == repository.id }
    }

    private var changedFilesSection: some View {
        detailCard(title: "变更文件名预览") {
            if presentation.changedFileNames.isEmpty {
                Text(changedFilesEmptyText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(presentation.changedFileNames, id: \.self) { fileName in
                    Label(fileName, systemImage: "doc")
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if presentation.remainingChangedFileCount > 0 {
                    Text("另有 \(presentation.remainingChangedFileCount) 个文件未在预览中显示")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Label("仅显示 Git 元数据中的文件名，不读取文件内容", systemImage: "lock.shield")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var nextActionSection: some View {
        detailCard(title: "下一步建议") {
            Label(presentation.nextAction, systemImage: "lightbulb")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text("DevPulse 只提供建议，不会自动提交、拉取、推送或修改仓库。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            ForEach(RepositoryExternalOpenAction.allCases, id: \.self) { action in
                Button {
                    RepositoryExternalOpener.open(
                        action: action,
                        repositoryPath: repository.path
                    )
                } label: {
                    Label(action.title, systemImage: action.systemImage)
                }
                .help(action.title)
            }

            Spacer()

            Text("不会执行 Git 命令")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var dataSourceBadge: some View {
        Label(presentation.dataSource.label, systemImage: trustSystemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(trustTint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(trustTint.opacity(0.11)))
            .help(presentation.dataSource.detail)
    }

    private var trustSystemImage: String {
        switch presentation.dataSource.source {
        case .current: return "checkmark.circle"
        case .lastSuccessful: return "clock.arrow.circlepath"
        case .unknown: return "questionmark.circle"
        }
    }

    private var trustTint: Color {
        switch presentation.dataSource.source {
        case .current: return .secondary
        case .lastSuccessful: return .orange
        case .unknown: return .red
        }
    }

    private var changedFilesEmptyText: String {
        switch presentation.dataSource.source {
        case .unknown: return "当前没有可信的文件名预览"
        case .current, .lastSuccessful:
            return repository.changedFileCount == 0 ? "没有本地变更文件" : "文件名预览不可用"
        }
    }

    private func detailCard<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DevPulseVisualStyle.sectionCornerRadius, style: .continuous)
                .fill(DevPulseVisualStyle.surface)
        )
    }

    private func detailRow(title: String, value: String, systemImage: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 82, alignment: .leading)
            Text(value)
                .font(.callout)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}
