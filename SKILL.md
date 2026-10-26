---
name: aztec-ebsd
description: Use when cleaning Oxford AZtec Crystal CPR/CRC data with native algorithms, exporting native IPF/KAM/GOS maps, comparing EBSD maps, or processing and interpreting EBSD data with MATLAB/MTEX.
---

# Aztec-ebsd

先区分任务是数据清理、数值分析、原生地图导出，还是参考图比较。**v7 AZtec 原生清理是本技能处理 CPR 清理、去噪、未解析点（零解）处理，以及从原始 CPR 清理后导图的默认主流程。** 只有用户明确要求保留现有 CPR 状态、只导出地图时，才走直接原生导图支路。v7 是流程版本；本机已验证的参数配方名为 `local-cleanup-v1`，两者不是相互替代的版本。零解指 AZtec 未解析点；清理报告和独立读回必须同时证实未解析点数为 0，且验收器通过，之后才能从本次新生成的 `cleaned.cpr` 导图。清理失败、未解析点非零或证据缺失时停止导图，不得直接导出原始 CPR 绕过门槛，也不得用外部平滑或插值冒充 v7 原生清理。导出图片不代表清理了 CPR；原生数值或调用成功不代表地图与参考逐像素等同。

## 当前入口与路由

- **原始 CPR 全新处理并导出地图（默认）：** 先运行 `scripts/native-cleanup/run_aztec_native_cleanup.ps1` 的 v7 原生清理，再运行独立读回验收器；仅当 `cleanup-report.json` 状态为 `complete_native_cleanup_readback_verified`、`worker.final_zero_solution_count=0`、`readback.zero_solutions=0` 且验收器通过，才把该次运行新生成的 `cleaned.cpr` 交给原生导图器。清理失败、最终零解非零或证据缺失时停止导图，不改用原始 CPR 绕过门槛。
- **已保存 CPR/CRC 只导地图：** 仅在用户明确要求不清理、保留 CPR 当前状态时，直接使用 `assets/aztec-native-toolchain/03_tools/aztec_exporter/AZtecBmpExporter.exe`，默认 `native-v1`；DLL 为同目录 `AZtecBmpExporter.dll`。直接导图不执行降噪，也不保证零解数为0。这是真实 AZtec MapExport 的版本绑定集成，不是厂商承诺稳定的公共 SDK。先读 [原生工具链及操作规范](references/aztec-native-toolchain.md)。
- **参考图比较或展示：** 读上述规范的验收部分及 [当前验证边界](references/native-validation-evidence.md)。区分原生位图与保存一致、整图严格一致及图例/地图外一致。固定八样品验证器和展示脚本是回归用例，不能直接当作任意新样品的通用入口。
- **清理、去噪、补零或改进 CPR：** 先读 [AZtec 原生降噪配方](references/aztec-native-cleanup.md) 和 [清理、数值与 MTEX 边界](references/cleanup-metrics-and-mtex.md)，当前用户默认使用已验证的本地配方 `local-cleanup-v1`，入口为 `scripts/native-cleanup/run_aztec_native_cleanup.ps1`（优化版入口；保留原参数兼容）。默认 `-AuditMode Fast`：阶段进度追加写入 `stage-progress.jsonl`，运行中只更新轻量检查点，结束时生成最终汇总；`Strict` 用于需要逐阶段全图快照的回归。字段反射访问器复用，最终全量快照与独立读回验收保持开启。该名称仅标识本文配方，不是新增 CLI 参数；它不是材料无关的通用清理建议，其他任务须依据输入和目标明确参数。顺序为：8→1 邻点去除零解析，每级原生迭代上限50次，完整阶梯最多100趟、零解数不再下降时停止 → 单独执行一次 Wild Spike Removal，固定 `FourPixels`，使≤4 pixels 的小连通晶粒进入 AZtec 原生野尖峰候选判据 → 使用原生 `RawData.Nullify(BitArray)` 清除同一 `PhaseID`、8 邻域连通、`PhaseID>0` 且严格小于10 pixels 的全部小连通区域 → Auto Clean 连续5次，每次将上一步原生 `IDataset` 返回值传入下一次（其序列内 WildSpikeRemoval 同样固定 `FourPixels`）→ 若仍有零解，再执行最多100趟完整8→1原生 `ZeroSolutionRemoval` 邻域补点，直到零解数不再下降；导出前最终零解必须为0。这里的100是完整阶梯循环上限，每个原生步骤的 `MaxIterations` 仍为50；若仍有残余零解，worker 记录 `native_zero_solution_exhausted` 和剩余数量后停止导图 → 象限（Quadrants）、半径3 Kuwahara滤波。原生尖峰判据还包含包围关系；不对边缘、跨相或多晶粒包围的小区域强制改写，详见降噪规范。`<10 pixels` 阶段是导出前的原生零解预处理，补点阶段只使用AZtec原生邻域算法并记录趟数和最终零解数，验收要求最终零解必须为0。按用户最新决定排除伪对称删除。默认 `-PersistencePolicy NativeSave` 保留原生Euler保存状态以匹配已有改进结果；需要将临时滤波四元数提交到Euler时显式选 `FilteredQuaternion`。两者保存语义不同，详见降噪规范。派生CPR必须独立读回验证后才能导出；地图EXE/DLL本身只负责导出。
- **全新批量处理并导图：** 使用 `scripts/run_aztec_native_fresh_batch.ps1`。先以 `-DryRun` 核对候选数、缺失 CRC 数及输出目录冲突，再以唯一 `-RunId` 启动；该入口逐个从源 CPR 执行 v7 清理、独立读回与零解数=0门槛，之后才从新 `cleaned.cpr` 原生导出地图，不扫描或复用历史清理/地图结果。可用 `-IncludePathRegex` 按相对路径筛选指定年份目录（例如 `(?i)(^|[\\/])2025`），也可用 `-IncludeSourceListPath` 精确筛选一组原始 CPR（用于失败样品修复后从源 CPR 重做）；筛选条件会写入 dry-run 和批次启动记录。外层 `-MaxConcurrency` 默认10；清理阶段 `-CleanupConcurrency` 默认2个 Framework/WPF worker，导图器由跨进程互斥锁串行运行。输出写入每个源 CPR 所在目录下的 `AZtec_v7_fresh_<RunId>\<样品名>\cleanup` 与 `maps`；JSONL 结果和批次汇总保存在输入根目录下 `.aztec_fresh_batch_logs\<RunId>`。缺同名 CRC 的源会记为 `skipped_missing_crc`，不执行替换或修补。全新任务不得改用 retry 入口。
- **恢复/重试批量：** `scripts/retry_failed_aztec_native_batch_parallel.ps1` 只用于明确的断点恢复/失败重试；它会重新验收并复用已有合格清理或地图输出。外层调度默认最多10个样品；清理阶段由命名信号量限制为2路，导图器串行运行。调度器测量 CPU 余量和可用物理内存；两者均不少于10%时保持10路；任一低于10%、资源测量失败或 worker 报告内存不足时自动限到5路，资源恢复后可回升。升降载原因及测量值写入 `resource-policy.jsonl`。`-AllowHighConcurrency` 仅为旧命令兼容，不绕过资源门槛。调度器使用跨进程互斥锁；机器重启后须重新验证工具链与实际 Framework STA 线程，再重试未完成样品。每个失败目录和 worker 诊断均保留。
- **全新批次配对预检与失败分类：** `run_aztec_native_fresh_batch.ps1` 在进入原生清理前验证 `NoOfPoints == xCells*yCells` 且同名 CRC 字节数等于 `NoOfPoints*25`；不匹配时写入 `failure_kind=input_pair_mismatch`、期望/实际值并停止该源，不截断、补零、替换 CRC 或修改 CPR 头。
- **原始损坏样品：** 工作区批次目录可放置 `raw-data-corrupted.json`，以 `entries[].source`、`reason`、`failure_kind=raw_data_corrupted` 记录已确认的原始 CPR/CRC 损坏或不可配对样品。`run_aztec_native_fresh_batch.ps1` 默认读取输入根目录下的 `raw-data-corrupted.json` 或 `.aztec_fresh_batch_logs\raw-data-corrupted.json`，永久跳过这些源，并在 dry-run、启动记录、中断记录和最终汇总中计入 `excluded_raw_data_corrupted`；不会把它们伪装成完成或普通失败。只有数据修复并明确传入 `-IncludeRawDataCorrupted` 才允许重新纳入。`skipped_missing_crc` 现在进入统一候选与覆盖统计，未标记的缺 CRC 样品在补齐同名 CRC 后可恢复重试。
- 批量脚本会跳过历史状态日志中的空行、非法 JSON 和误写入的 JSON 数组行，并在覆盖报告记录解析错误计数；按源 CPR 取最新状态，每次批次结束生成 `retry-coverage.json`、`unattempted-sources.json` 和 `unresolved-sources.json`。只有排除项之外的 `unattempted=0` 且 `unresolved=0` 才能宣称可处理范围完成。STA/WPF worker 的 stdout、stderr、退出码和失败 JSON 会写入样品清理目录的 `*-failure-diagnostic.json`，顶层状态保留诊断路径，禁止用 `worker_failed:clean` 这类泛化文本掩盖底层原因。
- 失败路由按证据分类：`native_dataset_not_populated`、不支持的 CRC schema、缺同名 CRC 等数据预检错误只执行一次并生成不可重试诊断；STA/WPF 初始化、内存资源、导图器和可验证的读回错误才使用有界重试。这样既减少无效重复清理，也保留后续人工修复所需的原始证据。
- 进入原生 worker 前必须做 CPR/CRC 配对预检：`NoOfPoints == xCells*yCells`，且同名 CRC 字节数必须等于 `NoOfPoints*25`。不满足时状态分类为 `input_pair_mismatch`，记录期望/实际长度并停止；禁止截断、补零、替换其他样品 CRC 或修改 CPR 头来制造配对。worker 打开项目后若 `Dataset.IsPopulated` 为 false，先通过 `Project.DataProvider` 调用带 `IDataProvider` 参数的原生填充接口，再继续清理；填充后仍为空才记录为真实 `data_preflight` 失败。
- 并发调度不改变 Fast 的最终快照、独立读回、三图 manifest 和 SHA-256 验收。完成范围从原始日志中的 `failed_or_conflicted` 与 `skipped_missing_crc` 记录构造，先按持久化损坏清单排除，再按源 CPR 汇总最新 retry 状态；只有 `retry-coverage.json` 显示 `unattempted=0`、`unresolved=0` 才能判定该可处理范围完成。被排除的损坏 CPR 通过 `excluded_raw_data_corrupted` 单列，不混入完成数；不要用旧覆盖文件或当前批次候选数推断全局 CPR 总数。缺同名 CRC 必须单独留痕；修复并配对后，未列入损坏清单的项可恢复重试。不要同时启动旧的串行 retry 入口和并行入口。
- **MTEX 分析或算法对比：** 本包未提供通用可运行的 MTEX 处理入口；先读 [MTEX 分析边界](references/cleanup-metrics-and-mtex.md)，依据本机当前 MATLAB/MTEX 版本的官方 help 确认读取器和参数，再为当前任务编写并验证脚本。明确对称性、坐标系、邻域、晶粒重构和阈值，记录软件版本。AZtec 原生图片请求不自动切换到 MTEX 或 Pillow 绘制。

从当前实际技能目录解析相对路径，不假设当前目录或工作区固定。包内历史说明只用于解释适用边界，不包含样品、参考图或本机工作区路径。

## 快速使用

在 PowerShell 7 中，把 `$skillRoot` 设置为本技能的实际目录：

```powershell
$skillRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
& (Join-Path $skillRoot 'scripts/verify-toolchain.ps1')
# 全新批次先 dry-run，再给本次运行唯一 ID；旧结果不会复用。
$freshBatch = Join-Path $skillRoot 'scripts/run_aztec_native_fresh_batch.ps1'
& $freshBatch -InputRoot 'C:\path\raw-data' -ExcludeDirectoryName @('reference','improved') -RunId '20261026_run01' -MaxConcurrency 10 -DryRun
& $freshBatch -InputRoot 'C:\path\raw-data' -ExcludeDirectoryName @('reference','improved') -RunId '20261026_run01' -MaxConcurrency 10
# 按年份分批时可先 dry-run 再启动；此例只匹配相对路径中的 2025 年目录。
& $freshBatch -InputRoot 'C:\path\raw-data' -ExcludeDirectoryName @('参考','改进') -IncludePathRegex '(?i)(^|[\\/])2025' -RunId '20261026_2025_run01' -MaxConcurrency 10 -DryRun
# 使用当前用户的 local-cleanup-v1 本地配方降噪；默认 MaxZeroCycles=100、NativeSave。
& (Join-Path $skillRoot 'scripts/native-cleanup/run_aztec_native_cleanup.ps1') -CprPath 'C:\path\sample.cpr' -OutputDirectory 'C:\path\new-cleanup'
# 仅在 cleanup-report.json 状态通过、worker.final_zero_solution_count=0、readback.zero_solutions=0 且独立验收器通过后，导出本次新生成的 cleaned.cpr。
$null = & (Join-Path $skillRoot 'scripts/native-cleanup/verify_aztec_native_cleanup_run.ps1') -RunDirectory 'C:\path\new-cleanup'
$toolRoot = Join-Path $skillRoot 'assets/aztec-native-toolchain'
$exporter = Join-Path $toolRoot '03_tools/aztec_exporter/AZtecBmpExporter.exe'
& $exporter --input 'C:\path\new-cleanup\cleaned.cpr' --output 'C:\path\new-output' --types ALL --template native-v1
```

输入必须是已获授权的本地 CPR 及同名 CRC，输出目录必须尚不存在。示例路径必须换成实际输入和全新输出；不要把样品或运行结果写进技能目录。批量入口、DLL、显示范围及兼容模式见操作规范。

本机前置条件为标准路径 PowerShell 7、.NET Framework 4.8 和已授权 AZtec Crystal 5.1 安装。主流程运行于 PowerShell 7；仅厂商 WPF worker 和 Framework DLL 验证宿主使用 Windows PowerShell Framework STA 子进程。技能不携带厂商程序集或许可，不是仅靠两个二进制即可独立部署的工具。

## 必须保持的导出与验收约束

- 交付目录每种图只保留最终 `maps\\IPF.bmp`、`maps\\KAM.bmp`、`maps\\GOS.bmp`；`maps\\work` 下的 native stdout/stderr、`render.log`、`work\\native_*` 和重试目录都是临时导图资料，成功复制并验收最终图后连同目录一起删除，manifest 内保留必要的 native report 快照和清理记录；若全部尝试失败，则保留失败目录和诊断证据供排查。
- 生产原生导出不读取参考 BMP，不改写输入 CPR/CRC，不启动 AZtec GUI、Application/Window、HTTP 或网络服务，不调用 MTEX/Pillow 重绘。参考图仅供独立离线比较与展示。
- 使用原生绘制，严格报告与参考的真实差异。用户已选择保留原生行为；不采用串行诊断代替生产绘制，不以参考像素补图，不为降低误差改变参考图或待比较图的尺寸。
- 检查每种图的状态、源文件前后哈希、原生 report 及最终文件哈希；保留 `native_pixel_snapshot`、`saved_pixel_snapshot`、`saved_pixels_match_native`、`pixel_sha256` 和重试日志。
- 最多三次新 STA worker 尝试，仅已知 WPF 初始化症状重试；STA 条件错误、输入变化和像素不一致不重试。成功验收后 native 临时目录会被删除，验收按 manifest 中的 `native_report_snapshot` 定位；失败目录和诊断证据保留。
- 当前完整等同性仍为 `NativeFullMapFidelity=not_accepted`。原生边界并行写入已复现黑/灰像素波动；不得把某次 0 差异、宽松容差或原生代码调用等同于普遍完整等同性。
- `native-v1` 是固定本地 profile，非通用 AZtec 设置恢复器：KAM 使用 Square/3×3/periphery/5°，GOS 使用 10° 晶界重构及 Mean，IPF 要求唯一保存的 BC+IPF+GB 地图。不能称这些为所有数据的默认或当前 UI 设置。

## 科学解释

区分 GOS、KAM、LAGB/HAGB、IPF 和再结晶分数。GOS < 2° 可描述为 recrystallized-like / low internal misorientation state，不能绝对等同完全再结晶；低 KAM 只能支持局部取向梯度较低，不能单独证明再结晶。讨论 CDRX/DDRX 应结合晶粒尺寸、边界迁移、亚晶旋转、HAGB 增加和新晶粒形貌，不把相关性写成因果。

## 历史资料

[IPF 规范](references/aztec-ipf-standard.md) 和 [工作流](references/ebsd-workflow.md) 仅用于解释当前适用边界。历史结果须独立复核，不因本次导出验证而自动升级。


## 失败恢复与语义验收补充

- fresh-batch 运行期间，`.aztec_fresh_batch_logs\\<RunId>\\batch-active.json` 是活动锁；只要该文件对应的批次进程仍存活，禁止删除、移动或清空任何该 RunId 的输出目录。样品目录中的 `maps\\.owner` 也视为正在写入的保护信号。只有批次进程已终止、`batch-results.jsonl` 已落盘并完成结果审计后，才允许清理残留不完整目录；被锁目录应跳过并在批次结束后复核，避免破坏导出器正在写入的 BMP。

- `requires_framework_sta_worker`、STA 预检失败或重启后环境不确定时，先停止调度并复测真实执行线程；这类宿主错误不能通过降低并发重试成样品失败。只有 STA 预检通过、且资源测量或错误诊断指向内存/并发竞争时，才自动降到 5 路；重试后若仍出现同一类非 STA 故障，再暂停并调查根因，不要盲目降到单路循环重试。
- C5 验收以 dataset_errorcode_unchanged=true 和独立读回通过为语义门槛；相位相关序列化造成的 C5 字节哈希差异记录为 phase_dependent_c5_reencoding warning，不再把它误判为清理失败。


## Framework STA 启动预检

- 每个批次启动前必须从隔离 Framework 子进程实际验证 `PSEdition=Desktop` 且 `Thread.CurrentThread.ApartmentState=STA`；验证代码必须在将要运行 native worker 的执行线程内，不得仅检查 `-STA` 参数、`$Host.Runspace.ApartmentState` 或子进程名称。当前验证环境中 Framework PowerShell 进程启动线程即使带 `-STA` 仍可能是 MTA；应在该 Framework 子进程中创建 `RunspaceFactory.CreateRunspace()`，设置 `ApartmentState=STA` 与 `PSThreadOptions.UseNewThread` 后，在该 runspace 内运行 probe 和 native worker。判定时使用 `GetApartmentState()` 与 `ApartmentState.STA` 枚举比较或数值 1；不要把该枚举先转成字符串后据此判定。PowerShell 7 下直接调用 `& $frameworkHost ...` 和 `Start-Process -STA` 也可能在不同宿主配置中报告 MTA；以实际 worker 执行线程的实测为准，失败即停止批次。
- Windows 重启后，旧进程句柄已经失效；不依据旧会话印象推断 STA 状态，也不直接补跑。确认没有残留调度器/worker，执行完整 `verify-toolchain.ps1`，再从将实际用于 Framework worker 的同一路径做线程预检。预检失败时，不创建样品失败状态或输出目录。
- 原生导图的 Framework 阶段必须启动独立子进程并保留 stdout、stderr、退出码和超时处理；使用 .NET `ProcessStartInfo`（`UseShellExecute=false`、`CreateNoWindow=true`）。Framework 宿主即使带 `-STA` 也可能在主线程报告 MTA；导图预检和 `Native()` 必须在子进程内创建 `ApartmentState=STA`、`ThreadOptions=UseNewThread` 的 runspace，并由 `native_map.ps1` 在实际执行线程上检查 Desktop|STA。不能仅凭启动参数或 runspace 配置值判定通过。
- 若实际 native worker 线程显示 MTA，归因为宿主/线程模型故障，不归因于 CPR/CRC，不生成样品失败记录，也不重复清理或导图。先修复并实测 STA runspace 启动链；恢复运行前须用同一调用路径验证实际 native worker 线程为 STA。
- 若运行中出现 requires_framework_sta_worker、worker_exit_without_result、WPF Geometry 类型初始化错误或 0xC0000142，立即暂停调度并先检查 Framework STA 启动链；不可仅降低并发或加大重试次数继续。只有 STA 预检通过、且错误证据明确为资源竞争时，才按 5 路或 1 路恢复。
- 修改启动链后，用 `scripts/test-process-launch.ps1` 在当前宿主中实测 Framework `Desktop|STA`、stdout/stderr、退出码和无窗口启动，再运行完整 `scripts/verify-toolchain.ps1`。测试探针须在独立 STA runspace 的执行线程内读线程 apartment 数值，并确认值为 1。
