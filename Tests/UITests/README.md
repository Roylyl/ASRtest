# ASRtest UI 检查
运行项目根目录下的 `Scripts/run-ui-smoke.sh`，或在 Xcode 选择共享方案 `ASRtestUISmoke` 后执行 Test。正常安装和运行 App 仍使用 `ASRtest` 方案。
脚本在 iOS 模拟器上构建并启动真实 App，检查三个原生 Tab、日志/模型信息切换、八个模型入口、设置中切换 Whisper tiny 后首页状态同步，再恢复 Zipformer。检查期间不点击开始录音，不采集麦克风音频，也不操作实际手机。
浅色和深色通过模拟器系统外观设置切换，结束后恢复原外观。App 本身没有加入专用测试模式或模拟模型。
运行前需准备好根目录 README 所述的本地运行库与八组模型，并在 Apple Silicon Mac 上启动一个 iOS 模拟器。脚本默认要求只有一个 iOS 模拟器处于已启动状态；没有或存在多个时会停止并提示，绝不选择实际手机。可通过 `ASR_UI_SIMULATOR` 指定已创建的 iOS 模拟器 UDID，脚本会按需启动它。
构建目录默认为 `.build/ui-derived`，包缓存默认为 `.build/SourcePackages`；分别可通过 `ASR_UI_DERIVED_DATA`、`ASR_UI_SOURCE_PACKAGES` 覆盖。先运行 `bash Scripts/run-ui-smoke.sh --help` 可查看参数说明，运行检查使用 `bash Scripts/run-ui-smoke.sh`。
每轮的构建日志、测试日志、XCTest 结果包及附件保存在 `Tests/UITests/Artifacts/<时间>/`。成功后，摘要更新到 `Tests/UITests/last-run.json`，截图导出到 `Preview/ui-*.png`。截图来自 XCTest 的实际屏幕附件。
结果文件与截图属于本机生成内容，不随 Git 提交。请以本次运行生成的结果为准，不将旧截图视为新构建已通过的证据。
本检查验证界面导航、真实模型加载切换和显示状态，不替代识别准确率、真机麦克风、蓝牙切换、功耗或长时间稳定性测试。
