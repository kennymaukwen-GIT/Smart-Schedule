import AVFoundation
import Observation
import Speech

/// Push-to-talk dictation for the mic buttons, in Settings › Assistant › "Speech language" (the device language
/// when automatic). With "On-device recognition" on and a language this iPhone supports, no audio leaves the
/// phone and dictation works offline.
@MainActor
@Observable
final class SpeechTranscriber {
    var transcript = ""
    var isRecording = false

    /// Built per recording, so a language picked in Settings applies to the next one.
    @ObservationIgnored private var recognizer: SFSpeechRecognizer?
    @ObservationIgnored private let audioEngine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?

    func toggle() async {
        if isRecording { stop() } else { await start() }
    }

    func start() async {
        guard !isRecording, await Self.authorize() else { return }
        let preferences = PreferencesStore.shared.current()
        let locale = preferences.speechLanguage.localeIdentifier.map(Locale.init(identifier:)) ?? Locale.current
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else { return }
        self.recognizer = recognizer
        transcript = ""

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch { return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = preferences.speechOnDevice && recognizer.supportsOnDeviceRecognition
        request.addsPunctuation = true
        self.request = request

        let input = audioEngine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
        }
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.request = nil
            return
        }
        isRecording = true

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            Task { @MainActor in
                guard let self else { return }
                if let text { self.transcript = text }
                if isFinal || error != nil { self.stop() }
            }
        }
    }

    func stop() {
        guard isRecording || audioEngine.isRunning else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        request = nil
        task = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func authorize() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }
}
