import Foundation

/// "Report this reply" on an assistant message (App Review Guidelines 1.2 and 4.7.1: a way to report offensive
/// content, answered by the developer): an email to Smart Schedules support that quotes the reply. Only what the reply
/// showed goes in (its prose, its cards, which can name the user's events, and its suggestion chips), never the request
/// that led to it, and the user sees all of it in the new email before deciding to send it.
///
/// Pure Foundation, no UIKit: `ReplyReportDialog` (App/Views/ChatPanel.swift, used by the chat's long-press menu and
/// Settings › AI & privacy) passes the support address (`AppConstants.info("SSSupportEmail")`), the app's version
/// (`AboutView.version`, "1.0.0 (1)") and iOS's, copies `plainText` and opens `mailURL`. What is quoted comes from
/// `reportText`, which joins the prose, what the reply's cards show and its suggestions.
enum ReplyReport {
    /// The reply is cut to this many characters ("…" included), so the mailto link stays a size mail apps open.
    static let maxReplyCharacters = 1_500

    /// The email's subject: "Report an AI reply".
    static var subject: String { String(localized: "Report an AI reply") }

    /// The reply as the report quotes it: trimmed, and at most `maxReplyCharacters` long, ending in "…" when cut.
    /// Counted in characters, so an emoji or a Chinese character is never split.
    static func quoted(_ reply: String) -> String {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxReplyCharacters else { return trimmed }
        let kept = String(trimmed.prefix(maxReplyCharacters - 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        return kept + "…"
    }

    /// The email's text: what the assistant replied, a line inviting the user to say what was wrong (with room to
    /// write under it), then the app and iOS versions. With no reply to quote (Settings › AI & privacy, or a reply
    /// that is only spaces) the first line asks the user to paste or describe the reply instead, above the empty
    /// lines where the quote would be.
    static func body(reply: String, appVersion: String, systemVersion: String) -> String {
        let quote = quoted(reply)
        let lead = quote.isEmpty ? String(localized: "Paste the assistant's reply here, or describe it:")
                                 : String(localized: "The Smart Schedules assistant replied:")
        return [lead,
                "",
                quote,
                "",
                String(localized: "What was wrong with it? (optional)"),
                "",
                "",
                versionLine(appVersion: appVersion, systemVersion: systemVersion)]
            .joined(separator: "\n")
    }

    /// Everything a reply showed that the assistant wrote, as one plain text for Copy and for the report: the prose,
    /// then a plan's title and summary, its phases, its sessions, the assumptions, and the events (added, waiting for
    /// Add, or listed in an answer), one "• " line each. Blocks are separated by a blank line. Every part is trimmed
    /// and empty ones are left out; a list keeps the first of repeated lines (the same session in every phase). ""
    /// when there is nothing to report. Strings only: the app picks what each card shows
    /// (`ChatViewModel.Message.reportText`).
    static func reportText(text: String,
                           planTitle: String? = nil,
                           planSummary: String? = nil,
                           phaseNames: [String] = [],
                           sessionTitles: [String] = [],
                           assumptions: [String] = [],
                           eventTitles: [String] = []) -> String {
        reportText(text: text, planTitle: planTitle, planSummary: planSummary, phaseNames: phaseNames,
                   sessionTitles: sessionTitles, assumptions: assumptions, eventTitles: eventTitles, suggestedReplies: [])
    }

    /// The same, with the reply's suggestions (the chips under it, which the assistant wrote too) as a last "• " block.
    static func reportText(text: String,
                           planTitle: String? = nil,
                           planSummary: String? = nil,
                           phaseNames: [String] = [],
                           sessionTitles: [String] = [],
                           assumptions: [String] = [],
                           eventTitles: [String] = [],
                           suggestedReplies: [String]) -> String {
        let plan = [cleaned(planTitle), cleaned(planSummary)].filter { !$0.isEmpty }.joined(separator: "\n")
        let blocks = [cleaned(text), plan,
                      bulleted(phaseNames), bulleted(sessionTitles), bulleted(assumptions), bulleted(eventTitles),
                      bulleted(suggestedReplies)]
        return blocks.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// One of `eventTitles` as a card shows the event: "Lunch with Andrew · Wed, Oct 14 · 13:00–14:00", then
    /// " · <location>" when it has one (the added and pending cards show it; an agenda passes none). Each part trimmed.
    static func eventLine(title: String, when: String, location: String? = nil) -> String {
        let line = cleaned(title) + " · " + cleaned(when)
        let place = cleaned(location)
        return place.isEmpty ? line : line + " · " + place
    }

    /// Trimmed; "" for nil.
    private static func cleaned(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "• a\n• b", without empty or repeated items.
    private static func bulleted(_ items: [String]) -> String {
        var seen: Set<String> = []
        var lines: [String] = []
        for raw in items {
            let item = cleaned(raw)
            guard !item.isEmpty, seen.insert(item).inserted else { continue }
            lines.append("• " + item)
        }
        return lines.joined(separator: "\n")
    }

    /// "Smart Schedules 1.0.0 (1) · iOS 18.6". Product names and numbers only, so it is not translated.
    static func versionLine(appVersion: String, systemVersion: String) -> String {
        "Smart Schedules \(appVersion) · iOS \(systemVersion)"
    }

    /// `mailto:<address>?subject=…&body=…`; nil without an address. Every character of the subject and body except
    /// A–Z, a–z, 0–9 and "-._~" is percent-encoded (UTF-8): spaces, line breaks, "&", "=", "?", "#", non-ASCII, and
    /// "+", which `URLComponents.queryItems` would leave as it is and some mail apps read as a space.
    static func mailURL(to address: String?, reply: String, appVersion: String, systemVersion: String) -> URL? {
        guard let address = address?.trimmingCharacters(in: .whitespacesAndNewlines), !address.isEmpty else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = address
        components.percentEncodedQuery = [
            "subject=" + encoded(subject),
            "body=" + encoded(body(reply: reply, appVersion: appVersion, systemVersion: systemVersion))
        ].joined(separator: "&")
        return components.url
    }

    /// The same report as text, for the clipboard (copied by Open Email and Copy Report alike, so it can be pasted
    /// into any email app): the subject, a blank line, then the body.
    static func plainText(reply: String, appVersion: String, systemVersion: String) -> String {
        subject + "\n\n" + body(reply: reply, appVersion: appVersion, systemVersion: systemVersion)
    }

    /// RFC 3986's unreserved characters, ASCII only (`CharacterSet.alphanumerics` would let Chinese through unencoded).
    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func encoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }
}
