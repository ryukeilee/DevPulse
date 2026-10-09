# 仓库列表排序性能验证

本轮仅预计算每个仓库的排序输入，复用单次查询内的时间戳解析器。置顶、决策优先级、数据可信度、风险、计数、活动时间、名称比较及稳定排序规则保持原有顺序。

## 复现

基线：`da5b955057e6d49fd94f69a8ff8fce49b6e7f507`。

```sh
./scripts/benchmark-repository-list-query.sh --baseline-git da5b955057e6d49fd94f69a8ff8fce49b6e7f507
```

默认参数为 `BENCH_REPOS=1200 BENCH_ITERATIONS=15 BENCH_WARMUP=3`。脚本使用 `swiftc -O` 分别编译基线和当前源代码，比较六种查询模式。每种模式对完整结果数组（含顺序）进行 JSON 编码并计算 SHA-256；指纹不一致时返回非零退出码。测试数据为合成仓库，不扫描真实工作区。

测量环境：arm64、macOS 27.0.1、Apple Swift 6.4。耗时受硬件及负载影响，结果等价性仅覆盖该合成数据集，另由定向测试覆盖排序分支。

## 确定性边界验证

`mostRecentActivityAcceptsExactlySixtySecondsInFuture` 固定 `now`，验证未来 `59.999` 秒、恰好 `60` 秒（标准及毫秒格式）被接受，`60.001` 秒被拒绝；覆盖两个来源字段、无回退值和有效旧值回退，并检查时间戳及解析日期。

定向测试覆盖原比较器等价性、稳定排序、名称决胜、负计数及共享模型相关行为。

## 2026-10-09 实测结果

使用默认参数，六种模式完整结果指纹全部一致。智能排序平均耗时降低 94.5%，最近活动排序降低 99.3%；未优化的名称排序分别波动 +0.4% 和 +0.2%，本次未观察到实质性能回退。

```text
Repository list query benchmark
  repos=1200 iterations=15

BENCH label=baseline repos=1200 iterations=15
MODE all-smart rows=1200 total_ms=55374.548 mean_ms=3691.637 fingerprint=a230ebb492d945594bbc3abde1cda6d13a2a25170c8d80b2f73ff491695830e6
MODE all-name rows=1200 total_ms=155.639 mean_ms=10.376 fingerprint=82631e0d5594821657fb1abb82ad9e1c2c7430d49e869851d4cfeeac557a5782
MODE all-recent rows=1200 total_ms=353902.192 mean_ms=23593.479 fingerprint=720a395d1de61a5618d3b6b68f7ce7a3d0358b96eb37819a45ba031ff18ac9bd
MODE search-recent rows=53 total_ms=13423.460 mean_ms=894.897 fingerprint=95dadc1529208adfd8de7be641c5c10a7f106450b608856b69ccb3d783a17171
MODE filter-recent rows=1182 total_ms=349709.753 mean_ms=23313.984 fingerprint=067bc9d9f12b853b01d53b20cc806b08e685b1cb79d59318282e39a6f39b635b
MODE filter-local-name rows=530 total_ms=58.817 mean_ms=3.921 fingerprint=d70c5cd4c8d795ceef6d40f15ba56ea9a3d9d9193822c41d753459871b20bd1d
BENCH label=current repos=1200 iterations=15
MODE all-smart rows=1200 total_ms=3054.625 mean_ms=203.642 fingerprint=a230ebb492d945594bbc3abde1cda6d13a2a25170c8d80b2f73ff491695830e6
MODE all-name rows=1200 total_ms=156.222 mean_ms=10.415 fingerprint=82631e0d5594821657fb1abb82ad9e1c2c7430d49e869851d4cfeeac557a5782
MODE all-recent rows=1200 total_ms=2508.910 mean_ms=167.261 fingerprint=720a395d1de61a5618d3b6b68f7ce7a3d0358b96eb37819a45ba031ff18ac9bd
MODE search-recent rows=53 total_ms=172.561 mean_ms=11.504 fingerprint=95dadc1529208adfd8de7be641c5c10a7f106450b608856b69ccb3d783a17171
MODE filter-recent rows=1182 total_ms=2511.486 mean_ms=167.432 fingerprint=067bc9d9f12b853b01d53b20cc806b08e685b1cb79d59318282e39a6f39b635b
MODE filter-local-name rows=530 total_ms=58.920 mean_ms=3.928 fingerprint=d70c5cd4c8d795ceef6d40f15ba56ea9a3d9d9193822c41d753459871b20bd1d
all-smart          3691.637 ms -> 203.642 ms  (18.13x faster, -94.5%)
all-name           10.376 ms -> 10.415 ms  (1.00x faster, --0.4%)
all-recent         23593.479 ms -> 167.261 ms  (141.06x faster, -99.3%)
search-recent      894.897 ms -> 11.504 ms  (77.79x faster, -98.7%)
filter-recent      23313.984 ms -> 167.432 ms  (139.24x faster, -99.3%)
filter-local-name   3.921 ms ->  3.928 ms  (1.00x faster, --0.2%)

output equivalence: all query fingerprints identical
```

## 验收

- `DEVPULSE_SIGNING_MODE=unsigned ./scripts/verify.sh build`：通过。
- 定向测试 `CommitReadinessEngineTests`、`SharedSnapshotStoreTests`、`ActivityEventTests`、`RepositoryActivityConsistencyTests`：234 个测试通过。
- 复用 `/tmp/devpulse-build` 运行 `DEVPULSE_SIGNING_MODE=unsigned ./scripts/verify.sh test`：939 个测试、94 个套件通过。
- `bash -n scripts/benchmark-repository-list-query.sh`、`git diff --check`、`./scripts/secret-scan.sh staged`：通过。

首次沙箱内构建因 Swift 宏插件的 `sandbox_apply: Operation not permitted` 失败；首次沙箱内基准因无法写入 `.git/worktrees` 失败。所需权限下重新执行后通过，未修改签名或产品配置。验证范围为 CLI 构建、测试和合成数据基准，未进行 GUI 手工验证。
