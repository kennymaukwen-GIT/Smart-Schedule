import AVFoundation
import Observation
import Speech

/// The mic button's recorder (`ComposerBar`, in the chat and Quick Capture): push to talk, recognised on this iPhone
/// only. Brought back 2026-10-18 after 0d70137 removed the earlier SpeechTranscriber, now without Apple's servers.
///
/// - The recognizer is for Settings › Assistant › Speech language (`VoiceInput.localeIdentifier`: zh-TW or en-US, the
///   app's language when Automatic). The button shows only while it exists, `isAvailable` and
///   `supportsOnDeviceRecognition`; otherwise it is hidden and the keyboard's dictation is still there. Its delegate
///   (`AvailabilityRelay`) updates that while the button is on screen, e.g. when the on-device model finishes
///   downloading.
/// - Every request sets `requiresOnDeviceRecognition = true` (scripts/validate_schema.py check 9 fails otherwise).
///   Audio buffers go from the microphone straight to the recognizer: nothing is written to disk or sent anywhere.
/// - The words fill the text field as they come (`fieldText`); nothing is sent until Send.
/// - Stops on a second tap, on Send, when the composer goes away, is covered (`ComposerBar.isCovered`) or its field is
///   cleared, when the app leaves the foreground, after a silence and at `VoiceInput.maxDuration`.
/// - iOS asks for speech recognition and the microphone on the first tap only; after a refusal a tap explains which
///   switch to turn on and opens Settings (`problem`).
///
/// Named VoiceTranscriber, not SpeechTranscriber: iOS 26's Speech framework has a type of that name.
@MainActor
@Observable
final class VoiceTranscriber {
    /// What the text field should show: what was typed before the mic was tapped, then the words heard so far. nil
    /// until this recording hears something.
    private(set) var fieldText: String?
    private(set) var isRecording = false
    /// Whether the mic button shows: the recognizer for the chosen language works on this iPhone right now.
    private(set) var isAvailable = false
    /// Why a tap couldn't start recording (a permission refused or restricted), shown as an alert.
    var problem: VoiceInput.Access?

    @ObservationIgnored private var recognizer: SFSpeechRecognizer?
    @ObservationIgnored private var recognizerLocaleID: String?
    /// The recognizer's delegate, kept here because `SFSpeechRecognizer.delegate` is weak.
    @ObservationIgnored private var availabilityRelay: AvailabilityRelay?
    /// Made on the first recording: SwiftUI builds a transcriber each time a composer's parent redraws and keeps only
    /// the first, so creating one must stay cheap.
    @ObservationIgnored private var audioEngine: AVAudioEngine?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var typedBefore = ""
    @ObservationIgnored private var heard = ""
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var lastWordsAt: Date?
    /// Bumped by every start and cancel, so results still arriving for an earlier recording are ignored.
    @ObservationIgnored private var recording = 0
    @ObservationIgnored private var preferencesObservation: SharedChangeObservation?
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?

    /// One recording at a time across the app's mic buttons.
    private static weak var active: VoiceTranscriber?

    // MARK: Availability

    /// Re-checks whether the mic button can show: on appear, when the app comes back to the foreground and when the
    /// speech language changes (any process). In between, the recognizer's availability changes arrive through
    /// `AvailabilityRelay`.
    func refreshAvailability() {
        if preferencesObservation == nil {
            preferencesObservation = SharedChangeNotifier.observe(.preferences) { [weak self] in
                Task { @MainActor [weak self] in self?.refreshAvailability() }
            }
        }
        let identifier = VoiceInput.localeIdentifier(for: PreferencesStore.shared.current())
        if identifier != recognizerLocaleID {
            cancel()
            let relay = availabilityRelay ?? AvailabilityRelay(owner: self)
            availabilityRelay = relay
            recognizer = SFSpeechRecognizer(locale: Locale(identifier: identifier))
            recognizer?.delegate = relay
            recognizerLocaleID = identifier
        }
        isAvailable = Self.worksOnDevice(recognizer)
    }

    /// The recognizer became available or unavailable (`AvailabilityRelay`): the button follows while it is on screen.
    fileprivate func recognizerAvailabilityChanged() {
        isAvailable = Self.worksOnDevice(recognizer)
    }

    /// Whether this iPhone recognises `localeIdentifier` on the device right now (Settings › Assistant's status line).
    static func supportsOnDevice(localeIdentifier: String) -> Bool {
        worksOnDevice(SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)))
    }

    private static func worksOnDevice(_ recognizer: SFSpeechRecognizer?) -> Bool {
        guard let recognizer else { return false }
        return recognizer.isAvailable && recognizer.supportsOnDeviceRecognition
    }

    // MARK: Recording

    /// The mic button. `typed`: the field's text now; the words heard are added after it.
    func toggle(typed: String) async {
        if isRecording {
            stop()
        } else {
            await start(typed: typed, asking: true)
        }
    }

    /// `smartschedule://compose?mode=voice`: starts only when nothing has to be asked first (both permissions given,
    /// the language recognised on this iPhone). False when it did not start.
    func startIfAllowed(typed: String) async -> Bool {
        await start(typed: typed, asking: false)
        return isRecording
    }

    private func start(typed: String, asking: Bool) async {
        guard !isRecording else { return }
        refreshAvailability()
        guard isAvailable else { return }
        switch Self.access {
        case .ready:
            break
        case .ask:
            guard asking else { return }
            await Self.requestPermissions()
            // Refused just now: iOS's own prompt was the answer, so no alert on top of it.
            guard Self.access == .ready else { return }
        case let refused:
            if asking { problem = refused }
            return
        }
        refreshAvailability()
        guard !isRecording, isAvailable, let recognizer else { return }
        Self.active?.cancel()
        task?.cancel() // an earlier recording's last words, if still on their way

        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        // On this iPhone only, never Apple's servers.
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true

        let engine = audioEngine ?? AVAudioEngine()
        audioEngine = engine
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            deactivateAudioSession()
            return
        }
        Self.feed(request, from: input, format: format)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            deactivateAudioSession()
            return
        }

        recording += 1
        let current = recording
        self.request = request
        typedBefore = typed
        heard = ""
        fieldText = nil
        startedAt = Date()
        lastWordsAt = nil
        isRecording = true
        Self.active = self
        task = Self.recognize(request, with: recognizer) { [weak self] text, ended in
            Task { @MainActor [weak self] in
                self?.receive(text, ended: ended, recording: current)
            }
        }
        watch(recording: current)
        observeInterruptions()
    }

    /// Ends the recording; the last words still arrive and fill the field. A second tap, a silence, the time limit,
    /// the app leaving the foreground, the composer being covered.
    func stop() {
        guard isRecording else { return }
        stopAudio()
        request?.endAudio()
        task?.finish()
    }

    /// Ends the recording and ignores whatever is still on its way: Send, the field cleared from anywhere, and the
    /// composer going away.
    func cancel() {
        recording += 1
        if isRecording { stopAudio() }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }

    private func receive(_ text: String?, ended: Bool, recording: Int) {
        guard recording == self.recording else { return }
        if let text, !text.isEmpty, text != heard {
            heard = text
            lastWordsAt = Date()
            fieldText = VoiceInput.combined(typed: typedBefore, spoken: text)
        }
        if ended {
            if isRecording { stopAudio() }
            request = nil
            task = nil
        }
    }

    private func stopAudio() {
        watchdog?.cancel()
        watchdog = nil
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        interruptionObserver = nil
        if let audioEngine {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        isRecording = false
        if Self.active === self { Self.active = nil }
        deactivateAudioSession()
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Microphone buffers straight into the request, in memory. Not main-actor isolated: the tap runs on the audio
    /// thread.
    nonisolated private static func feed(_ request: SFSpeechAudioBufferRecognitionRequest,
                                         from input: AVAudioInputNode, format: AVAudioFormat) {
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
    }

    /// The words so far (partial results) and whether the recognition ended (final result or error). Not main-actor
    /// isolated either: the recognizer calls back on its own queue.
    nonisolated private static func recognize(_ request: SFSpeechAudioBufferRecognitionRequest,
                                              with recognizer: SFSpeechRecognizer,
                                              deliver: @escaping @Sendable (String?, Bool) -> Void) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            deliver(result?.bestTranscription.formattedString, (result?.isFinal ?? false) || error != nil)
        }
    }

    /// Silence and the time limit (`VoiceInput.stopReason`), checked twice a second.
    private func watch(recording current: Int) {
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.recording == current, self.isRecording else { return }
                let now = Date()
                let reason = VoiceInput.stopReason(elapsed: now.timeIntervalSince(self.startedAt),
                                                   sinceLastWords: self.lastWordsAt.map { now.timeIntervalSince($0) })
                if reason != nil {
                    self.stop()
                    return
                }
            }
        }
    }

    /// A call or Siri takes the audio session: stop, keeping what was heard.
    private func observeInterruptions() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.stop() }
        }
    }

    // MARK: Permissions

    private static var access: VoiceInput.Access {
        VoiceInput.access(microphone: microphonePermission, speechRecognition: speechRecognitionPermission)
    }

    private static var microphonePermission: VoiceInput.Permission {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: .granted
        case .denied: .denied
        default: .notDetermined
        }
    }

    private static var speechRecognitionPermission: VoiceInput.Permission {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: .granted
        case .denied: .denied
        case .restricted: .restricted
        default: .notDetermined
        }
    }

    /// iOS's prompts, speech recognition first, each only if it was never asked.
    private static func requestPermissions() async {
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
            }
        }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { return }
        if AVAudioApplication.shared.recordPermission == .undetermined {
            _ = await AVAudioApplication.requestRecordPermission()
        }
    }
}

/// `SFSpeechRecognizer.delegate` must be an NSObject and is weak, so `VoiceTranscriber` keeps this one. The recognizer
/// calls it on its `queue` (the main queue unless changed) when it becomes available or unavailable: the language's
/// on-device model finished downloading, the speech service came back or went away. As in Apple's SpokenWord sample.
private final class AvailabilityRelay: NSObject, SFSpeechRecognizerDelegate {
    private weak var owner: VoiceTranscriber?

    init(owner: VoiceTranscriber) {
        self.owner = owner
    }

    func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        Task { @MainActor [weak owner = self.owner] in owner?.recognizerAvailabilityChanged() }
    }
}
