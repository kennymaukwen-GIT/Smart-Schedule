import Foundation

struct GeminiConfig: Sendable {
    /// Smart Schedule's server (server/worker) + "/v1beta": it checks App Attest and adds the Gemini key, which is
    /// never in the app. The path below it is Gemini's REST path.
    var baseURL: String
    var modelID: String
    /// Not sent: the server adds the key. Kept so existing callers still build.
    var apiKey: String?
    /// Gemini 3.x `thinkingLevel` ("low" | "high"). Nil = model default. Do not send to 2.x models.
    var thinkingLevel: String?

    /// `SSGeminiBaseURL` comes from GEMINI_BASE_URL in Config/Secrets.xcconfig. Without it the base is empty and every
    /// request fails with `AttestationError.notConfigured`: the app never calls Google itself.
    static var fromBundle: GeminiConfig {
        GeminiConfig(
            baseURL: AppConstants.info("SSGeminiBaseURL") ?? "",
            modelID: AppConstants.info("SSGeminiModelID") ?? "gemini-3.8-flash",
            apiKey: nil,
            thinkingLevel: "low" // parsing a sentence is latency-bound; plans still come out well-structured
        )
    }
}

enum GeminiError: LocalizedError {
    case http(status: Int, message: String)
    case blocked(reason: String)
    case malformed(String)
    /// AI data sharing is not allowed (`AIConsentStore`); thrown before anything is built or sent.
    case consentRequired

    /// What the user reads in the assistant's reply (chat, Quick Capture, Siri, the notification extension): never
    /// Gemini's raw reason, status or English message, which stay in the case's payload.
    var errorDescription: String? {
        switch self {
        case let .http(status, _):
            Self.isBusy(status: status)
                ? String(localized: "The assistant is busy right now. Please try again in a moment.")
                : Self.requestFailedMessage
        case let .blocked(reason):
            Self.isContentBlock(reason: reason)
                ? String(localized: "I can't help with that. I can help with your events, times and plans.")
                : Self.requestFailedMessage
        case .malformed: Self.requestFailedMessage
        case .consentRequired: String(localized: "Allow AI data sharing in Settings › AI & privacy to use the assistant.")
        }
    }

    /// A request that went wrong for a reason the user can't act on (a block that is not about the content, Google's
    /// 4xx, a response that can't be read): try again, or say it another way.
    private static var requestFailedMessage: String {
        String(localized: "Something went wrong with that request. Please try again, or say it another way.")
    }

    /// Whether an `http(status:message:)` status means Gemini is overloaded or out of quota for now (429, 5xx), which
    /// passes: "busy, try again in a moment". `send` has already retried these twice.
    static func isBusy(status: Int) -> Bool {
        status == 429 || status >= 500
    }

    /// The `promptFeedback.blockReason` and `finishReason` values that mean the content itself was filtered (the
    /// request's `safetySettings`, Google's own policy and blocklists, personal data, recitation).
    static let contentBlockReasons: Set<String> = [
        "SAFETY", "PROHIBITED_CONTENT", "BLOCKLIST", "SPII", "IMAGE_SAFETY", "RECITATION"
    ]

    /// Whether a `blocked(reason:)` reason means the content was filtered, so the reply steers back to events, times
    /// and plans. Every other reason (MAX_TOKENS, MALFORMED_FUNCTION_CALL, OTHER, "no candidates", one Gemini adds
    /// later) is a request that went wrong: try again, or say it another way.
    static func isContentBlock(reason: String) -> Bool {
        contentBlockReasons.contains(reason)
    }
}

/// One `Content` object (`{role, parts}`) kept as raw JSON.
/// Model turns are stored *verbatim* so `thoughtSignature` fields survive — Gemini 3 rejects
/// function-calling follow-ups with a 400 if the signature from the previous model turn is missing.
struct GeminiTurn: Sendable {
    let json: Data

    static func user(_ text: String) -> GeminiTurn {
        GeminiTurn(json: (try? JSONSerialization.data(withJSONObject: [
            "role": "user", "parts": [["text": text]]
        ])) ?? Data())
    }

    struct FunctionResult: Sendable {
        let name: String
        let id: String?
        let responseJSON: Data   // JSON object
    }

    static func functionResponses(_ results: [FunctionResult]) -> GeminiTurn {
        let parts: [[String: Any]] = results.map { result in
            var functionResponse: [String: Any] = [
                "name": result.name,
                "response": (try? JSONSerialization.jsonObject(with: result.responseJSON)) ?? [:]
            ]
            if let id = result.id { functionResponse["id"] = id }
            return ["functionResponse": functionResponse]
        }
        return GeminiTurn(json: (try? JSONSerialization.data(withJSONObject: ["role": "user", "parts": parts])) ?? Data())
    }
}

struct GeminiFunctionCall: Sendable {
    let name: String
    let id: String?
    let argsJSON: Data

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: argsJSON)
    }
}

struct GeminiResponse: Sendable {
    let modelTurn: GeminiTurn
    let functionCalls: [GeminiFunctionCall]
    let text: String?
}

/// Minimal REST client for `models/{model}:generateContent` with function calling.
/// Deliberately dependency-free so it also runs inside the notification content extension.
///
/// The one gate for AI data sharing: every entry point (chat, Quick Capture, Siri, notification replies, the
/// notification extension) reaches Gemini through `generate`, which refuses without consent.
///
/// Requests go to Smart Schedule's server, not to Google: the same Gemini REST path and body, with App Attest
/// headers (`AttestationProviding`) instead of an API key.
final class GeminiClient: Sendable {
    let config: GeminiConfig
    private let declarationsJSON: Data
    private let session: URLSession
    private let consentCheck: @Sendable () -> Bool
    private let attestation: AttestationProviding

    /// - Parameter consentCheck: whether the user allowed AI data sharing. Unit tests inject it.
    convenience init(config: GeminiConfig = .fromBundle,
                     session: URLSession = NetworkSession.shared,
                     consentCheck: @escaping @Sendable () -> Bool = { AIConsentStore.current.isGranted }) {
        self.init(config: config, session: session, consentCheck: consentCheck, attestation: AppAttestClient.shared)
    }

    /// - Parameter attestation: proves the request comes from this app. Unit tests inject it.
    init(config: GeminiConfig,
         session: URLSession,
         consentCheck: @escaping @Sendable () -> Bool,
         attestation: AttestationProviding) {
        self.config = config
        self.session = session
        self.consentCheck = consentCheck
        self.attestation = attestation
        self.declarationsJSON = Self.loadDeclarations()
    }

    /// - Parameter mode: "ANY" forces a function call every turn (deterministic parsing; plain chat
    ///   goes through `reply_to_user`). "AUTO" lets the model answer in text.
    /// - Throws: `GeminiError.consentRequired` before anything is sent when AI data sharing is not allowed.
    func generate(system: String,
                  history: [GeminiTurn],
                  mode: String = "ANY",
                  allowedFunctions: [String]? = nil) async throws -> GeminiResponse {
        try await generate(system: system, history: history, mode: mode, allowedFunctions: allowedFunctions,
                           including: [])
    }

    /// Declarations only some requests carry: `plan_departure` goes out only when departure reminders 「該出發了」 are
    /// on for this request (owner decision 3A: off, the request declares exactly what it did without the feature).
    static let optInFunctions: Set<String> = [AssistantFunction.planDeparture.rawValue]

    /// The same, declaring the opt-in functions named in `including` too. No defaults, so no call can match both.
    func generate(system: String,
                  history: [GeminiTurn],
                  mode: String,
                  allowedFunctions: [String]?,
                  including: Set<String>) async throws -> GeminiResponse {
        guard consentCheck() else { throw GeminiError.consentRequired }
        var functionCallingConfig: [String: Any] = ["mode": mode]
        if let allowedFunctions { functionCallingConfig["allowedFunctionNames"] = allowedFunctions }

        var body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": try history.map { try JSONSerialization.jsonObject(with: $0.json) },
            "tools": [["functionDeclarations": try Self.declarations(declarationsJSON, including: including)]],
            "toolConfig": ["functionCallingConfig": functionCallingConfig],
            "safetySettings": Self.safetySettings
        ]
        // Gemini 3 guidance: keep temperature at its default (1.0); lowering it can cause looping.
        if let level = config.thinkingLevel {
            body["generationConfig"] = ["thinkingConfig": ["thinkingLevel": level]]
        }

        let base = config.baseURL.hasSuffix("/") ? String(config.baseURL.dropLast()) : config.baseURL
        guard ServerEndpoint.origin(of: base) != nil else {
            // Not set, or Google itself, which would need an API key in the app.
            throw AttestationError.notConfigured
        }
        guard let url = URL(string: "\(base)/models/\(config.modelID):generateContent") else {
            throw GeminiError.malformed("bad base URL")
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let data = try await send(request, body: try JSONSerialization.data(withJSONObject: body))
        return try Self.parse(data)
    }

    /// Gemini's content filter, sent with every request: Gemini 2.5 and 3 models filter nothing unless a threshold
    /// is set. A blocked answer throws `GeminiError.blocked`, shown as "I can't help with that…".
    static let safetySettings: [[String: String]] = [
        ["category": "HARM_CATEGORY_HARASSMENT", "threshold": "BLOCK_MEDIUM_AND_ABOVE"],
        ["category": "HARM_CATEGORY_HATE_SPEECH", "threshold": "BLOCK_MEDIUM_AND_ABOVE"],
        ["category": "HARM_CATEGORY_SEXUALLY_EXPLICIT", "threshold": "BLOCK_MEDIUM_AND_ABOVE"],
        // Only high: the prompt carries up to 40 of the user's own event titles and notes, and ordinary ones (a
        // shooting range, a chemistry exam, picking up a prescription) must not make every request fail.
        ["category": "HARM_CATEGORY_DANGEROUS_CONTENT", "threshold": "BLOCK_ONLY_HIGH"]
    ]

    // MARK: - Transport with bounded retry on 429 / 5xx

    /// Each attempt is signed again: the server accepts every assertion once.
    private func send(_ request: URLRequest, body: Data, attempt: Int = 0) async throws -> Data {
        let (data, response) = try await AttestedRequest.send(request, body: body, attestation: attestation, session: session)
        let status = response?.statusCode ?? 0
        if (200..<300).contains(status) { return data }
        // Smart Schedule's server answers for itself with {"error": "<code>"}; Google's own errors pass through
        // as {"error": {"message": …}}. Not retried: the server's rate limit (it counts per minute, or per day, so a
        // retry seconds later only spends another request) and a server that is not set up. Otherwise its
        // Retry-After (503 server_busy) is waited for, up to 5 seconds.
        let serverCode = AttestedRequest.errorCode(data)
        if status == 429 || status >= 500, serverCode != "rate_limited", serverCode != "server_misconfigured", attempt < 2 {
            let delay = min(5, max(pow(2.0, Double(attempt)) * 0.8, AttestedRequest.retryAfter(response) ?? 0))
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            return try await send(request, body: body, attempt: attempt + 1)
        }
        if let failure = AttestedRequest.failure(status: status, data: data, response: response) { throw failure }
        let message = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
            .flatMap { $0["error"] as? [String: Any] }
            .flatMap { $0["message"] as? String } ?? String(decoding: data.prefix(300), as: UTF8.self)
        throw GeminiError.http(status: status, message: message)
    }

    // MARK: - Parsing

    static func parse(_ data: Data) throws -> GeminiResponse {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GeminiError.malformed("root is not an object")
        }
        guard let candidate = (root["candidates"] as? [[String: Any]])?.first,
              var content = candidate["content"] as? [String: Any] else {
            // A filtered prompt has no candidates and a blockReason; a filtered answer, a candidate with a
            // finishReason (SAFETY…) and no content.
            let blockReason = (root["promptFeedback"] as? [String: Any])?["blockReason"] as? String
            let finishReason = (root["candidates"] as? [[String: Any]])?.first?["finishReason"] as? String
            throw GeminiError.blocked(reason: blockReason ?? finishReason ?? "no candidates")
        }
        content["role"] = "model"

        var calls: [GeminiFunctionCall] = []
        var text = ""
        for part in content["parts"] as? [[String: Any]] ?? [] {
            if let call = part["functionCall"] as? [String: Any], let name = call["name"] as? String {
                let args = call["args"] ?? [String: Any]()
                calls.append(GeminiFunctionCall(
                    name: name,
                    id: call["id"] as? String,
                    argsJSON: try JSONSerialization.data(withJSONObject: args)
                ))
            } else if let fragment = part["text"] as? String, (part["thought"] as? Bool) != true {
                text += fragment
            }
        }
        if calls.isEmpty, text.isEmpty, let finish = candidate["finishReason"] as? String, finish != "STOP" {
            throw GeminiError.blocked(reason: finish)
        }
        return GeminiResponse(
            modelTurn: GeminiTurn(json: try JSONSerialization.data(withJSONObject: content)),
            functionCalls: calls,
            text: text.isEmpty ? nil : text
        )
    }

    /// The declarations file as a JSON array, in its own order, without the opt-in functions `including` doesn't name.
    static func declarations(_ json: Data, including: Set<String>) throws -> Any {
        let all = try JSONSerialization.jsonObject(with: json)
        guard let list = all as? [[String: Any]] else { return all }
        return list.filter { declaration in
            guard let name = declaration["name"] as? String, optInFunctions.contains(name) else { return true }
            return including.contains(name)
        }
    }

    private static func loadDeclarations() -> Data {
        let bundles = [Bundle.main, Bundle(for: GeminiClient.self)]
        for bundle in bundles {
            if let url = bundle.url(forResource: "FunctionDeclarations", withExtension: "json"),
               let data = try? Data(contentsOf: url) { return data }
        }
        assertionFailure("FunctionDeclarations.json missing from target resources")
        return Data("[]".utf8)
    }
}
