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
}
