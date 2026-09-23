import XCTest

final class ASRtestUITests: XCTestCase {
    private let modelIDs = ["zipformer", "whisperTiny", "whisperBase", "voskChinese", "voskEnglish", "senseVoice", "paraformer", "nano"]

    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 45), "Native tab bar should appear")
        return app
    }

    @MainActor
    private func selectTab(_ label: String, identifier: String, app: XCUIApplication) {
        let identified = app.tabBars.buttons[identifier]
        let tab = identified.exists ? identified : app.tabBars.buttons[label]
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "Missing tab: \(label)")
        tab.tap()
        XCTAssertTrue(tab.isSelected, "Tab is not selected: \(label)")
    }

    @MainActor
    private func capture(_ name: String, app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name + "-accessibility"
        tree.lifetime = .keepAlways
        add(tree)
    }

    @MainActor
    private func makeVisible(_ element: XCUIElement, app: XCUIApplication, maximumSwipes: Int = 5) {
        for _ in 0...maximumSwipes {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.exists && element.isHittable, "Element is not visible: \(element)")
    }

    @MainActor
    private func chooseZipformerFromHome(app: XCUIApplication, checkAllModels: Bool) {
        let selector = app.buttons["test.modelSelector"]
        XCTAssertTrue(selector.waitForExistence(timeout: 45))
        // Model initialization may temporarily disable configuration. No microphone action is invoked.
        let enabled = NSPredicate(format: "enabled == true")
        expectation(for: enabled, evaluatedWith: selector)
        waitForExpectations(timeout: 90)
        selector.tap()
        XCTAssertTrue(app.navigationBars["选择模型"].waitForExistence(timeout: 10))
        if checkAllModels {
            for id in modelIDs {
                let row = app.buttons["model.\(id)"]
                makeVisible(row, app: app)
                XCTAssertTrue(row.isHittable, "Model entry is not accessible: \(id)")
            }
            capture("model-selector-light", app: app)
        }
        let zipformer = app.buttons["model.zipformer"]
        for _ in 0..<6 where !zipformer.isHittable { app.swipeDown() }
        XCTAssertTrue(zipformer.isHittable)
        zipformer.tap()
        if app.navigationBars["选择模型"].exists && app.buttons["完成"].exists { app.buttons["完成"].tap() }
        let start = app.buttons["test.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        expectation(for: enabled, evaluatedWith: start)
        waitForExpectations(timeout: 90)
        XCTAssertTrue(app.buttons["test.stop"].exists)
        XCTAssertFalse(app.buttons["test.stop"].isEnabled, "Recording must remain stopped")
    }

    @MainActor
    func testPrimaryViewsAndBundledModelNavigation() {
        let app = launchApp()
        selectTab("测试", identifier: "tab.test", app: app)
        chooseZipformerFromHome(app: app, checkAllModels: true)
        capture("test-light", app: app)

        selectTab("日志及模型", identifier: "tab.library", app: app)
        let logs = app.segmentedControls.buttons["测试日志"]
        XCTAssertTrue(logs.waitForExistence(timeout: 10))
        logs.tap()
        capture("logs-light", app: app)
        let info = app.segmentedControls.buttons["模型信息"]
        XCTAssertTrue(info.waitForExistence(timeout: 10))
        info.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Zipformer")).firstMatch.waitForExistence(timeout: 10))
        capture("models-light", app: app)

        selectTab("设置", identifier: "tab.settings", app: app)
        let settingsModel = app.buttons["settings.modelSelector"]
        XCTAssertTrue(settingsModel.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS '下载' OR label CONTAINS '导入'")).firstMatch.exists,
                       "The bundled-only app must not expose download or import actions")
        capture("settings-light", app: app)

        // Exercise the actual shared model switch from Settings, without recording audio.
        settingsModel.tap()
        let tiny = app.buttons["model.whisperTiny"]
        XCTAssertTrue(tiny.waitForExistence(timeout: 10))
        tiny.tap()
        expectation(for: NSPredicate(format: "enabled == true AND label CONTAINS %@", "Whisper tiny"), evaluatedWith: settingsModel)
        waitForExpectations(timeout: 90)
        selectTab("测试", identifier: "tab.test", app: app)
        let homeModel = app.buttons["test.modelSelector"]
        XCTAssertTrue(homeModel.label.contains("Whisper tiny"), "Settings selection must be reflected on Test")
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: app.buttons["test.start"])
        waitForExpectations(timeout: 90)
        XCTAssertFalse(app.buttons["test.stop"].isEnabled)
        capture("whisper-tiny-light", app: app)
        chooseZipformerFromHome(app: app, checkAllModels: false)
        XCTAssertTrue(homeModel.label.contains("Zipformer"))

        selectTab("设置", identifier: "tab.settings", app: app)
        app.swipeUp()
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS '下载' OR label CONTAINS '导入'")).firstMatch.exists)
        selectTab("测试", identifier: "tab.test", app: app)
        XCTAssertFalse(app.buttons["test.stop"].isEnabled)
        app.terminate()
    }

    @MainActor
    func testDarkTestPage() {
        // Scripts/run-ui-smoke.sh sets Simulator system appearance to dark before this test.
        let app = launchApp()
        selectTab("测试", identifier: "tab.test", app: app)
        chooseZipformerFromHome(app: app, checkAllModels: false)
        capture("test-dark", app: app)
        XCTAssertFalse(app.buttons["test.stop"].isEnabled)
        app.terminate()
    }

    @MainActor
    func testIPadWideLayoutAndBatchEntry() {
        let app = XCUIApplication()
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons["允许"]
        if allow.waitForExistence(timeout: 5) { allow.tap() }
        let selector = app.buttons["test.modelSelector"]
        XCTAssertTrue(selector.waitForExistence(timeout: 45))
        let transcript = app.descendants(matching: .any)["test.transcript"].firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(transcript.frame.minX, selector.frame.maxX,
                             "Wide iPad layout should place results to the right of controls")
        XCTAssertTrue(app.staticTexts["批量 WAV 测试"].exists)
        XCTAssertTrue(app.buttons["选择 WAV"].exists)
        capture("ipad-batch-layout", app: app)
    }

    @MainActor
    func testBatchWAVProcessingAndGroupDetails() {
        let app = XCUIApplication()
        app.launchArguments = ["ASRTEST_BATCH_SMOKE"]
        app.launch()
        let status = app.staticTexts["test.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 45))
        expectation(for: NSPredicate(format: "label == %@", "批量测试完成"), evaluatedWith: status)
        waitForExpectations(timeout: 90)
        let library = app.buttons["tab.library"].firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        library.tap()
        XCTAssertTrue(app.staticTexts["批量测试"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "2/2 完成")).firstMatch.waitForExistence(timeout: 10))
        capture("ipad-batch-completed", app: app)
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Zipformer Small")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["batch-a.wav"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["batch-b.wav"].exists)
        capture("ipad-batch-details", app: app)
    }

    @MainActor
    func testBatchContinuesAfterInvalidWAV() {
        let app = XCUIApplication()
        app.launchArguments = ["ASRTEST_BATCH_FAILURE_SMOKE"]
        app.launch()
        let status = app.staticTexts["test.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 45))
        expectation(for: NSPredicate(format: "label == %@", "批量测试完成"), evaluatedWith: status)
        waitForExpectations(timeout: 90)
        app.buttons["tab.library"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "2/3 完成 · 1 失败")).firstMatch.waitForExistence(timeout: 10))
        capture("ipad-batch-invalid-continues", app: app)
    }

    @MainActor
    func testBatchCanBeStopped() {
        let app = XCUIApplication()
        app.launchArguments = ["ASRTEST_BATCH_STOP_SMOKE"]
        app.launch()
        let selector = app.buttons["test.modelSelector"]
        XCTAssertTrue(selector.waitForExistence(timeout: 45))
        selector.tap()
        let zipformer = app.buttons["model.zipformer"]
        XCTAssertTrue(zipformer.waitForExistence(timeout: 10))
        zipformer.tap()
        expectation(for: NSPredicate(format: "enabled == true AND label CONTAINS %@", "Zipformer"), evaluatedWith: selector)
        waitForExpectations(timeout: 90)
        let start = app.buttons["开始本轮"]
        XCTAssertTrue(start.waitForExistence(timeout: 45))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: start)
        waitForExpectations(timeout: 45)
        start.tap()
        let stop = app.buttons["停止批量测试"]
        XCTAssertTrue(stop.waitForExistence(timeout: 45))
        stop.tap()
        let status = app.staticTexts["test.status"]
        expectation(for: NSPredicate(format: "label == %@", "批量测试已停止"), evaluatedWith: status)
        waitForExpectations(timeout: 90)
        capture("ipad-batch-stopped", app: app)
    }

    @MainActor
    func testBatchCanRerunWithAnotherModel() {
        let app = XCUIApplication()
        app.launchArguments = ["ASRTEST_BATCH_SMOKE"]
        app.launch()
        let status = app.staticTexts["test.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 45))
        expectation(for: NSPredicate(format: "label == %@", "批量测试完成"), evaluatedWith: status)
        waitForExpectations(timeout: 90)

        let selector = app.buttons["test.modelSelector"]
        XCTAssertTrue(selector.waitForExistence(timeout: 10))
        selector.tap()
        let tiny = app.buttons["model.whisperTiny"]
        XCTAssertTrue(tiny.waitForExistence(timeout: 10))
        tiny.tap()
        expectation(for: NSPredicate(format: "enabled == true AND label CONTAINS %@", "Whisper tiny"), evaluatedWith: selector)
        waitForExpectations(timeout: 90)
        let rerun = app.buttons["开始本轮"]
        XCTAssertTrue(rerun.waitForExistence(timeout: 10))
        rerun.tap()
        expectation(for: NSPredicate(format: "label == %@", "批量测试完成"), evaluatedWith: status)
        waitForExpectations(timeout: 90)
        app.buttons["tab.library"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Whisper tiny")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Zipformer Small")).firstMatch.exists)
        capture("ipad-batch-two-model-rounds", app: app)
    }
}
