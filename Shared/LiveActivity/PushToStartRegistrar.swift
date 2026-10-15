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
/// Uploads and "Erase all data" run one at a time, in the order asked for (`serialized`).
enum PushToStartRegistrar {
    /// The 48-hour window rarely holds more; a cap keeps the upload small.
    static let maxEvents = 50
    /// The server retries a push that failed for 2 minutes after `triggerAt` (its cron looks back that far); with
    /// clock slack, an event due this recently that is not showing stays registered so the retry still finds it.
    static let retryWindow: TimeInterval = 180
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
        /// Random, made with the first registration file; not tied to the person or the hardware. The file is
        /// excluded from backups, so a backup restored to another iPhone starts over with a new ID (`sync`).
        var deviceID: String
        /// The push-to-start token, hex. nil until iOS hands one out (it needs the push entitlement).
        var token: String?
        var events: [Event]
    }

    static var defaultFileURL: URL {
        (FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppConstants.appGroupID)
            ?? FileManager.default.temporaryDirectory).appendingPathComponent("push-to-start.json")
    }

    /// Where older builds kept the ID; the registration file holds it now.
    private static let legacyDeviceIDKey = "pushToStart.deviceID"
    /// The last upload failed (or was never made): try again on the next sync even if nothing changed.
    static let uploadPendingKey = "pushToStart.uploadPending"
    /// The server holds event titles from this iPhone: an upload without consent clears them.
    static let serverHasEventsKey = "pushToStart.serverHasEvents"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var uploader: (@Sendable (Registration) async -> Bool)?
    /// The upload or erase asked for last; the next one waits for it.
    nonisolated(unsafe) private static var tail: Task<Void, Never>?

    /// The app installs the network upload at launch; it returns whether the server accepted the registration.
    static func install(upload: @escaping @Sendable (Registration) async -> Bool) {
        lock.withLock { uploader = upload }
    }

    /// Sends the registration whenever the server's copy may differ from what it should hold: it changed, the last
    /// upload failed, consent was just given (the server has none of it) or withdrawn (the server still has titles).
    /// With consent, a push token and events it goes as it is; otherwise with no events and no token, and only to clear
    /// what the server holds.
    static func uploadIfNeeded(changed: Bool,
                               consented: Bool,
                               upload: (@Sendable (Registration) async -> Bool)? = nil,
                               fileURL: URL = PushToStartRegistrar.defaultFileURL,
                               defaults: UserDefaults? = UserDefaults(suiteName: AppConstants.appGroupID)) async {
        // Cancellable: a background refresh that runs out of time stops the upload (it stays pending).
        await serialized(cancellable: true) {
            await uploadNow(changed: changed, consented: consented, upload: upload, fileURL: fileURL, defaults: defaults)
        }
    }

    private static func uploadNow(changed: Bool,
                                  consented: Bool,
                                  upload: (@Sendable (Registration) async -> Bool)?,
                                  fileURL: URL,
                                  defaults: UserDefaults?) async {
        guard let upload = upload ?? lock.withLock({ uploader }),
              var registration = pending(fileURL: fileURL) else { return }
        // Without consent the server keeps nothing from this iPhone: no events, and no push token either. The token only
        // goes up with events, so once the server holds none it holds no token either and nothing is left to clear.
        if !consented || registration.token == nil || registration.events.isEmpty {
            registration.events = []
            registration.token = nil
        }
        let serverHasEvents = defaults?.bool(forKey: serverHasEventsKey) == true
        let needed = registration.events.isEmpty
            ? serverHasEvents
            : changed || defaults?.bool(forKey: uploadPendingKey) == true || !serverHasEvents
        guard needed else {
            defaults?.set(false, forKey: uploadPendingKey)
            return
        }
        // Set first: the server may store the events even when its answer is lost, and a process ended during the
        // upload (suspended, then terminated) sends it again next time although the file no longer changes.
        if !registration.events.isEmpty { defaults?.set(true, forKey: serverHasEventsKey) }
        defaults?.set(true, forKey: uploadPendingKey)
        if Task.isCancelled { return }
        let accepted = await upload(registration)
        defaults?.set(!accepted, forKey: uploadPendingKey)
        if accepted, registration.events.isEmpty { defaults?.set(false, forKey: serverHasEventsKey) }
    }

    /// "Erase all data": the server forgets this iPhone's events, then the registration and its ID go. When the
    /// server cannot be reached, an empty registration under the same ID stays behind and the next run clears it.
    /// Waits for an upload already under way, so that one cannot store titles again after the clear.
    static func eraseAll(upload: (@Sendable (Registration) async -> Bool)? = nil,
                         fileURL: URL = PushToStartRegistrar.defaultFileURL,
                         defaults: UserDefaults? = UserDefaults(suiteName: AppConstants.appGroupID)) async {
        await serialized {
            await uploadNow(changed: true, consented: false, upload: upload, fileURL: fileURL, defaults: defaults)
            if defaults?.bool(forKey: serverHasEventsKey) == true, var registration = pending(fileURL: fileURL) {
                registration.token = nil
                registration.events = []
                write(registration, to: fileURL)
                return
            }
            try? FileManager.default.removeItem(at: fileURL)
            for key in [legacyDeviceIDKey, uploadPendingKey, serverHasEventsKey] { defaults?.removeObject(forKey: key) }
        }
    }

    /// Runs `work` after every upload or erase asked for before it has finished. `cancellable`: cancelling the
    /// caller cancels `work` too (it still runs after the earlier ones, then finds itself cancelled); an erase is
    /// never cancelled.
    private static func serialized(cancellable: Bool = false, _ work: @escaping @Sendable () async -> Void) async {
        let task: Task<Void, Never> = lock.withLock {
            let previous = tail
            let next = Task {
                if let previous { await previous.value }
                await work()
            }
            tail = next
            return next
        }
        if cancellable {
            await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        } else {
            await task.value
        }
    }

    static func event(for item: ActivityPlanner.Item,
                      attributes: ScheduleActivityAttributes,
                      state: ScheduleActivityAttributes.ContentState) throws -> Event {
        var state = state
        state.lastAssistantLine = nil // the assistant's reply never goes to the server
        state.headline = capped(state.headline)
        // Default date and data strategies: ActivityKit decodes pushes with its defaults. Sorted keys: the same
        // content always gives the same text, so an unchanged calendar is not "changed" and uploaded again.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return Event(eventID: item.eventID,
                     title: capped(item.event.title),
                     eventStart: item.event.start,
                     leadTime: item.leadMinutes,
                     triggerAt: item.triggerAt,
                     attributesJSON: String(decoding: try encoder.encode(attributes), as: UTF8.self),
                     contentStateJSON: String(decoding: try encoder.encode(state), as: UTF8.self))
    }

    /// Replaces the registration with `upcomingEvents` (whole, never merged). Returns whether it changed.
    ///
    /// `token` nil keeps the one already registered: a new process reads iOS's token only once its update stream
    /// delivers, and "no token" would otherwise clear the server's events until then. With no registration file,
    /// the upload flags are dropped and a new ID is made: either nothing was registered yet, or a backup was
    /// restored to another iPhone (the file is excluded from backups, the flags are not) and the old ID belongs to
    /// the other phone, whose registration is left alone.
    @discardableResult
    static func sync(token: Data?,
                     upcomingEvents: [Event],
                     fileURL: URL = PushToStartRegistrar.defaultFileURL,
                     defaults: UserDefaults? = UserDefaults(suiteName: AppConstants.appGroupID)) async -> Bool {
        let previous = pending(fileURL: fileURL)
        if previous == nil {
            for key in [legacyDeviceIDKey, uploadPendingKey, serverHasEventsKey] { defaults?.removeObject(forKey: key) }
        }
        let registration = Registration(deviceID: previous?.deviceID ?? UUID().uuidString,
                                        token: token.map { $0.map { String(format: "%02x", $0) }.joined() } ?? previous?.token,
                                        events: Array(upcomingEvents.prefix(maxEvents)))
        if previous == registration { return false }
        return write(registration, to: fileURL)
    }

    @discardableResult
    private static func write(_ registration: Registration, to fileURL: URL) -> Bool {
        guard let data = try? encoder.encode(registration),
              (try? data.write(to: fileURL, options: .atomic)) != nil else { return false }
        // Never restored onto another iPhone (see `sync`). An atomic write makes a new file: set it every time.
        var url = fileURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
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
}
