# 扫描目录解析精简与性能证据

## 基线与范围

基于 fetch 后的 `origin/main`：`e992718bffc40c58574fc432e0d6f757604c588d`。
保留此前的 canonicalization scope、扫描请求合并、Git 刷新、待收尾评估及单次排序 drain 优化。

- `ScanScheduler.swift`：两个解析入口共享 `ScanRootResolver`，删除未使用的 `capturedConfig` 参数。
- `ScanLocationProvider.swift`：默认目录成员判断由生成、排序、构造 Set 改为线性查找；每次判断只为默认目录展开解析一次 home，无跨调用缓存。
- 不改变扫描执行、Task、优先级、并发限制、取消／watchdog、Git 命令、权限申请或 security-scope 生命周期。

共享逻辑的精简本身不作为性能收益承诺；可测收益主要来自默认目录成员判断。

## 行为等价边界

- 主线程仍调用原 `resolvedURL(for:)`，保留 stale／路径变化的书签刷新、配置清理及持久化；后台仍仅解析 `.withSecurityScope` 书签，不写回。
- 遍历配置快照；即使回调更新 scheduler 配置，当前遍历不受影响。
- 默认目录先于自定义目录检查；逐项检查后才去重、排序，不提前合并书签或跳过重复条目的副作用。
- 有效书签使用其 URL；无书签或解析失败使用持久化路径。缺失目录和普通文件仍留在 roots 中，以便扫描报告错误及后续恢复。
- 容器路径被过滤；警告优先级仍为 roots 为空、容器、不可访问。设置与后台各自的既有警告文案保持原样。
- 默认目录不会因成员判断而解析符号链接；自定义目录仍使用原 canonicalization。

新增三个测试覆盖上述公共解析规则、书签 URL 回调／失败回退、调用次序（含重复条目）、符号链接去重、默认目录选择、旧容器路径迁移及成员判断与旧 Set 实现等价。
真实有效及损坏的安全作用域书签另外由 A/B 程序覆盖。没有进行签名安装或手动撤销 macOS 权限；CLI 不能证明真实授权弹窗、已安装 Widget 的运行体验。

## 可复现 A/B

```sh
python3 scripts/benchmark-scan-roots.py --baseline-git e992718bffc40c58574fc432e0d6f757604c588d
```

程序从 Git 基线和工作区提取实际 Provider、后台解析方法及共享 resolver，以 Swift `-O` 在同一进程编译运行。两侧使用相同且未修改的 `RepositoryIdentity` canonicalization；不启用额外缓存。fixture 为临时目录、符号链接、缺失路径、普通文件、容器路径以及真实／损坏书签。对 roots 与 warning 精确断言后，预热并交替测量 11 对，报告每次调用的中位数（ns）。配置与 fixture 创建不计入耗时；正常解析涉及的 home 查询、文件状态及书签解析计入耗时。

环境：macOS 27.0.1 (26A434)，arm64，Apple Swift 6.4 (swiftlang-6.4.0.34.1)。重复运行两次，均全部 `equivalent=true`，checksum 均为 `378024`。

首次成功运行：

```text
empty             baseline_ns=110891   current_ns=110778   speedup=1.00x
built-ins         baseline_ns=1603906  current_ns=930999   speedup=1.72x
custom            baseline_ns=366584   current_ns=270676   speedup=1.35x
mixed-boundaries  baseline_ns=2170039  current_ns=1493338  speedup=1.45x
custom-100        baseline_ns=24326361 current_ns=14718167 speedup=1.65x
bookmark          baseline_ns=644725   current_ns=549819   speedup=1.17x
```

第二次成功运行（与最终验收并行，存在构建／测试负载）：

```text
empty             baseline_ns=113881   current_ns=113676   speedup=1.00x
built-ins         baseline_ns=1643122  current_ns=952644   speedup=1.72x
custom            baseline_ns=375478   current_ns=277570   speedup=1.35x
mixed-boundaries  baseline_ns=2168095  current_ns=1505593  speedup=1.44x
custom-100        baseline_ns=25529320 current_ns=15476458 speedup=1.65x
bookmark          baseline_ns=677579   current_ns=577923   speedup=1.17x
```

收益仅指目录解析阶段，不能外推为整体扫描速度。默认目录的绝对节省约 0.67–0.69 ms/call，100 个自定义目录约 9.61–10.05 ms/call；空配置持平。

基准脚本首轮编译因截取 `RepositoryIdentity` 时漏掉解码依赖的 `id(for:)` 失败，补齐实际方法及 CryptoKit import 后以上两轮成功。提取的既有 TaskLocal async 方法产生 Swift 6.4 deprecation warning；不属于本次生产代码改动，未为消除警告扩大范围。

## 验收记录

统一 DerivedData：`/tmp/devpulse-build`，`DEVPULSE_SIGNING_MODE=unsigned`，测试数据使用隔离容器。

- `./scripts/verify.sh build`：通过。
- 定向 `./scripts/verify.sh test`：RepositoryDiscoveryExperienceTests、CommitReadinessEngineTests、DataFreshnessStateTests、ScanConcurrencyTests、ScannerTimeoutErrorTests、ScanConfigSanitizationTests selectors；实际执行 266 tests / 4 suites，通过。
- `./scripts/verify.sh final`：构建通过，完整 961 tests / 95 suites 通过（106.269 s）。
- `./scripts/verify.sh widgetkit`：Debug 构建及 16 项接线检查通过，0 FAIL。
- `git diff --check`：通过。

维护循环的 `.agent/rules.md`、`memory.md`、`history.md`、`loop.md` 在当前 main 不存在；已读取现存历史归档，没有补造维护规则。
