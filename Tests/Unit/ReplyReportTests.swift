import XCTest

/// "Report this reply" (App Review Guidelines 1.2 and 4.7.1): the mailto link to support that quotes an assistant
/// reply, the same report as text for the clipboard, and the text quoted from a reply's prose and cards. Bundle.main is
/// the test runner, so the strings are the English keys.
final class ReplyReportTests: XCTestCase {
    private let address = "support@smart-schedules.com"
    private let appVersion = "1.0.0 (1)"
    private let systemVersion = "18.6"

    private func link(_ reply: String) throws -> URL {
        try XCTUnwrap(ReplyReport.mailURL(to: address, reply: reply, appVersion: appVersion, systemVersion: systemVersion))
    }

    private func fields(_ url: URL) throws -> [String: String] {
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    func testTheLinkIsAMailtoToSupport() throws {
        let url = try link("Lunch with Andrew is at 13:00.")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(url.scheme, "mailto")
        XCTAssertNil(components.host)
        XCTAssertEqual(components.path, address)
        XCTAssertTrue(url.absoluteString.hasPrefix("mailto:support@smart-schedules.com?subject="), url.absoluteString)
        XCTAssertEqual(components.queryItems?.map(\.name), ["subject", "body"])
    }

    func testSubjectAndBodyDecodeBackExactly() throws {
        let reply = "Gym 💪🏽 Fri 18:00 & dinner? 1+1=2; 50% off / #2\n週五晚上 7 點和 Andrew 吃飯\n\n• Bring “passport”"
        let decoded = try fields(link(reply))
        XCTAssertEqual(decoded["subject"], "Report an AI reply")
        XCTAssertEqual(decoded["subject"], ReplyReport.subject)
        XCTAssertEqual(decoded["body"], ReplyReport.body(reply: reply, appVersion: appVersion, systemVersion: systemVersion))
        XCTAssertEqual(decoded["body"], [
            "The Smart Schedules assistant replied:",
            "",
            reply,
            "",
            "What was wrong with it? (optional)",
            "",
            "",
            "Smart Schedules 1.0.0 (1) · iOS 18.6"
        ].joined(separator: "\n"))
    }

    func testOnlyUnreservedCharactersAreLeftUnencoded() throws {
        let url = try link("a+b & c=d? #tag\n午餐 😀")
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
        XCTAssertEqual(query.components(separatedBy: "&").count, 2, "the reply's & can't start a field of its own")
        XCTAssertNil(query.range(of: "[^A-Za-z0-9._~%=&-]", options: .regularExpression), query)
        XCTAssertTrue(query.contains("a%2Bb%20%26%20c%3Dd%3F%20%23tag%0A"), query)
        // "+" would read as a space in some mail apps; "#" would end the link.
        XCTAssertFalse(url.absoluteString.contains("+"))
        XCTAssertFalse(url.absoluteString.contains("#"))
        XCTAssertTrue(query.contains("%E5%8D%88%E9%A4%90"), "午餐 as UTF-8")
        XCTAssertTrue(query.contains("%F0%9F%98%80"), "😀 as UTF-8")
    }

    func testTheReplyIsTrimmed() {
        XCTAssertEqual(ReplyReport.quoted("  Done.\n\n"), "Done.")
        XCTAssertTrue(ReplyReport.body(reply: "\n Done. ", appVersion: appVersion, systemVersion: systemVersion)
            .contains("replied:\n\nDone.\n\nWhat was wrong"))
    }

    func testALongReplyIsCutWithAnEllipsis() throws {
        let long = String(repeating: "行程", count: 1_000) // 2,000 characters
        let quoted = ReplyReport.quoted(long)
        XCTAssertEqual(quoted.count, ReplyReport.maxReplyCharacters)
        XCTAssertTrue(quoted.hasSuffix("…"))
        XCTAssertTrue(long.hasPrefix(String(quoted.dropLast())))
        XCTAssertEqual(try fields(link(long))["body"]?.contains(quoted), true)
    }

    func testAReplyAtTheLimitIsKeptWhole() {
        let exact = String(repeating: "a", count: ReplyReport.maxReplyCharacters)
        XCTAssertEqual(ReplyReport.quoted(exact), exact)
    }

    func testTheCutNeverSplitsAnEmoji() {
        let emoji = String(repeating: "💪🏽", count: 1_600)
        XCTAssertEqual(ReplyReport.quoted(emoji),
                       String(repeating: "💪🏽", count: ReplyReport.maxReplyCharacters - 1) + "…")
    }

    func testNoAddressNoLink() {
        XCTAssertNil(ReplyReport.mailURL(to: "", reply: "Hi", appVersion: appVersion, systemVersion: systemVersion))
        XCTAssertNil(ReplyReport.mailURL(to: "  ", reply: "Hi", appVersion: appVersion, systemVersion: systemVersion))
        XCTAssertNil(ReplyReport.mailURL(to: nil, reply: "Hi", appVersion: appVersion, systemVersion: systemVersion))
    }

    func testThePlainTextIsTheSubjectThenTheBody() {
        let reply = "Moved the team sync to 15:30 & told Andrew."
        let text = ReplyReport.plainText(reply: reply, appVersion: appVersion, systemVersion: systemVersion)
        XCTAssertEqual(text, "Report an AI reply\n\n"
                       + ReplyReport.body(reply: reply, appVersion: appVersion, systemVersion: systemVersion))
        XCTAssertTrue(text.contains("\n\(reply)\n"))
        XCTAssertTrue(text.hasSuffix("\nSmart Schedules 1.0.0 (1) · iOS 18.6"))
    }

    // MARK: What is quoted

    /// A plan reply's prose is often empty (its summary is on the card): the card's title, summary, phases, sessions
    /// and assumptions are the report.
    func testAPlanOnlyReplyQuotesItsCard() {
        let text = ReplyReport.reportText(text: "",
                                          planTitle: "6-month muscle plan",
                                          planSummary: "Three phases of strength training, four days a week.",
                                          phaseNames: ["Foundation", "Build"],
                                          sessionTitles: ["Upper body", "Lower body", "Upper body", " "],
                                          assumptions: ["You can train at 07:00", ""])
        XCTAssertEqual(text, [
            "6-month muscle plan",
            "Three phases of strength training, four days a week.",
            "",
            "• Foundation",
            "• Build",
            "",
            "• Upper body",
            "• Lower body",
            "",
            "• You can train at 07:00"
        ].joined(separator: "\n"))
    }

    /// Added events, events waiting for Add, or an agenda, with no prose: one line per event.
    func testAnEventsOnlyReplyQuotesItsEvents() {
        let text = ReplyReport.reportText(text: "  \n",
                                          eventTitles: ["Lunch with Andrew · Wed, Oct 14 · 13:00–14:00",
                                                        "",
                                                        "健身 · 10月15日（週四）18:00–19:00"])
        XCTAssertEqual(text, "• Lunch with Andrew · Wed, Oct 14 · 13:00–14:00\n• 健身 · 10月15日（週四）18:00–19:00")
    }

    func testTheProseComesFirstThenTheCards() {
        let text = ReplyReport.reportText(text: "  Moved the team sync to 15:30.\n",
                                          planTitle: nil,
                                          planSummary: nil,
                                          assumptions: ["You meant this week"],
                                          eventTitles: ["Team sync · Thu, Oct 15 · 15:30–16:00"])
        XCTAssertEqual(text, "Moved the team sync to 15:30.\n\n• You meant this week\n\n• Team sync · Thu, Oct 15 · 15:30–16:00")
    }

    func testAPlanTitleAloneIsKept() {
        XCTAssertEqual(ReplyReport.reportText(text: "", planTitle: " Marathon plan ", planSummary: "  "), "Marathon plan")
    }

    /// A reply with nothing the assistant wrote (only a learned suggestion or a settings card) gets no menu.
    func testNothingToReportIsEmpty() {
        XCTAssertEqual(ReplyReport.reportText(text: ""), "")
        XCTAssertEqual(ReplyReport.reportText(text: " \n ", planTitle: "", planSummary: " ", phaseNames: [""],
                                              sessionTitles: [" "], assumptions: ["\n"], eventTitles: [""]), "")
    }

    func testAPlanReportGoesThroughTheLinkWhole() throws {
        let quote = ReplyReport.reportText(text: "", planTitle: "Couch to 5K", planSummary: "Run 3 times a week & rest.",
                                           sessionTitles: ["Easy run"], eventTitles: ["Easy run · Mon, Oct 19 · 07:00–07:30"])
        let body = try XCTUnwrap(fields(link(quote))["body"])
        XCTAssertTrue(body.contains("replied:\n\nCouch to 5K\nRun 3 times a week & rest.\n\n• Easy run\n\n• Easy run · Mon"), body)
    }

    // MARK: Suggestions and locations

    /// The chips under a reply are the assistant's words too: one last block, after the cards, trimmed, without empty
    /// or repeated ones.
    func testTheSuggestionsComeLast() {
        let text = ReplyReport.reportText(text: "Added lunch with Andrew.",
                                          assumptions: ["You meant this week"],
                                          eventTitles: ["Lunch with Andrew · Wed, Oct 14 · 13:00–14:00"],
                                          suggestedReplies: [" Move it to 14:00 ", "", "Add a reminder", "Move it to 14:00"])
        XCTAssertEqual(text, [
            "Added lunch with Andrew.",
            "",
            "• You meant this week",
            "",
            "• Lunch with Andrew · Wed, Oct 14 · 13:00–14:00",
            "",
            "• Move it to 14:00",
            "• Add a reminder"
        ].joined(separator: "\n"))
    }

    func testSuggestionsAloneAreReported() {
        XCTAssertEqual(ReplyReport.reportText(text: " ", suggestedReplies: ["What's on today?", "今天有什麼行程"]),
                       "• What's on today?\n• 今天有什麼行程")
    }

    func testNoSuggestionsLeaveTheTextAsItWas() {
        XCTAssertEqual(ReplyReport.reportText(text: "Done.", planTitle: "Marathon plan", assumptions: ["You meant this week"],
                                              suggestedReplies: []),
                       ReplyReport.reportText(text: "Done.", planTitle: "Marathon plan", assumptions: ["You meant this week"]))
        XCTAssertEqual(ReplyReport.reportText(text: "", suggestedReplies: [" ", "\n", ""]), "")
    }

    /// The added and pending cards show where an event is, so its line ends in " · <location>"; no location, or a
    /// blank one, adds nothing.
    func testAnEventLineEndsWithItsLocation() {
        XCTAssertEqual(ReplyReport.eventLine(title: "Lunch with Andrew", when: "Wed, Oct 14 · 13:00–14:00",
                                             location: " Din Tai Fung, Taipei 101 "),
                       "Lunch with Andrew · Wed, Oct 14 · 13:00–14:00 · Din Tai Fung, Taipei 101")
        for blank in [nil, "", "  \n"] as [String?] {
            XCTAssertEqual(ReplyReport.eventLine(title: "Lunch with Andrew", when: "Wed, Oct 14 · 13:00–14:00", location: blank),
                           "Lunch with Andrew · Wed, Oct 14 · 13:00–14:00", String(describing: blank))
        }
        XCTAssertEqual(ReplyReport.eventLine(title: "健身", when: "10月15日（週四）18:00–19:00"), "健身 · 10月15日（週四）18:00–19:00")
    }

    func testALocationGoesThroughTheLinkWhole() throws {
        let line = ReplyReport.eventLine(title: "Dinner", when: "Fri, Oct 16 · 19:00–21:00", location: "Kiki & Co. #2, 3F")
        let quote = ReplyReport.reportText(text: "", eventTitles: [line], suggestedReplies: ["Move it to 20:00?"])
        XCTAssertEqual(quote, "• Dinner · Fri, Oct 16 · 19:00–21:00 · Kiki & Co. #2, 3F\n\n• Move it to 20:00?")
        let body = try XCTUnwrap(fields(link(quote))["body"])
        XCTAssertTrue(body.contains("replied:\n\n" + quote + "\n\nWhat was wrong"), body)
    }

    // MARK: No quote (Settings › AI & privacy)

    func testWithoutAQuoteTheEmailAsksForTheReply() throws {
        let expected = [
            "Paste the assistant's reply here, or describe it:",
            "",
            "",
            "",
            "What was wrong with it? (optional)",
            "",
            "",
            "Smart Schedules 1.0.0 (1) · iOS 18.6"
        ].joined(separator: "\n")
        XCTAssertEqual(ReplyReport.body(reply: "", appVersion: appVersion, systemVersion: systemVersion), expected)
        XCTAssertEqual(ReplyReport.body(reply: " \n ", appVersion: appVersion, systemVersion: systemVersion), expected)
        XCTAssertEqual(try fields(link(""))["body"], expected)
        XCTAssertEqual(ReplyReport.plainText(reply: "", appVersion: appVersion, systemVersion: systemVersion),
                       "Report an AI reply\n\n" + expected)
    }

    func testAQuoteIsNotIntroducedAsMissing() {
        let body = ReplyReport.body(reply: "Done.", appVersion: appVersion, systemVersion: systemVersion)
        XCTAssertTrue(body.hasPrefix("The Smart Schedules assistant replied:\n\nDone.\n"), body)
        XCTAssertFalse(body.contains("Paste the assistant's reply"))
    }
}
