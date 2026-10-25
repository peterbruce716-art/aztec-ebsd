# AZtec 原生 CPR 清理

本目录提供一套绑定特定 AZtec Crystal 版本和 CPR 布局的原生清理流程。它不是适用于所有材料和任务的通用降噪建议；运行前先确认内置步骤与研究目标相符，并检查代码中使用的具体参数。

## 内置流程

默认顺序为：

| 顺序 | 原生步骤 | 设置 |
|---|---|---|
| 1 | Zero Solution Removal | agreeing neighbours 依次 8→1；每级 Iterate=true、MaxIterations=50；完整阶梯最多50趟，某趟结束后零解数量不再下降时停止 |
| 2 | Wild Spike Removal | 一次；读取并记录当前 MaximumPixelSize |
| 3 | Auto Clean-Up | 连续5次；每次使用上一步返回的 IDataset，并分别记录原生 Sequence 和结果 |
| 4 | Kuwahara | Quadrants、Radius=3，最后执行一次 |

流程不执行伪对称删除。UI Level1 对应8邻点，Level8对应1邻点；内部枚举0..7对应8..1。每级50次是原生迭代上限，阶梯最多50趟是另一个上限。

默认保存策略为 `NativeSave`，保留原生 Euler 保存语义。若需要把临时滤波四元数提交为 Euler，可显式指定 `FilteredQuaternion`；两种保存语义不同，不能静默替换。详情及报告字段以运行后的 `cleanup-report.json` 为准。

## 运行环境与命令

主编排使用 PowerShell 7 Core；AZtec .NET Framework 调用由 Windows PowerShell Framework `-NoProfile -STA` 子进程执行。要求 x64 Windows、AZtec Crystal **5.1.7829.1** 和 .NET Framework 4.8。厂商程序集和许可不随包提供，其他 AZtec 版本或安装布局须先适配并重新验证。

```powershell
$skillRoot = (Resolve-Path 'C:\path\to\aztec-ebsd').Path
& (Join-Path $skillRoot 'scripts/native-cleanup/run_aztec_native_cleanup.ps1') `
  -CprPath 'D:\data\map.cpr' -OutputDirectory 'D:\results\map-cleanup'
& (Join-Path $skillRoot 'scripts/native-cleanup/verify_aztec_native_cleanup_run.ps1') `
  -RunDirectory 'D:\results\map-cleanup'
```

输入需有同名 CRC，输出目录必须不存在。当前 adapter 仅支持单 Dataset、矩形网格和代码校验的 CPR 字段布局；点数必须匹配网格维度，CRC 长度须满足每点记录大小。遇到不匹配或不支持结构时停止，不截断、补零或替换 CRC 来绕过预检。

仅当 `cleanup-report.json` 显示完成且独立 verifier 通过后，才将 `cleaned.cpr` 用于后续导出。保留报告、日志、provenance mask、快照以及派生 CPR/CRC 文件。

## 验收与数据解释

流程对输入前后哈希、派生文件、点级数据和独立读回进行验收。报告分别记录字段变化和新增已解析点。邻点补出的取向仍是算法生成的派生值，不是实验测量。

原生滤波可能以内存取向和 CPR Euler 序列化表示不同的状态；不得假设每个中间四元数都按相同形式持久化。按所选保存策略阅读报告和独立读回结果。GOS/KAM 的解释边界见[清理指标与 MTEX](cleanup-metrics-and-mtex.md)。
