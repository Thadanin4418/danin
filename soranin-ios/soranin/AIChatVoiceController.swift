import AVFoundation
import AVFAudio
import OSLog
import Speech
import SwiftUI

enum AIChatSpeechPlaybackSpeed: String, CaseIterable, Identifiable {
    case slow
    case fast

    var id: String { rawValue }

    func openAISpeedValue(isKhmer: Bool) -> String {
        switch self {
        case .slow:
            return isKhmer ? "0.94" : "0.96"
        case .fast:
            return isKhmer ? "1.12" : "1.08"
        }
    }

    var builtInRateMultiplier: Float {
        switch self {
        case .slow:
            return 0.96
        case .fast:
            return 1.12
        }
    }

    var builtInPitchMultiplier: Float {
        switch self {
        case .slow:
            return 1.02
        case .fast:
            return 1.06
        }
    }
}

@MainActor
final class AIChatVoiceController: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    private static let speechOutputDefaultsKey = "com.nin.soranin.aiChatSpeechOutputEnabled"

    @Published private(set) var isRecording = false
    @Published private(set) var isSpeaking = false
    @Published private(set) var speakingMessageID: UUID?
    @Published private(set) var isTranscribing = false
    @Published private(set) var recognizedText = ""
    @Published private(set) var voiceErrorText = ""
    @Published var isSpeechOutputEnabled = false

    private let audioEngine = AVAudioEngine()
    private let synthesizer = AVSpeechSynthesizer()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.nin.soranin", category: "AIChatVoice")
    private let debugLogDateFormatter = ISO8601DateFormatter()
    private var audioRecorder: AVAudioRecorder?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var speechRecognizer: SFSpeechRecognizer?
    private var audioPlayer: AVAudioPlayer?
    private var speechOutputTask: Task<Void, Never>?
    private var currentRecordingURL: URL?
    private var hasInstalledInputTap = false
    private var prefersKhmer = false
    private var inputMode: VoiceInputMode = .none

    private enum VoiceInputMode {
        case none
        case builtInSpeech
        case openAIRecorder
    }

    override init() {
        if let storedValue = UserDefaults.standard.object(forKey: Self.speechOutputDefaultsKey) as? Bool {
            isSpeechOutputEnabled = storedValue
        } else {
            isSpeechOutputEnabled = true
            UserDefaults.standard.set(true, forKey: Self.speechOutputDefaultsKey)
        }
        super.init()
        synthesizer.delegate = self
    }

    private func debug(_ message: String) {
        print(message)

        guard let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return
        }

        let logURL = cachesDirectory.appendingPathComponent("voice-debug.log")
        let line = "[\(debugLogDateFormatter.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: logURL.path) {
            if let handle = try? FileHandle(forWritingTo: logURL) {
                defer { try? handle.close() }
                do {
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } catch {
                    logger.error("Could not append voice debug log: \(error.localizedDescription, privacy: .public)")
                }
            }
        } else {
            do {
                try data.write(to: logURL, options: .atomic)
            } catch {
                logger.error("Could not create voice debug log: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func clearVoiceError() {
        voiceErrorText = ""
    }

    func setSpeechOutputEnabled(_ enabled: Bool) {
        isSpeechOutputEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.speechOutputDefaultsKey)
        if !enabled {
            stopSpeaking()
        }
    }

    func startRecording(isKhmer: Bool) async -> Bool {
        prefersKhmer = isKhmer
        clearVoiceError()
        stopSpeaking()
        logger.info("Starting voice recording. Khmer mode: \(isKhmer, privacy: .public)")
        debug("VOICE DEBUG startRecording begin isKhmer=\(isKhmer)")

        let microphoneGranted = await Self.microphonePermissionGranted()
        debug("VOICE DEBUG microphone granted=\(microphoneGranted)")
        guard microphoneGranted else {
            logger.error("Microphone permission not granted")
            voiceErrorText = text(
                "Allow Microphone access in Settings to use voice input.",
                "សូមអនុញ្ញាត Microphone ក្នុង Settings ដើម្បីប្រើ voice input។"
            )
            debug("VOICE DEBUG microphone denied")
            return false
        }

        let hasOpenAIKey = OpenAIAPIKeyStore.load()?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        guard hasOpenAIKey else {
            logger.error("OpenAI API key missing for voice input")
            voiceErrorText = text(
                "Add your OpenAI API key first to use voice input.",
                "សូមបញ្ចូល OpenAI API key ជាមុនសិន ដើម្បីប្រើ voice input។"
            )
            debug("VOICE DEBUG openai key missing for voice input")
            return false
        }

        return startOpenAIRecording()
    }

    private func startBuiltInRecording(isKhmer: Bool) -> Bool {
        guard let recognizer = makeSpeechRecognizer(isKhmer: isKhmer), recognizer.isAvailable else {
            logger.error("Speech recognizer unavailable for current locale")
            voiceErrorText = text(
                "Voice recognition is not available right now.",
                "Voice recognition មិនអាចប្រើបានទេនៅពេលនេះ។"
            )
            debug("VOICE DEBUG recognizer unavailable")
            return false
        }

        debug("VOICE DEBUG recognizer locale=\(recognizer.locale.identifier) available=\(recognizer.isAvailable)")

        stopRecording(resetTranscript: true)
        inputMode = .builtInSpeech
        speechRecognizer = recognizer
        recognizedText = ""

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP]
            )
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.taskHint = .dictation
            recognitionRequest = request

            let inputNode = audioEngine.inputNode
            if hasInstalledInputTap {
                inputNode.removeTap(onBus: 0)
                hasInstalledInputTap = false
            }
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            debug("VOICE DEBUG recording format sampleRate=\(recordingFormat.sampleRate) channels=\(recordingFormat.channelCount)")
            guard recordingFormat.channelCount > 0, recordingFormat.sampleRate > 0 else {
                logger.error("Invalid recording format. Channels: \(recordingFormat.channelCount, privacy: .public), sample rate: \(recordingFormat.sampleRate, privacy: .public)")
                voiceErrorText = text(
                    "Microphone input is not ready. Please try again.",
                    "មីក្រូហ្វូនមិនទាន់រួចរាល់ទេ។ សូមសាកម្ដងទៀត។"
                )
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
                debug("VOICE DEBUG invalid recording format")
                return false
            }
            Self.installRecognitionTap(
                on: inputNode,
                format: recordingFormat,
                request: request
            )
            hasInstalledInputTap = true

            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true
            logger.info("Voice recording started successfully")
            debug("VOICE DEBUG audio engine started")

            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                guard let self else { return }
                Task { @MainActor in
                    if let result {
                        let transcript = result.bestTranscription.formattedString
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if self.recognizedText != transcript {
                            self.recognizedText = transcript
                        }
                        self.debug("VOICE DEBUG transcript partial=\(transcript)")
                        if result.isFinal, self.isRecording {
                            self.debug("VOICE DEBUG transcript final stopping")
                            _ = self.stopRecording()
                        }
                    }

                    if let error, self.isRecording {
                        self.logger.error("Speech recognition failed: \(error.localizedDescription, privacy: .public)")
                        self.voiceErrorText = self.localizedRecognitionError(error)
                        self.debug("VOICE DEBUG recognition error=\(error.localizedDescription)")
                        _ = self.stopRecording()
                    }
                }
            }

            return true
        } catch {
            logger.error("Could not start voice input: \(error.localizedDescription, privacy: .public)")
            voiceErrorText = text(
                "Could not start voice input. Please try again.",
                "មិនអាចចាប់ផ្តើម voice input បានទេ។ សូមសាកម្ដងទៀត។"
            )
            debug("VOICE DEBUG start failed error=\(error.localizedDescription)")
            stopRecording(resetTranscript: false)
            return false
        }
    }

    private func startOpenAIRecording() -> Bool {
        stopRecording(resetTranscript: true)
        recognizedText = ""
        isTranscribing = false
        inputMode = .openAIRecorder

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP]
            )
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let recordingURL = Self.makeTemporaryRecordingURL()
            try? FileManager.default.removeItem(at: recordingURL)

            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]

            let recorder = try AVAudioRecorder(url: recordingURL, settings: settings)
            recorder.isMeteringEnabled = false
            guard recorder.prepareToRecord(), recorder.record() else {
                voiceErrorText = text(
                    "Could not start voice input. Please try again.",
                    "មិនអាចចាប់ផ្តើម voice input បានទេ។ សូមសាកម្ដងទៀត។"
                )
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
                inputMode = .none
                return false
            }

            audioRecorder = recorder
            currentRecordingURL = recordingURL
            isRecording = true
            debug("VOICE DEBUG openai recorder started path=\(recordingURL.lastPathComponent)")
            return true
        } catch {
            logger.error("Could not start OpenAI voice recording: \(error.localizedDescription, privacy: .public)")
            voiceErrorText = text(
                "Could not start voice input. Please try again.",
                "មិនអាចចាប់ផ្តើម voice input បានទេ។ សូមសាកម្ដងទៀត។"
            )
            debug("VOICE DEBUG openai recorder failed error=\(error.localizedDescription)")
            stopRecording(resetTranscript: false)
            return false
        }
    }

    func finishRecording(resetTranscript: Bool = false) async -> String {
        switch inputMode {
        case .openAIRecorder:
            return await finishOpenAIRecording(resetTranscript: resetTranscript)
        case .builtInSpeech, .none:
            return stopRecording(resetTranscript: resetTranscript)
        }
    }

    @discardableResult
    func stopRecording(resetTranscript: Bool = false) -> String {
        debug("VOICE DEBUG stopRecording resetTranscript=\(resetTranscript)")
        if let recorder = audioRecorder {
            if recorder.isRecording {
                recorder.stop()
            }
            audioRecorder = nil
        }
        currentRecordingURL = nil
        isTranscribing = false
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if hasInstalledInputTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInstalledInputTap = false
        }
        audioEngine.reset()
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        inputMode = .none
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        let finalText = recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if resetTranscript {
            recognizedText = ""
        }
        return finalText
    }

    private func finishOpenAIRecording(resetTranscript: Bool) async -> String {
        debug("VOICE DEBUG finishOpenAIRecording resetTranscript=\(resetTranscript)")

        if let recorder = audioRecorder, recorder.isRecording {
            recorder.stop()
        }
        audioRecorder = nil

        guard let recordingURL = currentRecordingURL else {
            inputMode = .none
            isRecording = false
            if resetTranscript {
                recognizedText = ""
            }
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            return recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        currentRecordingURL = nil
        isTranscribing = true
        debug("VOICE DEBUG openai transcription started path=\(recordingURL.lastPathComponent)")

        defer {
            try? FileManager.default.removeItem(at: recordingURL)
            isTranscribing = false
            inputMode = .none
            isRecording = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }

        do {
            guard let apiKey = OpenAIAPIKeyStore.load()?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !apiKey.isEmpty else {
                throw NSError(domain: "AIChatVoiceController", code: -2, userInfo: [
                    NSLocalizedDescriptionKey: "Missing OpenAI API key."
                ])
            }

            let transcript = try await fetchOpenAITranscription(
                from: recordingURL,
                apiKey: apiKey,
                isKhmer: prefersKhmer
            )
            recognizedText = transcript
            voiceErrorText = ""
            debug("VOICE DEBUG openai transcription text=\(transcript)")
        } catch {
            logger.error("OpenAI transcription failed: \(error.localizedDescription, privacy: .public)")
            voiceErrorText = text(
                "Could not turn your voice into text. Please try again.",
                "មិនអាចបម្លែងសំឡេងទៅអក្សរបានទេ។ សូមសាកម្ដងទៀត។"
            )
            debug("VOICE DEBUG openai transcription failed error=\(error.localizedDescription)")
        }

        let finalText = recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if resetTranscript {
            recognizedText = ""
        }
        return finalText
    }

    func speak(
        _ textToSpeak: String,
        isKhmer: Bool,
        messageID: UUID? = nil,
        obeyEnabledToggle: Bool = true,
        playbackSpeed: AIChatSpeechPlaybackSpeed = .fast
    ) {
        prefersKhmer = isKhmer
        guard !obeyEnabledToggle || isSpeechOutputEnabled else { return }

        let trimmed = normalizedSpeechText(from: textToSpeak, isKhmer: isKhmer)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        clearVoiceError()
        if isRecording {
            _ = stopRecording()
        }
        stopSpeaking()
        speakingMessageID = messageID

        if let apiKey = OpenAIAPIKeyStore.load()?.trimmingCharacters(in: .whitespacesAndNewlines),
           !apiKey.isEmpty {
            isSpeaking = true
            speechOutputTask = Task { [weak self] in
                guard let self else { return }
                let didStartPlayback = await self.playOpenAISpeech(
                    text: trimmed,
                    apiKey: apiKey,
                    isKhmer: isKhmer,
                    playbackSpeed: playbackSpeed
                )
                if !didStartPlayback, !Task.isCancelled {
                    self.playBuiltInSpeech(trimmed, isKhmer: isKhmer, playbackSpeed: playbackSpeed)
                }
            }
            return
        }

        playBuiltInSpeech(trimmed, isKhmer: isKhmer, playbackSpeed: playbackSpeed)
    }

    private func playBuiltInSpeech(
        _ textToSpeak: String,
        isKhmer: Bool,
        playbackSpeed: AIChatSpeechPlaybackSpeed
    ) {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            voiceErrorText = text(
                "Could not play the AI voice reply.",
                "មិនអាចបញ្ចេញសំឡេងឆ្លើយតបរបស់ AI បានទេ។"
            )
            return
        }

        let normalizedText = normalizedSpeechText(from: textToSpeak, isKhmer: isKhmer)
        let utterance = AVSpeechUtterance(string: normalizedText)
        utterance.voice = preferredSpeechVoice(for: normalizedText, isKhmer: isKhmer)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * playbackSpeed.builtInRateMultiplier
        utterance.pitchMultiplier = playbackSpeed.builtInPitchMultiplier
        utterance.volume = 1.0
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0
        synthesizer.speak(utterance)
        isSpeaking = true
    }

    func stopSpeaking() {
        speechOutputTask?.cancel()
        speechOutputTask = nil
        audioPlayer?.stop()
        audioPlayer = nil

        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
        speakingMessageID = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func stopAll(resetTranscript: Bool = false) {
        _ = stopRecording(resetTranscript: resetTranscript)
        stopSpeaking()
        clearVoiceError()
    }

    nonisolated
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.speechOutputTask = nil
            self.isSpeaking = false
            self.speakingMessageID = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    nonisolated
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.speechOutputTask = nil
            self.isSpeaking = false
            self.speakingMessageID = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    nonisolated
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.audioPlayer = nil
            self.speechOutputTask = nil
            self.isSpeaking = false
            self.speakingMessageID = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    nonisolated
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            self.audioPlayer = nil
            self.speechOutputTask = nil
            self.isSpeaking = false
            self.speakingMessageID = nil
            if let error {
                self.logger.error("OpenAI speech decode failed: \(error.localizedDescription, privacy: .public)")
            }
            self.voiceErrorText = self.text(
                "Could not play the AI voice reply.",
                "មិនអាចបញ្ចេញសំឡេងឆ្លើយតបរបស់ AI បានទេ។"
            )
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func text(_ english: String, _ khmer: String) -> String {
        prefersKhmer ? khmer : english
    }

    private struct OpenAISpeechErrorEnvelope: Decodable {
        struct APIError: Decodable {
            let message: String?
        }

        let error: APIError?
    }

    private struct OpenAITranscriptionResponse: Decodable {
        let text: String
    }

    private func playOpenAISpeech(
        text: String,
        apiKey: String,
        isKhmer: Bool,
        playbackSpeed: AIChatSpeechPlaybackSpeed
    ) async -> Bool {
        do {
            let audioData = try await fetchOpenAISpeechData(
                text: text,
                apiKey: apiKey,
                isKhmer: isKhmer,
                playbackSpeed: playbackSpeed
            )
            guard !Task.isCancelled else { return false }

            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let player = try AVAudioPlayer(data: audioData)
            player.delegate = self
            player.prepareToPlay()
            audioPlayer = player

            guard player.play() else {
                logger.error("OpenAI speech player failed to start")
                audioPlayer = nil
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
                return false
            }

            debug("VOICE DEBUG openai speech playback started")
            return true
        } catch is CancellationError {
            return false
        } catch {
            logger.error("OpenAI speech generation failed: \(error.localizedDescription, privacy: .public)")
            debug("VOICE DEBUG openai speech failed error=\(error.localizedDescription)")
            audioPlayer = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            return false
        }
    }

    private func fetchOpenAISpeechData(
        text: String,
        apiKey: String,
        isKhmer: Bool,
        playbackSpeed: AIChatSpeechPlaybackSpeed
    ) async throws -> Data {
        let endpoint = URL(string: "https://api.openai.com/v1/audio/speech")!
        let clippedInput = String(
            normalizedSpeechText(from: text, isKhmer: isKhmer)
                .prefix(4000)
        )
        let body: [String: Any] = [
            "model": "gpt-4o-mini-tts",
            "input": clippedInput,
            "voice": preferredOpenAIVoice(isKhmer: isKhmer),
            "format": "mp3",
            "speed": NSDecimalNumber(string: playbackSpeed.openAISpeedValue(isKhmer: isKhmer)),
            "instructions": openAISpeechInstructions(isKhmer: isKhmer)
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body, options: [])

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = bodyData

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "AIChatVoiceController", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Invalid OpenAI speech response."
            ])
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let envelope = try? JSONDecoder().decode(OpenAISpeechErrorEnvelope.self, from: data)
            let message = envelope?.error?.message ?? "HTTP \(httpResponse.statusCode)"
            throw NSError(domain: "AIChatVoiceController", code: httpResponse.statusCode, userInfo: [
                NSLocalizedDescriptionKey: message
            ])
        }

        return data
    }

    private func fetchOpenAITranscription(from fileURL: URL, apiKey: String, isKhmer: Bool) async throws -> String {
        let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
        let fileData = try Data(contentsOf: fileURL)
        let boundary = "Boundary-\(UUID().uuidString)"

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.makeTranscriptionMultipartBody(
            fileData: fileData,
            boundary: boundary,
            filename: fileURL.lastPathComponent,
            mimeType: "audio/m4a",
            isKhmer: isKhmer
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "AIChatVoiceController", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Invalid OpenAI transcription response."
            ])
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let envelope = try? JSONDecoder().decode(OpenAISpeechErrorEnvelope.self, from: data)
            let message = envelope?.error?.message ?? "HTTP \(httpResponse.statusCode)"
            throw NSError(domain: "AIChatVoiceController", code: httpResponse.statusCode, userInfo: [
                NSLocalizedDescriptionKey: message
            ])
        }

        let responseEnvelope = try JSONDecoder().decode(OpenAITranscriptionResponse.self, from: data)
        return responseEnvelope.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func preferredOpenAIVoice(isKhmer: Bool) -> String {
        isKhmer ? "coral" : "marin"
    }

    private func openAISpeechInstructions(isKhmer: Bool) -> String {
        if isKhmer {
            return "Speak in warm, friendly, modern conversational Khmer with a natural human tone. Sound upbeat, kind, and approachable, with medium-fast pacing, clear Khmer pronunciation, short natural pauses, and lively energy. Avoid robotic cadence, slow drawn-out syllables, or formal announcer delivery."
        }

        return "Speak in a warm, friendly, upbeat conversational tone with natural human rhythm. Keep the pacing slightly brisk, approachable, and lively. Avoid robotic pacing, stiff delivery, or overly long pauses."
    }

    private func normalizedSpeechText(from text: String, isKhmer: Bool) -> String {
        let paragraphSeparator = isKhmer ? "។ " : ". "
        let cleanedMarkdown = text
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: #"(?m)^\s{0,3}#{1,6}\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^\s*[-*•]\s*"#, with: "", options: .regularExpression)

        let normalizedParagraphs = cleanedMarkdown
            .replacingOccurrences(of: #"\n{2,}"#, with: paragraphSeparator, options: .regularExpression)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return normalizedParagraphs
    }

    private static func makeTemporaryRecordingURL() -> URL {
        let baseDirectory = FileManager.default.temporaryDirectory
        return baseDirectory.appendingPathComponent("voice-input-\(UUID().uuidString).m4a")
    }

    private static func makeTranscriptionMultipartBody(
        fileData: Data,
        boundary: String,
        filename: String,
        mimeType: String,
        isKhmer: Bool
    ) throws -> Data {
        var body = Data()

        func appendField(name: String, value: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data("\(value)\r\n".utf8))
        }

        appendField(name: "model", value: "gpt-4o-transcribe")
        appendField(name: "response_format", value: "json")
        appendField(name: "temperature", value: "0")
        if isKhmer {
            appendField(name: "prompt", value: "សូមសរសេរជាអក្សរខ្មែរធម្មជាតិ និងដាក់សញ្ញាវណ្ណយុត្តិឲ្យសមស្រប។")
        }

        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(fileData)
        body.append(Data("\r\n".utf8))
        body.append(Data("--\(boundary)--\r\n".utf8))

        return body
    }

    private func localizedRecognitionError(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == "kAFAssistantErrorDomain" || nsError.domain == "SFSpeechRecognitionErrorDomain" {
            return text(
                "Voice recognition stopped. Try again.",
                "Voice recognition បានឈប់។ សូមសាកម្ដងទៀត។"
            )
        }

        return text(
            "Voice input failed. Try again.",
            "Voice input បរាជ័យ។ សូមសាកម្ដងទៀត។"
        )
    }

    private func makeSpeechRecognizer(isKhmer: Bool) -> SFSpeechRecognizer? {
        let supportedIDs = Set(SFSpeechRecognizer.supportedLocales().map { $0.identifier.lowercased() })
        let resolvedIdentifier = speechLocaleCandidates(isKhmer: isKhmer).first {
            supportedIDs.contains($0.lowercased())
        } ?? "en-US"

        return SFSpeechRecognizer(locale: Locale(identifier: resolvedIdentifier))
    }

    private func speechLocaleCandidates(isKhmer: Bool) -> [String] {
        var candidates: [String] = []
        if isKhmer {
            candidates.append(contentsOf: ["km-KH", "km"])
        }
        if let preferred = Locale.preferredLanguages.first {
            candidates.append(preferred)
        }
        candidates.append(Locale.current.identifier)
        candidates.append(contentsOf: ["en-US", "en-GB"])

        var deduped: [String] = []
        var seen = Set<String>()
        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { continue }
            deduped.append(trimmed)
        }
        return deduped
    }

    private func preferredSpeechVoice(for text: String, isKhmer: Bool) -> AVSpeechSynthesisVoice? {
        let containsKhmerScript = text.unicodeScalars.contains { scalar in
            (0x1780 ... 0x17FF).contains(scalar.value)
        }

        var candidates: [String] = []
        if containsKhmerScript || isKhmer {
            candidates.append("km-KH")
        }
        candidates.append(contentsOf: ["en-US", AVSpeechSynthesisVoice.currentLanguageCode()])

        for identifier in candidates {
            if let voice = AVSpeechSynthesisVoice(language: identifier) {
                return voice
            }
        }

        return AVSpeechSynthesisVoice(language: "en-US")
    }

    nonisolated
    private static func speechAuthorizationStatus() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }

        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    nonisolated
    private static func microphonePermissionGranted() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        print("VOICE DEBUG capture audio auth status=\(status.rawValue)")

        switch status {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    print("VOICE DEBUG capture requestAccess granted=\(granted)")
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    nonisolated
    private static func installRecognitionTap(
        on inputNode: AVAudioInputNode,
        format: AVAudioFormat,
        request: SFSpeechAudioBufferRecognitionRequest
    ) {
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
    }
}
