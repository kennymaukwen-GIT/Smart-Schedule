import Foundation

/// iOS 18: the events a server should start a Live Activity for with an ActivityKit push-to-start notification.
///
/// iOS 18 cannot schedule an activity, and an app in the background cannot start one, so a server sends the push at
/// each event's `triggerAt`. Every sync replaces the whole registration, so a deleted or moved event is never
/// started. Only what the push needs is kept: the token, and per event its ID, title, start, lead time, trigger time
/// and the attributes and content already encoded — never notes or places.
///
/// The registration waits in the App Group (`push-to-start.json`) and goes to Smart Schedule's server through the
/// uploader the app installs (`install(upload:)`; code here is also built into the widget extension, which has no
/// network client). Event titles leave the iPhone only with AI consent, whose disclosure names this server storage.
enum PushToStartRegistrar {
    /// The 48-hour window rarely holds more; a cap keeps the upload small.
    static let maxEvents = 50
    /// The server's limit for a title, in Unicode scalars (what JavaScript's `Array.from` counts).
    static let maxTitleScalars = 200
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
    /// The last upload failed (or was never made): try again on the next sync even if nothing changed.
    static let uploadPendingKey = "pushToStart.uploadPending"
    /// The server holds event titles from this iPhone: an upload without consent clears them.
    static let serverHasEventsKey = "pushToStart.serverHasEvents"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var uploader: (@Sendable (Registration) async -> Bool)?

    /// The app installs the network upload at launch; it returns whether the server accepted the registration.
    static func install(upload: @escaping @Sendable (Registration) async -> Bool) {
        lock.withLock { uploader = upload }
    }

    /// Sends the registration whenever the server's copy may differ from what it should hold: it changed, the last
    /// upload failed, consent was just given (the server has none of it) or withdrawn (the server still has titles).
    /// With consent and a push token it goes as it is; otherwise with no events, and only to clear what the server
    /// holds.
    static func uploadIfNeeded(changed: Bool,
                               consented: Bool,
                               upload: (@Sendable (Registration) async -> Bool)? = nil,
                               fileURL: URL = PushToStartRegistrar.defaultFileURL,
                               defaults: UserDefaults? = UserDefaults(suiteName: AppConstants.appGroupID)) async {
        guard let upload = upload ?? lock.withLock({ uploader }),
              var registration = pending(fileURL: fileURL) else { return }
        if !consented || registration.token == nil { registration.events = [] }
        let serverHasEvents = defaults?.bool(forKey: serverHasEventsKey) == true
        let needed = registration.events.isEmpty
            ? serverHasEvents
            : changed || defaults?.bool(forKey: uploadPendingKey) == true || !serverHasEvents
        guard needed else {
            defaults?.set(false, forKey: uploadPendingKey)
            return
        }
        // Set first: the server may store the events even when its answer is lost.
        if !registration.events.isEmpty { defaults?.set(true, forKey: serverHasEventsKey) }
        let accepted = await upload(registration)
        defaults?.set(!accepted, forKey: uploadPendingKey)
        if accepted, registration.events.isEmpty { defaults?.set(false, forKey: serverHasEventsKey) }
    }

    /// "Erase all data": the server forgets this iPhone's events, then the registration and its ID go. When the
    /// server cannot be reached, an empty registration under the same ID stays behind and the next run clears it.
    static func eraseAll(upload: (@Sendable (Registration) async -> Bool)? = nil,
                         fileURL: URL = PushToStartRegistrar.defaultFileURL,
                         defaults: UserDefaults? = UserDefaults(suiteName: AppConstants.appGroupID)) async {
        await uploadIfNeeded(changed: true, consented: false, upload: upload, fileURL: fileURL, defaults: defaults)
        if defaults?.bool(forKey: serverHasEventsKey) == true, var registration = pending(fileURL: fileURL) {
            registration.token = nil
            registration.events = []
            write(registration, to: fileURL)
            return
        }
        try? FileManager.default.removeItem(at: fileURL)
        for key in [deviceIDKey, uploadPendingKey, serverHasEventsKey] { defaults?.removeObject(forKey: key) }
    }

    static func event(for item: ActivityPlanner.Item,
                      attributes: ScheduleActivityAttributes,
                      state: ScheduleActivityAttributes.ContentState) throws -> Event {
        var state = state
        state.lastAssistantLine = nil // the assistant's reply never goes to the server
        let encoder = JSONEncoder() // default strategies only: ActivityKit decodes pushes with its defaults
        state.headline = capped(state.headline)
        return Event(eventID: item.eventID,
                     title: capped(item.event.title),
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
        return write(registration, to: fileURL)
    }

    @discardableResult
    private static func write(_ registration: Registration, to fileURL: URL) -> Bool {
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

    /// A title longer than the server takes (it shows only the start of one anyway).
    static func capped(_ title: String) -> String {
        guard title.unicodeScalars.count > maxTitleScalars else { return title }
        return String(String.UnicodeScalarView(title.unicodeScalars.prefix(maxTitleScalars)))
    }

    private static func deviceID(_ defaults: UserDefaults?) -> String {
        if let id = defaults?.string(forKey: deviceIDKey) { return id }
        let id = UUID().uuidString
        defaults?.set(id, forKey: deviceIDKey)
        return id
    }
}
