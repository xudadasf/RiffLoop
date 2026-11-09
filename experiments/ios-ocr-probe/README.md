# 独立 iPad 数字模型探针

这个工程只比较合成输入在电脑 CPU 与 iPad 模拟器上的模型输出，不接入 RiffLoop、谱面文件或音频。它不代表真实谱子的识别准确率，也不代表 iPad mini 6 真机的速度和内存。

固定模型是 RapidOCR 的 `PP-OCRv6_rec_small.onnx`，SHA-256 为 `6f327246b50388f3c176ae304bd95767ea6dc0c9ae92153ef8cbe210b3c14884`。权重不存入本仓库；独立云端工作流从 RapidAI 的固定版本下载到临时目录并校验哈希，随后只用于模拟器测试。ONNX Runtime 的 Swift 包固定为 1.24.2；电脑参考结果由 1.31.1 的 CPU 执行器生成。

电脑端脚本要求自行提供模型文件：

```powershell
& 'D:\RiffLoop-model-tests\raster-tab-20261027\digit-ocr-env\Scripts\python.exe' -B `
  experiments\ios-ocr-probe\cpu_reference.py `
  --model 'D:\RiffLoop-model-tests\raster-tab-20261027\digit-ocr-probe\models\PP-OCRv6_rec_small.onnx'
```

脚本默认只输出 JSON；如需文件，`--output` 和 `--alphabet-output` 只接受不存在的目标，不覆盖模型或已有结果。`cpu_reference_expected.json` 只包含合成输入的参考结果，没有用户文件或路径。

模拟器测试校验输入字节、输出形状、每个时间步的最高类别、部分数字的 CTC 解码及抽样数值。固定点阵不等于实际六线谱；真正识谱仍需单独移植与验证图像预处理、完整词典、谱线定位和字符分组。

## 首次模拟器结果

[独立云端运行](https://github.com/xudadasf/RiffLoop/actions/runs/42620174477) 下载并校验了相同哈希的公开模型，使用 iOS 18.5 的 iPad mini 模拟器完成 3 项测试。两组合成张量的输入哈希、输出形状 `[1, 40, 18710]`、全部 40 个时间步的最高类别、CTC 结果与电脑 CPU 参考一致；最高类别分数和抽样值在 `0.001` 容差内。点阵样例的 CTC 输出为 `0123456789`。

这证明该固定模型可以在独立模拟器工程中执行，**不证明**图片预处理、实际音符识别或 GP 文件已经可用。模拟器不是 iPad mini 6 真机，日志中的耗时不能作为真机性能数据。下一步需用同一合成图片逐步核对图像缩放、通道、填充、完整词典和字符位置，再做真实谱面及设备性能验证。
