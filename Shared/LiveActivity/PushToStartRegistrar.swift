import Foundation

/// iOS 18: the events a server should start a Live Activity for with an ActivityKit push-to-start notification.
///
/// iOS 18 cannot schedule an activity, and an app in the background cannot start one, so a server sends the push at
/// each event's `triggerAt`. Every sync replaces the whole registration, so a deleted or moved event is never
/// started. Only what the push needs is kept: the token, and per event its ID, title, start, lead time, trigger time
/// and the attributes and content already encoded — never notes or places.
///
/// The registration waits in the App Group (`push-to-start.json`); sending it to the server is a separate step.
enum PushToStartRegistrar {
    /// The 48-hour window rarely holds more; a cap keeps the upload small.
    static let maxEvents = 50
    static let attributesType = "ScheduleActivityAttributes"

    struct Event: Codable, Equatable, Sendable {
        var eventID: String
        var title: String
        var eventStart: Date
        /// Minutes before `eventStart` (Settings › Dynamic Island).
        var leadTime: Int
        var triggerAt: Date
        /// `ScheduleActivityAttributes` and its `ContentState` as the default `JSONEncoder` writes them: what
        /// ActivityKit decodes from the push's `attributes` and `content-state`.
        var attributesJSON: String
        var contentStateJSON: String
    }

    struct Registration: Codable, Equatable, Sendable {
        /// Random, made once per install; not tied to the person or the hardware.
        var deviceID: String
        /// The push-to-start token, hex. nil until iOS hands one out (it needs the push entitlement).
        var token: String?
        var events: [Event]
    }

    static var defaultFileURL: URL {
        (FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppConstants.appGroupID)
            ?? FileManager.default.temporaryDirectory).appendingPathComponent("push-to-start.json")
    }

    private static let deviceIDKey = "pushToStart.deviceID"

    static func event(for item: ActivityPlanner.Item,
                      attributes: ScheduleActivityAttributes,
                      state: ScheduleActivityAttributes.ContentState) throws -> Event {
        let encoder = JSONEncoder() // default strategies only: ActivityKit decodes pushes with its defaults
        return Event(eventID: item.eventID,
                     title: item.event.title,
                     eventStart: item.event.start,
                     leadTime: item.leadMinutes,
                     triggerAt: item.triggerAt,
                     attributesJSON: String(decoding: try encoder.encode(attributes), as: UTF8.self),
                     contentStateJSON: String(decoding: try encoder.encode(state), as: UTF8.self))
    }

    /// Replaces the registration with `upcomingEvents` (whole, never merged). Returns whether it changed.
    @discardableResult
    static func sync(token: Data?,
                     upcomingEvents: [Event],
                     fileURL: URL = PushToStartRegistrar.defaultFileURL,
                     defaults: UserDefaults? = UserDefaults(suiteName: AppConstants.appGroupID)) async -> Bool {
        let registration = Registration(deviceID: deviceID(defaults),
                                        token: token.map { $0.map { String(format: "%02x", $0) }.joined() },
                                        events: Array(upcomingEvents.prefix(maxEvents)))
        if pending(fileURL: fileURL) == registration { return false }
        guard let data = try? encoder.encode(registration) else { return false }
        try? data.write(to: fileURL, options: .atomic)
        return true
    }

    /// The registration as last synced.
    static func pending(fileURL: URL = PushToStartRegistrar.defaultFileURL) -> Registration? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? decoder.decode(Registration.self, from: data)
    }

    /// The registration's own dates are ISO 8601 for the server; the embedded JSON keeps ActivityKit's defaults.
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func deviceID(_ defaults: UserDefaults?) -> String {
        if let id = defaults?.string(forKey: deviceIDKey) { return id }
        let id = UUID().uuidString
        defaults?.set(id, forKey: deviceIDKey)
        return id
    }
}
