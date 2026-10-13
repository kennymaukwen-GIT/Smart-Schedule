import XCTest

/// Shared/Localization/Localizable.xcstrings is compiled into an en.lproj and a zh-Hant.lproj in every bundle that
/// has it as a resource, this test bundle included. String(localized:) reads Bundle.main, which is the test runner
/// here (so every other test sees the English keys); these tests read the compiled zh-Hant table directly.
/// scripts/validate_schema.py checks the catalog file itself: every key translated, matching format specifiers, and
/// every String(localized:) literal in the sources present.
final class LocalizationCatalogTests: XCTestCase {
    private final class BundleToken {}

    /// The zh-Hant.lproj folder as a bundle, so `localizedString` reads its Localizable table.
    private func chineseTable() throws -> Bundle {
        let bundle = Bundle(for: BundleToken.self)
        guard let strings = bundle.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: "zh-Hant"),
              let table = Bundle(path: (strings as NSString).deletingLastPathComponent) else {
            throw XCTSkip("No compiled zh-Hant Localizable.strings in the test bundle (Localizable.xcstrings not compiled into it)")
        }
        return table
    }

    private func zh(_ key: String, in table: Bundle) -> String {
        table.localizedString(forKey: key, value: nil, table: "Localizable")
    }

    func testPlanReviewLabels() throws {
        let table = try chineseTable()
        XCTAssertEqual(zh("Add", in: table), "加入")
        XCTAssertEqual(zh("Keep editing", in: table), "繼續修改")
        XCTAssertEqual(zh("Nothing is added until you tap Add.", in: table), "按「加入」前不會寫入行事曆。")
        XCTAssertEqual(zh("Added to Google Calendar", in: table), "已加入 Google 日曆")
        XCTAssertEqual(zh("Added (demo)", in: table), "已加入（示範）")
        XCTAssertEqual(zh("Type in any plan to add or change", in: table), "輸入要新增或修改的計畫")
        // ReplyFormatter's strings are the English keys here, because Bundle.main is the test runner.
        XCTAssertEqual(zh(ReplyFormatter.planEditQuestion, in: table), "要修改哪裡？")
        XCTAssertEqual(ReplyFormatter.planEditSuggestions.map { zh($0, in: table) }, ["換訓練日", "換時間", "縮短時長", "換開始日期"])
        XCTAssertEqual(zh(ReplyFormatter.nothingScheduled, in: table), "沒有行程")
    }

    /// DemoAssistantReplyTests.testChineseExamplePromptsWork runs these translations through the demo assistant.
    func testExamplePromptTranslations() throws {
        let table = try chineseTable()
        XCTAssertEqual(zh("Lunch with Andrew tomorrow 1pm", in: table), "明天下午 1 點 Andrew 午餐")
        XCTAssertEqual(zh("Push the team sync 30 min", in: table), "下一個行程延後 30 分鐘")
        XCTAssertEqual(zh("Show me my schedule for today", in: table), "顯示今天的行程")
        XCTAssertEqual(zh("I want to be muscular in 6 month design me a daily routine", in: table), "我想在 6 個月內增肌，幫我排每天的訓練")
    }

    /// Artboard 5's header, drawer, account sheet and Settings (glossary in docs/SETTINGS.md §2.10).
    func testSettingsLabels() throws {
        let table = try chineseTable()
        XCTAssertEqual(zh("Try without signing in", in: table), "不登入先試用")
        XCTAssertEqual(zh("Add Google account", in: table), "新增 Google 帳號")
        XCTAssertEqual(zh("General", in: table), "一般")
        XCTAssertEqual(zh("Settings updated", in: table), "設定已更新")
        XCTAssertEqual(zh("What the assistant remembers", in: table), "助理記得的事")
        XCTAssertEqual(zh("Erase all data on this device", in: table), "清除這台裝置上的所有資料")
        XCTAssertEqual(zh("Not in your calendar yet", in: table), "尚未加入行事曆")
    }

    func testSettingsFormatArguments() throws {
        let table = try chineseTable()
        XCTAssertEqual(String(format: zh("Disconnect %@?", in: table), "student@university.example.edu"),
                       "要中斷連接 student@university.example.edu 嗎？")
        XCTAssertEqual(String(format: zh("At most %lld a day", in: table), 10), "每天最多 10 則")
        XCTAssertEqual(String(format: zh("Adds to %@", in: table), "我的行事曆 · kenny@example.com"),
                       "加入到 我的行事曆 · kenny@example.com")
    }

    func testFormatArgumentsKeepTheirPositions() throws {
        let table = try chineseTable()
        XCTAssertEqual(String(format: zh("Added: %@ · %@", in: table), "午餐", "10月14日（週三）13:00–14:00"),
                       "已加入：午餐 · 10月14日（週三）13:00–14:00")
        XCTAssertEqual(String(format: zh("%@ (%lld times)", in: table), "健身", 3), "健身（3 次）")
        XCTAssertEqual(String(format: zh("Replaced by revision %lld", in: table), 2), "已由第 2 版取代")
        XCTAssertEqual(String(format: zh("Daily reminder %@", in: table), "07:30"), "每天 07:30 提醒")
    }
}
