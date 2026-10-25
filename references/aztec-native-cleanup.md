# AZtec 原生降噪

## 当前配方

这套配方由当前用户指定，并在本工作区验证，文档中称为 `local-cleanup-v1`（仅为配方名称，不是 CLI 参数）。它仍是当前用户的默认配方，默认保存策略保持 `NativeSave`；验证范围是本文的版本、数据结构和保存状态，不是材料无关的通用降噪建议。其他任务应按输入、科学目标和明确参数选择配方，不能仅因请求“降噪”就把本地次数与阈值当成普适参数。所有清理调用已安装AZtec的具体原生步骤；导出器本身不清理数据。

| 顺序 | 原生步骤 | 设置 |
|---|---|---|
| 1 | Zero Solution Removal | agreeing neighbours依次8→1；每级Iterate=true、MaxIterations=50；完整阶梯最多50趟，某趟结束零解数不再下降时停止 |
| 2 | Wild Spike Removal | 独立执行一次；固定MaximumPixelSize=FourPixels |
| 3 | Small-component pre-clean | 使用原生`RawData.Nullify(BitArray)`，清除同一`PhaseID`、8邻域连通、`PhaseID>0`且严格小于10 pixels的全部小连通区域；记录候选连通域、置零像素和残余数 |
| 4 | Auto Clean-Up | 连续执行5次；每次将上一步返回的原生IDataset传入下一次，分别记录原生Sequence和结果；Sequence内WildSpikeRemoval也固定FourPixels |
| 5 | Native zero-solution refill | 若Auto Clean后仍有零解，再执行最多50趟完整8→1原生`ZeroSolutionRemoval`邻域补点；最终残余零解必须为0 |
| 6 | Kuwahara | Quadrants、Radius=3，1次；最后执行 |

用户已取消伪对称删除；不读取或要求其相/轴/角度参数，也不在Auto Clean中执行该步骤。UI Level1对应8邻点、Level8对应1邻点；内部枚举0..7对应8..1。每级50为原生迭代上限，不是实际执行轮数。完整阶梯50趟是另一层上限；默认启用历史上限，不能只做一趟。

### 小连通晶粒与野尖峰上限

当前已验证的 AZtec Crystal 5.1.7829.1 原生枚举 `WildSpikeRemovalMaximumPixelSize` 只提供 `OnePixel`、`TwoPixels`、`ThreePixels`、`FourPixels` 四档；本机 API 探针保存在工作区 `03_tools/aztec_component_api_probe.txt`。本配方将 `FourPixels` 作为最大候选连通晶粒尺寸，因此不超过4 pixels 的小连通晶粒进入原生 wild-spike 候选范围；5 pixels 及以上不由该阈值处理。该阈值此前未显式设置，清理报告记录的默认值为 `OnePixel`，是小连通噪点漏过的原因。

按 AZtec 原生语义，尺寸上限只是候选筛选之一：Wild Spike Removal 还要求候选晶粒由一个其他晶粒包围，并按附近候选取向的总错配度选择替代取向。因此，“≤4 pixels 视为噪音”在本配方中表示进入原生噪点判据，不代表地图边缘、跨相边界或由多个晶粒包围的所有小区域都会被强制改写。独立 `Wild Spike Removal` 恰好执行一次；五轮 `Auto Clean-Up` 序列中的 WildSpikeRemoval 设置也显式设为 `FourPixels`，并由运行报告和验收器复核。每轮 Auto Clean-Up 调用均使用上一轮返回的原生 `IDataset` 作为输入，报告记录数据集身份链以供验收。

为处理导出前仍残留的零散像素，配方在独立 Wild Spike Removal 之后增加原生小连通区域预处理：按行优先网格使用8邻域遍历，只把同一`PhaseID`、`PhaseID>0`且连通域面积严格小于10 pixels的区域写入`BitArray`，调用`RawData.Nullify`置为原生零解，然后将该原生`IDataset`继续传给5轮Auto Clean。该步骤不是伪造的`WildSpikeRemovalStep`，也不使用伪对称删除；它保证导出前对所有小于10 pixels的同相连通噪点执行确定性的原生置零。运行报告中的`small_component_residual_components`和`small_component_residual_pixels`必须为0，验收器拒绝缺少该证据的结果。

由于`RawData.Nullify`会产生新的零解，Auto Clean完成后仍可能留下空白点。v7 在最终 Kuwahara 之前重新使用AZtec原生`ZeroSolutionRemoval`，按8→1邻点顺序执行完整阶梯，最多50趟；每级仍为`Iterate=true`、`MaxIterations=50`，当一趟结束零解数不再下降时停止。如果最终零解数不为0，清理直接失败，禁止导出空白地图。该方案不直接写入自定义相位或取向，补点完全由AZtec原生邻域算法产生。

## 可执行入口

主进程使用PowerShell 7 Core，AZtec .NET Framework调用仅由短生命周期Windows PowerShell 5.1 `-NoProfile -STA`子进程执行。要求合法安装AZtec Crystal **5.1.7829.1**和.NET Framework 4.8，不携带厂商程序集或许可。

```powershell
$skillRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
& (Join-Path $skillRoot 'scripts/native-cleanup/run_aztec_native_cleanup.ps1') `
  -CprPath 'C:\path\sample.cpr' -OutputDirectory 'C:\path\new-cleanup'
& (Join-Path $skillRoot 'scripts/native-cleanup/verify_aztec_native_cleanup_run.ps1') `
  -RunDirectory 'C:\path\new-cleanup'
```

默认`MaxZeroCycles=50`；仅用户明确变更配方时使用较小值。`StageTimeoutSeconds=3600`是当前主入口的每个worker进程默认超时，可在30..3600秒间设置。优化版默认`AuditMode=Fast`：逐阶段记录追加到`stage-progress.jsonl`，`stage-progress.json`运行时仅保存检查点，成功结束时再写最终摘要；`Strict`保留逐阶段全图快照。两种模式均执行最终完整快照、源文件哈希、持久化和独立读回核验。快模式只减少重复全图审计与JSON重写，不改变AZtec原生算法及最终验收。输入须有同名CRC，输出目录必须不存在。当前限定已验证的CPR字段顺序3,4,5,6,7,8,10,11,12和每点25字节的CRC；ErrorCode偏移20，源/派生原始C5码逐点哈希核对。当前入口仅支持单数据集、已加载的二维矩形网格；不支持的版本/数据结构直接失败，保留诊断目录。原始CPR/CRC以运行前后SHA-256检查，禁止覆盖。

实现调用`settings.GetCleanUpStep(tools)`及`step.Populate(previousDataset, CancellationTokenSource, isFirstStep)`，逐步传递输出。原生队列登记或历史记录不等于实际应用。Auto Clean的内部Sequence必须记录，不以本地补点算法替代。最终通过版本绑定的原生复制与保存接口写入`cleaned.cpr`/`cleaned.crc`，另起进程读取验证；持久化的具体边界见下节。

## 输出与验收

只有`cleanup-report.json`状态为`complete_native_cleanup_readback_verified`且独立验证器通过，才能把`cleaned.cpr`交给当前MapExport EXE/DLL。检查每一阶梯8个阶段、1次尖峰、5次独立Auto Clean及最后滤波的顺序、设置、结果与改变点数。原生报告替换数和逐点摘要改变数含义不同，两者分别记录。

`stage-progress.jsonl`以追加方式记录每个阶段事件；`stage-progress.json`运行时只保存轻量检查点，成功结束时保存最终汇总；`clean-worker.json`记录版本、设置、网格、相表、前后零解和摘要；`readback-worker.json`记录独立持久化核对。逐点审核覆盖PhaseID、四元数Orientation、Euler1..3、MAD、ErrorCode、BC、BS、NumberOfBands。原生临时清理数据的质量数组可能不同，应如实报告；复制后与读回的BC、BS、Bands必须与原始采集数据逐字节相同。ErrorCode的原始C5编码字节必须保持；AZtec按最终PhaseID解码，原始NoSolution可变为Replaced。必须通过原生双向编码接口预先预测到expected快照并逐字节读回核对；不能把Dataset.ErrorCode直接改为Replaced，以免原生写入器丢失替换来源。MAD随原生取向结果保存。

`point-provenance.mask`每点一字节，按原生row-major顺序：bit0=所审字段改变，bit1=原始PhaseID为0且最终已解析。它标记修改/补点，不证明补点取向是实测值。原生步骤没有暴露donor来源，reliability也没有可用数据字段，报告为不可用，不伪造。`expected.snapshot`用于独立读回审核。报告保留派生文件、日志、掩码与快照哈希。

原生滤波结果先原样保存至`native-result.snapshot`。保存策略用`-PersistencePolicy`显式记录，默认`NativeSave`：

- `NativeSave`：保留原生清理结果的Single Euler字节，用`RawData.UpdateData()`根据这些Euler重建与CPR加载一致的四元数。它匹配本工作区已有“改进”数据的保存状态；原生Kuwahara会修改临时四元数，却未同步全部Euler，因此该模式不声称完整持久化临时滤波四元数。报告临时四元数与实际保存状态的差异，Euler必须逐字节不变。
- `FilteredQuaternion`：将临时滤波四元数的原生double副本`Normalize()`后`ToEuler()`，转Single Euler再`RawData.UpdateData()`。这将完整滤波取向提交为可保存Euler；与原生保存兼容模式可能有明显KAM/GOS差别，不能静默替换。

两种模式都保留1e-5的符号对齐四元数分量精度门，但参考对象须与策略相符：NativeSave核对序列化Euler预测状态，FilteredQuaternion核对临时滤波取向。预测与实际规范化四元数及独立读回仍逐字段、逐字节核对；不得把临时滤波取向与原生Euler保存状态的真实差异当成浮点误差，也不得删掉精度门。

本次默认变更来源于真实保存差异诊断，不通过调色标降低角度。相同配方的样品2实验仅切换保存策略，KAM对改进MAE由0.198566°降至0.002705°、GOS由0.151696°降至0.015197°。这些是复现误差，不是物理准确性证据。已有改进数据的尖峰/Auto/Kuwahara次数逐样品不同于固定1/5/1配方；默认模式不承诺严格重放这些历史，不能为消除剩余差异盲目增加滤波次数。

清理通过不代表原生地图整图等同：`NativeFullMapFidelity=not_accepted`仍保持。清理后才导出IPF/KAM/GOS；不拿其他数据状态的图作数值一致性证据。

## 历史来源及回退

历史批次证据不随包发布，也不作为新数据的验证依据。旧版入口如需追溯，应在原始授权工作区单独复核。

原生API版本/签名改变或读回失败时不能以计数相同宣布成功，也不降级为MTEX/Python近似。需要人工原生UI处理时：在新副本依次执行相同完整阶梯停止规则、尖峰一次、等待完成的Auto Clean五次及最后象限半径3滤波；保存后仍须独立核验取向、网格及质量。不得只凭清理历史判断保存成功。
