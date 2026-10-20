import Foundation
import Testing
@testable import DevPulse

// MARK: - 共享快照 revision 一致性与诊断准确性回归测试
//
// 覆盖已确认缺陷：
// 1. 刷新起点的共享快照写入失败不能被静默吞掉；
// 2. 启动还原清除残留 isRefreshing 后必须采纳写入后的 revision；
// 3. 跨进程 CAS 必须比对本轮载荷的来源版本，而不是刚刚读到的磁盘版本；
// 4. 共享快照写入真正完成前不得报告 .verified；
// 5. 跨进程冲突后必须重基到磁盘基线，否则本实例再也写不进去；
// 6. 磁盘 revision 回退（快照被删除或还原）时旧载荷同样必须被拒绝。
// 7. 重基之前捕获的扫描结果不得在重基之后被发布（来源代必须绑在快照捕获点）；
// 8. 被重基丢弃的排队写入必须留下终态，不能停在“正在写入”；
// 9. 连续多轮跨进程冲突都必须重基并在之后恢复写入。
//
// 这些用例会改写进程级 App Group 容器（钳制容器写入、注入外部进程提交），
// 因此整组串行执行，且只在验证脚本注入了隔离容器与偏好域时才运行：
// 裸 xcodebuild 会让 App Group 回落到真实用户容器，绝不能在这里被改写。
// 跨套件并行无法完全消除（其他套件同样改动共享容器），但 verify.sh 为每次
// 运行提供一次性容器，而且权限窗口只覆盖单次同步写入。

@Suite(.serialized, .enabled(if: hasIsolatedAppGroupEnvironment))
struct SnapshotRevisionSyncTests {

    // MARK: - H2 启动还原采纳写入后的 revision

    @MainActor
    @Test("启动还原清除残留 isRefreshing 后采纳写入后的 revision")
    func startupRestoreAdoptsClearedSnapshotRevision() async throws {
        try await withSnapshotHarness { harness in
            let seeded = try requireSuccess(
                AppGroupStore.write(AppGroupData.empty().withIsRefreshing(true))
            )
            #expect(seeded.isRefreshing == true)
            let clearedRevision = seeded.storageRevision + 1

            let scheduler = harness.track(ScanScheduler(commandMode: false) { _ in (.empty(), [], []) })
            try await waitUntilIdle(scheduler)

            // 清除残留标记后的写入已经推进磁盘版本，内存必须同步采纳。
            let persisted = try readSnapshot()
            #expect(persisted.storageRevision == clearedRevision)
            #expect(persisted.isRefreshing == nil)
            #expect(scheduler.lastResult.storageRevision == persisted.storageRevision)
            #expect(scheduler.lastResult.isRefreshing != true)
            #expect(scheduler.diagnostics.lastSnapshotStoreState != .failed)
            #expect(scheduler.diagnostics.sharedDataSnapshot?.isRefreshing != true)
            // 清除明细不能覆盖启动还原信息。
            #expect(scheduler.diagnostics.lastSnapshotStoreDetail?.contains("已清除") == true)

            // 下一次刷新起点用内存 revision 作为观察值时必须通过 CAS：失败即版本脱节。
            let next = AppGroupStore.write(
                scheduler.lastResult.withIsRefreshing(nil),
                observedStorageRevision: scheduler.lastResult.storageRevision
            )
            switch next {
            case .success(let written):
                #expect(written.storageRevision == persisted.storageRevision + 1)
            case .failure(let error):
                Issue.record("清除残留标记后内存与磁盘 revision 脱节：\(error)")
            }
        }
    }

    // MARK: - H2 链路：还原后的刷新起点写入

    @MainActor
    @Test("残留 isRefreshing 还原后刷新起点写入仍然成功")
    func refreshStartWriteSucceedsAfterStaleRefreshingFlag() async throws {
        try await withSnapshotHarness { harness in
            let gate = ScanExecutionGate()

            let seeded = try requireSuccess(
                AppGroupStore.write(AppGroupData.empty().withIsRefreshing(true))
            )
            #expect(seeded.isRefreshing == true)

            let scheduler = harness.track(ScanScheduler(commandMode: false) { _ in
                await gate.enterAndWait()
                return (.empty(), [], [])
            })
            try await waitUntilIdle(scheduler)

            let restoredRevision = try readSnapshot().storageRevision

            scheduler.scanNow(forceRepositoryDiscovery: true)
            try await gate.waitForStart()

            // 刷新起点写入发生在扫描开始之前，此时应已落盘且没有写错误。
            let refreshing = try readSnapshot()
            #expect(refreshing.isRefreshing == true)
            #expect(refreshing.storageRevision == restoredRevision + 1)
            #expect(scheduler.diagnostics.sharedDataWriteError == nil)

            await gate.release()
            try await waitForSnapshotStoreSettled(scheduler)
            #expect(scheduler.diagnostics.lastSnapshotStoreState == .verified)
        }
    }

    // MARK: - H1 刷新起点写入失败必须如实上报

    @MainActor
    @Test("刷新起点写入失败必须被诊断上报且不中断扫描")
    func refreshStartWriteFailureIsSurfaced() async throws {
        try await withSnapshotHarness { harness in
            // 先把可写快照与锁文件准备好，再钳制容器目录（只读目录下无法创建
            // staging/锁文件），从而得到一个确定性的写入失败。
            let seeded = try requireSuccess(AppGroupStore.write(AppGroupData.empty()))
            #expect(seeded.storageRevision > 0)

            let scheduler = harness.track(ScanScheduler(commandMode: false) { _ in (.empty(), [], []) })
            try await waitUntilIdle(scheduler)
            scheduler.diagnostics.sharedDataWriteError = nil
            scheduler.diagnostics.lastSnapshotStoreState = .restored

            guard try harness.tightenContainerPermissionsUnlessPrivileged() else { return }

            // 刷新起点写入在本轮主 actor 执行里同步发生，权限窗口只需覆盖它。
            scheduler.scanNow(forceRepositoryDiscovery: true)

            // 在让出主 actor 之前断言真实失败，此时权限仍然被钳制。
            #expect(scheduler.diagnostics.sharedDataWriteError != nil)
            #expect(scheduler.diagnostics.lastSnapshotStoreState == .failed)
            #expect(scheduler.diagnostics.lastSnapshotStoreTrigger == "refresh-start")
            #expect(scheduler.diagnostics.lastSnapshotStoreDetail?.contains("刷新开始时写入共享快照失败") == true)

            // 断言完成后立即放开权限，把对并发套件的影响压缩到毫秒级。
            harness.restorePermissions()

            try await waitForSnapshotStoreSettled(scheduler)

            // 扫描本身没有被写入失败中断：失败只体现在刷新起点的写入上，
            // 随后的最终同步写入会自行恢复。
            #expect(scheduler.refreshPhase == .success)
            #expect(scheduler.refreshFailureMessage == nil)
            #expect(scheduler.diagnostics.lastSnapshotStoreState == .verified)
            #expect(scheduler.diagnostics.sharedDataWriteError == nil)
        }
    }

    // MARK: - H3 旧载荷不能覆盖更新的外部提交

    @MainActor
    @Test("扫描期间的外部提交不会被本轮旧载荷覆盖")
    func stalePayloadCannotOverwriteNewerForeignCommit() async throws {
        try await withSnapshotHarness { harness in
            let gate = ScanExecutionGate()

            _ = try requireSuccess(AppGroupStore.write(AppGroupData.empty()))

            let scheduler = harness.track(ScanScheduler(commandMode: false) { _ in
                await gate.enterAndWait()
                return (.empty(), [], [])
            })
            try await waitUntilIdle(scheduler)

            scheduler.scanNow(forceRepositoryDiscovery: true)
            try await gate.waitForStart()

            // 扫描进行中，另一个进程提交了内容完全不同的更新快照。
            let foreign = try commitForeignMarker()
            #expect(foreign.isRefreshing == nil)

            await gate.release()
            try await waitForSnapshotStoreSettled(scheduler)

            // 旧载荷必须被 CAS 拒绝：磁盘保持外部提交的内容与版本。
            let persisted = try readSnapshot()
            #expect(persisted.repositories.map(\.name) == ["foreign-marker"])
            #expect(persisted.storageRevision == foreign.storageRevision)

            // 冲突必须如实上报，且不能被描述成 Widget 侧故障。
            #expect(scheduler.diagnostics.sharedDataWriteError != nil)
            #expect(scheduler.diagnostics.lastSnapshotStoreState == .failed)
            #expect(!scheduler.warnings.contains { $0.contains("Widget 数据同步失败") })
            #expect(scheduler.warnings.contains { $0.contains("另一个实例") })
            #expect(scheduler.diagnostics.lastSnapshotStoreDetail?.contains("另一个实例") == true)

            // 冲突同时触发重基：本实例的基线被换成磁盘现状。
            #expect(scheduler.lastResult.storageRevision == persisted.storageRevision)
            #expect(scheduler.diagnostics.sharedDataSnapshot?.storageRevision == persisted.storageRevision)
        }
    }

    // MARK: - 冲突后的写入活性（重基）

    @MainActor
    @Test("跨进程冲突后调度器必须重基并自行恢复写入")
    func conflictRebaseRestoresWriteLiveness() async throws {
        try await withSnapshotHarness { harness in
            let gate = ScanExecutionGate()

            _ = try requireSuccess(AppGroupStore.write(AppGroupData.empty()))

            let scheduler = harness.track(ScanScheduler(commandMode: false) { _ in
                await gate.enterAndWait()
                return (.empty(), [], [])
            })
            try await waitUntilIdle(scheduler)
            let baselineRevision = try readSnapshot().storageRevision

            scheduler.scanNow(forceRepositoryDiscovery: true)
            try await gate.waitForStart()

            // 扫描进行中，另一个实例提交了内容完全不同的新快照（R+2）。
            let foreign = try commitForeignMarker()
            #expect(foreign.repositories.map(\.name) == ["foreign-marker"])

            await gate.release()
            try await waitForSnapshotStoreSettled(scheduler)

            // 旧载荷被拒，磁盘保持外部提交的内容与版本。
            let persisted = try readSnapshot()
            #expect(persisted.repositories.map(\.name) == ["foreign-marker"])
            #expect(persisted.storageRevision == foreign.storageRevision)
            #expect(persisted.storageRevision > baselineRevision)
            #expect(scheduler.diagnostics.lastSnapshotStoreState == .failed)

            // 关键：冲突后本实例必须采纳磁盘基线，否则后续每一次写入都会被拒。
            #expect(scheduler.lastResult.storageRevision == persisted.storageRevision)
            #expect(scheduler.diagnostics.sharedDataSnapshot?.storageRevision == persisted.storageRevision)
            #expect(scheduler.diagnostics.lastWrittenAt == persisted.writtenAt)

            // 第二轮刷新不得再提交旧载荷：必须成功，并写入本轮自己的结果。
            scheduler.scanNow(forceRepositoryDiscovery: true)
            try await waitForSnapshotStoreSettled(scheduler)

            let recovered = try readSnapshot()
            #expect(scheduler.diagnostics.lastSnapshotStoreState == .verified)
            #expect(recovered.storageRevision > foreign.storageRevision)
            #expect(scheduler.lastResult.storageRevision == recovered.storageRevision)
            #expect(recovered.repositories.isEmpty)
            #expect(scheduler.diagnostics.sharedDataWriteError == nil)
        }
    }

    // MARK: - 连续冲突（重基链路不得卡死）

    @MainActor
    @Test("连续两轮跨进程冲突都能重基并在之后恢复写入")
    func consecutiveConflictsStillRecover() async throws {
        try await withSnapshotHarness { harness in
            let gate = ScanExecutionGate()

            _ = try requireSuccess(AppGroupStore.write(AppGroupData.empty()))

            let scheduler = harness.track(ScanScheduler(commandMode: false) { _ in
                await gate.enterAndWait()
                return (.empty(), [], [])
            })
            try await waitUntilIdle(scheduler)

            var adoptedRevision: UInt64 = 0
            for round in 1...2 {
                if round > 1 {
                    // 重新封闭闸门，让第二轮扫描再次挂起。
                    await gate.close()
                }
                let previousStarts = await gate.startCount()

                scheduler.scanNow(forceRepositoryDiscovery: true)
                try await gate.waitForStart(after: previousStarts)

                // 每轮都在扫描挂起期间提交外部快照：本轮写入必须被拒并重基。
                let foreign = try commitForeignMarker(
                    repositoryName: "foreign-marker-\(round)",
                    id: "foreign-marker-\(round)-id"
                )

                await gate.release()
                try await waitForSnapshotStoreSettled(scheduler)

                // 冲突轮绝不能报告 verified，而且必须采纳磁盘基线。
                #expect(
                    scheduler.diagnostics.lastSnapshotStoreState == .failed,
                    "第 \(round) 轮冲突没有如实报告 failed"
                )
                let persisted = try readSnapshot()
                #expect(persisted.repositories.map(\.name) == ["foreign-marker-\(round)"])
                #expect(persisted.storageRevision == foreign.storageRevision)
                #expect(
                    scheduler.lastResult.storageRevision == persisted.storageRevision,
                    "第 \(round) 轮没有采纳重基后的磁盘基线"
                )
                #expect(scheduler.diagnostics.sharedDataSnapshot?.storageRevision == persisted.storageRevision)
                // 重基刚刚成功读过磁盘快照：诊断不得继续声称快照不可解码。
                #expect(scheduler.diagnostics.snapshotDecodable)
                #expect(scheduler.diagnostics.sharedDataReadError == nil)
                adoptedRevision = persisted.storageRevision
            }

            // 连续冲突之后写入必须恢复。
            scheduler.scanNow(forceRepositoryDiscovery: true)
            try await waitForSnapshotStoreSettled(scheduler)

            let recovered = try readSnapshot()
            #expect(scheduler.diagnostics.lastSnapshotStoreState == .verified)
            #expect(recovered.storageRevision > adoptedRevision)
            #expect(scheduler.lastResult.storageRevision == recovered.storageRevision)
            #expect(scheduler.diagnostics.sharedDataWriteError == nil)
        }
    }

    // MARK: - 磁盘 revision 回退

    @MainActor
    @Test("磁盘 revision 回退时旧载荷同样必须被拒绝")
    func diskRevisionRollbackRejectsStalePayload() async throws {
        try await withSnapshotHarness { harness in
            let gate = ScanExecutionGate()

            _ = try requireSuccess(AppGroupStore.write(AppGroupData.empty()))

            let scheduler = harness.track(ScanScheduler(commandMode: false) { _ in
                await gate.enterAndWait()
                return (.empty(), [], [])
            })
            try await waitUntilIdle(scheduler)

            scheduler.scanNow(forceRepositoryDiscovery: true)
            try await gate.waitForStart()

            // 刷新起点已经推进过磁盘版本，本实例的观察值高于新基线。
            let observedRevision = try readSnapshot().storageRevision
            #expect(observedRevision >= 2)

            // 快照文件被外部删除，另一个实例从 0 重新开始，写出更低的版本号。
            harness.removeSharedSnapshotArtifacts()
            let foreign = try commitForeignMarker()
            #expect(foreign.storageRevision < observedRevision)

            await gate.release()
            try await waitForSnapshotStoreSettled(scheduler)

            // 若把“观察值高于磁盘”当作可用，旧载荷会被写成 foreign + 1 并覆盖外部
            // 写入，因此必须拒绝，磁盘保持外部内容。
            let persisted = try readSnapshot()
            #expect(persisted.repositories.map(\.name) == ["foreign-marker"])
            #expect(persisted.storageRevision == foreign.storageRevision)
            #expect(scheduler.diagnostics.lastSnapshotStoreState == .failed)
            #expect(scheduler.lastResult.storageRevision == persisted.storageRevision)

            // 重基之后下一轮刷新必须恢复。
            scheduler.scanNow(forceRepositoryDiscovery: true)
            try await waitForSnapshotStoreSettled(scheduler)

            let recovered = try readSnapshot()
            #expect(scheduler.diagnostics.lastSnapshotStoreState == .verified)
            #expect(recovered.storageRevision > foreign.storageRevision)
            #expect(scheduler.lastResult.storageRevision == recovered.storageRevision)
        }
    }

    // MARK: - 重基之后不得发布重基前捕获的结果（P1）

    @MainActor
    @Test("重基之前捕获的扫描结果不得在重基之后被写入")
    func supersededScanResultIsNotWrittenAfterRebase() async throws {
        try await withSnapshotHarness { harness in
            let gate = ScanExecutionGate()

            _ = try requireSuccess(AppGroupStore.write(AppGroupData.empty()))

            let scheduler = harness.track(ScanScheduler(commandMode: false) { _ in
                await gate.enterAndWait()
                return (.empty(), [], [])
            })
            try await waitUntilIdle(scheduler)

            scheduler.scanNow(forceRepositoryDiscovery: true)
            try await gate.waitForStart()

            // 扫描仍在 await 中：另一个实例提交了内容完全不同的快照。
            let foreign = try commitForeignMarker()

            // 扫描仍然挂起时触发一次同步写入，它必须因跨进程冲突而重基，
            // 把本实例基线换成磁盘现状（重基代推进）。
            scheduler.togglePin(repoID: "rebase-probe")
            try await waitForRevision(scheduler, foreign.storageRevision)
            #expect(scheduler.lastResult.storageRevision == foreign.storageRevision)

            // 现在才放行扫描：本轮结果是重基之前捕获的，绝不能写出去。
            await gate.release()
            try await waitForSnapshotStoreSettled(scheduler)

            // 磁盘必须保持外部内容与外部版本；重基前的扫描结果已被丢弃。
            let persisted = try readSnapshot()
            #expect(persisted.repositories.map(\.name) == ["foreign-marker"])
            #expect(persisted.storageRevision == foreign.storageRevision)
            #expect(scheduler.lastResult.storageRevision == foreign.storageRevision)
            #expect(scheduler.diagnostics.sharedDataSnapshot?.storageRevision == foreign.storageRevision)
            #expect(
                scheduler.diagnostics.lastSnapshotStoreState != .verified,
                "重基前的旧内容被当成新版本写入并报 verified"
            )
            #expect(scheduler.diagnostics.lastSnapshotStoreDetail?.contains("冲突重基") == true)
            #expect(!scheduler.hasPendingSnapshotSync)

            // 丢弃之后下一次刷新必须基于重基后的基线正常写入。
            scheduler.scanNow(forceRepositoryDiscovery: true)
            try await waitForSnapshotStoreSettled(scheduler)

            let recovered = try readSnapshot()
            #expect(scheduler.diagnostics.lastSnapshotStoreState == .verified)
            #expect(recovered.storageRevision > foreign.storageRevision)
            #expect(scheduler.lastResult.storageRevision == recovered.storageRevision)
            #expect(recovered.repositories.isEmpty)
            #expect(scheduler.diagnostics.sharedDataWriteError == nil)
        }
    }

    // MARK: - 被取代的排队写入与终态（P2-A / P2-C）

    @MainActor
    @Test("同一轮内被取代的排队写入不会留下“正在写入”终态")
    func supersededQueuedWriteSettlesWithoutInProgressState() async throws {
        try await withSnapshotHarness { harness in
            let gate = ScanExecutionGate()

            _ = try requireSuccess(AppGroupStore.write(AppGroupData.empty()))

            let scheduler = harness.track(ScanScheduler(commandMode: false) { _ in
                await gate.enterAndWait()
                return (.empty(), [], [])
            })
            try await waitUntilIdle(scheduler)

            scheduler.scanNow(forceRepositoryDiscovery: true)
            try await gate.waitForStart()

            // 同一主 actor 回合里连续入队两次同步：前一代在排队时就被后一代取代，
            // 它的退出路径必须同样登记完成代，否则 `hasPendingSnapshotSync` 会
            // 永远挂在真上，诊断也可能停在“正在写入”。
            scheduler.togglePin(repoID: "queued-probe-a")
            scheduler.togglePin(repoID: "queued-probe-b")

            try await waitForPendingSnapshotSyncToDrain(scheduler)
            #expect(!scheduler.hasPendingSnapshotSync)
            #expect(
                scheduler.diagnostics.lastSnapshotStoreDetail?.contains("正在把") != true,
                "排队写入结束后诊断仍停在写入中：\(String(describing: scheduler.diagnostics.lastSnapshotStoreDetail))"
            )
            // 幸存的那一代真的写入了：未被取代的写入不能被误当成已丢弃。
            let persisted = try readSnapshot()
            #expect(scheduler.diagnostics.lastSnapshotStoreState == .verified)
            #expect(scheduler.lastResult.storageRevision == persisted.storageRevision)

            // 放行挂起的扫描，让整轮收敛。
            await gate.release()
            try await waitForSnapshotStoreSettled(scheduler)
            #expect(!scheduler.hasPendingSnapshotSync)
            #expect(try readSnapshot().storageRevision == scheduler.lastResult.storageRevision)
        }
    }

    // MARK: - 连续刷新

    @MainActor
    @Test("连续两轮刷新各自成功且版本严格递增")
    func consecutiveRefreshesKeepRevisionInSync() async throws {
        try await withSnapshotHarness { harness in
            _ = try requireSuccess(AppGroupStore.write(AppGroupData.empty()))

            let scheduler = harness.track(ScanScheduler(commandMode: false) { _ in (.empty(), [], []) })
            try await waitUntilIdle(scheduler)

            var previousRevision = try readSnapshot().storageRevision
            for round in 1...2 {
                scheduler.scanNow(forceRepositoryDiscovery: true)
                try await waitForSnapshotStoreSettled(scheduler)

                let persisted = try readSnapshot()
                #expect(
                    scheduler.diagnostics.lastSnapshotStoreState == .verified,
                    "第 \(round) 轮刷新没有报告 verified"
                )
                #expect(
                    scheduler.lastResult.storageRevision == persisted.storageRevision,
                    "第 \(round) 轮内存与磁盘 revision 脱节"
                )
                #expect(
                    persisted.storageRevision > previousRevision,
                    "第 \(round) 轮 revision 没有递增"
                )
                #expect(scheduler.diagnostics.sharedDataWriteError == nil)
                previousRevision = persisted.storageRevision
            }
        }
    }

    // MARK: - 启动阶段清除残留标记写入失败

    @MainActor
    @Test("启动清除残留 isRefreshing 写入失败必须被如实上报")
    func startupClearWriteFailureIsSurfaced() async throws {
        try await withSnapshotHarness { harness in
            // 先写入一个带残留 isRefreshing 的有效快照（此时容器仍可写）。
            let seeded = try requireSuccess(
                AppGroupStore.write(AppGroupData.empty().withIsRefreshing(true))
            )
            #expect(seeded.isRefreshing == true)

            guard try harness.tightenContainerPermissionsUnlessPrivileged() else { return }

            // 初始化同步执行启动还原：读取成功，清除标记的写入失败。
            let scheduler = harness.track(ScanScheduler(commandMode: false) { _ in (.empty(), [], []) })
            harness.restorePermissions()

            // 内存已清除残留标记，但磁盘仍是原样。
            #expect(scheduler.lastResult.isRefreshing == nil)
            let persisted = try readSnapshot()
            #expect(persisted.isRefreshing == true)
            #expect(persisted.storageRevision == seeded.storageRevision)

            // 读取本身没有被破坏，失败只落在写入这一步上，并且被如实上报。
            #expect(scheduler.diagnostics.sharedDataReadError == nil)
            #expect(scheduler.diagnostics.lastSnapshotStoreState == .failed)
            #expect(scheduler.diagnostics.sharedDataWriteError != nil)
            #expect(scheduler.diagnostics.lastSnapshotStoreDetail?.contains("清除残留的 isRefreshing 标记") == true)
            #expect(scheduler.lastResult.storageRevision == persisted.storageRevision)
        }
    }

    // MARK: - H4 写入完成前不得报告 .verified

    @MainActor
    @Test("无变化扫描在写入真正落地前不报告 verified")
    func noChangesScanNeverReportsVerifiedBeforeWrite() async throws {
        try await withSnapshotHarness { harness in
            let seeded = try requireSuccess(AppGroupStore.write(AppGroupData.empty()))
            let preScanRevision = seeded.storageRevision

            // 扫描结果与已持久化的快照一致，驱动 reason == "scan-nochanges" 分支。
            let scheduler = harness.track(ScanScheduler(commandMode: false) { _ in (.empty(), [], []) })
            try await waitUntilIdle(scheduler)
            #expect(scheduler.lastResult.storageRevision == preScanRevision)

            scheduler.scanNow(forceRepositoryDiscovery: true)

            // 逐轮采样调度器自己报告的终态：refresh-start 写入推进 +1，最终同步写入
            // 再推进 +1，因此 .verified 首次出现时调度器采纳的写入版本至少是
            // preScan + 2。这里只看内存中的“已采纳快照版本”（handleSyncSnapshotSuccess
            // 设置），不在采样循环里读磁盘，避开与写入方的锁顺序竞争。
            var sampledStates: [String] = []
            var verifiedRevision: UInt64?
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(5)
            while clock.now < deadline {
                let state = scheduler.diagnostics.lastSnapshotStoreState
                let adoptedRevision = scheduler.diagnostics.sharedDataSnapshot?.storageRevision
                let sample = "\(state)@\(adoptedRevision.map(String.init) ?? "nil")"
                if sampledStates.last != sample {
                    sampledStates.append(sample)
                }
                if state == .verified {
                    verifiedRevision = adoptedRevision
                    break
                }
                if state == .failed || clock.now >= deadline {
                    break
                }
                try? await Task.sleep(for: .milliseconds(2))
            }

            let landedRevision = try #require(
                verifiedRevision,
                "无变化扫描未在超时前报告 verified：\(sampledStates)"
            )
            #expect(
                landedRevision >= preScanRevision + 2,
                "verified 出现在写入落地之前（期望至少 \(preScanRevision + 2)，实际 \(landedRevision)）：\(sampledStates)"
            )

            // 终态必须与真实写入结果一致。
            let persisted = try readSnapshot()
            // 同步写入使用显式 false，因此以“不再处于刷新中”为准（不是 nil）。
            #expect(persisted.isRefreshing != true)
            #expect(persisted.storageRevision >= landedRevision)
        }
    }

    // MARK: - 取消路径的状态一致性

    @MainActor
    @Test("取消扫描后磁盘与内存的 revision 保持一致")
    func cancelledScanKeepsPersistedSnapshotConsistent() async throws {
        try await withSnapshotHarness { harness in
            let gate = ScanExecutionGate()

            _ = try requireSuccess(AppGroupStore.write(AppGroupData.empty()))

            let scheduler = harness.track(ScanScheduler(commandMode: false) { _ in
                await gate.enterAndWait()
                return (.empty(), [], [])
            })
            try await waitUntilIdle(scheduler)

            scheduler.scanNow(forceRepositoryDiscovery: true)
            try await gate.waitForStart()

            // 新的强制刷新会取消正在进行的扫描，并排队执行后一轮。
            scheduler.scanNow(forceRepositoryDiscovery: true)
            await gate.release()

            try await waitForSnapshotStoreSettled(scheduler)

            let persisted = try readSnapshot()
            #expect(persisted.isRefreshing != true)
            #expect(scheduler.lastResult.isRefreshing != true)
            #expect(scheduler.lastResult.storageRevision == persisted.storageRevision)
            #expect(scheduler.diagnostics.lastSnapshotStoreState == .verified)
        }
    }

    // MARK: - 测试辅助

    private func readSnapshot() throws -> AppGroupData {
        try requireSuccess(AppGroupStore.read())
    }

    /// 用独立存储实例提交一份内容明显不同的“外部进程”快照。
    private func commitForeignMarker(
        repositoryName: String = "foreign-marker",
        id: String = "foreign-marker-id"
    ) throws -> AppGroupData {
        let store = try SharedSnapshotStore(
            directoryURL: #require(AppGroupStore.containerURL),
            fileName: SharedSnapshotLocation.fileName
        )
        return try requireSuccess(
            store.commit(foreignMarkerSnapshot(repositoryName: repositoryName, id: id))
        )
    }

    private func foreignMarkerSnapshot(
        repositoryName: String = "foreign-marker",
        id: String = "foreign-marker-id"
    ) -> AppGroupData {
        let timestamp = DateFormatting.nowISO()
        let repository = RepositorySnapshot(
            id: id,
            name: repositoryName,
            path: "/tmp/DevPulseTests/\(id)",
            workspaceKind: .standalone,
            branch: "main",
            status: .clean,
            modifiedFileCount: 0,
            addedFileCount: 0,
            deletedFileCount: 0,
            untrackedFileCount: 0,
            stagedFileCount: 0,
            unstagedFileCount: 0,
            conflictedFileCount: 0,
            aheadCount: 0,
            hasUpstream: true,
            changedFileCount: 0,
            changedFilesPreview: [],
            risk: .low,
            lastScannedAt: timestamp,
            lastChangedAt: nil,
            errorMessage: nil,
            isPinned: false
        )
        return AppGroupData(
            schemaVersion: RepositorySnapshotSchema.version,
            generatedAt: timestamp,
            writtenAt: timestamp,
            lastSuccessfulRefreshAt: timestamp,
            scanSummary: ScanSummary.build(from: [repository]),
            repositories: [repository]
        )
    }

    @MainActor
    private func waitUntilIdle(_ scheduler: ScanScheduler) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(3)
        while scheduler.isScanning {
            guard clock.now < deadline else {
                throw TestWaitError("等待调度器进入空闲态超时")
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    @MainActor
    private func waitForSnapshotStoreSettled(_ scheduler: ScanScheduler) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        // 只认调度器自己给出的信号：扫描结束 + 队列里没有未完成的共享快照写入。
        // 采样诊断状态无法证明排队中的提交已经落地。
        while scheduler.isScanning || scheduler.hasPendingSnapshotSync {
            guard clock.now < deadline else {
                throw TestWaitError(
                    "等待共享快照写入收敛超时：isScanning=\(scheduler.isScanning)，"
                        + "hasPendingSnapshotSync=\(scheduler.hasPendingSnapshotSync)，"
                        + "state=\(scheduler.diagnostics.lastSnapshotStoreState)，"
                        + "detail=\(scheduler.diagnostics.lastSnapshotStoreDetail ?? "nil")"
                )
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    /// 只等排队中的共享快照写入结束（扫描可能仍然挂起）。
    @MainActor
    private func waitForPendingSnapshotSyncToDrain(_ scheduler: ScanScheduler) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while scheduler.hasPendingSnapshotSync {
            guard clock.now < deadline else {
                throw TestWaitError(
                    "等待排队中的共享快照写入结束超时：state=\(scheduler.diagnostics.lastSnapshotStoreState)，"
                        + "detail=\(scheduler.diagnostics.lastSnapshotStoreDetail ?? "nil")"
                )
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    /// 等调度器采纳指定 revision（用于确认冲突重基已经发生）。
    @MainActor
    private func waitForRevision(_ scheduler: ScanScheduler, _ revision: UInt64) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while scheduler.lastResult.storageRevision != revision {
            guard clock.now < deadline else {
                throw TestWaitError(
                    "等待调度器重基到 revision \(revision) 超时："
                        + "lastResult=\(scheduler.lastResult.storageRevision)"
                )
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }
}

// MARK: - 隔离环境与用例收尾

/// 只有验证脚本注入了隔离容器与偏好域时才执行整组用例。
/// 裸 xcodebuild 下 App Group 会回落到真实用户容器，这组用例会往里写快照、
/// 甚至临时改动目录权限，因此必须整组禁用。
private var hasIsolatedAppGroupEnvironment: Bool {
    let environment = ProcessInfo.processInfo.environment
    let container = environment["DEVPULSE_APP_GROUP_CONTAINER_PATH"] ?? ""
    let suite = environment["DEVPULSE_APP_GROUP_DEFAULTS_SUITE"] ?? ""
    return !container.isEmpty && !suite.isEmpty
}

@MainActor
private func withSnapshotHarness(
    _ body: (SnapshotTestHarness) async throws -> Void
) async throws {
    let harness = try SnapshotTestHarness()
    do {
        try await body(harness)
    } catch {
        await harness.tearDown()
        throw error
    }
    await harness.tearDown()
}

/// 一次性容器环境：隔离共享快照与扫描位置，并保证每个用例结束时
/// 先抽干后台写入、再恢复目录权限、最后恢复容器内容。
@MainActor
private final class SnapshotTestHarness {
    private let snapshotArtifacts: SharedSnapshotArtifacts
    private let scanLocations: Data?
    private var schedulers: [ScanScheduler] = []
    private var permissionRestores: [(url: URL, permissions: NSNumber?)] = []

    init() throws {
        snapshotArtifacts = isolateSharedSnapshotArtifacts()
        scanLocations = try isolateScanLocations()
        removeSharedSnapshotArtifacts()
    }

    @discardableResult
    func track(_ scheduler: ScanScheduler) -> ScanScheduler {
        schedulers.append(scheduler)
        return scheduler
    }

    func removeSharedSnapshotArtifacts() {
        removeSharedSnapshotArtifactsFiles()
    }

    /// 钳制容器目录使写入失败、读取仍然可用（锁文件在种子写入时已存在）。
    ///
    /// 返回 false 表示当前进程无视目录权限（例如以特权用户运行）：此时写入
    /// 探测会成功，用例既不能真实验证失败路径，也不该产生假失败，因此直接跳过。
    func tightenContainerPermissionsUnlessPrivileged() throws -> Bool {
        guard let containerURL = AppGroupStore.containerURL else {
            Issue.record("App Group 容器不可用，无法注入写入失败")
            return false
        }
        let original = try FileManager.default
            .attributesOfItem(atPath: containerURL.path)[.posixPermissions] as? NSNumber
        permissionRestores.append((containerURL, original))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: containerURL.path
        )

        // 特权探测：写入成功说明权限被忽略，恢复权限后让调用方直接返回。
        if case .success = AppGroupStore.write(AppGroupData.empty()) {
            print("[SnapshotRevisionSyncTests] 当前进程忽略目录权限（疑似特权执行），跳过权限注入断言。")
            restorePermissions()
            return false
        }
        return true
    }

    func restorePermissions() {
        for restore in permissionRestores {
            try? FileManager.default.setAttributes(
                [.posixPermissions: restore.permissions ?? NSNumber(value: 0o700)],
                ofItemAtPath: restore.url.path
            )
        }
        permissionRestores.removeAll()
    }

    func tearDown() async {
        // 先抽干后台工作：此后才能安全改动权限/文件。
        await drainSchedulers()
        restorePermissions()
        restoreSharedSnapshot(snapshotArtifacts)
        restoreScanLocations(scanLocations)
    }

    /// 有界抽干：等所有调度器停止扫描，并且再没有排队中/进行中的共享快照写入。
    /// 只认 `hasPendingSnapshotSync`：采样诊断状态无法证明排队中的提交已经落地。
    private func drainSchedulers() async {
        for scheduler in schedulers {
            scheduler.stopBackgroundScanning()
        }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while clock.now < deadline {
            let settled = schedulers.allSatisfy { !$0.isScanning && !$0.hasPendingSnapshotSync }
            if settled { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

private func isolateScanLocations() throws -> Data? {
    guard let defaults = AppGroupStore.defaults else {
        Issue.record("App Group 偏好域不可用")
        return nil
    }
    let previous = defaults.data(forKey: scanLocationsKey)
    defaults.set(
        try JSONEncoder().encode(
            ScanLocationConfiguration(enabledBuiltInPaths: [], customDirectories: [])
        ),
        forKey: scanLocationsKey
    )
    return previous
}

private func restoreScanLocations(_ previous: Data?) {
    guard let defaults = AppGroupStore.defaults else { return }
    if let previous {
        defaults.set(previous, forKey: scanLocationsKey)
    } else {
        defaults.removeObject(forKey: scanLocationsKey)
    }
}

private var scanLocationsKey: String { "scan_locations_v1_json" }

private struct SharedSnapshotArtifacts {
    let primary: Data?
    let backup: Data?
}

private func isolateSharedSnapshotArtifacts() -> SharedSnapshotArtifacts {
    SharedSnapshotArtifacts(
        primary: AppGroupStore.snapshotURL.flatMap { try? Data(contentsOf: $0) },
        backup: AppGroupStore.backupURL.flatMap { try? Data(contentsOf: $0) }
    )
}

private func restoreSharedSnapshot(_ artifacts: SharedSnapshotArtifacts) {
    removeSharedSnapshotArtifactsFiles()
    restoreSharedSnapshotArtifact(artifacts.primary, at: AppGroupStore.snapshotURL)
    restoreSharedSnapshotArtifact(artifacts.backup, at: AppGroupStore.backupURL)
}

private func restoreSharedSnapshotArtifact(_ data: Data?, at url: URL?) {
    guard let url else { return }
    if let data {
        try? data.write(to: url, options: [.atomic])
    } else {
        try? FileManager.default.removeItem(at: url)
    }
}

private func removeSharedSnapshotArtifactsFiles() {
    [AppGroupStore.snapshotURL, AppGroupStore.backupURL]
        .compactMap { $0 }
        .forEach { try? FileManager.default.removeItem(at: $0) }
    _ = AppGroupStore.cleanupTemporaryFiles()
}

// MARK: - 测试辅助类型

private struct TestWaitError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// 扫描执行闸门：让测试精确控制“扫描正在进行”的时间窗口。
/// 取消时立即放行，便于取消路径正常收敛。
private actor ScanExecutionGate {
    private var started = 0
    private var released = false

    /// 已进入扫描执行的次数（多轮场景里作为“新一轮还没开始”的起点）。
    func startCount() -> Int { started }

    /// 重新封闭闸门，让下一轮扫描再次挂起。
    func close() { released = false }

    func enterAndWait() async {
        started += 1
        while !released {
            if Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    /// 有界等待扫描进入执行阶段：无界等待会把测试挂死变成超时。
    func waitForStart(after previousStarts: Int = 0) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while started <= previousStarts {
            guard clock.now < deadline else {
                throw TestWaitError("等待扫描进入执行阶段超时")
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    func release() {
        released = true
    }
}

private func requireSuccess<T>(
    _ result: Result<T, some Error>,
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> T {
    switch result {
    case .success(let value):
        return value
    case .failure(let error):
        Issue.record("Expected success, got failure: \(error)", sourceLocation: sourceLocation)
        throw error
    }
}
