import Darwin
import Foundation

enum SharedSnapshotReadSource: Equatable {
    case primary
    case migratedPrimary
    case backup
}

struct SharedSnapshotRead: Equatable {
    let snapshot: AppGroupData
    let source: SharedSnapshotReadSource
}

enum SharedSnapshotCommitPhase: Equatable {
    case afterStaging
    case beforePrimaryReplacement
    case afterPrimaryReplacement
}

/// Foundation-only persistence shared by the host app and Widget extension.
///
/// Every participant honors the same advisory lock. Commits stage and verify a
/// complete payload in the App Group directory before one atomic `rename`, so a
/// reader can observe only the old or the new file. A separately verified
/// backup remains available when the primary is missing or damaged.
final class SharedSnapshotStore: @unchecked Sendable {
    /// POSIX record locks are process-scoped, so a local mutex is also needed
    /// to serialize independent store instances inside one process.
    private static let processLock = NSLock()

    let primaryURL: URL
    let backupURL: URL
    let temporaryFilePrefix: String

    private let directoryURL: URL
    private let lockURL: URL
    private let fileManager: FileManager
    private let now: () -> Date
    private let failureInjector: ((SharedSnapshotCommitPhase) throws -> Void)?

    init(
        directoryURL: URL,
        fileName: String,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        failureInjector: ((SharedSnapshotCommitPhase) throws -> Void)? = nil
    ) {
        self.directoryURL = directoryURL
        primaryURL = directoryURL.appendingPathComponent(fileName)
        backupURL = directoryURL.appendingPathComponent("\(fileName).backup")
        lockURL = directoryURL.appendingPathComponent(".\(fileName).lock")
        temporaryFilePrefix = ".\(fileName).tmp-"
        self.fileManager = fileManager
        self.now = now
        self.failureInjector = failureInjector
    }

    func load() -> Result<SharedSnapshotRead, AppGroupStoreError> {
        do {
            return .success(try withFileLock(.shared) { try loadUnlocked() })
        } catch let error as AppGroupStoreError {
            return .failure(error)
        } catch {
            return .failure(.readFailed(error.localizedDescription))
        }
    }

    func commit(_ candidate: AppGroupData) -> Result<AppGroupData, AppGroupStoreError> {
        do {
            let committed = try withFileLock(.exclusive) {
                return try commitUnlocked(candidate)
            }
            return .success(committed)
        } catch let error as AppGroupStoreError {
            return .failure(error)
        } catch {
            return .failure(.writeFailed(error.localizedDescription))
        }
    }

    @discardableResult
    func cleanupTemporaryFiles() -> Result<Void, AppGroupStoreError> {
        do {
            try withFileLock(.exclusive) {
                _ = try commitBaselineUnlocked()
                try cleanupTemporaryFilesUnlocked()
            }
            return .success(())
        } catch let error as AppGroupStoreError {
            return .failure(error)
        } catch {
            return .failure(.writeFailed(error.localizedDescription))
        }
    }

    // MARK: - Read and migration

    private func loadUnlocked() throws -> SharedSnapshotRead {
        let primaryResult = decodeFile(at: primaryURL)
        let backupResult = decodeFile(at: backupURL)

        if case .failure(.futureSchema(let actual)) = primaryResult {
            // A future primary is authoritative. An older process must never
            // hide or overwrite it by falling back to a schema-v2 backup.
            throw AppGroupStoreError.schemaVersionMismatch(
                expected: RepositorySnapshotSchema.version,
                actual: actual
            )
        }
        if case .failure(.futureSchema(let actual)) = backupResult {
            // A newer recovery artifact makes the whole pair version-unsafe
            // for this process, even while the older primary is readable.
            throw AppGroupStoreError.schemaVersionMismatch(
                expected: RepositorySnapshotSchema.version,
                actual: actual
            )
        }

        if case .success(let decoded) = primaryResult {
            return SharedSnapshotRead(
                snapshot: decoded.snapshot,
                source: decoded.wasMigrated ? .migratedPrimary : .primary
            )
        }

        if case .success(let decoded) = backupResult {
            let recovered = decoded.snapshot.downgradedForPersistenceRecovery(
                reason: "共享主快照不可用，当前使用最后验证备份，等待再次刷新确认。",
                state: .recovered
            )
            return SharedSnapshotRead(snapshot: recovered, source: .backup)
        }

        guard case .failure(let primaryFailure) = primaryResult,
              case .failure(let backupFailure) = backupResult else {
            throw AppGroupStoreError.readFailed("snapshot selection reached an invalid state")
        }
        if primaryFailure == .missing, backupFailure == .missing {
            throw AppGroupStoreError.snapshotMissing
        }
        throw AppGroupStoreError.recoveryFailed(
            primary: primaryFailure.description,
            backup: backupFailure.description
        )
    }

    private func decodeFile(at url: URL) -> Result<DecodedFile, SnapshotFileFailure> {
        guard fileManager.fileExists(atPath: url.path) else {
            return .failure(.missing)
        }

        let bytes: Data
        do {
            bytes = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            return .failure(.read(error.localizedDescription))
        }
        guard !bytes.isEmpty else {
            return .failure(.invalid("file is empty"))
        }

        let decoder = JSONDecoder()
        let versionHeader: SnapshotVersionHeader
        do {
            // Decode the version in isolation. A future schema may introduce
            // enum values or field shapes this process cannot decode, but the
            // version guard must still recognize and protect that artifact.
            versionHeader = try decoder.decode(SnapshotVersionHeader.self, from: bytes)
        } catch {
            return .failure(.decode("schema header: \(error.localizedDescription)"))
        }

        if versionHeader.schemaVersion > RepositorySnapshotSchema.version {
            return .failure(.futureSchema(versionHeader.schemaVersion))
        }

        guard versionHeader.schemaVersion >= RepositorySnapshotSchema.oldestMigratableVersion else {
            return .failure(.unsupportedSchema(versionHeader.schemaVersion))
        }

        if versionHeader.schemaVersion == RepositorySnapshotSchema.version {
            let metadataHeader: CurrentSnapshotMetadataHeader
            do {
                metadataHeader = try decoder.decode(
                    CurrentSnapshotMetadataHeader.self,
                    from: bytes
                )
            } catch {
                return .failure(.decode("persistence header: \(error.localizedDescription)"))
            }
            guard metadataHeader.writtenAt != nil else {
                return .failure(.invalid("schema-v2 writtenAt field is missing"))
            }
            guard metadataHeader.storageRevision != nil else {
                return .failure(.invalid("schema-v2 storageRevision field is missing"))
            }
            guard metadataHeader.persistenceState != nil else {
                return .failure(.invalid("schema-v2 persistenceState field is missing"))
            }
        }

        let decoded: AppGroupData
        do {
            decoded = try decoder.decode(AppGroupData.self, from: bytes)
        } catch {
            return .failure(.decode(error.localizedDescription))
        }

        if versionHeader.schemaVersion == RepositorySnapshotSchema.version {
            do {
                try validatePersistedSnapshot(decoded)
                return .success(DecodedFile(snapshot: decoded, bytes: bytes, wasMigrated: false))
            } catch {
                return .failure(.invalid(error.localizedDescription))
            }
        }

        do {
            let migrated = try migrateLegacySnapshot(decoded)
            return .success(DecodedFile(snapshot: migrated, bytes: bytes, wasMigrated: true))
        } catch {
            return .failure(.invalid(error.localizedDescription))
        }
    }

    private func migrateLegacySnapshot(_ legacy: AppGroupData) throws -> AppGroupData {
        guard legacy.schemaVersion == RepositorySnapshotSchema.oldestMigratableVersion else {
            throw SnapshotValidationError(
                "no migration is available for schema v\(legacy.schemaVersion)"
            )
        }
        guard DateFormatting.date(from: legacy.generatedAt) != nil else {
            throw SnapshotValidationError("legacy generatedAt is missing or invalid")
        }
        guard legacy.scanSummary.totalRepositories >= 0,
              legacy.scanSummary.changedRepositories >= 0,
              legacy.scanSummary.totalChangedFiles >= 0,
              legacy.scanSummary.errorRepositories >= 0 else {
            throw SnapshotValidationError("legacy scanSummary contains negative values")
        }
        // `RepositoryIdentity.normalize` rebuilds the summary, so reject
        // impossible counts (including cross-repository overflow) first.
        try validateRepositoryCounts(legacy.repositories)

        let normalized = RepositoryIdentity.normalize(legacy)
        let validWrittenAt = legacy.writtenAt.flatMap {
            DateFormatting.date(from: $0) == nil ? nil : $0
        }
        let validLastSuccessfulRefreshAt = legacy.lastSuccessfulRefreshAt.flatMap {
            DateFormatting.date(from: $0) == nil ? nil : $0
        }
        let migrated = normalized.withPersistenceMetadata(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: normalized.generatedAt,
            writtenAt: validWrittenAt,
            lastSuccessfulRefreshAt: validLastSuccessfulRefreshAt,
            storageRevision: 0,
            persistenceState: .migrated
        ).downgradedForPersistenceRecovery(
            reason: "旧版共享快照已迁移，等待再次刷新确认。",
            state: .migrated
        )
        try validateMigratedSnapshot(migrated)
        return migrated
    }

    // MARK: - Commit

    private func commitUnlocked(_ candidate: AppGroupData) throws -> AppGroupData {
        let baseline = try commitBaselineUnlocked()
        // Future-schema checks above happen before any cleanup or write.
        try cleanupTemporaryFilesUnlocked()
        let prepared = try prepare(candidate, previous: baseline.snapshot)
        try validatePersistedSnapshot(prepared)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let encoded: Data
        do {
            encoded = try encoder.encode(prepared)
        } catch {
            throw AppGroupStoreError.writeFailed("encode failed: \(error.localizedDescription)")
        }

        let stagingURL = makeTemporaryURL()
        defer { try? fileManager.removeItem(at: stagingURL) }
        do {
            try encoded.write(to: stagingURL, options: [.withoutOverwriting])
            try synchronizeFile(at: stagingURL)
            try failureInjector?(.afterStaging)
        } catch {
            throw AppGroupStoreError.writeFailed("staging failed: \(error.localizedDescription)")
        }

        switch decodeFile(at: stagingURL) {
        case .success(let staged) where !staged.wasMigrated && staged.snapshot == prepared:
            break
        case .success:
            throw AppGroupStoreError.verificationFailed(
                "Staged snapshot does not equal the prepared payload."
            )
        case .failure(let failure):
            throw AppGroupStoreError.verificationFailed(
                "Staged snapshot is invalid: \(failure.description)"
            )
        }

        // Establish and durably synchronize one verified recovery copy before
        // the only commit point. If neither artifact is valid, the fully
        // verified candidate itself becomes that recovery copy.
        try prepareRecoveryCopy(
            baseline: baseline,
            candidateBytes: encoded
        )

        do {
            try failureInjector?(.beforePrimaryReplacement)
        } catch {
            throw AppGroupStoreError.writeFailed(
                "interrupted before primary replacement: \(error.localizedDescription)"
            )
        }

        // This atomic rename is the commit point. The source bytes were fully
        // synchronized and decoded above, so returning failure after this line
        // would make the API disagree with the visible on-disk generation.
        guard Darwin.rename(stagingURL.path, primaryURL.path) == 0 else {
            throw AppGroupStoreError.writeFailed(
                "atomic primary replacement failed: \(posixDescription())"
            )
        }
        synchronizeDirectoryBestEffort()

        do {
            try failureInjector?(.afterPrimaryReplacement)
        } catch {
            // The commit point has already succeeded. A post-commit test hook
            // can only skip best-effort backup advancement, never change the
            // operation into an apparent failure.
            return prepared
        }

        // Advance the backup when possible. A failure cannot invalidate the
        // commit: `prepareRecoveryCopy` already left a verified fallback, and
        // `atomicWrite` never exposes a partial destination.
        refreshRecoveryCopyAfterCommit(encoded)
        return prepared
    }

    private func commitBaselineUnlocked() throws -> CommitBaseline {
        let primary = decodeFile(at: primaryURL)
        let backup = decodeFile(at: backupURL)

        if case .failure(.futureSchema(let actual)) = primary {
            throw AppGroupStoreError.schemaVersionMismatch(
                expected: RepositorySnapshotSchema.version,
                actual: actual
            )
        }
        if case .failure(.futureSchema(let actual)) = backup {
            // Even when the primary is readable, an older writer must not
            // destroy a recovery artifact written by a newer app version.
            throw AppGroupStoreError.schemaVersionMismatch(
                expected: RepositorySnapshotSchema.version,
                actual: actual
            )
        }

        let validPrimary: DecodedFile?
        if case .success(let decoded) = primary {
            validPrimary = decoded
        } else {
            validPrimary = nil
        }
        let validBackup: DecodedFile?
        if case .success(let decoded) = backup {
            validBackup = decoded
        } else {
            validBackup = nil
        }

        if let validPrimary {
            if let validBackup,
               backupIsNewer(primary: validPrimary.snapshot, backup: validBackup.snapshot) {
                return CommitBaseline(
                    snapshot: validBackup.snapshot,
                    recoveryCopyPlan: .preserveExistingBackup
                )
            }
            return CommitBaseline(
                snapshot: validPrimary.snapshot,
                recoveryCopyPlan: .publish(validPrimary.bytes)
            )
        }

        if let validBackup {
            let recovered = validBackup.snapshot.downgradedForPersistenceRecovery(
                reason: "共享主快照不可用，写入前已采用最后验证备份作为时间水位。",
                state: .recovered
            )
            return CommitBaseline(
                snapshot: recovered,
                recoveryCopyPlan: .preserveExistingBackup
            )
        }

        // A complete, validated current scan may establish a new first
        // snapshot when neither artifact is recoverable. Invalid artifacts
        // remain untouched until a verified recovery copy has been published.
        return CommitBaseline(snapshot: nil, recoveryCopyPlan: .publishCandidate)
    }

    private func backupIsNewer(
        primary: AppGroupData,
        backup: AppGroupData
    ) -> Bool {
        if backup.storageRevision != primary.storageRevision {
            return backup.storageRevision > primary.storageRevision
        }
        let primaryWrittenAt = primary.writtenAt.flatMap {
            DateFormatting.date(from: $0)
        }
        let backupWrittenAt = backup.writtenAt.flatMap {
            DateFormatting.date(from: $0)
        }
        if let primaryWrittenAt, let backupWrittenAt, backupWrittenAt > primaryWrittenAt {
            return true
        }
        return false
    }

    private func prepare(
        _ candidate: AppGroupData,
        previous: AppGroupData?
    ) throws -> AppGroupData {
        guard let candidateGeneratedDate = DateFormatting.date(from: candidate.generatedAt) else {
            throw AppGroupStoreError.invalidSnapshot("generatedAt is missing or invalid")
        }

        let candidateSuccessful: (String, Date)?
        if let timestamp = candidate.lastSuccessfulRefreshAt {
            guard let date = DateFormatting.date(from: timestamp) else {
                throw AppGroupStoreError.invalidSnapshot(
                    "lastSuccessfulRefreshAt is invalid"
                )
            }
            candidateSuccessful = (timestamp, date)
        } else {
            candidateSuccessful = nil
        }

        let previousGenerated = try parsedTimestamp(
            previous?.generatedAt,
            field: "previous generatedAt"
        )
        let previousSuccessful = try parsedTimestamp(
            previous?.lastSuccessfulRefreshAt,
            field: "previous lastSuccessfulRefreshAt"
        )
        let previousWritten = try parsedTimestamp(
            previous?.writtenAt,
            field: "previous writtenAt"
        )

        let generated = latestTimestamp(
            [(candidate.generatedAt, candidateGeneratedDate), previousGenerated].compactMap { $0 }
        )!
        let successful = latestTimestamp(
            [candidateSuccessful, previousSuccessful].compactMap { $0 }
        )
        let nowValue = now()
        let nowTimestamp = DateFormatting.isoString(from: nowValue)
        let written = latestTimestamp(
            [
                (nowTimestamp, nowValue),
                previousWritten,
                generated,
                successful
            ].compactMap { $0 }
        )!

        let previousRevision = previous?.storageRevision ?? 0
        guard previousRevision < UInt64.max else {
            throw AppGroupStoreError.invalidSnapshot("storageRevision overflow")
        }

        return candidate.withPersistenceMetadata(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: generated.0,
            writtenAt: written.0,
            lastSuccessfulRefreshAt: successful?.0,
            storageRevision: previousRevision + 1,
            persistenceState: candidate.persistenceState
        )
    }

    // MARK: - Validation

    private func validatePersistedSnapshot(_ snapshot: AppGroupData) throws {
        guard snapshot.schemaVersion == RepositorySnapshotSchema.version else {
            throw SnapshotValidationError(
                "expected schema v\(RepositorySnapshotSchema.version), found v\(snapshot.schemaVersion)"
            )
        }
        guard snapshot.storageRevision > 0 else {
            throw SnapshotValidationError("storageRevision must be greater than zero")
        }
        guard let generatedDate = DateFormatting.date(from: snapshot.generatedAt) else {
            throw SnapshotValidationError("generatedAt is missing or invalid")
        }
        guard let writtenTimestamp = snapshot.writtenAt,
              let writtenDate = DateFormatting.date(from: writtenTimestamp) else {
            throw SnapshotValidationError("writtenAt is missing or invalid")
        }
        if writtenDate < generatedDate {
            throw SnapshotValidationError("writtenAt precedes generatedAt")
        }
        if let successfulTimestamp = snapshot.lastSuccessfulRefreshAt {
            guard let successfulDate = DateFormatting.date(from: successfulTimestamp) else {
                throw SnapshotValidationError("lastSuccessfulRefreshAt is invalid")
            }
            guard writtenDate >= successfulDate else {
                throw SnapshotValidationError("writtenAt precedes lastSuccessfulRefreshAt")
            }
        }

        try validateRepositoryPayload(snapshot)
    }

    private func validateMigratedSnapshot(_ snapshot: AppGroupData) throws {
        guard snapshot.schemaVersion == RepositorySnapshotSchema.version else {
            throw SnapshotValidationError("migration did not produce the current schema")
        }
        guard snapshot.storageRevision == 0,
              snapshot.persistenceState == .migrated else {
            throw SnapshotValidationError("migration metadata is inconsistent")
        }
        guard DateFormatting.date(from: snapshot.generatedAt) != nil else {
            throw SnapshotValidationError("migrated generatedAt is missing or invalid")
        }
        if let writtenAt = snapshot.writtenAt,
           DateFormatting.date(from: writtenAt) == nil {
            throw SnapshotValidationError("migrated writtenAt is invalid")
        }
        if let successfulAt = snapshot.lastSuccessfulRefreshAt,
           DateFormatting.date(from: successfulAt) == nil {
            throw SnapshotValidationError("migrated lastSuccessfulRefreshAt is invalid")
        }

        try validateRepositoryPayload(snapshot)
    }

    private func validateRepositoryPayload(_ snapshot: AppGroupData) throws {
        // This must precede every `ScanSummary.build` call below. The model's
        // summary builder intentionally assumes already-validated app data and
        // uses ordinary integer addition.
        try validateRepositoryCounts(snapshot.repositories)

        for repository in snapshot.repositories {
            guard let source = repository.dataSource else {
                throw SnapshotValidationError(
                    "repository \(repository.id) has no explicit dataSource"
                )
            }
            guard DateFormatting.date(from: repository.lastScannedAt) != nil else {
                throw SnapshotValidationError(
                    "repository \(repository.id) has invalid lastScannedAt"
                )
            }
            if source == .current || source == .lastSuccessful {
                guard let successfulAt = repository.lastSuccessfulScanAt,
                      DateFormatting.date(from: successfulAt) != nil else {
                    throw SnapshotValidationError(
                        "repository \(repository.id) lacks a valid successful scan time"
                    )
                }
            }
            if source == .current,
               repository.status == .error || repository.errorMessage != nil {
                throw SnapshotValidationError(
                    "repository \(repository.id) marks failed data as current"
                )
            }
        }

        if snapshot.persistenceState != .committed,
           snapshot.repositories.contains(where: { $0.resolvedDataSource == .current }) {
            throw SnapshotValidationError(
                "recovered or migrated snapshots cannot contain current repository data"
            )
        }

        let summary = snapshot.scanSummary
        guard summary.totalRepositories >= snapshot.repositories.count,
              summary.changedRepositories >= 0,
              summary.totalChangedFiles >= 0,
              summary.errorRepositories >= 0 else {
            throw SnapshotValidationError("scanSummary contains impossible counts")
        }
        let expectedSummary = ScanSummary.build(
            from: snapshot.repositories,
            totalRepositories: summary.totalRepositories
        )
        guard expectedSummary == summary else {
            throw SnapshotValidationError("scanSummary does not match repository payload")
        }
    }

    private func validateRepositoryCounts(
        _ repositories: [RepositorySnapshot]
    ) throws {
        var totalChangedFiles = 0
        for repository in repositories {
            let requiredCounts = [
                repository.modifiedFileCount,
                repository.addedFileCount,
                repository.deletedFileCount,
                repository.untrackedFileCount,
                repository.changedFileCount
            ]
            guard requiredCounts.allSatisfy({ $0 >= 0 }) else {
                throw SnapshotValidationError(
                    "repository \(repository.id) contains negative change counts"
                )
            }
            let optionalCounts = [
                repository.stagedFileCount,
                repository.unstagedFileCount,
                repository.conflictedFileCount,
                repository.aheadCount,
                repository.behindCount
            ].compactMap { $0 }
            guard optionalCounts.allSatisfy({ $0 >= 0 }) else {
                throw SnapshotValidationError(
                    "repository \(repository.id) contains negative optional counts"
                )
            }
            var categorizedChangeCount = 0
            for count in [
                repository.modifiedFileCount,
                repository.addedFileCount,
                repository.deletedFileCount,
                repository.untrackedFileCount
            ] {
                let addition = categorizedChangeCount.addingReportingOverflow(count)
                guard !addition.overflow else {
                    throw SnapshotValidationError(
                        "repository \(repository.id) change counts overflow"
                    )
                }
                categorizedChangeCount = addition.partialValue
            }
            guard categorizedChangeCount == repository.changedFileCount else {
                throw SnapshotValidationError(
                    "repository \(repository.id) change counts are inconsistent"
                )
            }
            guard repository.changedFilesPreview.count <= repository.changedFileCount,
                  (repository.stagedFileCount ?? 0) <= repository.changedFileCount,
                  (repository.unstagedFileCount ?? 0) <= repository.changedFileCount,
                  (repository.conflictedFileCount ?? 0) <= repository.changedFileCount else {
                throw SnapshotValidationError(
                    "repository \(repository.id) derived counts exceed total changes"
                )
            }
            let totalAddition = totalChangedFiles.addingReportingOverflow(
                repository.changedFileCount
            )
            guard !totalAddition.overflow else {
                throw SnapshotValidationError(
                    "repository change-count total overflows"
                )
            }
            totalChangedFiles = totalAddition.partialValue
        }
    }

    // MARK: - File transaction helpers

    private func atomicWrite(_ bytes: Data, to destination: URL) throws {
        let temporaryURL = makeTemporaryURL()
        defer { try? fileManager.removeItem(at: temporaryURL) }
        do {
            try bytes.write(to: temporaryURL, options: [.withoutOverwriting])
            try synchronizeFile(at: temporaryURL)
        } catch {
            throw AppGroupStoreError.writeFailed(
                "failed to stage \(destination.lastPathComponent): \(error.localizedDescription)"
            )
        }
        guard Darwin.rename(temporaryURL.path, destination.path) == 0 else {
            throw AppGroupStoreError.writeFailed(
                "failed to replace \(destination.lastPathComponent): \(posixDescription())"
            )
        }
        try synchronizeDirectory()
    }

    private func prepareRecoveryCopy(
        baseline: CommitBaseline,
        candidateBytes: Data
    ) throws {
        switch baseline.recoveryCopyPlan {
        case .publish(let bytes):
            // Never preserve a damaged primary over a valid backup.
            try atomicWrite(bytes, to: backupURL)
        case .preserveExistingBackup:
            // The existing backup was decoded successfully. Re-sync it so the
            // following primary replacement always has a durable fallback.
            try synchronizeFile(at: backupURL)
            try synchronizeDirectory()
        case .publishCandidate:
            try atomicWrite(candidateBytes, to: backupURL)
        }
    }

    private func refreshRecoveryCopyAfterCommit(_ committedBytes: Data) {
        do {
            try atomicWrite(committedBytes, to: backupURL)
        } catch {
            // The pre-commit recovery copy remains valid. This is deliberately
            // non-fatal because the primary rename is the sole commit point.
        }
    }

    private func cleanupTemporaryFilesUnlocked() throws {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return }
        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            // The staging files are hidden, so retry without skipping them.
            do {
                contents = try fileManager.contentsOfDirectory(
                    at: directoryURL,
                    includingPropertiesForKeys: nil
                )
            } catch {
                throw AppGroupStoreError.writeFailed(
                    "temporary-file enumeration failed: \(error.localizedDescription)"
                )
            }
        }

        // `skipsHiddenFiles` normally hides every candidate. If it returned no
        // matches, enumerate once without that option so abandoned files are
        // still removed on normal App startup.
        let candidates: [URL]
        if contents.contains(where: { $0.lastPathComponent.hasPrefix(temporaryFilePrefix) }) {
            candidates = contents
        } else {
            candidates = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil
            )
        }
        for url in candidates where url.lastPathComponent.hasPrefix(temporaryFilePrefix) {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                throw AppGroupStoreError.writeFailed(
                    "temporary-file cleanup failed: \(error.localizedDescription)"
                )
            }
        }
    }

    private func makeTemporaryURL() -> URL {
        directoryURL.appendingPathComponent("\(temporaryFilePrefix)\(UUID().uuidString)")
    }

    private func synchronizeFile(at url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw AppGroupStoreError.writeFailed(
                "failed to open staged file for synchronization: \(posixDescription())"
            )
        }
        defer { Darwin.close(descriptor) }

        if Darwin.fcntl(descriptor, F_FULLFSYNC) == 0 {
            return
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw AppGroupStoreError.writeFailed(
                "failed to synchronize staged file: \(posixDescription())"
            )
        }
    }

    private func synchronizeDirectoryBestEffort() {
        try? synchronizeDirectory()
    }

    private func synchronizeDirectory() throws {
        let descriptor = Darwin.open(directoryURL.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw AppGroupStoreError.writeFailed(
                "failed to open snapshot directory for synchronization: \(posixDescription())"
            )
        }
        defer { Darwin.close(descriptor) }

        if Darwin.fcntl(descriptor, F_FULLFSYNC) == 0 {
            return
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw AppGroupStoreError.writeFailed(
                "failed to synchronize snapshot directory: \(posixDescription())"
            )
        }
    }

    // MARK: - Cross-process lock

    private enum LockMode {
        case shared
        case exclusive
    }

    private func withFileLock<T>(_ mode: LockMode, body: () throws -> T) throws -> T {
        _ = mode
        Self.processLock.lock()
        defer { Self.processLock.unlock() }

        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw AppGroupStoreError.lockFailed(posixDescription())
        }
        defer { Darwin.close(descriptor) }

        // `lockf` deliberately uses one exclusive whole-file lock for reads and
        // writes. Snapshot files are tiny, and serial recovery selection avoids
        // observing a primary/backup pair from different commit generations.
        while Darwin.lockf(descriptor, F_LOCK, 0) != 0 {
            if errno == EINTR { continue }
            throw AppGroupStoreError.lockFailed(posixDescription())
        }
        defer { _ = Darwin.lockf(descriptor, F_ULOCK, 0) }
        return try body()
    }

    // MARK: - Timestamp helpers

    private func parsedTimestamp(
        _ timestamp: String?,
        field: String
    ) throws -> (String, Date)? {
        guard let timestamp else { return nil }
        guard let date = DateFormatting.date(from: timestamp) else {
            throw AppGroupStoreError.invalidSnapshot("\(field) is invalid")
        }
        return (timestamp, date)
    }

    private func latestTimestamp(
        _ timestamps: [(String, Date)]
    ) -> (String, Date)? {
        timestamps.max { lhs, rhs in lhs.1 < rhs.1 }
    }

    private func posixDescription() -> String {
        String(cString: strerror(errno))
    }
}

private struct SnapshotVersionHeader: Decodable {
    let schemaVersion: Int
}

private struct CurrentSnapshotMetadataHeader: Decodable {
    let writtenAt: String?
    let storageRevision: UInt64?
    let persistenceState: SharedSnapshotPersistenceState?
}

private struct DecodedFile {
    let snapshot: AppGroupData
    let bytes: Data
    let wasMigrated: Bool
}

private struct CommitBaseline {
    let snapshot: AppGroupData?
    let recoveryCopyPlan: RecoveryCopyPlan
}

private enum RecoveryCopyPlan {
    case publish(Data)
    case preserveExistingBackup
    case publishCandidate
}

private struct SnapshotValidationError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

private enum SnapshotFileFailure: Error, Equatable {
    case missing
    case futureSchema(Int)
    case unsupportedSchema(Int)
    case read(String)
    case decode(String)
    case invalid(String)

    var description: String {
        switch self {
        case .missing:
            return "file is missing"
        case .futureSchema(let version):
            return "future schema v\(version) is not supported"
        case .unsupportedSchema(let version):
            return "schema v\(version) has no safe migration"
        case .read(let reason):
            return "read failed: \(reason)"
        case .decode(let reason):
            return "decode failed: \(reason)"
        case .invalid(let reason):
            return "validation failed: \(reason)"
        }
    }
}
