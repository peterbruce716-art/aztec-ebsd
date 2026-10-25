---
name: aztec-ebsd
description: Use when processing Oxford Instruments AZtec Crystal EBSD data, cleaning CPR/CRC files, exporting native IPF/KAM/GOS maps, or analyzing EBSD data with MATLAB/MTEX.
---

# AZtec EBSD

本技能用于 AZtec Crystal EBSD 数据清理、原生地图导出和相关分析。根据用户目标选择流程：导出地图不会清理 CPR；程序成功运行也不能证明所有样品或配置下均与参考图逐像素一致。

## 工作流

- **导出原生地图：** 使用 `assets/aztec-native-toolchain/03_tools/aztec_exporter/AZtecBmpExporter.exe`，同目录的 `AZtecBmpExporter.dll` 为配套接口。先读[原生工具链说明](references/aztec-native-toolchain.md)。
- **清理或更新 CPR：** 先读[原生清理说明](references/aztec-native-cleanup.md)，再使用 `scripts/native-cleanup/run_aztec_native_cleanup.ps1`，显式指定 CPR 输入与全新的输出目录，并运行独立验收脚本。内置流程依赖特定 AZtec 版本和数据布局；运行前需确认其设置适合当前输入与科学目标。
- **批次处理：** 使用 `scripts/retry_failed_aztec_native_batch_parallel.ps1`。必须显式提供 `-Workspace`、`-OriginalStatusPath` 和 `-RetryStatusPath`；README.md 提供 dry-run 示例。
- **MTEX 或指标分析：** 阅读[清理、指标与 MTEX 边界](references/cleanup-metrics-and-mtex.md)。区分 GOS、KAM、LAGB/HAGB、IPF 和 recrystallized-like fraction。
- **评估导出结论：** 阅读[验证范围](references/native-validation-evidence.md)。本包不证明所有 AZtec 版本、数据集、地图或显示配置具有等同性。

## 安装与前置条件

按 [README.md](README.md) 安装和验证。仓库附带四个由本项目源码构建的 helper 二进制；路径见 [BINARY-DISTRIBUTION.md](BINARY-DISTRIBUTION.md)。它们不是 AZtec Crystal 程序或 Oxford Instruments 厂商程序集。

原生执行要求 x64 Windows、PowerShell 7、.NET Framework 4.8、在 STA 线程运行的 Windows PowerShell Framework worker，以及单独安装且已获许可的 AZtec Crystal 5.1.7829.1。脚本当前按工具链说明中的标准 AZtec 安装位置查找程序。仅下载二进制不足以运行原生功能。

## 数据处理

需要匹配的 CPR/CRC 文件。仅处理用户授权的数据，保留原始文件，并将结果写入技能目录以外的新目录。遇到不支持的 schema、CPR/CRC 不匹配、读回失败或输入哈希改变时停止。补点或重建的取向属于派生数据，不能描述为新测得数据。

`NativeFullMapFidelity=not_accepted` 是本包保留的限制。对实际数据集和配置逐项验证后，再报告科学结论或像素等同性。
