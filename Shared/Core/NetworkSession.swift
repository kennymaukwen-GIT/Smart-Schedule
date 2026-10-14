import Foundation

/// The `URLSession` for Google and Gemini requests.
///
/// The notification content extension answers in place (long-press a reminder, type or speak, confirm a deletion):
/// it runs the Gemini and Calendar requests itself, in a short-lived process with a small memory limit. There the
/// session is ephemeral (no disk cache, cookie or credential storage) and no request waits more than 30 seconds.
/// The app keeps `URLSession.shared`.
enum NetworkSession {
    /// Requests from an app extension wait at most this long.
    static let extensionTimeout: TimeInterval = 30

    /// Whether this process is an app extension (its bundle is an `.appex`).
    static let isAppExtension = Bundle.main.bundlePath.hasSuffix(".appex")

    static let shared: URLSession = isAppExtension ? makeExtensionSession() : .shared

    static func makeExtensionSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = extensionTimeout
        return URLSession(configuration: configuration)
    }

    /// `shared.data(for:)`, the request's own timeout capped at 30 seconds in an extension.
    static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await shared.data(for: capped(request, inExtension: isAppExtension))
    }

    static func capped(_ request: URLRequest, inExtension: Bool) -> URLRequest {
        guard inExtension, request.timeoutInterval > extensionTimeout else { return request }
        var capped = request
        capped.timeoutInterval = extensionTimeout
        return capped
    }
}
