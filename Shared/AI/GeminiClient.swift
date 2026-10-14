import Foundation

struct GeminiConfig: Sendable {
    var baseURL: String
    var modelID: String
    /// Dev only. In production leave empty and point `baseURL` at a proxy that injects the key
    /// and verifies App Check / DeviceCheck.
    var apiKey: String?
    /// Gemini 3.x `thinkingLevel` ("low" | "high"). Nil = model default. Do not send to 2.x models.
    var thinkingLevel: String?

    static var fromBundle: GeminiConfig {
        GeminiConfig(
            baseURL: AppConstants.info("SSGeminiBaseURL") ?? "https://generativelanguage.googleapis.com/v1beta",
            modelID: AppConstants.info("SSGeminiModelID") ?? "gemini-3.5-flash",
            apiKey: AppConstants.info("SSGeminiAPIKey"),
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

    var errorDescription: String? {
        switch self {
        case let .http(status, message): "Gemini HTTP \(status): \(message)"
        case let .blocked(reason): String(localized: "Gemini blocked the request (\(reason)).")
        case let .malformed(detail): String(localized: "Unexpected Gemini response: \(detail)")
        case .consentRequired: String(localized: "Allow AI data sharing in Settings › AI & privacy to use the assistant.")
        }
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
final class GeminiClient: Sendable {
    let config: GeminiConfig
    private let declarationsJSON: Data
    private let session: URLSession
    private let consentCheck: @Sendable () -> Bool

    /// - Parameter consentCheck: whether the user allowed AI data sharing. Unit tests inject it.
    init(config: GeminiConfig = .fromBundle,
         session: URLSession = NetworkSession.shared,
         consentCheck: @escaping @Sendable () -> Bool = { AIConsentStore.current.isGranted }) {
        self.config = config
        self.session = session
        self.consentCheck = consentCheck
        self.declarationsJSON = Self.loadDeclarations()
    }

    /// - Parameter mode: "ANY" forces a function call every turn (deterministic parsing; plain chat
    ///   goes through `reply_to_user`). "AUTO" lets the model answer in text.
    /// - Throws: `GeminiError.consentRequired` before anything is sent when AI data sharing is not allowed.
    func generate(system: String,
                  history: [GeminiTurn],
                  mode: String = "ANY",
                  allowedFunctions: [String]? = nil) async throws -> GeminiResponse {
        guard consentCheck() else { throw GeminiError.consentRequired }
        var functionCallingConfig: [String: Any] = ["mode": mode]
        if let allowedFunctions { functionCallingConfig["allowedFunctionNames"] = allowedFunctions }

        var body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": try history.map { try JSONSerialization.jsonObject(with: $0.json) },
            "tools": [["functionDeclarations": try JSONSerialization.jsonObject(with: declarationsJSON)]],
            "toolConfig": ["functionCallingConfig": functionCallingConfig]
        ]
        // Gemini 3 guidance: keep temperature at its default (1.0); lowering it can cause looping.
        if let level = config.thinkingLevel {
            body["generationConfig"] = ["thinkingConfig": ["thinkingLevel": level]]
        }

        let base = config.baseURL.hasSuffix("/") ? String(config.baseURL.dropLast()) : config.baseURL
        guard let url = URL(string: "\(base)/models/\(config.modelID):generateContent") else {
            throw GeminiError.malformed("bad base URL")
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = config.apiKey { request.setValue(key, forHTTPHeaderField: "x-goog-api-key") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await send(request)
        return try Self.parse(data)
    }

    // MARK: - Transport with bounded retry on 429 / 5xx

    private func send(_ request: URLRequest, attempt: Int = 0) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (200..<300).contains(status) { return data }
        if (status == 429 || status >= 500), attempt < 2 {
            try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt)) * 800_000_000))
            return try await send(request, attempt: attempt + 1)
        }
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
            let reason = (root["promptFeedback"] as? [String: Any])?["blockReason"] as? String
            throw GeminiError.blocked(reason: reason ?? "no candidates")
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
