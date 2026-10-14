import Foundation

/// An event's notes ⇄ its Google Calendar `description`.
///
/// `ScheduleEvent.notes` is always plain text: whatever the description holds, as text the event page can show and
/// edit. Google Calendar's web editor stores descriptions as HTML (`<br>`, `<b>`, `<a href>`, `&amp;`…), the API
/// and other apps store plain text, so reading turns HTML into text (line breaks kept, tags dropped, entities
/// decoded, a link's address kept when its text differs) and leaves plain text as it is. Saving sends plain text.
///
/// What Smart Schedule itself writes into a description stays part of the notes: the provenance line
/// ("由 Smart Schedule 智慧助理自動排程：<what the user said>"), then the event's notes, and for plan sessions the goal,
/// the phase and the workout. Google Calendar shows all of it (as in Artboard 5); the event page keeps the provenance
/// line out of its editor and writes it back on save (`provenanceLine`, `joining`), the rest is ordinary text the
/// user can change or delete. Nothing parses it back (plans are found by `extendedProperties.private.ssPlanId`).
/// See docs/GOOGLE_CALENDAR_SYNC.md §2 and §11.2.
enum EventNotes {
    // MARK: Google → notes

    /// Plain text for a description: `<br>`, `<p>`, `</p>`, `</div>`, lists, headings and table rows become line
    /// breaks, `<li>` a "• ", `<a href="x">text</a>` "text (x)" (just "x" when the text is the address), other tags
    /// are dropped and entities decoded (`&amp;` `&lt;` `&gt;` `&quot;` `&#39;` `&apos;` `&nbsp;`, `&#NNN;`,
    /// `&#xHH;`). Text without tags keeps its own characters (an "a < b" stays). Trimmed; nil when nothing is left.
    static func plainText(fromDescription html: String?) -> String? {
        guard var text = html, !text.isEmpty else { return nil }
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if looksLikeHTML(text) {
            text = replacing(#"(?s)<!--.*?-->"#, in: text, with: "")
            text = links(in: text)
            text = replacing(#"<br\s*/?>"#, in: text, with: "\n")
            text = replacing(#"<li(?:\s[^<>]*)?>"#, in: text, with: "\n• ")
            // A paragraph is set off on both sides; a div (Google's editor: one per line) ends its line.
            text = replacing(#"</?(?:p|ul|ol|tr|h[1-6]|blockquote|pre|table)(?:\s[^<>]*)?/?>"#, in: text, with: "\n")
            text = replacing(#"</div\s*>"#, in: text, with: "\n")
            text = replacing(#"</?[A-Za-z][A-Za-z0-9-]*(?:\s[^<>]*)?/?>"#, in: text, with: "")
        }
        text = decodingEntities(text)
        return tidy(text)
    }

    // MARK: Notes → Google

    /// The description to send for notes typed on the event page: plain text, line breaks kept, outer blank lines
    /// trimmed. nil when nothing is left (the PATCH then clears the description with "").
    static func description(fromPlainText text: String) -> String? {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The same text compared the way the event page saves it: two notes that save the same are equal.
    static func normalized(_ notes: String?) -> String? {
        notes.flatMap(description(fromPlainText:))
    }

    /// "Add a note" (assistant): the existing notes, then the note on a line of its own (after a blank line when
    /// the notes are only Smart Schedule's provenance line, as the mapper sets notes apart). A note that is
    /// already there as a line of its own is not added twice.
    static func appending(_ note: String, to existing: String?) -> String {
        guard let addition = description(fromPlainText: note) else { return normalized(existing) ?? "" }
        guard let current = normalized(existing) else { return addition }
        let lines = current.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.contains(addition) { return current }
        let onlyProvenance = current.hasPrefix(CalendarEventMapper.provenancePrefix) && !current.contains("\n")
        return current + (onlyProvenance ? "\n\n" : "\n") + addition
    }

    // MARK: Prompt

    /// The notes as one line for the assistant's UPCOMING and FOCUS rows: without Smart Schedule's provenance
    /// paragraph (it only repeats what the user once said), line breaks as " / ", "|" as "/", at most `limit`
    /// characters ("…" when cut). nil when nothing is left.
    static func promptLine(_ notes: String?, limit: Int = 300) -> String? {
        guard let body = withoutProvenance(notes) else { return nil }
        let flat = body
            .replacingOccurrences(of: "|", with: "/")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " / ")
        let collapsed = flat.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(max(0, limit - 1))).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The leading "由 Smart Schedule 智慧助理自動排程：…" line, when the notes start with it. The event page keeps it
    /// out of the editor (Google Calendar still shows it, as in Artboard 5) and puts it back on save.
    static func provenanceLine(_ notes: String?) -> String? {
        guard let notes = normalized(notes), notes.hasPrefix(CalendarEventMapper.provenancePrefix) else { return nil }
        guard let lineEnd = notes.firstIndex(of: "\n") else { return notes }
        return String(notes[..<lineEnd])
    }

    /// What the user typed on the event page under the kept provenance line, set apart by a blank line as the
    /// mapper writes it. nil when both are empty.
    static func joining(provenance: String?, userNotes: String) -> String? {
        let body = normalized(userNotes)
        guard let provenance = normalized(provenance) else { return body }
        guard let body else { return provenance }
        return provenance + "\n\n" + body
    }

    /// Notes without a leading "由 Smart Schedule 智慧助理自動排程：…" line (what `CalendarEventMapper` writes first);
    /// nil when that was all.
    static func withoutProvenance(_ notes: String?) -> String? {
        guard let notes = normalized(notes) else { return nil }
        guard notes.hasPrefix(CalendarEventMapper.provenancePrefix) else { return notes }
        guard let lineEnd = notes.firstIndex(of: "\n") else { return nil }
        return normalized(String(notes[notes.index(after: lineEnd)...]))
    }

    // MARK: Helpers

    /// A tag Google's editor or a mail client writes. Plain text with a stray "<" is not HTML.
    private static func looksLikeHTML(_ text: String) -> Bool {
        let tags = "br|p|div|span|b|i|u|s|strong|em|a|ul|ol|li|h[1-6]|font|table|tbody|thead|tr|td|th|img|hr|blockquote|pre|code|sup|sub|small|big|strike|del|ins|center"
        return text.range(of: #"</?(?:\#(tags))(?:\s[^<>]*)?/?>"#, options: [.regularExpression, .caseInsensitive]) != nil
            || text.contains("<!--")
    }

    /// `<a href="x">text</a>` → "text (x)", or "x" when the text is the address (or empty).
    private static func links(in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"<a\s[^<>]*?href\s*=\s*(?:"([^"]*)"|'([^']*)')[^<>]*>(.*?)</a\s*>"#,
                                                   options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return text }
        var result = ""
        var last = text.startIndex
        let whole = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: whole) {
            guard let range = Range(match.range, in: text) else { continue }
            result += text[last..<range.lowerBound]
            let href = [1, 2].compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }.first ?? ""
            let inner = Range(match.range(at: 3), in: text).map { String(text[$0]) } ?? ""
            let label = decodingEntities(replacing(#"<[^<>]*>"#, in: inner, with: ""))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let address = decodingEntities(href).trimmingCharacters(in: .whitespacesAndNewlines)
            if address.isEmpty || label == address || label == address.replacingOccurrences(of: "mailto:", with: "") {
                result += label.isEmpty ? address : label
            } else if label.isEmpty {
                result += address
            } else {
                result += "\(label) (\(address))"
            }
            last = range.upperBound
        }
        result += text[last...]
        return result
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "ndash": "–", "mdash": "—", "hellip": "…", "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“"
    ]

    /// `&amp;` and friends, `&#39;`, `&#x27;`. Unknown names stay as written. One pass, so "&amp;lt;" is "&lt;".
    static func decodingEntities(_ text: String) -> String {
        guard text.contains("&"),
              let regex = try? NSRegularExpression(pattern: #"&(#[0-9]{1,7}|#[xX][0-9A-Fa-f]{1,6}|[A-Za-z]{2,8});"#)
        else { return text }
        var result = ""
        var last = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text), let nameRange = Range(match.range(at: 1), in: text) else { continue }
            let name = String(text[nameRange])
            var replacement: String?
            if name.hasPrefix("#x") || name.hasPrefix("#X") {
                replacement = UInt32(name.dropFirst(2), radix: 16).flatMap { Unicode.Scalar($0) }.map { String(Character($0)) }
            } else if name.hasPrefix("#") {
                replacement = UInt32(name.dropFirst(), radix: 10).flatMap { Unicode.Scalar($0) }.map { String(Character($0)) }
            } else {
                replacement = namedEntities[name.lowercased()]
            }
            result += text[last..<range.lowerBound]
            result += replacement ?? String(text[range])
            last = range.upperBound
        }
        result += text[last...]
        return result
    }

    /// Non-breaking spaces as spaces, trailing spaces off each line, at most one blank line in a row, trimmed.
    private static func tidy(_ text: String) -> String? {
        let lines = text
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .components(separatedBy: "\n")
            .map { line -> String in
                var line = line
                while let last = line.last, last == " " || last == "\t" { line.removeLast() }
                return line
            }
        var kept: [String] = []
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if let previous = kept.last, previous.isEmpty { continue }
                kept.append("")
            } else {
                kept.append(line)
            }
        }
        let joined = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    private static func replacing(_ pattern: String, in text: String, with template: String) -> String {
        text.replacingOccurrences(of: pattern, with: template,
                                  options: [.regularExpression, .caseInsensitive])
    }
}
