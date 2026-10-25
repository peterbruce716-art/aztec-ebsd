---
name: aztec-ebsd
description: Use when cleaning Oxford AZtec Crystal CPR/CRC data with native algorithms, exporting native IPF/KAM/GOS maps, comparing EBSD maps, or processing and interpreting EBSD data with MATLAB/MTEX.
---

# Aztec-ebsd

先区分任务是数据清理、数值分析、原生地图导出，还是参考图比较。导出图片不代表清理了 CPR；原生数值或调用成功不代表地图与参考逐像素等同。

## 当前入口与路由

- **已保存 CPR/CRC 导出 IPF、KAM、OS/GOS：** 使用本技能的 `assets/aztec-native-toolchain/03_tools/aztec_exporter/AZtecBmpExporter.exe`，默认 `native-v1`；DLL 为同目录 `AZtecBmpExporter.dll`。先读 [原生工具链及操作规范](references/aztec-native-toolchain.md)。这是真实 AZtec MapExport 的版本绑定集成，不是厂商承诺稳定的公共 SDK。
- **参考图比较或展示：** 读上述规范的验收部分及 [当前验证边界](references/native-validation-evidence.md)。区分原生位图与保存一致、整图严格一致及图例/地图外一致。固定八样品验证器和展示脚本是回归用例，不能直接当作任意新样品的通用入口。
- **清理、去噪、补零或改进 CPR：** 先读 [AZtec 原生降噪配方](references/aztec-native-cleanup.md) 和 [清理、数值与 MTEX 边界](references/cleanup-metrics-and-mtex.md)，当前用户默认使用已验证的本地配方 `local-cleanup-v1`，入口为 `scripts/native-cleanup/run_aztec_native_cleanup.ps1`（优化版入口；保留原参数兼容）。默认 `-AuditMode Fast`：阶段进度追加写入 `stage-progress.jsonl`，运行中只更新轻量检查点，结束时生成最终汇总；`Strict` 用于需要逐阶段全图快照的回归。字段反射访问器复用，最终全量快照与独立读回验收保持开启。该名称仅标识本文配方，不是新增 CLI 参数；它不是材料无关的通用清理建议，其他任务须依据输入和目标明确参数。顺序为：8→1 邻点去除零解析，每级原生迭代上限50次，完整阶梯最多50趟、零解数不再下降时停止 → 单独执行一次 Wild Spike Removal，固定 `FourPixels`，使≤4 pixels 的小连通晶粒进入 AZtec 原生野尖峰候选判据 → 使用原生 `RawData.Nullify(BitArray)` 清除同一 `PhaseID`、8 邻域连通、`PhaseID>0` 且严格小于10 pixels 的全部小连通区域 → Auto Clean 连续5次，每次将上一步原生 `IDataset` 返回值传入下一次（其序列内 WildSpikeRemoval 同样固定 `FourPixels`）→ 若仍有零解，再执行最多50趟完整8→1原生 `ZeroSolutionRemoval` 邻域补点，直到零解数不再下降；导出前最终零解必须为0 → 象限（Quadrants）、半径3 Kuwahara滤波。原生尖峰判据还包含包围关系；不对边缘、跨相或多晶粒包围的小区域强制改写，详见降噪规范。`<10 pixels` 阶段是导出前的原生零解预处理，补点阶段只使用AZtec原生邻域算法并记录趟数和最终零解数，验收要求最终零解数为0。按用户最新决定排除伪对称删除。默认 `-PersistencePolicy NativeSave` 保留原生Euler保存状态以匹配已有改进结果；需要将临时滤波四元数提交到Euler时显式选 `FilteredQuaternion`。两者保存语义不同，详见降噪规范。派生CPR必须独立读回验证后才能导出；地图EXE/DLL本身只负责导出。
- **批量调度：** 使用 `scripts/retry_failed_aztec_native_batch_parallel.ps1`，默认 `-AuditMode Fast -MaxConcurrency 10 -CleanupConcurrency 2 -WorkerAttempts 3`。调度器测量 CPU 余量和可用物理内存；两者均不少于 10% 时保持 10 路。任一低于 10%、资源测量失败或 worker 报告内存不足时，自动限到 5 路；资源恢复后可在已有 worker 自然结束后回升到 10 路，不强杀正在处理的样品。升降载原因与测量值写入本次运行目录的 `resource-policy.jsonl`。`-AllowHighConcurrency` 仅为旧命令兼容，不绕过资源门槛。调度器使用跨进程互斥锁，重复启动会直接报告 `batch_already_running`。机器重启后，先确认没有旧调度器/worker 仍在运行，并重新执行完整工具链校验及 Framework 实际 STA 线程预检；随后先用 `-FailedOnly` 重试日志中仍失败的样品，再不加 `-FailedOnly` 恢复全部未完成项。后一步会覆盖没有来得及写入 retry 日志的中断样品；已验收输出会重新校验并复用。每个样品在独立 PowerShell 子进程、独立清理目录和独立 BMP 目录中执行；原生 Framework/WPF 清理阶段由命名信号量限制为 2 路，BMP exporter 由跨进程命名互斥锁串行执行。导图程序即使返回非零码，只要 `render_manifest.json` 为 completed 且 IPF/KAM/GOS 三图哈希验收通过，也记录为完成并保留 `export_warning`。每个失败目录及 worker 诊断均保留。
- **原始损坏样品：** 工作区批次目录可放置 `raw-data-corrupted.json`，以 `entries[].source`、`reason`、`failure_kind=raw_data_corrupted` 记录已确认的原始 CPR/CRC 损坏或不可配对样品。批量入口默认永久跳过这些源，覆盖报告将它们计入 `excluded_raw_data_corrupted`，不把跳过项伪装成完成；只有数据修复并明确传入 `-IncludeRawDataCorrupted` 才允许重新纳入。`skipped_missing_crc` 现在进入统一候选与覆盖统计，未标记的缺 CRC 样品在补齐同名 CRC 后可恢复重试。
- 批量脚本会跳过历史状态日志中的空行、非法 JSON 和误写入的 JSON 数组行，并在覆盖报告记录解析错误计数；按源 CPR 取最新状态，每次批次结束生成 `retry-coverage.json`、`unattempted-sources.json` 和 `unresolved-sources.json`。只有排除项之外的 `unattempted=0` 且 `unresolved=0` 才能宣称可处理范围完成。STA/WPF worker 的 stdout、stderr、退出码和失败 JSON 会写入样品清理目录的 `*-failure-diagnostic.json`，顶层状态保留诊断路径，禁止用 `worker_failed:clean` 这类泛化文本掩盖底层原因。
- 失败路由按证据分类：`native_dataset_not_populated`、不支持的 CRC schema、缺同名 CRC 等数据预检错误只执行一次并生成不可重试诊断；STA/WPF 初始化、内存资源、导图器和可验证的读回错误才使用有界重试。这样既减少无效重复清理，也保留后续人工修复所需的原始证据。
- 进入原生 worker 前必须做 CPR/CRC 配对预检：`NoOfPoints == xCells*yCells`，且同名 CRC 字节数必须等于 `NoOfPoints*25`。不满足时状态分类为 `input_pair_mismatch`，记录期望/实际长度并停止；禁止截断、补零、替换其他样品 CRC 或修改 CPR 头来制造配对。worker 打开项目后若 `Dataset.IsPopulated` 为 false，先通过 `Project.DataProvider` 调用带 `IDataProvider` 参数的原生填充接口，再继续清理；填充后仍为空才记录为真实 `data_preflight` 失败。
- 并发调度不改变 Fast 的最终快照、独立读回、三图 manifest 和 SHA-256 验收。完成范围从原始日志中的 `failed_or_conflicted` 与 `skipped_missing_crc` 记录构造，先按持久化损坏清单排除，再按源 CPR 汇总最新 retry 状态；只有 `retry-coverage.json` 显示 `unattempted=0`、`unresolved=0` 才能判定该可处理范围完成。被排除的损坏 CPR 通过 `excluded_raw_data_corrupted` 单列，不混入完成数；不要用旧覆盖文件或当前批次候选数推断全局 CPR 总数。缺同名 CRC 必须单独留痕；修复并配对后，未列入损坏清单的项可恢复重试。不要同时启动旧的串行 retry 入口和并行入口。
- **MTEX 分析或算法对比：** 本包未提供通用可运行的 MTEX 处理入口；先读 [MTEX 分析边界](references/cleanup-metrics-and-mtex.md)，依据本机当前 MATLAB/MTEX 版本的官方 help 确认读取器和参数，再为当前任务编写并验证脚本。明确对称性、坐标系、邻域、晶粒重构和阈值，记录软件版本。AZtec 原生图片请求不自动切换到 MTEX 或 Pillow 绘制。

从当前实际技能目录解析相对路径，不假设当前目录或工作区固定。`C:/ziliao/sem-eds-ebsd` 是已有证据的来源工作区；该工作区的旧 `03_tools/aztec_mtex_local_profile.md` 和本技能历史记录可能包含旧渲染路线，不覆盖本入口及最新规范。

## 快速使用

在 PowerShell 7 中，把 `$skillRoot` 设置为本技能的实际目录：

```powershell
$skillRoot = (Get-Location).Path
& (Join-Path $skillRoot 'scripts/verify-toolchain.ps1')
# 使用当前用户的 local-cleanup-v1 本地配方降噪；默认 MaxZeroCycles=50、NativeSave。
& (Join-Path $skillRoot 'scripts/native-cleanup/run_aztec_native_cleanup.ps1') -CprPath 'C:\path\sample.cpr' -OutputDirectory 'C:\path\new-cleanup'
# 仅在 cleanup-report.json 验收通过后，将其 cleaned.cpr 送入导出器。
$toolRoot = Join-Path $skillRoot 'assets/aztec-native-toolchain'
$exporter = Join-Path $toolRoot '03_tools/aztec_exporter/AZtecBmpExporter.exe'
& $exporter --input 'C:\path\new-cleanup\cleaned.cpr' --output 'C:\path\new-output' --types ALL --template native-v1
```

输入必须是已获授权的本地 CPR 及同名 CRC，输出目录必须尚不存在。示例路径必须换成实际输入和全新输出；不要把样品或运行结果写进技能目录。批量入口、DLL、显示范围及兼容模式见操作规范。

本机前置条件为标准路径 PowerShell 7、.NET Framework 4.8 和已授权 AZtec Crystal 5.1 安装。主流程运行于 PowerShell 7；仅厂商 WPF worker 和 Framework DLL 验证宿主使用 Windows PowerShell Framework STA 子进程。技能不携带厂商程序集或许可，不是仅靠两个二进制即可独立部署的工具。

## 必须保持的导出与验收约束

- 生产原生导出不读取参考 BMP，不改写输入 CPR/CRC，不启动 AZtec GUI、Application/Window、HTTP 或网络服务，不调用 MTEX/Pillow 重绘。参考图仅供独立离线比较与展示。
- 使用原生绘制，严格报告与参考的真实差异。用户已选择保留原生行为；不采用串行诊断代替生产绘制，不以参考像素补图，不为降低误差改变参考图或待比较图的尺寸。
- 检查每种图的状态、源文件前后哈希、原生 report 及最终文件哈希；保留 `native_pixel_snapshot`、`saved_pixel_snapshot`、`saved_pixels_match_native`、`pixel_sha256` 和重试日志。
- 最多三次新 STA worker 尝试，仅已知 WPF 初始化症状重试；STA 条件错误、输入变化和像素不一致不重试。失败目录保留，验收按 manifest 的成功 `native_report` 定位。
- 当前完整等同性仍为 `NativeFullMapFidelity=not_accepted`。原生边界并行写入已复现黑/灰像素波动；不得把某次 0 差异、宽松容差或原生代码调用等同于普遍完整等同性。
- `native-v1` 是固定本地 profile，非通用 AZtec 设置恢复器：KAM 使用 Square/3×3/periphery/5°，GOS 使用 10° 晶界重构及 Mean，IPF 要求唯一保存的 BC+IPF+GB 地图。不能称这些为所有数据的默认或当前 UI 设置。

## 科学解释

区分 GOS、KAM、LAGB/HAGB、IPF 和再结晶分数。GOS < 2° 可描述为 recrystallized-like / low internal misorientation state，不能绝对等同完全再结晶；低 KAM 只能支持局部取向梯度较低，不能单独证明再结晶。讨论 CDRX/DDRX 应结合晶粒尺寸、边界迁移、亚晶旋转、HAGB 增加和新晶粒形貌，不把相关性写成因果。

## 历史资料

[旧技能完整记录](references/legacy-skill-before-native-mapexport.md)、[旧 IPF 规范](references/aztec-ipf-standard.md) 和 [旧工作流](references/ebsd-workflow.md) 仅在追溯旧结果时按需读取。其“完整原生导出尚不可用”、Pillow/MTEX 生产重建、参考画布复用或无条件依赖 GUI 的段落已被当前原生路线取代；旧数据清理证据须独立复核，不因本次导出验证而自动升级。


## 失败恢复与语义验收补充

- `requires_framework_sta_worker`、STA 预检失败或重启后环境不确定时，先停止调度并复测真实执行线程；这类宿主错误不能通过降低并发重试成样品失败。只有 STA 预检通过、且资源测量或错误诊断指向内存/并发竞争时，才自动降到 5 路；重试后若仍出现同一类非 STA 故障，再暂停并调查根因，不要盲目降到单路循环重试。
- C5 验收以 dataset_errorcode_unchanged=true 和独立读回通过为语义门槛；相位相关序列化造成的 C5 字节哈希差异记录为 phase_dependent_c5_reencoding warning，不再把它误判为清理失败。


## Framework STA 启动预检

- 每个批次启动前必须从隔离 Framework 子进程实际验证 `PSEdition=Desktop` 且 `Thread.CurrentThread.ApartmentState=STA`；验证代码必须在将要运行 native worker 的执行线程内，不得仅检查 `-STA` 参数、`$Host.Runspace.ApartmentState` 或子进程名称。PowerShell 7 下直接调用 `& $frameworkHost ...` 和 `Start-Process -STA` 都可能在不同宿主配置中报告 MTA；以子进程实测为准，失败即停止批次。
- Windows 重启后，旧进程句柄已经失效；不依据旧会话印象推断 STA 状态，也不直接补跑。确认没有残留调度器/worker，执行完整 `verify-toolchain.ps1`，再从将实际用于 Framework worker 的同一路径做线程预检。预检失败时，不创建样品失败状态或输出目录。
- 原生导图的 Framework STA 阶段也必须用 `Start-Process` 启动独立子进程并保留 stdout、stderr、退出码和超时处理；不要仅凭命令行含 `-STA` 或宿主为 Framework 就认定线程是 STA。
- 若预检子进程的 PowerShell runspace 显示 STA、但实际执行线程显示 MTA，归因为宿主/线程模型故障，不归因于 CPR/CRC，不生成样品失败记录，也不重复清理或导图。先更换并实测可用的 Framework STA 执行宿主；恢复运行前须用同一调用路径验证实际 native worker 线程为 STA。
- 若运行中出现 requires_framework_sta_worker、worker_exit_without_result、WPF Geometry 类型初始化错误或 0xC0000142，立即暂停调度并先检查 Framework STA 启动链；不可仅降低并发或加大重试次数继续。只有 STA 预检通过、且错误证据明确为资源竞争时，才按 5 路或 1 路恢复。
