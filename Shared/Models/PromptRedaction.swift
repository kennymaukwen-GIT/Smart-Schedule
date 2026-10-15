import Foundation

/// Email addresses in text bound for the assistant's model (`CalendarAliases` replaces the user's own Google account
/// addresses; `AppPreferences.promptValue` never shows one). Plain Foundation, so every target can use it.
enum PromptRedaction {
    /// An address as people write it: ASCII local part and a domain with at least two labels. ASCII only, so text
    /// around it in other scripts ("寄給kenny@example.com謝謝") is not taken for part of the address, and the local part
    /// starts with a letter, digit or "_", so a quote, dot or "+" in front ("'example@yourmail.com'") is not either.
    /// Text run together with an address ("see...example@yourmail.com", "example@yourmail.com.Thanks") can still be taken
    /// for part of it: `CalendarAliases` also replaces the accounts' addresses literally.
    static let emailPattern = #"[A-Z0-9_][A-Z0-9._%+'-]*@[A-Z0-9-]+(?:\.[A-Z0-9-]+)+"#

    /// What the model calls a calendar whose name is an email address (another person's calendar shared with the
    /// user, or one without a title, which shows its id).
    static let sharedCalendarName = "Shared calendar"

    static func containsEmail(_ text: String) -> Bool {
        text.contains("@") && text.range(of: emailPattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Every address in `text` replaced by `replacement(address)`; nil keeps that address as it is.
    static func replacingEmails(in text: String, _ replacement: (String) -> String?) -> String {
        guard text.contains("@"),
              let regex = try? NSRegularExpression(pattern: emailPattern, options: [.caseInsensitive]) else { return text }
        let source = text as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            guard let new = replacement(source.substring(with: match.range)) else { continue }
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)) + new
            cursor = match.range.location + match.range.length
        }
        return result + source.substring(from: cursor)
    }
}
