import SwiftUI

/// Settings › About: version, terms, privacy policy and support. Rows whose Info.plist value is missing are hidden.
struct AboutView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section {
                LabeledContent("Version") {
                    Text(verbatim: Self.version)
                }
            }
            Section {
                if let terms = AccountSheet.url(forInfoKey: "SSTermsURL") {
                    Button("Terms of Use") { openURL(terms) }
                }
                if let privacy = AccountSheet.url(forInfoKey: "SSPrivacyURL") {
                    Button("Privacy Policy") { openURL(privacy) }
                }
                if let email = AppConstants.info("SSSupportEmail"), let mail = URL(string: "mailto:\(email)") {
                    Button("Contact support") { openURL(mail) }
                }
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// "0.1.0 (1)".
    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "–"
        let build = info["CFBundleVersion"] as? String ?? "–"
        return "\(short) (\(build))"
    }
}
