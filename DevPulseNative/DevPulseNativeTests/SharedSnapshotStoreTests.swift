import Foundation
import Testing
@testable import DevPulse

struct SharedSnapshotStoreTests {
    @Test func beforePrimaryReplacementFailurePreservesPrimaryAndCleansCurrentTemporaryFile() throws {
        let directory = try temporaryDirectory()
        defer { removeTemporaryDirectory(directory) }

        let baselineStore = store(in: directory, now: date("2026-07-18T10:00:00Z"))
        let original = fixture(label: "A", timestamp: "2026-07-18T09:00:00Z")
        try requireSuccess(baselineStore.commit(original))
        let primaryBytes = try Data(contentsOf: baselineStore.primaryURL)

        let failingStore = SharedSnapshotStore(
            directoryURL: directory,
            fileName: "repositories.json",
            now: { Self.date("2026-07-18T10:01:00Z") },
            failureInjector: { phase in
                if phase == .beforePrimaryReplacement {
                    throw InjectedFailure.beforePrimaryReplacement
                }
            }
        )

        switch failingStore.commit(fixture(label: "B", timestamp: "2026-07-18T10:01:00Z")) {
        case .success:
            Issue.record("Injected replacement failure unexpectedly committed a snapshot.")
        case .failure:
            break
        }

        #expect(try Data(contentsOf: baselineStore.primaryURL) == primaryBytes)
        let loaded = try requireSuccess(baselineStore.load())
        #expect(loaded.snapshot.repositories.map(\.id) == ["A"])
        #expect(temporaryFiles(in: directory, prefix: baselineStore.temporaryFilePrefix).isEmpty)
    }

    @Test func interruptedFirstCommitLeavesVerifiedBackupForRecovery() throws {
        let directory = try temporaryDirectory()
        defer { removeTemporaryDirectory(directory) }

        let snapshotStore = SharedSnapshotStore(
            directoryURL: directory,
            fileName: "repositories.json",
            now: { Self.date("2026-07-18T10:00:00Z") },
            failureInjector: { phase in
                if phase == .beforePrimaryReplacement {
                    throw InjectedFailure.beforePrimaryReplacement
                }
            }
        )

        switch snapshotStore.commit(
            fixture(label: "recoverable", timestamp: "2026-07-18T09:00:00Z")
        ) {
        case .success:
            Issue.record("Interrupted first commit unexpectedly reached its commit point.")
        case .failure:
            break
        }

        #expect(FileManager.default.fileExists(atPath: snapshotStore.primaryURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: snapshotStore.backupURL.path))
        let recovered = try requireSuccess(snapshotStore.load())
        #expect(recovered.source == .backup)
        #expect(recovered.snapshot.repositories.first?.id == "recoverable")
        #expect(recovered.snapshot.persistenceState == .recovered)
        #expect(recovered.snapshot.repositories.first?.resolvedDataSource != .current)
        #expect(temporaryFiles(in: directory, prefix: snapshotStore.temporaryFilePrefix).isEmpty)
    }

    @Test func postCommitFailureCannotTurnPublishedSnapshotIntoReportedFailure() throws {
        let directory = try temporaryDirectory()
        defer { removeTemporaryDirectory(directory) }

        let snapshotStore = SharedSnapshotStore(
            directoryURL: directory,
            fileName: "repositories.json",
            now: { Self.date("2026-07-18T10:00:00Z") },
            failureInjector: { phase in
                if phase == .afterPrimaryReplacement {
                    throw InjectedFailure.afterPrimaryReplacement
                }
            }
        )

        let committed = try requireSuccess(
            snapshotStore.commit(
                fixture(label: "published", timestamp: "2026-07-18T09:00:00Z")
            )
        )
        #expect(committed.repositories.first?.id == "published")

        let primary = try requireSuccess(snapshotStore.load())
        #expect(primary.source == .primary)
        #expect(primary.snapshot == committed)

        try Data("damaged primary".utf8).write(to: snapshotStore.primaryURL)
        let recovered = try requireSuccess(snapshotStore.load())
        #expect(recovered.source == .backup)
        #expect(recovered.snapshot.repositories.first?.id == "published")
    }

    @Test func concurrentSingleWriterAndReadersOnlyObserveCompleteSnapshots() async throws {
        let directory = try temporaryDirectory()
        defer { removeTemporaryDirectory(directory) }

        let initialStore = store(in: directory, now: date("2026-07-18T10:00:00Z"))
        try requireSuccess(initialStore.commit(fixture(label: "A", timestamp: "2026-07-18T09:00:00Z")))

        let collector = ConcurrentReadCollector()
        let writerPayloadA = fixture(label: "A", timestamp: "2026-07-18T10:00:00Z")
        let writerPayloadB = fixture(label: "B", timestamp: "2026-07-18T10:01:00Z")

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                let writer = Self.store(in: directory, now: Self.date("2026-07-18T10:02:00Z"))
                for index in 0..<80 {
                    let payload = index.isMultiple(of: 2) ? writerPayloadA : writerPayloadB
                    if case .failure(let error) = writer.commit(payload) {
                        await collector.record("writer: \(error.localizedDescription)")
                    }
                }
            }

            for readerIndex in 0..<4 {
                group.addTask {
                    let reader = Self.store(in: directory, now: Self.date("2026-07-18T10:02:00Z"))
                    for _ in 0..<160 {
                        switch reader.load() {
                        case .success(let read):
                            let repositories = read.snapshot.repositories
                            guard repositories.count == 1,
                                  repositories[0].id == "A" || repositories[0].id == "B",
                                  repositories[0].changedFilesPreview == ["\(repositories[0].id).swift"],
                                  read.snapshot.scanSummary.totalRepositories == 1 else {
                                await collector.record("reader \(readerIndex): partial or unexpected snapshot")
                                continue
                            }
                        case .failure(let error):
                            await collector.record("reader \(readerIndex): \(error.localizedDescription)")
                        }
                    }
                }
            }
        }

        let errors = await collector.errors()
        #expect(errors.isEmpty)
    }

    @Test func schemaV1WithoutNewFieldsMigratesToCurrentSchemaAndMarksSnapshot() throws {
        let directory = try temporaryDirectory()
        defer { removeTemporaryDirectory(directory) }

        let snapshot = fixture(label: "legacy", timestamp: "2026-07-18T09:00:00Z")
        let legacyBytes = try legacyV1JSON(from: snapshot)
        let snapshotStore = store(in: directory, now: date("2026-07-18T10:00:00Z"))
        try legacyBytes.write(to: snapshotStore.primaryURL)

        let read = try requireSuccess(snapshotStore.load())
        #expect(read.source == .migratedPrimary)
        #expect(read.snapshot.schemaVersion == RepositorySnapshotSchema.version)
        #expect(read.snapshot.persistenceState == .migrated)
        #expect(read.snapshot.repositories.first?.resolvedDataSource != .current)
    }

    @Test func currentSchemaSnapshotWithoutWorkspaceKindRemainsReadable() throws {
        let directory = try temporaryDirectory()
        defer { removeTemporaryDirectory(directory) }

        let snapshot = fixture(label: "pre-worktree-kind", timestamp: "2026-07-18T09:00:00Z")
        let snapshotStore = store(in: directory, now: date("2026-07-18T10:00:00Z"))
        let committed = try requireSuccess(snapshotStore.commit(snapshot))
        var object = try jsonObject(from: committed)
        var repositories = try #require(object["repositories"] as? [[String: Any]])
        repositories[0].removeValue(forKey: "workspaceKind")
        object["repositories"] = repositories
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try bytes.write(to: snapshotStore.primaryURL)

        let read = try requireSuccess(snapshotStore.load())
        #expect(read.source == .primary)
        #expect(read.snapshot.schemaVersion == RepositorySnapshotSchema.version)
        #expect(read.snapshot.repositories.first?.workspaceKind == nil)
    }

    @Test func structurallyInvalidSchemaV1CannotBeMigratedAsTrustedData() throws {
        let directory = try temporaryDirectory()
        defer { removeTemporaryDirectory(directory) }

        let snapshot = fixture(label: "legacy", timestamp: "2026-07-18T09:00:00Z")
        var legacy = try #require(
            JSONSerialization.jsonObject(with: legacyV1JSON(from: snapshot))
                as? [String: Any]
        )
        var repositories = try #require(legacy["repositories"] as? [[String: Any]])
        repositories[0]["lastScannedAt"] = "not-a-timestamp"
        legacy["repositories"] = repositories
        let invalidBytes = try JSONSerialization.data(
            withJSONObject: legacy,
            options: [.sortedKeys]
        )

        let snapshotStore = store(in: directory, now: date("2026-07-18T10:00:00Z"))
        try invalidBytes.write(to: snapshotStore.primaryURL)

        switch snapshotStore.load() {
        case .success:
            Issue.record("Structurally invalid schema-v1 data was incorrectly migrated.")
        case .failure:
            break
        }
        #expect(try Data(contentsOf: snapshotStore.primaryURL) == invalidBytes)
        #expect(FileManager.default.fileExists(atPath: snapshotStore.backupURL.path) == false)
    }

    @Test func schemaV1WithNegativeRepositoryCountsCannotBeMigrated() throws {
        let directory = try temporaryDirectory()
        defer { removeTemporaryDirectory(directory) }

        let snapshot = fixture(label: "legacy", timestamp: "2026-07-18T09:00:00Z")
        var legacy = try #require(
            JSONSerialization.jsonObject(with: legacyV1JSON(from: snapshot))
                as? [String: Any]
        )
        var repositories = try #require(legacy["repositories"] as? [[String: Any]])
        repositories[0]["stagedFileCount"] = -1
        legacy["repositories"] = repositories
        let invalidBytes = try JSONSerialization.data(
            withJSONObject: legacy,
            options: [.sortedKeys]
        )

        let snapshotStore = store(in: directory, now: date("2026-07-18T10:00:00Z"))
        try invalidBytes.write(to: snapshotStore.primaryURL)

        switch snapshotStore.load() {
        case .success:
            Issue.record("Schema-v1 data with negative counts was incorrectly migrated.")
        case .failure:
            break
        }
        #expect(try Data(contentsOf: snapshotStore.primaryURL) == invalidBytes)
        #expect(FileManager.default.fileExists(atPath: snapshotStore.backupURL.path) == false)
    }

    @Test func schemaV1CrossRepositoryCountOverflowIsRejectedBeforeMigration() throws {
        let directory = try temporaryDirectory()
        defer { removeTemporaryDirectory(directory) }

        let snapshotStore = store(in: directory, now: date("2026-07-18T10:00:00Z"))
        let invalidBytes = try crossRepositoryOverflowJSON(
            schemaVersion: RepositorySnapshotSchema.oldestMigratableVersion
        )
        try invalidBytes.write(to: snapshotStore.primaryURL)

        switch snapshotStore.load() {
        case .success:
            Issue.record("Overflowing schema-v1 repository totals were incorrectly migrated.")
        case .failure:
            break
        }
        #expect(try Data(contentsOf: snapshotStore.primaryURL) == invalidBytes)
    }

    @Test func schemaV2CrossRepositoryCountOverflowIsRejectedWithoutTrap() throws {
        let directory = try temporaryDirectory()
        defer { removeTemporaryDirectory(directory) }

        let snapshotStore = store(in: directory, now: date("2026-07-18T10:00:00Z"))
        let invalidBytes = try crossRepositoryOverflowJSON(
            schemaVersion: RepositorySnapshotSchema.version
        )
        try invalidBytes.write(to: snapshotStore.primaryURL)

        switch snapshotStore.load() {
        case .success:
            Issue.record("Overflowing schema-v2 repository totals were incorrectly accepted.")
        case .failure:
            break
        }
        #expect(try Data(contentsOf: snapshotStore.primaryURL) == invalidBytes)
    }

    @Test func schemaV2MissingPersistenceStateCannotBeTreatedAsCommitted() throws {
        let directory = try temporaryDirectory()
        defer { removeTemporaryDirectory(directory) }

        let snapshotStore = store(in: directory, now: date("2026-07-18T10:00:00Z"))
        try requireSuccess(
            snapshotStore.commit(fixture(label: "A", timestamp: "2026-07-18T09:00:00Z"))
        )
        var incomplete = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: snapshotStore.primaryURL)
            ) as? [String: Any]
        )
        incomplete.removeValue(forKey: "persistenceState")
        try JSONSerialization.data(withJSONObject: incomplete, options: [.sortedKeys])
            .write(to: snapshotStore.primaryURL)

        let read = try requireSuccess(snapshotStore.load())
        #expect(read.source == .backup)
        #expect(read.snapshot.persistenceState == .recovered)
        #expect(read.snapshot.repositories.first?.resolvedDataSource != .current)
    }

    @Test func corruptedPrimaryRecoversFromValidBackupAndMarksRepositoryNonCurrent() throws {
        let directory = try temporaryDirectory()
        defer { removeTemporaryDirectory(directory) }

        let snapshotStore = store(in: directory, now: date("2026-07-18T10:00:00Z"))
        try requireSuccess(snapshotStore.commit(fixture(label: "A", timestamp: "2026-07-18T09:00:00Z")))
        try requireSuccess(snapshotStore.commit(fixture(label: "B", timestamp: "2026-07-18T09:01:00Z")))
        try Data("not json".utf8).write(to: snapshotStore.primaryURL)

        let read = try requireSuccess(snapshotStore.load())
        #expect(read.source == .backup)
        #expect(read.snapshot.persistenceState == .recovered)
        #expect(read.snapshot.repositories.first?.id == "B")
        #expect(read.snapshot.repositories.first?.resolvedDataSource != .current)
    }

    @Test func corruptedPrimaryAndBackupFailWithoutOverwritingEitherFileOrCreatingEmptySnapshot() throws {
        let directory = try temporaryDirectory()
        defer { removeTemporaryDirectory(directory) }

        let snapshotStore = store(in: directory, now: date("2026-07-18T10:00:00Z"))
        try requireSuccess(snapshotStore.commit(fixture(label: "A", timestamp: "2026-07-18T09:00:00Z")))
        try requireSuccess(snapshotStore.commit(fixture(label: "B", timestamp: "2026-07-18T09:01:00Z")))

        let damagedPrimary = Data("damaged primary".utf8)
        let damagedBackup = Data("damaged backup".utf8)
        try damagedPrimary.write(to: snapshotStore.primaryURL)
        try damagedBackup.write(to: snapshotStore.backupURL)

        switch snapshotStore.load() {
        case .success:
            Issue.record("Two damaged snapshots unexpectedly produced data.")
        case .failure:
            break
        }

        #expect(try Data(contentsOf: snapshotStore.primaryURL) == damagedPrimary)
        #expect(try Data(contentsOf: snapshotStore.backupURL) == damagedBackup)
        #expect(temporaryFiles(in: directory, prefix: snapshotStore.temporaryFilePrefix).isEmpty)
    }

    @Test func freshCommitAfterBothArtifactsAreDamagedReestablishesTwoRecoverableCopies() throws {
        let directory = try temporaryDirectory()
        defer { removeTemporaryDirectory(directory) }

        let snapshotStore = store(in: directory, now: date("2026-07-18T10:00:00Z"))
        try Data("damaged primary".utf8).write(to: snapshotStore.primaryURL)
        try Data("damaged backup".utf8).write(to: snapshotStore.backupURL)

        let committed = try requireSuccess(
            snapshotStore.commit(
                fixture(label: "fresh", timestamp: "2026-07-18T09:00:00Z")
            )
        )
        #expect(committed.storageRevision == 1)
        #expect(FileManager.default.fileExists(atPath: snapshotStore.primaryURL.path))
        #expect(FileManager.default.fileExists(atPath: snapshotStore.backupURL.path))

        let primary = try requireSuccess(snapshotStore.load())
        #expect(primary.source == .primary)
        #expect(primary.snapshot.repositories.first?.id == "fresh")

        try Data("damaged again".utf8).write(to: snapshotStore.primaryURL)
        let recovered = try requireSuccess(snapshotStore.load())
        #expect(recovered.source == .backup)
        #expect(recovered.snapshot.repositories.first?.id == "fresh")
        #expect(recovered.snapshot.persistenceState == .recovered)
    }

    @Test func recoveredSnapshotCanCommitFreshDataWithoutMovingWatermarksOrRevisionBackward() throws {
        let directory = try temporaryDirectory()
        defer { removeTemporaryDirectory(directory) }

        let initialStore = store(in: directory, now: date("2026-07-18T10:00:00Z"))
        try requireSuccess(initialStore.commit(fixture(label: "A", timestamp: "2026-07-18T09:00:00Z")))
        try requireSuccess(initialStore.commit(fixture(label: "stale", timestamp: "2026-07-18T09:01:00Z")))
        try Data("bad primary".utf8).write(to: initialStore.primaryURL)

        let recoveryStore = store(in: directory, now: date("2026-07-18T10:02:00Z"))
        let recovered = try requireSuccess(recoveryStore.load()).snapshot
        #expect(recovered.persistenceState == .recovered)

        let freshStore = store(in: directory, now: date("2026-07-18T10:03:00Z"))
        let committed = try requireSuccess(
            freshStore.commit(fixture(label: "B", timestamp: "2026-07-18T10:03:00Z"))
        )
        let reread = try requireSuccess(freshStore.load())

        #expect(reread.source == .primary)
        #expect(reread.snapshot.persistenceState == .committed)
        #expect(reread.snapshot.repositories.first?.id == "B")
        #expect(reread.snapshot.repositories.first?.resolvedDataSource == .current)
        #expect(committed.generatedAt >= recovered.generatedAt)
        #expect((committed.lastSuccessfulRefreshAt ?? "") >= (recovered.lastSuccessfulRefreshAt ?? ""))
        #expect((committed.writtenAt ?? "") >= (recovered.writtenAt ?? ""))
        #expect(committed.storageRevision >= recovered.storageRevision)
    }

    @Test func clockRollbackCannotMovePersistedWatermarksBackward() throws {
        let directory = try temporaryDirectory()
        defer { removeTemporaryDirectory(directory) }

        let firstStore = store(in: directory, now: date("2026-07-18T10:00:00Z"))
        let first = try requireSuccess(
            firstStore.commit(fixture(label: "A", timestamp: "2026-07-18T09:00:00Z"))
        )

        let rolledBackClockStore = store(
            in: directory,
            now: date("2026-07-18T08:00:00Z")
        )
        let second = try requireSuccess(
            rolledBackClockStore.commit(
                fixture(label: "B", timestamp: "2026-07-18T08:00:00Z")
            )
        )

        #expect(second.repositories.first?.id == "B")
        #expect(DateFormatting.date(from: second.generatedAt)! >= DateFormatting.date(from: first.generatedAt)!)
        #expect(DateFormatting.date(from: second.writtenAt!)! >= DateFormatting.date(from: first.writtenAt!)!)
        #expect(
            DateFormatting.date(from: second.lastSuccessfulRefreshAt!)!
                >= DateFormatting.date(from: first.lastSuccessfulRefreshAt!)!
        )
        #expect(second.storageRevision == first.storageRevision + 1)
    }

    @Test func newerBackupSurvivesInterruptedCommitAndControlsNextRevision() throws {
        let directory = try temporaryDirectory()
        defer { removeTemporaryDirectory(directory) }

        let initialStore = store(in: directory, now: date("2026-07-18T10:00:00Z"))
        let first = try requireSuccess(
            initialStore.commit(fixture(label: "A", timestamp: "2026-07-18T09:00:00Z"))
        )
        let firstBytes = try Data(contentsOf: initialStore.primaryURL)
        let second = try requireSuccess(
            initialStore.commit(fixture(label: "B", timestamp: "2026-07-18T09:01:00Z"))
        )
        let newerBackupBytes = try Data(contentsOf: initialStore.backupURL)
        #expect(second.storageRevision == first.storageRevision + 1)

        // Recreate the crash window where primary is still generation N while
        // a fully verified backup already carries generation N+1.
        try firstBytes.write(to: initialStore.primaryURL)
        let failingStore = SharedSnapshotStore(
            directoryURL: directory,
            fileName: "repositories.json",
            now: { Self.date("2026-07-18T10:02:00Z") },
            failureInjector: { phase in
                if phase == .beforePrimaryReplacement {
                    throw InjectedFailure.beforePrimaryReplacement
                }
            }
        )
        switch failingStore.commit(
            fixture(label: "C", timestamp: "2026-07-18T10:02:00Z")
        ) {
        case .success:
            Issue.record("Interrupted commit unexpectedly published generation N+2.")
        case .failure:
            break
        }
        #expect(try Data(contentsOf: initialStore.backupURL) == newerBackupBytes)
        let preservedBackup = try JSONDecoder().decode(
            AppGroupData.self,
            from: Data(contentsOf: initialStore.backupURL)
        )
        #expect(preservedBackup.storageRevision == second.storageRevision)

        let succeedingStore = store(in: directory, now: date("2026-07-18T10:03:00Z"))
        let next = try requireSuccess(
            succeedingStore.commit(
                fixture(label: "D", timestamp: "2026-07-18T10:03:00Z")
            )
        )
        #expect(next.storageRevision == second.storageRevision + 1)
    }

    @Test func futureSchemaPrimaryRefusesBackupFallback() throws {
        let directory = try temporaryDirectory()
        defer { removeTemporaryDirectory(directory) }

        let snapshotStore = store(in: directory, now: date("2026-07-18T10:00:00Z"))
        try requireSuccess(snapshotStore.commit(fixture(label: "backup", timestamp: "2026-07-18T09:00:00Z")))
        try requireSuccess(snapshotStore.commit(fixture(label: "current", timestamp: "2026-07-18T09:01:00Z")))

        var future = try jsonObject(from: fixture(label: "future", timestamp: "2026-07-18T10:00:00Z"))
        future["schemaVersion"] = RepositorySnapshotSchema.version + 1
        future["persistenceState"] = "archived"
        let futureBytes = try JSONSerialization.data(withJSONObject: future, options: [.sortedKeys])
        try futureBytes.write(to: snapshotStore.primaryURL)
        let abandoned = directory.appendingPathComponent(
            "\(snapshotStore.temporaryFilePrefix)future-primary"
        )
        try Data("keep".utf8).write(to: abandoned)

        switch snapshotStore.load() {
        case .success:
            Issue.record("Future-schema primary incorrectly fell back to an older backup.")
        case .failure:
            break
        }
        switch snapshotStore.commit(
            fixture(label: "older-writer", timestamp: "2026-07-18T10:01:00Z")
        ) {
        case .success:
            Issue.record("Current writer incorrectly replaced a future-schema primary.")
        case .failure:
            break
        }
        switch snapshotStore.cleanupTemporaryFiles() {
        case .success:
            Issue.record("Cleanup ignored a future-schema primary.")
        case .failure:
            break
        }
        #expect(try Data(contentsOf: snapshotStore.primaryURL) == futureBytes)
        #expect(FileManager.default.fileExists(atPath: abandoned.path))
    }

    @Test func futureSchemaBackupMakesPairUnreadableAndCannotBeOverwritten() throws {
        let directory = try temporaryDirectory()
        defer { removeTemporaryDirectory(directory) }

        let snapshotStore = store(in: directory, now: date("2026-07-18T10:00:00Z"))
        try requireSuccess(
            snapshotStore.commit(fixture(label: "current", timestamp: "2026-07-18T09:00:00Z"))
        )
        let primaryBytes = try Data(contentsOf: snapshotStore.primaryURL)

        var future = try jsonObject(
            from: fixture(label: "future-backup", timestamp: "2026-07-18T10:00:00Z")
        )
        future["schemaVersion"] = RepositorySnapshotSchema.version + 1
        future["persistenceState"] = "archived"
        let futureBytes = try JSONSerialization.data(withJSONObject: future, options: [.sortedKeys])
        try futureBytes.write(to: snapshotStore.backupURL)
        let abandoned = directory.appendingPathComponent(
            "\(snapshotStore.temporaryFilePrefix)future-backup"
        )
        try Data("keep".utf8).write(to: abandoned)

        switch snapshotStore.load() {
        case .success:
            Issue.record("A pair containing a future-schema backup was incorrectly read.")
        case .failure:
            break
        }
        switch snapshotStore.commit(
            fixture(label: "older-writer", timestamp: "2026-07-18T10:01:00Z")
        ) {
        case .success:
            Issue.record("Current writer incorrectly replaced a future-schema backup.")
        case .failure:
            break
        }
        switch snapshotStore.cleanupTemporaryFiles() {
        case .success:
            Issue.record("Cleanup ignored a future-schema backup.")
        case .failure:
            break
        }
        #expect(try Data(contentsOf: snapshotStore.primaryURL) == primaryBytes)
        #expect(try Data(contentsOf: snapshotStore.backupURL) == futureBytes)
        #expect(FileManager.default.fileExists(atPath: abandoned.path))
    }

    @Test func cleanupTemporaryFilesRemovesOnlyAbandonedSnapshotStagingFiles() throws {
        let directory = try temporaryDirectory()
        defer { removeTemporaryDirectory(directory) }

        let snapshotStore = store(in: directory, now: date("2026-07-18T10:00:00Z"))
        let abandoned = directory.appendingPathComponent("\(snapshotStore.temporaryFilePrefix)abandoned.tmp")
        let unrelated = directory.appendingPathComponent("unrelated.txt")
        try Data("stale".utf8).write(to: abandoned)
        try Data("keep".utf8).write(to: unrelated)

        snapshotStore.cleanupTemporaryFiles()

        #expect(FileManager.default.fileExists(atPath: abandoned.path) == false)
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    private static func store(in directory: URL, now: Date) -> SharedSnapshotStore {
        SharedSnapshotStore(
            directoryURL: directory,
            fileName: "repositories.json",
            now: { now }
        )
    }

    private func store(in directory: URL, now: Date) -> SharedSnapshotStore {
        Self.store(in: directory, now: now)
    }

    private func fixture(label: String, timestamp: String) -> AppGroupData {
        let repository = RepositorySnapshot(
            id: label,
            name: "Repository \(label)",
            path: "/tmp/SharedSnapshotStoreTests/\(label)",
            branch: "main",
            status: .changed,
            modifiedFileCount: 1,
            addedFileCount: 0,
            deletedFileCount: 0,
            untrackedFileCount: 0,
            stagedFileCount: 1,
            unstagedFileCount: 0,
            conflictedFileCount: 0,
            aheadCount: 0,
            behindCount: 0,
            hasUpstream: true,
            changedFileCount: 1,
            changedFilesPreview: ["\(label).swift"],
            risk: .low,
            lastScannedAt: timestamp,
            dataSource: .current,
            lastSuccessfulScanAt: timestamp,
            lastChangedAt: timestamp,
            lastCommitID: "commit-\(label)",
            lastCommitSummary: "Commit \(label)",
            lastCommitMetadataAvailable: true,
            lastActivityAt: timestamp,
            unavailableSince: nil,
            errorMessage: nil,
            isPinned: false
        )
        return AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: timestamp,
            writtenAt: timestamp,
            lastSuccessfulRefreshAt: timestamp,
            scanSummary: ScanSummary.build(from: [repository]),
            repositories: [repository],
            recentActivityEvents: nil,
            repositoryUnavailableSinceByPath: nil,
            storageRevision: 0,
            persistenceState: .committed
        )
    }

    private func legacyV1JSON(from snapshot: AppGroupData) throws -> Data {
        var object = try jsonObject(from: snapshot)
        object["schemaVersion"] = RepositorySnapshotSchema.oldestMigratableVersion
        object.removeValue(forKey: "writtenAt")
        object.removeValue(forKey: "storageRevision")
        object.removeValue(forKey: "persistenceState")
        var repositories = try #require(object["repositories"] as? [[String: Any]])
        repositories[0].removeValue(forKey: "dataSource")
        object["repositories"] = repositories
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func crossRepositoryOverflowJSON(schemaVersion: Int) throws -> Data {
        var object = try jsonObject(
            from: fixture(label: "overflow-A", timestamp: "2026-07-18T09:00:00Z")
        )
        object["schemaVersion"] = schemaVersion
        object["storageRevision"] = 1

        var repositories = try #require(object["repositories"] as? [[String: Any]])
        var first = try #require(repositories.first)
        first["modifiedFileCount"] = Int.max
        first["changedFileCount"] = Int.max

        var second = first
        second["id"] = "overflow-B"
        second["name"] = "Repository overflow-B"
        second["path"] = "/tmp/SharedSnapshotStoreTests/overflow-B"
        second["changedFilesPreview"] = ["overflow-B.swift"]
        repositories = [first, second]
        object["repositories"] = repositories
        object["scanSummary"] = [
            "totalRepositories": 2,
            "changedRepositories": 2,
            "totalChangedFiles": Int.max,
            "errorRepositories": 0
        ]

        if schemaVersion == RepositorySnapshotSchema.oldestMigratableVersion {
            object.removeValue(forKey: "writtenAt")
            object.removeValue(forKey: "storageRevision")
            object.removeValue(forKey: "persistenceState")
            object["repositories"] = repositories.map { repository in
                var legacy = repository
                legacy.removeValue(forKey: "dataSource")
                return legacy
            }
        }

        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func jsonObject(from snapshot: AppGroupData) throws -> [String: Any] {
        let data = try JSONEncoder().encode(snapshot)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func requireSuccess<T>(_ result: Result<T, AppGroupStoreError>) throws -> T {
        switch result {
        case .success(let value):
            return value
        case .failure(let error):
            throw SnapshotTestFailure.unexpectedStoreError(error.localizedDescription)
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devpulse-shared-snapshot-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func removeTemporaryDirectory(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    private func temporaryFiles(in directory: URL, prefix: String) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ))?.filter { $0.lastPathComponent.hasPrefix(prefix) } ?? []
    }

    private static func date(_ iso8601: String) -> Date {
        ISO8601DateFormatter().date(from: iso8601)!
    }

    private func date(_ iso8601: String) -> Date {
        Self.date(iso8601)
    }
}

private actor ConcurrentReadCollector {
    private var values: [String] = []

    func record(_ value: String) {
        values.append(value)
    }

    func errors() -> [String] {
        values
    }
}

private enum InjectedFailure: Error {
    case beforePrimaryReplacement
    case afterPrimaryReplacement
}

private enum SnapshotTestFailure: Error {
    case unexpectedStoreError(String)
}
