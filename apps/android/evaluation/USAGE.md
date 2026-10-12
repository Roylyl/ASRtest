# 演示语料与自动评测
仓库根目录shared/assets/evaluation/demo中的4条语料均为macOS本地合成语音，不是真实用户录音。参考文本直接来自合成输入，source和isSynthetic字段写入语料清单及App日志；真实录音后续应人工核对参考文本后另行评测。
## 合成语料
|编号|语言|参考文字|
|---|---|---|
|zh_short|中文|今天下午三点，请提醒我参加项目会议。|
|zh_numbers|中文|这台手机售价两千三百元，订单编号是一二三四五六。|
|en_short|英文|Please remind me to attend the project meeting at three this afternoon.|
|mixed_short|中英混合|请打开蓝牙，连接我的Bluetooth speaker，然后播放音乐。|
音频为16kHz、单声道、16位PCM WAV。中文使用Tingting，英文使用Samantha；混合句由中英文片段拼接，所以仅用于功能演示。
以下命令从apps/android目录执行。在macOS上重新生成：
```bash
python3 evaluation/generate_demo.py
```
## 连接手机自动测试
先编译并安装Debug APK，再运行：
```bash
python3 scripts/run_benchmark.py --threads 2 --runs 3
```
多设备连接时使用--serial指定自己的设备。仅测试一个模型和一个音频：
```bash
python3 scripts/run_benchmark.py --models zipformer --corpus zh_short --runs 1
```
可用模型编号为zipformer、whisperTiny、whisperBase、voskChinese、voskEnglish、senseVoice、paraformer、nano。脚本在每个模型开始前重新启动App，通过benchModel/benchCorpus/benchThreads/benchRuns启动参数触发本地识别；不会上传音频或调用服务器。App逐条保存真实结果，脚本轮询完成状态并复制结果JSON和过程JSONL。超时保留已有结果，driver.json明确记录timeout，不伪造完成结果。Vosk的单语言限制由App标注或跳过。
默认每个模型最多等待1200秒，可用--timeout调整。脚本检测App进程意外退出后会提前保存已有结果和相关崩溃日志，并继续健康模型。脚本不会修改手机设置；电量、温度和后台负载仍可能影响对比，应保留driver.json中的设备状态。
## 计分与结果
```bash
python3 evaluation/evaluate.py evaluation/runs/具体测试目录 --output evaluation/report
```
仅从真实benchmark结果生成records.csv、summary.csv和report.md，不以官方参考数据冒充手机实测。中文采用CER；英文采用WER；中英混合采用CER（混合字符），混合句里的每个汉字、英文字母和数字均为一个单位。统一忽略大小写、标点及空白，不做数字读法、同义词和繁简转换。错误率=(替换+删除+插入)/参考单位数。批量汇总按错误数总和/参考单位总和计算；失败和跳过单列，不当成成功样本。中文数字参考使用汉字，ITN若输出2300或123456，严格CER会把书写形式差异计为编辑错误，不能直接说数字语义识别错误。完整参考和转写保留供复查；Vosk各模型仅支持对应单语言，中英混合结果不代表完整双语能力。
RTF=识别调用耗时总和/音频时长总和，模型加载时间另列。RSS为App整个进程的采样峰值，PSS是推理结束时快照而非峰值；两者包含运行库、界面和识别状态，不等于模型大小，RSS采样也可能漏掉短暂峰值。表格以MiB计，1MiB=1024KiB；baseline在模型加载后采集。每次重复重新创建识别上下文，后续运行可能受系统文件缓存影响，不能称为同一已加载模型的热推理。同一模型的多个记录在同一个App进程内执行，分配器可能保留已释放页面，峰值RSS不能视为模型独占内存。固定顺序、发热和后台负载可能影响模型之间的耗时比较。
参数量从模型来源记录；FLOPs/GOPs需要根据具体网络图和输入/输出长度分析，不能用手机耗时反推，也不能与MIPS直接换算。识别效果优先用后续真实录音确认。
