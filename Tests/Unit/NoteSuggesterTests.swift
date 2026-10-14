import XCTest

/// Smart Schedule's own note suggestions (`NoteSuggester`): kinds of event in Chinese and English, exclusions, the
/// user's own country, what the notes already hold, the limit, the language, and the line a tap adds.
final class NoteSuggesterTests: XCTestCase {
    private let london = TimeZone(identifier: "Europe/London")!
    private let taipei = TimeZone(identifier: "Asia/Taipei")!

    private func event(_ title: String, location: String? = nil, notes: String? = nil, allDay: Bool = false,
                       days: Int = 1, meet: Bool = false, suggested: [String]? = nil) -> ScheduleEvent {
        let start = allDay ? TestClock.local(2026, 10, 20) : TestClock.local(2026, 10, 20, 9)
        let end = allDay ? TestClock.local(2026, 10, 20 + days) : TestClock.local(2026, 10, 20, 10)
        var event = TestEvents.make(id: "e1", title: title, start: start, end: end, allDay: allDay)
        event.location = location
        event.notes = notes
        event.suggestedNotes = suggested
        if meet { event.meetURL = URL(string: "https://meet.google.com/abc-defg-hij") }
        return event
    }

    /// The texts offered for an event with these notes (the page's buffer), from London unless `home` says otherwise.
    private func texts(_ title: String, location: String? = nil, notes: String? = nil, chinese: Bool? = nil,
                       limit: Int = 4, home: TimeZone? = nil, allDay: Bool = false, days: Int = 1,
                       meet: Bool = false) -> [String] {
        NoteSuggester.suggestions(for: event(title, location: location, notes: notes, allDay: allDay, days: days, meet: meet),
                                  existingNotes: notes, preferChinese: chinese, limit: limit,
                                  homeTimeZone: home ?? london)
            .map(\.text)
    }

    private func kinds(_ title: String, location: String? = nil, home: TimeZone? = nil) -> [String] {
        NoteSuggester.matchedCategoryIDs(for: event(title, location: location), homeTimeZone: home ?? london)
    }

    // MARK: Kinds of event

    func testTripAbroadSuggestsPassport() {
        XCTAssertEqual(texts("出國旅遊"), ["帶護照", "確認簽證或入境文件", "帶轉接插頭", "投保旅遊保險"])
        XCTAssertEqual(texts("東京旅遊").first, "帶護照")
        XCTAssertEqual(texts("Trip to Japan").first, "Bring passport")
        // A flight adds getting to the airport early.
        XCTAssertEqual(texts("Flight to Tokyo"),
                       ["Bring passport", "Arrive 2-3 hours before the flight", "Check visa or entry documents",
                        "Pack a plug adapter"])
        XCTAssertEqual(texts("飛東京"), ["帶護照", "提早 2-3 小時到機場", "確認簽證或入境文件", "帶轉接插頭"])
        // A flight with no place in the user's country counts as international.
        XCTAssertEqual(texts("班機 CI100").first, "帶護照")
        // A multi-day all-day event at a foreign place is a trip there.
        XCTAssertEqual(texts("Tokyo", allDay: true, days: 5).first, "Bring passport")
        XCTAssertEqual(texts("Tokyo"), [])
        XCTAssertEqual(kinds("Flight to Tokyo"), ["abroad"])
    }

    func testTheUsersOwnCountryIsNotAbroad() {
        XCTAssertEqual(texts("Trip to London", home: london), ["Bring ID", "Have tickets ready", "Bring a power bank"])
        XCTAssertEqual(texts("Trip to London", home: taipei).first, "Bring passport")
        XCTAssertEqual(texts("Flight to Edinburgh", home: london), ["Bring ID", "Check in online", "Bring a power bank"])
        // Taiwan's islands are a domestic flight from Taipei, abroad from London.
        XCTAssertEqual(texts("澎湖班機", home: taipei), ["帶身分證", "完成線上報到", "帶行動電源"])
        XCTAssertEqual(texts("飛澎湖", home: taipei), ["帶身分證", "完成線上報到", "帶行動電源"])
        XCTAssertEqual(texts("飛澎湖", home: london).first, "帶護照")
        XCTAssertEqual(kinds("開車去台中", home: taipei), ["driving", "travel"])
    }

    func testDomesticTravelByTrain() {
        XCTAssertEqual(texts("高鐵"), ["帶身分證", "準備好車票", "帶行動電源"])
        XCTAssertEqual(texts("Business trip to Taipei", home: taipei),
                       ["Bring ID", "Have tickets ready", "Bring a power bank", "Bring business cards"])
    }

    func testWorkoutSuggestsWater() {
        XCTAssertEqual(texts("健身"), ["帶水", "帶毛巾", "穿運動服和運動鞋", "帶替換衣物"])
        XCTAssertEqual(texts("跑步").first, "帶水")
        XCTAssertEqual(texts("Gym"), ["Bring water", "Bring a towel", "Sportswear and shoes", "Change of clothes"])
        XCTAssertEqual(texts("Morning run").first, "Bring water")
        XCTAssertEqual(texts("5k run").first, "Bring water")
        // Renewing a gym membership may still mean a visit to the gym.
        XCTAssertEqual(texts("健身房會員續約").first, "帶水")
    }

    func testMoreSpecificSportsReplaceTheWorkoutItems() {
        XCTAssertEqual(texts("瑜伽"), ["帶瑜伽墊", "帶水", "穿舒適的衣服", "帶毛巾"])
        XCTAssertEqual(texts("Yoga").first, "Bring a yoga mat")
        XCTAssertFalse(texts("瑜伽").contains("穿運動服和運動鞋"))
        XCTAssertEqual(texts("游泳"), ["帶泳衣", "帶泳鏡", "帶毛巾", "帶泳帽"])
        XCTAssertEqual(texts("Swimming").first, "Bring a swimsuit")
        XCTAssertEqual(texts("爬山"), ["帶水", "帶雨具", "帶行動糧", "帶頭燈"])
        XCTAssertEqual(texts("Hiking in the Alps").first, "Bring water")
        XCTAssertEqual(kinds("瑜伽"), ["yoga"])
        XCTAssertEqual(kinds("登山"), ["hiking"])
    }

    func testExamSuggestsAdmissionTicket() {
        XCTAssertEqual(texts("考試"), ["帶准考證", "帶身分證", "帶文具", "帶計算機"])
        XCTAssertEqual(texts("Exam").first, "Bring admission ticket")
        // No calculator for a language exam; no admission ticket for a class test.
        XCTAssertEqual(texts("多益考試"), ["帶准考證", "帶身分證", "帶文具"])
        XCTAssertEqual(texts("期末考"), ["帶身分證", "帶文具", "帶計算機"])
    }

    func testTheOtherKindsOfEvent() {
        XCTAssertEqual(texts("面試"), ["帶履歷", "提早 10 分鐘到", "準備想問的問題"])
        XCTAssertEqual(texts("會議"), ["帶筆電和充電器", "提早 10 分鐘到"])
        XCTAssertEqual(texts("看醫生"), ["帶健保卡", "帶目前用藥清單", "寫下想問醫生的問題"])
        XCTAssertEqual(texts("Dentist").first, "Bring health insurance card")
        XCTAssertEqual(texts("生日"), ["準備禮物", "寫張卡片"])
        XCTAssertEqual(texts("婚禮"), ["準備紅包", "確認服裝規定"])
        XCTAssertEqual(texts("開車"), ["帶駕照", "查好路線和停車"])
        XCTAssertEqual(texts("演唱會"), ["準備好門票", "帶身分證", "帶行動電源"])
        XCTAssertEqual(texts("訂位"), ["確認訂位"])
        XCTAssertEqual(texts("Dinner reservation at Nobu"), ["Confirm the reservation"])
        XCTAssertEqual(texts("簡報").first, "帶筆電和充電器")
        XCTAssertEqual(texts("Beach day").first, "Bring sunscreen")
        XCTAssertEqual(texts("Camping").first, "Tent and sleeping bag")
        XCTAssertEqual(texts("辦護照"), ["帶身分證", "帶齊所需文件", "帶證件照"])
    }

    func testOnlineEventsGetCallItems() {
        XCTAssertEqual(texts("Interview with Acme", meet: true), ["Test mic and camera", "Prepare questions to ask"])
        XCTAssertEqual(texts("Online meeting with Joe"), ["Test mic and camera", "Check the meeting link"])
        // A video call about a trip is no trip.
        XCTAssertEqual(texts("國外客戶視訊會議").first, "測試麥克風和鏡頭")
        XCTAssertFalse(texts("國外客戶視訊會議").contains("帶護照"))
    }

    // MARK: Exclusions

    func testNotEverythingThatMentionsAKeywordIsThatKindOfEvent() {
        XCTAssertEqual(texts("跑步機維修"), [], "a treadmill repair is no workout")
        XCTAssertEqual(texts("去機場接機"), [], "picking someone up is no flight")
        XCTAssertEqual(texts("日本料理晚餐"), [], "Japanese food is no trip to Japan")
        XCTAssertEqual(texts("Running late"), [])
        XCTAssertEqual(texts("Google Drive cleanup"), [])
        XCTAssertEqual(texts("Third-party audit"), [])
        XCTAssertEqual(texts("Gymnastics class"), [], "whole English words only")
        XCTAssertEqual(texts("Carpool to school"), [])
        XCTAssertEqual(texts("Bank holiday"), [])
        XCTAssertEqual(texts("Test event"), [])
        XCTAssertEqual(texts("看報告"), [])
        XCTAssertEqual(texts("Lunch with Andrew"), [])
        // A blood test is the doctor's, not an exam.
        XCTAssertEqual(kinds("Blood test"), ["doctor"])
        XCTAssertEqual(kinds("Visit grandma at hospital"), [])
        // A spin class or a gym in the user's own city is no trip.
        XCTAssertEqual(texts("飛輪", location: "World Gym 台中店", home: taipei),
                       ["帶水", "帶毛巾", "穿運動服和運動鞋", "帶替換衣物"])
        XCTAssertEqual(texts("去健身房", location: "台北市信義區", home: taipei),
                       ["帶水", "帶毛巾", "穿運動服和運動鞋", "帶替換衣物"])
        XCTAssertEqual(kinds("飛盤練習", location: "台中", home: taipei), [])
        XCTAssertEqual(texts("Run 5km").first, "Bring water")
    }

    func testWordsInTheNotesDoNotUndoWhatTheTitleSays() {
        XCTAssertEqual(texts("Flight to Tokyo", notes: "Dad will pick me up at the airport").first, "Bring passport")
        XCTAssertEqual(texts("日本旅遊", notes: "訂飯店").first, "帶護照")
        XCTAssertEqual(texts("健身", notes: "順便買菜"), ["帶水", "帶毛巾", "穿運動服和運動鞋", "帶替換衣物"])
        XCTAssertEqual(texts("Gym", notes: "buy protein powder").first, "Bring water")
        // When only the notes say it, their exclusions still count.
        XCTAssertEqual(texts("Pick up Anna", notes: "Her flight lands at 6pm"), [])
    }

    // MARK: Ranking and the limit

    func testSeveralKindsShareTheLimit() {
        // The first kind leads; the next adds its most useful item.
        XCTAssertEqual(texts("東京自駕旅遊"), ["帶護照", "確認簽證或入境文件", "帶轉接插頭", "帶國際駕照"])
        // The title's kind comes before the place's.
        XCTAssertEqual(texts("Team meeting", location: "World Gym"),
                       ["Laptop and charger", "Arrive 10 min early", "Bring water", "Bring a towel"])
        // An international driving permit only for a trip abroad.
        XCTAssertEqual(texts("自駕", home: taipei), ["帶駕照", "查好路線和停車", "確認油量或電量"])
    }

    func testLimit() {
        XCTAssertEqual(texts("Flight to Tokyo", limit: 2), ["Bring passport", "Arrive 2-3 hours before the flight"])
        XCTAssertEqual(texts("Flight to Tokyo", limit: 0), [])
        XCTAssertEqual(texts("Flight to Tokyo", limit: 8).count, 7)
        for title in ["出國旅遊", "健身", "考試", "Flight to Tokyo", "東京自駕旅遊", "Team meeting"] {
            XCTAssertLessThanOrEqual(texts(title).count, 4, title)
        }
    }

    // MARK: Already in the notes

    func testWhatTheNotesHoldIsNotOfferedAgain() {
        // Case, full-width letters and the bullet do not matter; the slot goes to the next item.
        XCTAssertEqual(texts("Flight to Tokyo", notes: "• BRING PASSPORT"),
                       ["Arrive 2-3 hours before the flight", "Check visa or entry documents", "Pack a plug adapter",
                        "Get travel insurance"])
        XCTAssertFalse(texts("Flight to Tokyo", notes: "ｐａｓｓｐｏｒｔ ready").contains("Bring passport"))
        XCTAssertFalse(texts("出國旅遊", notes: "記得帶護照").contains("帶護照"))
        // Either language counts.
        XCTAssertFalse(texts("Flight to Tokyo", notes: "護照").contains("Bring passport"))
        XCTAssertFalse(texts("健身", notes: "water bottle").contains("帶水"))
    }

    func testIsAlreadyNoted() {
        XCTAssertTrue(NoteSuggester.isAlreadyNoted("Bring passport", in: "• bring PASSPORT"))
        XCTAssertTrue(NoteSuggester.isAlreadyNoted("Bring passport", in: "ｐａｓｓｐｏｒｔ"))
        XCTAssertTrue(NoteSuggester.isAlreadyNoted("帶護照", in: "１. 帶護照"))
        XCTAssertTrue(NoteSuggester.isAlreadyNoted("Bring water", in: "water bottle"))
        XCTAssertTrue(NoteSuggester.isAlreadyNoted("帶水", in: "記得帶水壺"))
        XCTAssertFalse(NoteSuggester.isAlreadyNoted("帶水", in: "水果"), "one character is too short to tell")
        XCTAssertFalse(NoteSuggester.isAlreadyNoted("ID", in: "I did it"), "whole English words only")
        XCTAssertFalse(NoteSuggester.isAlreadyNoted("Bring passport", in: nil))
        XCTAssertFalse(NoteSuggester.isAlreadyNoted("Bring passport", in: ""))
    }

    // MARK: Language

    func testLanguageFollowsTheTitleElseTheFallback() {
        XCTAssertEqual(texts("Gym", chinese: true).first, "Bring water")
        XCTAssertEqual(texts("健身", chinese: false).first, "帶水")
        // No letters in the title: the app's language (here given).
        XCTAssertEqual(texts("🏋️", location: "World Gym", chinese: true).first, "帶水")
        XCTAssertEqual(texts("🏋️", location: "World Gym", chinese: false).first, "Bring water")
        XCTAssertTrue(NoteSuggester.usesChinese(for: event("與Joe開會")))
        XCTAssertFalse(NoteSuggester.usesChinese(for: event("Lunch"), fallback: true))
    }

    // MARK: Suggestions kept on the event

    func testKeptSuggestionsComeFirstAndRulesFillUp() {
        let trip = event("Tokyo trip", suggested: ["Passport", "Yen cash"])
        let suggestions = NoteSuggester.suggestions(for: trip, existingNotes: nil, homeTimeZone: london)
        XCTAssertEqual(suggestions.map(\.text), ["Passport", "Yen cash", "Check visa or entry documents", "Pack a plug adapter"])
        XCTAssertEqual(suggestions.map(\.source), [.ai, .ai, .rules, .rules])
        XCTAssertEqual(Set(suggestions.map(\.id)).count, 4)
        // A kept suggestion the notes now hold goes too.
        XCTAssertEqual(NoteSuggester.suggestions(for: trip, existingNotes: "• Yen cash", homeTimeZone: london).map(\.text),
                       ["Passport", "Check visa or entry documents", "Pack a plug adapter", "Get travel insurance"])
    }

    func testMergingKeepsTheFirstOfTwoAlike() {
        let rules = NoteSuggester.ruleSuggestions(for: event("Tokyo trip"), existingNotes: nil, homeTimeZone: london)
        let merged = NoteSuggester.merging([.ai("Passport"), .ai("Yen cash"), .ai("yen cash")], into: rules,
                                           existingNotes: nil, limit: 8)
        XCTAssertEqual(merged.map(\.text), rules.map(\.text) + ["Yen cash"])
        XCTAssertEqual(merged.last?.source, .ai)
    }

    func testGeminisItemsAreTidied() {
        let items = NoteSuggester.cleanedItems(["• Passport", "1. Yen cash", "passport", "", "Visit Japan Web entry QR.",
                                                String(repeating: "x", count: 80), "IC transit card", "Pocket Wi-Fi",
                                                "Umbrella"],
                                               existingNotes: "Yen cash already")
        XCTAssertEqual(items, ["Passport", "Visit Japan Web entry QR", "IC transit card", "Pocket Wi-Fi"])
        XCTAssertEqual(NoteSuggester.cleaned("  - 3.5mm adapter "), "3.5mm adapter")
        XCTAssertEqual(NoteSuggester.cleaned("2、帶水。"), "帶水")
    }

    // MARK: Adding a suggestion

    func testAppendingAddsABulletLine() {
        XCTAssertEqual(NoteSuggester.appending("Bring water", to: nil), "• Bring water")
        XCTAssertEqual(NoteSuggester.appending("Bring water", to: ""), "• Bring water")
        XCTAssertEqual(NoteSuggester.appending("Bring water", to: "Terminal 2"), "Terminal 2\n• Bring water")
        XCTAssertEqual(NoteSuggester.appending("Bring water", to: "Terminal 2\n\n"), "Terminal 2\n• Bring water")
        XCTAssertEqual(NoteSuggester.appending("帶護照", to: "• 帶水"), "• 帶水\n• 帶護照")
        // Twice is once.
        XCTAssertEqual(NoteSuggester.appending("Bring water", to: "Terminal 2\n• Bring water"), "Terminal 2\n• Bring water")
        // Below Smart Schedule's provenance line, a paragraph of its own, as the assistant's notes are.
        let provenance = CalendarEventMapper.provenancePrefix + "下週五飛東京"
        XCTAssertEqual(NoteSuggester.appending("帶護照", to: provenance), provenance + "\n\n• 帶護照")
        XCTAssertEqual(NoteSuggester.appending(NoteSuggestion(id: "rule.water", text: "Bring water", source: .rules), to: "Gym"),
                       "Gym\n• Bring water")
        XCTAssertEqual(NoteSuggester.appending("  • Bring water. ", to: nil), "• Bring water")
        XCTAssertEqual(NoteSuggester.appending("   ", to: "Terminal 2"), "Terminal 2")
        // What the page saves: EventNotes keeps the lines.
        XCTAssertEqual(EventNotes.normalized(NoteSuggester.appending("Bring water", to: "Terminal 2\n")),
                       "Terminal 2\n• Bring water")
    }

    // MARK: Tables

    func testRuleTablesAreWellFormed() {
        XCTAssertTrue(NoteSuggester.allMatchers.allSatisfy(\.isValid), "every English pattern compiles")
        var ids = Set<String>()
        for category in NoteSuggester.categories {
            XCTAssertTrue(ids.insert(category.id).inserted, category.id)
            XCTAssertFalse(category.items.isEmpty, category.id)
            XCTAssertLessThanOrEqual(category.items.count, 7, category.id)
            for item in category.items {
                XCTAssertFalse(NoteSuggester.containsCJK(item.en), item.en)
                XCTAssertTrue(NoteSuggester.containsCJK(item.zh), item.zh)
                XCTAssertLessThanOrEqual(item.en.count, 40, item.en)
                XCTAssertLessThanOrEqual(item.zh.count, 20, item.zh)
                XCTAssertEqual(NoteSuggester.cleaned(item.en), item.en)
                XCTAssertEqual(NoteSuggester.cleaned(item.zh), item.zh)
            }
            for superseded in category.supersedes {
                XCTAssertTrue(NoteSuggester.categories.contains { $0.id == superseded }, superseded)
            }
        }
        XCTAssertEqual(NoteSuggester.region(forZone: "Asia/Taipei"), "TW")
        XCTAssertEqual(NoteSuggester.region(forZone: "America/Indiana/Indianapolis"), "US")
        XCTAssertNil(NoteSuggester.region(forZone: "UTC"))
    }
}
