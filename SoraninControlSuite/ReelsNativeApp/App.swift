import SwiftUI
import AppKit
import AVFoundation
import AVKit
import Darwin
import Foundation
import UniformTypeIdentifiers

private struct SoraninBundledRuntimePaths: Decodable {
    let repoRoot: String
    let scriptsDir: String
    let runtimeDir: String
    let packagesRoot: String
}

private func expandedPath(_ raw: String) -> String {
    NSString(string: raw).expandingTildeInPath
}

private func fileURL(from raw: String, isDirectory: Bool = false) -> URL {
    URL(fileURLWithPath: expandedPath(raw), isDirectory: isDirectory)
}

private func firstEnvironmentValue(_ names: [String]) -> String? {
    for name in names {
        let value = ProcessInfo.processInfo.environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !value.isEmpty {
            return value
        }
    }
    return nil
}

private func ensureDirectoryURL(_ url: URL) -> URL {
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func loadBundledRuntimePaths() -> SoraninBundledRuntimePaths? {
    guard let resourceURL = Bundle.main.url(forResource: "runtime_paths", withExtension: "json"),
          let data = try? Data(contentsOf: resourceURL) else {
        return nil
    }
    return try? JSONDecoder().decode(SoraninBundledRuntimePaths.self, from: data)
}

private let soraninBundledRuntimePaths = loadBundledRuntimePaths()
private let soraninRepoRootURL: URL = {
    if let explicit = firstEnvironmentValue(["SORANIN_CONTROL_SUITE_DIR"]) {
        return fileURL(from: explicit, isDirectory: true)
    }
    if let bundled = soraninBundledRuntimePaths {
        return fileURL(from: bundled.repoRoot, isDirectory: true)
    }
    return URL(fileURLWithPath: (#filePath as NSString).deletingLastPathComponent, isDirectory: true)
        .deletingLastPathComponent()
}()
private let soraninScriptsDirURL: URL = {
    if let explicit = firstEnvironmentValue(["SORANIN_SCRIPTS_DIR"]) {
        return fileURL(from: explicit, isDirectory: true)
    }
    if let bundled = soraninBundledRuntimePaths {
        return fileURL(from: bundled.scriptsDir, isDirectory: true)
    }
    return soraninRepoRootURL.appendingPathComponent("scripts", isDirectory: true)
}()
private let soraninRuntimeDirURL: URL = {
    if let explicit = firstEnvironmentValue(["SORANIN_RUNTIME_DIR"]) {
        return ensureDirectoryURL(fileURL(from: explicit, isDirectory: true))
    }
    if let bundled = soraninBundledRuntimePaths {
        return ensureDirectoryURL(fileURL(from: bundled.runtimeDir, isDirectory: true))
    }
    return ensureDirectoryURL(URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(".soranin", isDirectory: true))
}()
private let rootDir: URL = {
    if let explicit = firstEnvironmentValue(["SORANIN_PACKAGES_ROOT", "SORANIN_ROOT_DIR"]) {
        return ensureDirectoryURL(fileURL(from: explicit, isDirectory: true))
    }
    if let bundled = soraninBundledRuntimePaths {
        return ensureDirectoryURL(fileURL(from: bundled.packagesRoot, isDirectory: true))
    }
    let legacyRoot = soraninRepoRootURL.deletingLastPathComponent().appendingPathComponent("Soranin", isDirectory: true)
    if FileManager.default.fileExists(atPath: legacyRoot.path) {
        return legacyRoot
    }
    return ensureDirectoryURL(soraninRuntimeDirURL.appendingPathComponent("Soranin", isDirectory: true))
}()

private func preferredRuntimeFile(named filename: String, envNames: [String] = []) -> URL {
    if let explicit = firstEnvironmentValue(envNames) {
        let url = fileURL(from: explicit)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }
    let legacy = soraninRepoRootURL.deletingLastPathComponent().appendingPathComponent(filename)
    if FileManager.default.fileExists(atPath: legacy.path) {
        return legacy
    }
    let fallback = soraninRuntimeDirURL.appendingPathComponent(filename)
    try? FileManager.default.createDirectory(at: fallback.deletingLastPathComponent(), withIntermediateDirectories: true)
    return fallback
}

private let facebookRootDir = rootDir.deletingLastPathComponent().appendingPathComponent("facebook", isDirectory: true)
private let batchScript = soraninScriptsDirURL.appendingPathComponent("fast_reels_batch.py")
private let facebookBatchUploadScript = soraninScriptsDirURL.appendingPathComponent("fb_reels_batch_upload.py")
private let facebookPreflightScript = soraninScriptsDirURL.appendingPathComponent("fb_reels_preflight_check.py")
private let reelsDashboardServerScript = soraninScriptsDirURL.appendingPathComponent("reels_dashboard_server.py")
private let facebookTimingStateFile = rootDir.appendingPathComponent(".fb_reels_publish_state.json")
private let soraDownloaderScript = soraninScriptsDirURL.appendingPathComponent("sora_downloader.py")
private let postLinksDownloaderScript = soraninScriptsDirURL.appendingPathComponent("post_links_downloader.py")
private let aiChatBridgeScript = soraninScriptsDirURL.appendingPathComponent("ai_chat_bridge.py")
private let aiChatHistoryFile = preferredRuntimeFile(named: ".soranin_ai_chat_history.json")
private let aiChatPendingRequestFile = preferredRuntimeFile(named: ".soranin_ai_chat_pending_request.json")
private let chromeProfileAssignmentsFile = preferredRuntimeFile(named: ".soranin_chrome_profile_links.json")
private let soraCompletedDownloadIDsFile = preferredRuntimeFile(named: ".soranin_completed_sora_ids.json")
private let geminiLiveEndpoint = URL(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")!
private let geminiLiveModel = "gemini-2.5-flash-native-audio-preview-12-2025"
private let geminiFilesBaseURL = URL(string: "https://generativelanguage.googleapis.com")!
private let geminiFlashTranscriptionModel = "gemini-3-flash-preview"
private let geminiProTranscriptionModel = "gemini-3-pro-preview"
private let geminiFilePollSeconds: TimeInterval = 5
private let geminiFileTimeoutSeconds: TimeInterval = 300
private let noClearSpokenWordsPlaceholder = "[No clear spoken words detected]"
private let openAILiveEndpoint = URL(string: "wss://api.openai.com/v1/realtime")!
private let openAILiveModel = "gpt-realtime"
private let openAILiveTranscriptionModel = "gpt-4o-mini-transcribe"
private let openAISpeechEndpoint = URL(string: "https://api.openai.com/v1/audio/speech")!
private let openAIReplySpeechModel = "gpt-4o-mini-tts"
private let openAIAudioTranscriptionEndpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
private let openAIChatTranscriptionModel = "gpt-4o-transcribe"
private let apiKeysFile = preferredRuntimeFile(named: ".reels_api_keys.json", envNames: ["SORANIN_API_KEYS_FILE"])
private let chromeBundleIdentifier = "com.google.Chrome"
private let chromeLocalStateFile = URL(
    fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Google/Chrome/Local State"
)
private let reelsDashboardServerBaseURL = URL(string: "http://127.0.0.1:8765")!
private let reelsDashboardServerStatusURL = URL(string: "http://127.0.0.1:8765/status")!
private let chromeUserDataDirectory = chromeLocalStateFile.deletingLastPathComponent()
private let chromeDefaultApplicationURL = URL(fileURLWithPath: "/Applications/Google Chrome.app", isDirectory: true)
private let chromeUserApplicationURL = URL(fileURLWithPath: NSHomeDirectory() + "/Applications/Google Chrome.app", isDirectory: true)
private weak var activeReelsModelForAppLifecycle: ReelsModel?
private var soraninForceTerminateWorkItem: DispatchWorkItem?
private var soraninKillWorkItem: DispatchWorkItem?
private var soraninQuitInProgress = false
private extension Notification.Name {
    static let soraninSelectAllEditedPackages = Notification.Name("soranin.selectAllEditedPackages")
    static let soraninDismissTransientUI = Notification.Name("soranin.dismissTransientUI")
}

private func normalizedFacebookRunnerPageName(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func normalizedFacebookRunnerPackageName(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    if trimmed.hasSuffix("_Reels_Package") {
        return trimmed
    }
    if Int(trimmed) != nil {
        return "\(trimmed)_Reels_Package"
    }
    return trimmed
}

private func nonLoopbackIPv4Interfaces() -> [(name: String, address: String)] {
    var addressPointer: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&addressPointer) == 0, let firstAddress = addressPointer else {
        return []
    }
    defer { freeifaddrs(addressPointer) }

    var results: [(name: String, address: String)] = []
    var seen: Set<String> = []
    var pointer = firstAddress

    while true {
        let interface = pointer.pointee
        let flags = Int32(interface.ifa_flags)
        if let addr = interface.ifa_addr,
           addr.pointee.sa_family == UInt8(AF_INET),
           (flags & IFF_UP) != 0,
           (flags & IFF_LOOPBACK) == 0 {
            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let nameInfoResult = getnameinfo(
                addr,
                socklen_t(addr.pointee.sa_len),
                &hostBuffer,
                socklen_t(hostBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            if nameInfoResult == 0 {
                let interfaceName = String(cString: interface.ifa_name)
                let address = String(cString: hostBuffer)
                let uniqueKey = "\(interfaceName)|\(address)"
                if seen.insert(uniqueKey).inserted {
                    results.append((interfaceName, address))
                }
            }
        }

        guard let next = interface.ifa_next else { break }
        pointer = next
    }

    let preferredOrder = ["en0", "en1", "en2", "en3", "bridge100"]
    return results.sorted { lhs, rhs in
        let leftIndex = preferredOrder.firstIndex(of: lhs.name) ?? Int.max
        let rightIndex = preferredOrder.firstIndex(of: rhs.name) ?? Int.max
        if leftIndex != rightIndex {
            return leftIndex < rightIndex
        }
        if lhs.name != rhs.name {
            return lhs.name < rhs.name
        }
        return lhs.address < rhs.address
    }
}

private func reelsDashboardBaseURLString(forHost host: String) -> String {
    "http://\(host):8765"
}

private func parseFacebookRunnerPackageNames(_ value: String) -> [String] {
    let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;"))
    let rawParts = value
        .components(separatedBy: separators)
        .map(normalizedFacebookRunnerPackageName)
        .filter { !$0.isEmpty }

    var seen: Set<String> = []
    var results: [String] = []
    for part in rawParts where !seen.contains(part) {
        seen.insert(part)
        results.append(part)
    }
    return results
}

private enum PostDownloadKind: String {
    case sora
    case facebook
}

private struct PostDownloadEntry: Hashable {
    let kind: PostDownloadKind
    let value: String

    var uniqueKey: String {
        "\(kind.rawValue):\(value.lowercased())"
    }

    var displayValue: String {
        value
    }

    var soraID: String? {
        kind == .sora ? value : nil
    }

    var facebookURL: String? {
        kind == .facebook ? value : nil
    }
}

@MainActor
private func requestSoraninAppQuit() {
    soraninQuitInProgress = true
    NotificationCenter.default.post(name: .soraninDismissTransientUI, object: nil)
    activeReelsModelForAppLifecycle?.prepareForTermination()
    soraninForceTerminateWorkItem?.cancel()
    soraninKillWorkItem?.cancel()

    DispatchQueue.main.async {
        if let mainWindow = NSApp.mainWindow ?? NSApp.windows.first {
            mainWindow.performClose(nil)
        } else {
            _ = NSRunningApplication.current.terminate()
            NSApp.terminate(nil)
        }
    }

    let forceTerminateWorkItem = DispatchWorkItem {
        _ = NSRunningApplication.current.forceTerminate()
    }
    soraninForceTerminateWorkItem = forceTerminateWorkItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: forceTerminateWorkItem)

    let killWorkItem = DispatchWorkItem {
        kill(getpid(), SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.4) {
            kill(getpid(), SIGKILL)
        }
    }
    soraninKillWorkItem = killWorkItem
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.2, execute: killWorkItem)
}

private enum SoraninPalette {
    static let bgTop = Color(red: 0.04, green: 0.06, blue: 0.16)
    static let bgBottom = Color(red: 0.10, green: 0.13, blue: 0.29)
    static let card = Color(red: 0.16, green: 0.18, blue: 0.30)
    static let cardSoft = Color(red: 0.21, green: 0.23, blue: 0.38)
    static let cardStrong = Color(red: 0.11, green: 0.13, blue: 0.23)
    static let input = Color(red: 0.24, green: 0.27, blue: 0.41)
    static let border = Color(red: 0.25, green: 0.29, blue: 0.47)
    static let primaryText = Color(red: 0.98, green: 0.98, blue: 1.0)
    static let secondaryText = Color(red: 0.66, green: 0.69, blue: 0.80)
    static let accentStart = Color(red: 0.58, green: 0.29, blue: 0.96)
    static let accentEnd = Color(red: 0.25, green: 0.46, blue: 0.97)
    static let accentGlow = Color(red: 0.38, green: 0.54, blue: 1.0)
    static let success = Color(red: 0.42, green: 0.89, blue: 0.71)
}

struct SoraninPrimaryButtonStyle: ButtonStyle {
    let compact: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 14, weight: .bold))
            .foregroundStyle(SoraninPalette.primaryText)
            .padding(.horizontal, compact ? 14 : 18)
            .padding(.vertical, compact ? 10 : 14)
            .background(
                RoundedRectangle(cornerRadius: compact ? 16 : 22, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [SoraninPalette.accentStart, SoraninPalette.accentEnd],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: compact ? 16 : 22, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: SoraninPalette.accentGlow.opacity(configuration.isPressed ? 0.18 : 0.34), radius: 18, y: 8)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

struct SoraninSecondaryButtonStyle: ButtonStyle {
    let compact: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 14, weight: .bold))
            .foregroundStyle(SoraninPalette.primaryText)
            .padding(.horizontal, compact ? 14 : 18)
            .padding(.vertical, compact ? 10 : 14)
            .background(
                RoundedRectangle(cornerRadius: compact ? 16 : 22, style: .continuous)
                    .fill(SoraninPalette.cardSoft.opacity(configuration.isPressed ? 0.92 : 1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: compact ? 16 : 22, style: .continuous)
                    .stroke(SoraninPalette.border, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
    }
}

private final class AIChatComposerNSTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var canSubmit: (() -> Bool)?
    var onStandaloneShiftPress: (() -> Void)?

    private var isStandaloneShiftArmed = false
    private var didUseArmedShiftWithAnotherKey = false

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if isStandaloneShiftArmed, flags.contains(.shift) {
            didUseArmedShiftWithAnotherKey = true
        }
        super.keyDown(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isShiftOnly = flags.contains(.shift) && flags.subtracting(.shift).isEmpty

        if isShiftOnly {
            if !isStandaloneShiftArmed {
                isStandaloneShiftArmed = true
                didUseArmedShiftWithAnotherKey = false
            }
        } else {
            let shouldTrigger = isStandaloneShiftArmed && !didUseArmedShiftWithAnotherKey
            isStandaloneShiftArmed = false
            didUseArmedShiftWithAnotherKey = false
            if shouldTrigger {
                DispatchQueue.main.async { [weak self] in
                    self?.onStandaloneShiftPress?()
                }
            }
        }

        super.flagsChanged(with: event)
    }

    override func doCommand(by selector: Selector) {
        if selector == #selector(insertNewline(_:)) {
            let flags = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
            let shouldInsertNewline = flags.contains(.shift) || flags.contains(.option)
            if shouldInsertNewline && flags.contains(.shift) {
                didUseArmedShiftWithAnotherKey = true
            }
            if !shouldInsertNewline && (canSubmit?() ?? true) {
                onSubmit?()
                return
            }
        }
        super.doCommand(by: selector)
    }
}

private struct AIChatComposerTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var measuredHeight: CGFloat
    let isEditable: Bool
    let onSubmit: () -> Void
    let canSubmit: () -> Bool
    let onStandaloneShiftPress: () -> Void

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AIChatComposerTextEditor

        init(parent: AIChatComposerTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let updatedText = textView.string
            if parent.text != updatedText {
                parent.text = updatedText
            }
            parent.updateMeasuredHeight(for: textView)
        }
    }

    private func updateMeasuredHeight(for textView: NSTextView) {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer
        else {
            return
        }
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let targetHeight = max(38, ceil(usedRect.height + (textView.textContainerInset.height * 2) + 2))
        if abs(measuredHeight - targetHeight) > 0.5 {
            DispatchQueue.main.async {
                measuredHeight = targetHeight
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = AIChatComposerNSTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 2, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = NSSize(width: 0, height: 38)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.font = .systemFont(ofSize: 14, weight: .medium)
        textView.textColor = NSColor(calibratedRed: 0.98, green: 0.98, blue: 1.0, alpha: 1.0)
        textView.insertionPointColor = NSColor(calibratedRed: 0.98, green: 0.98, blue: 1.0, alpha: 1.0)
        textView.string = text
        textView.isEditable = isEditable
        textView.onSubmit = onSubmit
        textView.canSubmit = canSubmit
        textView.onStandaloneShiftPress = onStandaloneShiftPress

        scrollView.documentView = textView
        updateMeasuredHeight(for: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? AIChatComposerNSTextView else { return }
        context.coordinator.parent = self
        if textView.string != text {
            textView.string = text
        }
        textView.isEditable = isEditable
        textView.onSubmit = onSubmit
        textView.canSubmit = canSubmit
        textView.onStandaloneShiftPress = onStandaloneShiftPress
        textView.font = .systemFont(ofSize: 14, weight: .medium)
        textView.textColor = NSColor(calibratedRed: 0.98, green: 0.98, blue: 1.0, alpha: 1.0)
        textView.insertionPointColor = NSColor(calibratedRed: 0.98, green: 0.98, blue: 1.0, alpha: 1.0)
        updateMeasuredHeight(for: textView)
    }
}

private final class AIChatSpeechRecorder: NSObject {
    private var recorder: AVAudioRecorder?
    private(set) var outputURL: URL?

    func startRecording(completion: @escaping (Result<Void, Error>) -> Void) {
        requestMicrophonePermission { [weak self] granted in
            guard let self else { return }
            guard granted else {
                completion(.failure(NSError(
                    domain: "SoraninAIChatRecorder",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Microphone permission was denied."]
                )))
                return
            }

            do {
                let recordingsDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("SoraninAIChatRecordings", isDirectory: true)
                try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
                let url = recordingsDirectory.appendingPathComponent("ai_chat_\(UUID().uuidString).m4a")
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 44_100,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                    AVEncoderBitRateKey: 128_000
                ]
                let recorder = try AVAudioRecorder(url: url, settings: settings)
                recorder.prepareToRecord()
                guard recorder.record() else {
                    throw NSError(
                        domain: "SoraninAIChatRecorder",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Recording could not start."]
                    )
                }
                self.recorder = recorder
                self.outputURL = url
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func stopRecording() -> URL? {
        recorder?.stop()
        recorder = nil
        let url = outputURL
        outputURL = nil
        return url
    }

    func cancelRecording() {
        recorder?.stop()
        recorder = nil
        if let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
        outputURL = nil
    }

    private func requestMicrophonePermission(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                completion(granted)
            }
        default:
            completion(false)
        }
    }
}

enum AILiveVoiceChoice: String, CaseIterable, Identifiable {
    case female
    case male

    var id: String { rawValue }

    var label: String {
        switch self {
        case .female: return "Female"
        case .male: return "Male"
        }
    }

    var shortLabel: String {
        switch self {
        case .female: return "Female"
        case .male: return "Male"
        }
    }

    var iconSystemName: String {
        switch self {
        case .female: return "figure.stand.dress"
        case .male: return "figure.stand"
        }
    }

    var openAIVoiceName: String {
        switch self {
        case .female: return "marin"
        case .male: return "cedar"
        }
    }

    var geminiVoiceName: String {
        switch self {
        case .female: return "Autonoe"
        case .male: return "Iapetus"
        }
    }

    static func fromSaved(_ value: String?) -> AILiveVoiceChoice {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let choice = AILiveVoiceChoice(rawValue: value) else {
            return .female
        }
        return choice
    }
}

enum AIProvider: String, CaseIterable, Identifiable {
    case openaiGPT54 = "openai_gpt54"
    case geminiFlash = "gemini_3_flash"
    case geminiPro = "gemini_3_pro"
    case gemini25Pro = "gemini_25_pro"

    var id: String { rawValue }

    var providerKey: String {
        switch self {
        case .openaiGPT54: return "openai"
        case .geminiFlash, .geminiPro, .gemini25Pro: return "gemini"
        }
    }

    var label: String {
        switch self {
        case .openaiGPT54: return "OpenAI GPT-5.4"
        case .geminiFlash: return "Gemini Chat 3 Flash"
        case .geminiPro: return "Gemini Chat 3 Pro"
        case .gemini25Pro: return "Gemini 2.5 Pro"
        }
    }

    var compactLabel: String {
        switch self {
        case .openaiGPT54: return "GPT-5.4"
        case .geminiFlash: return "Gemini Chat Flash"
        case .geminiPro: return "Gemini Chat Pro"
        case .gemini25Pro: return "Gemini 2.5 Pro"
        }
    }

    var logoText: String {
        switch self {
        case .openaiGPT54: return "O"
        case .geminiFlash, .geminiPro, .gemini25Pro: return "G"
        }
    }

    var detail: String {
        switch self {
        case .openaiGPT54: return "Transcript + sampled frames fallback flow"
        case .geminiFlash: return "Fast chat + full video understanding"
        case .geminiPro: return "Deeper chat + full video understanding"
        case .gemini25Pro: return "Advanced math + code stable reasoning"
        }
    }

    static func fromSavedSettings(_ saved: [String: String]) -> AIProvider {
        if let model = saved["AI_MODEL"]?.lowercased(), let value = AIProvider(rawValue: model) {
            return value
        }
        switch saved["AI_PROVIDER"]?.lowercased() {
        case "gemini":
            return .geminiFlash
        default:
            return .openaiGPT54
        }
    }

    static func fromSavedAIChatSettings(_ saved: [String: String]) -> AIProvider {
        if let model = saved["AI_CHAT_MODEL"]?.lowercased(), let value = AIProvider(rawValue: model) {
            return value
        }
        switch saved["AI_CHAT_PROVIDER"]?.lowercased() {
        case "gemini":
            return .geminiFlash
        case "openai":
            return .openaiGPT54
        default:
            return fromSavedSettings(saved)
        }
    }
}

enum AIChatRecordingProvider: String, CaseIterable, Identifiable {
    case openai
    case gemini

    var id: String { rawValue }

    var label: String {
        switch self {
        case .openai:
            return "OpenAI Record"
        case .gemini:
            return "Gemini Record"
        }
    }

    var shortLabel: String {
        switch self {
        case .openai:
            return "O"
        case .gemini:
            return "G"
        }
    }

    static func fromSaved(_ value: String?) -> AIChatRecordingProvider {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let provider = AIChatRecordingProvider(rawValue: value) else {
            return .openai
        }
        return provider
    }
}

enum AIChatThumbnailDesignStyle: String, CaseIterable, Identifiable {
    case safeViral = "safe_viral"
    case luxuryClean = "luxury_clean"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .safeViral:
            return "Safe Viral"
        case .luxuryClean:
            return "Luxury Clean"
        }
    }

    var requestSuffix: String {
        switch self {
        case .safeViral:
            return "in safe viral style"
        case .luxuryClean:
            return "in luxury clean style"
        }
    }
}

enum AIChatGeminiImageModelChoice: String, CaseIterable, Identifiable {
    case flash = "gemini_31_flash_image_preview"
    case pro = "gemini_3_pro_image_preview"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .flash:
            return "Gemini 3.1 Flash Image Preview"
        case .pro:
            return "Gemini 3 Pro Image Preview"
        }
    }

    var compactLabel: String {
        switch self {
        case .flash:
            return "Flash Image"
        case .pro:
            return "Pro Image"
        }
    }

    var slashCommand: String {
        switch self {
        case .flash:
            return "/banana2"
        case .pro:
            return "/bananapro"
        }
    }

    static func fromSaved(_ value: String?) -> AIChatGeminiImageModelChoice {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let choice = AIChatGeminiImageModelChoice(rawValue: value) else {
            return .flash
        }
        return choice
    }
}

enum GeminiReplyVoiceFallbackMode: String, CaseIterable, Identifiable {
    case geminiOnly = "gemini_only"
    case geminiWithOpenAIFallback = "gemini_with_openai_fallback"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .geminiOnly:
            return "Gemini only"
        case .geminiWithOpenAIFallback:
            return "Gemini + OpenAI fallback"
        }
    }

    var shortDescription: String {
        switch self {
        case .geminiOnly:
            return "Save cost. If Gemini voice fails, stay silent."
        case .geminiWithOpenAIFallback:
            return "Try OpenAI voice only if Gemini voice fails."
        }
    }

    static func fromSaved(_ value: String?) -> GeminiReplyVoiceFallbackMode {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let mode = GeminiReplyVoiceFallbackMode(rawValue: value) else {
            return .geminiOnly
        }
        return mode
    }
}

struct EditedPackageItem: Identifiable {
    let id: String
    let packageName: String
    let sourceName: String
    let videoName: String
    let title: String
    let thumbnailURL: URL?
    let packageURL: URL
    let assignedProfileDirectoryName: String?
    let assignedProfileDisplayName: String?
    let assignedProfileOnline: Bool
}

struct ChromeProfileItem: Identifiable, Equatable {
    let id: String
    let directoryName: String
    let displayName: String
    let isOnline: Bool
}

enum AIChatAttachmentKind: String, Codable {
    case image
    case video
}

struct AIChatAttachment: Identifiable, Equatable, Codable {
    let id: UUID
    var kind: AIChatAttachmentKind
    var path: String
    var mimeType: String?
    var displayName: String?

    init(
        id: UUID = UUID(),
        kind: AIChatAttachmentKind,
        path: String,
        mimeType: String? = nil,
        displayName: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.path = path
        self.mimeType = mimeType
        self.displayName = displayName
    }

    var url: URL {
        URL(fileURLWithPath: path)
    }

    var resolvedDisplayName: String {
        let trimmed = (displayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? url.lastPathComponent : trimmed
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case path
        case mimeType
        case displayName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try container.decode(AIChatAttachmentKind.self, forKey: .kind)
        path = try container.decode(String.self, forKey: .path)
        mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
    }
}

struct AIChatMessage: Identifiable, Equatable, Codable {
    let id: UUID
    var role: String
    var content: String
    var attachments: [AIChatAttachment]

    init(id: UUID = UUID(), role: String, content: String, attachments: [AIChatAttachment] = []) {
        self.id = id
        self.role = role
        self.content = content
        self.attachments = attachments
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case role
        case content
        case attachments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        role = try container.decode(String.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        attachments = try container.decodeIfPresent([AIChatAttachment].self, forKey: .attachments) ?? []
    }
}

private struct AIChatBridgeResult {
    var text: String
    var attachments: [AIChatAttachment]
}

struct AIChatSession: Identifiable, Codable, Equatable {
    let id: UUID
    var createdAt: Date
    var updatedAt: Date
    var title: String
    var messages: [AIChatMessage]
}

private struct AIChatStore: Codable {
    var currentSessionID: UUID?
    var sessions: [AIChatSession]
}

private struct AIChatPendingRequest: Codable {
    var id: UUID
    var sessionID: UUID
    var providerRawValue: String
    var prompt: String
    var imageModelLabel: String?
    var messages: [[String: String]]
    var imagePaths: [String]
    var videoPaths: [String]
    var requestTimeout: TimeInterval
    var createdAt: Date
}

private let aiChatSessionFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter
}()

private func aiChatSessionPreview(_ session: AIChatSession) -> String {
    let savedTitle = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
    if !savedTitle.isEmpty {
        return String(savedTitle.prefix(42))
    }
    let userMessage = session.messages.first(where: { $0.role == "user" })?.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !userMessage.isEmpty {
        return String(userMessage.prefix(42))
    }
    return "New Chat"
}

private func aiChatSessionTitle(from firstPrompt: String) -> String {
    let cleaned = firstPrompt
        .replacingOccurrences(of: #"\s*\[Attached:.*\]$"#, with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned.isEmpty ? "New Chat" : String(cleaned.prefix(60))
}

private func aiChatFirstUserTitle(from messages: [AIChatMessage]) -> String? {
    guard let firstUserMessage = messages.first(where: { $0.role == "user" }) else {
        return nil
    }
    let title = aiChatSessionTitle(from: firstUserMessage.content)
    return title == "New Chat" ? nil : title
}

private func aiChatSessionLabel(_ session: AIChatSession) -> String {
    let stamp = aiChatSessionFormatter.string(from: session.updatedAt)
    return "\(stamp) • \(aiChatSessionPreview(session))"
}

private func extractPromptText(from text: String) -> String? {
    let normalized = text.replacingOccurrences(
        of: #"(?is)\*\*\s*((?:image|video)?\s*prompt(?:\s*\d+)?\s*:)\s*\*\*"#,
        with: "$1",
        options: .regularExpression
    )
    let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
    let patterns = [
        #"(?is)\*{0,2}(?:image|video)?\s*prompt(?:\s*\d+)?\*{0,2}\s*:\s*["“](.+?)["”]"#,
        #"(?is)\*{0,2}(?:image|video)?\s*prompt(?:\s*\d+)?\*{0,2}\s*:\s*['‘](.+?)['’]"#,
        #"(?is)\*{0,2}(?:image|video)?\s*prompt(?:\s*\d+)?\*{0,2}\s*:\s*```(?:[\w-]+)?\s*(.+?)\s*```"#,
        #"(?is)\*{0,2}(?:image|video)?\s*prompt(?:\s*\d+)?\*{0,2}\s*:\s*(.+)$"#,
    ]

    for pattern in patterns {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
        guard let match = regex.firstMatch(in: normalized, options: [], range: range),
              match.numberOfRanges > 1,
              let promptRange = Range(match.range(at: 1), in: normalized)
        else {
            continue
        }
        let prompt = normalized[promptRange]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’"))
        if !prompt.isEmpty {
            return prompt
        }
    }
    return nil
}

private struct AIChatPromptBlock: Identifiable, Equatable {
    let id: String
    let label: String
    let prompt: String
    let location: Int
}

private func normalizedPromptBlockLabel(_ label: String, index: Int) -> String {
    let collapsed = label
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return collapsed.isEmpty ? "Prompt \(index + 1)" : collapsed
}

private func extractCopyablePromptBlocks(from text: String) -> [AIChatPromptBlock] {
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
    let fullRange = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
    let headerPattern = #"(?im)^\s*(?:\*\*)?\s*((?:image|video)?\s*prompt(?:\s*\d+)?)\s*:\s*(?:\*\*)?\s*"#
    let numberedHeadingPattern = #"^\s*(\d+)\.\s*(.+?)\s*:?\s*$"#

    func labelBefore(location: Int, fallbackIndex: Int) -> String {
        let prefixRange = NSRange(location: 0, length: max(0, min(location, fullRange.length)))
        guard let stringRange = Range(prefixRange, in: normalized) else {
            return "Prompt \(fallbackIndex + 1)"
        }
        let lines = normalized[stringRange]
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }

        for candidate in lines.reversed() {
            guard !candidate.isEmpty else { continue }
            let lower = candidate.lowercased()
            if lower == "plaintext" || lower == "text" || lower == "code" {
                continue
            }
            if let regex = try? NSRegularExpression(pattern: numberedHeadingPattern),
               let match = regex.firstMatch(
                    in: candidate,
                    options: [],
                    range: NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
               ),
               let numberRange = Range(match.range(at: 1), in: candidate),
               let titleRange = Range(match.range(at: 2), in: candidate)
            {
                let number = candidate[numberRange].trimmingCharacters(in: .whitespacesAndNewlines)
                let title = candidate[titleRange].trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty {
                    return "\(number). \(title)"
                }
                return "Prompt \(number)"
            }
            if lower.contains("prompt") {
                return normalizedPromptBlockLabel(candidate, index: fallbackIndex)
            }
        }
        return "Prompt \(fallbackIndex + 1)"
    }

    guard let headerRegex = try? NSRegularExpression(pattern: headerPattern) else {
        return []
    }

    let matches = headerRegex.matches(in: normalized, options: [], range: fullRange)
    var blocks: [AIChatPromptBlock] = []
    var seenPrompts = Set<String>()

    if !matches.isEmpty {
        for (index, match) in matches.enumerated() {
            guard match.numberOfRanges > 1,
                  let labelRange = Range(match.range(at: 1), in: normalized)
            else {
                continue
            }

            let blockStart = match.range.location
            let blockEnd = index + 1 < matches.count ? matches[index + 1].range.location : fullRange.upperBound
            let blockNSRange = NSRange(location: blockStart, length: max(0, blockEnd - blockStart))
            guard let blockRange = Range(blockNSRange, in: normalized) else { continue }

            let blockText = String(normalized[blockRange])
            guard let prompt = extractPromptText(from: blockText)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !prompt.isEmpty
            else {
                continue
            }

            let label = normalizedPromptBlockLabel(String(normalized[labelRange]), index: index)
            if seenPrompts.insert(prompt).inserted {
                blocks.append(
                    AIChatPromptBlock(
                        id: "\(match.range.location)-\(label)-\(String(prompt.prefix(24)))",
                        label: label,
                        prompt: prompt,
                        location: match.range.location
                    )
                )
            }
        }
    }

    if let codeRegex = try? NSRegularExpression(pattern: #"(?is)```(?:[\w+-]+)?\s*\n(.*?)\n```"#) {
        let codeMatches = codeRegex.matches(in: normalized, options: [], range: fullRange)
        for (index, match) in codeMatches.enumerated() {
            guard match.numberOfRanges > 1,
                  let promptRange = Range(match.range(at: 1), in: normalized)
            else {
                continue
            }
            let prompt = normalized[promptRange]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard prompt.count >= 12, seenPrompts.insert(prompt).inserted else { continue }

            let label = labelBefore(location: match.range.location, fallbackIndex: blocks.count + index)
            blocks.append(
                AIChatPromptBlock(
                    id: "\(match.range.location)-\(label)-\(String(prompt.prefix(24)))",
                    label: label,
                    prompt: prompt,
                    location: match.range.location
                )
            )
        }
    }

    if !blocks.isEmpty {
        return blocks.sorted { $0.location < $1.location }
    }

    guard let prompt = extractPromptText(from: normalized)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
          !prompt.isEmpty
    else {
        return []
    }

    return [
        AIChatPromptBlock(id: "prompt-0", label: "Prompt", prompt: prompt, location: 0)
    ]
}

private func extractCopyablePromptText(from text: String) -> String? {
    let blocks = extractCopyablePromptBlocks(from: text)
    guard !blocks.isEmpty else { return nil }
    return blocks.map(\.prompt).joined(separator: "\n\n")
}

enum AIChatGeneratedMediaKind {
    case image
    case video

    var slashCommand: String {
        switch self {
        case .image:
            return "/image"
        case .video:
            return "/video"
        }
    }

    var buttonTitle: String {
        switch self {
        case .image:
            return "Generate Image"
        case .video:
            return "Generate Video"
        }
    }
}

private let aiChatImageCommandAliases = [
    "/image", "image",
    "/picture", "picture",
    "/photo", "photo",
    "/art", "art",
    "/រូបភាព", "រូបភាព",
    "/រូប", "រូប",
    "/រូបថត", "រូបថត",
]

private let aiChatBanana2CommandAliases = [
    "/banana2", "banana2",
    "/banana 2", "banana 2",
    "/nano banana 2", "nano banana 2",
]

private let aiChatBananaProCommandAliases = [
    "/bananapro", "bananapro",
    "/banana pro", "banana pro",
    "/nano banana pro", "nano banana pro",
]

private let aiChatVideoCommandAliases = [
    "/video", "video",
    "/clip", "clip",
    "/movie", "movie",
    "/វីដេអូ", "វីដេអូ",
    "/ក្លីប", "ក្លីប",
]

private let aiChatVisibleMediaCommands = ["/image", "/video", "/រូបភាព", "/វីដេអូ", "/banana2", "/bananapro"]
private let aiChatGenerationVerbs = [
    "create", "generate", "make", "render", "draw", "design", "produce", "build", "craft", "illustrate", "paint", "sketch",
    "បង្កើត", "ធ្វើ", "គូរ", "សង់", "រចនា"
]
private let aiChatImageIntentNouns = [
    "image", "picture", "photo", "art", "artwork", "poster", "thumbnail", "logo", "banner", "wallpaper", "illustration",
    "portrait", "avatar", "icon", "sticker", "flyer", "brochure", "cover art", "product shot", "product photo",
    "infographic", "mockup", "packaging", "label", "scene",
    "រូប", "រូបភាព", "រូបថត", "គំនូរ", "ផូស្ទ័រ", "ប៉ូស្ទ័រ", "បដា", "ឡូហ្គោ", "ផ្ទាំងរូប", "អាវ៉ាតា", "ស្ទីគ័រ"
]
private let aiChatVideoIntentNouns = [
    "video", "clip", "movie", "animation", "reel", "short", "shorts", "trailer", "teaser", "promo video", "commercial",
    "intro video", "music video", "motion graphic",
    "វីដេអូ", "ក្លីប", "ឈុតវីដេអូ", "ឈុតភាពយន្ត"
]
private let aiChatImageIntentPhrases = [
    "create image", "generate image", "make image", "render image", "draw image",
    "create picture", "generate picture", "make picture",
    "create photo", "generate photo", "make photo",
    "create poster", "generate poster", "make poster", "poster for",
    "create thumbnail", "generate thumbnail", "make thumbnail", "thumbnail for",
    "create logo", "generate logo", "make logo", "logo for",
    "create banner", "generate banner", "make banner", "banner for",
    "create wallpaper", "generate wallpaper", "make wallpaper",
    "create illustration", "generate illustration", "make illustration", "illustration of",
    "portrait of", "photo of", "picture of", "image of", "art of",
    "product shot of", "mockup of", "cover art for", "flyer for", "brochure for",
    "បង្កើតរូប", "បង្កើតរូបភាព", "បង្កើតរូបថត", "ធ្វើរូប", "ធ្វើរូបភាព", "គូររូប", "គូររូបភាព",
    "រូបភាពនៃ", "រូបនៃ", "ផូស្ទ័រ", "ប៉ូស្ទ័រ", "បដា", "ឡូហ្គោ"
]
private let aiChatVideoIntentPhrases = [
    "create video", "generate video", "make video", "render video",
    "create clip", "generate clip", "make clip", "clip of",
    "create animation", "generate animation", "make animation", "animation of",
    "create reel", "generate reel", "make reel",
    "create trailer", "generate trailer", "make trailer",
    "create teaser", "generate teaser", "make teaser",
    "video of", "promo video", "intro video", "music video",
    "បង្កើតវីដេអូ", "ធ្វើវីដេអូ", "បង្កើតក្លីប", "ធ្វើក្លីប", "វីដេអូនៃ", "ក្លីបនៃ"
]
private let aiChatVideoThumbnailMarkers = [
    "thumbnail", "thumbnail image", "thumbnail frame", "thumbnail for", "create thumbnail", "generate thumbnail", "make thumbnail",
    "best thumbnail", "cover frame", "reel thumbnail", "facebook reel thumbnail", "youtube thumbnail",
    "រូបតូច", "បង្កើត thumbnail", "ធ្វើ thumbnail", "thumbnail ពីវីដេអូ"
]
private let aiChatFaceEditMarkers = [
    "face swap", "swap face", "change face", "replace face", "merge face", "face merge", "mix face", "blend face",
    "put this face on", "use this face", "use my face", "keep the same face", "preserve face",
    "ប្តូរមុខ", "ប្ដូរមុខ", "ដូរមុខ", "ផ្លាស់ប្តូរមុខ", "ផ្លាស់ប្ដូរមុខ", "បញ្ចូលមុខ", "លាយមុខ"
]
private let aiChatBananaProAutoMarkers = [
    "face swap", "swap face", "change face", "replace face", "merge face", "blend face",
    "poster", "thumbnail", "logo", "banner", "infographic", "flyer", "brochure", "billboard",
    "headline", "caption", "typography", "lettering", "text on", "with text", "title on",
    "product shot", "product ad", "advertisement", "ad creative", "commercial", "perfume",
    "cosmetic", "cosmetics", "skincare", "makeup", "jewelry", "glamour", "sensual", "sexy",
    "bikini", "swimsuit", "fashion editorial", "luxury product",
    "ប្តូរមុខ", "ប្ដូរមុខ", "ដូរមុខ", "ផ្លាស់ប្តូរមុខ", "ផ្លាស់ប្ដូរមុខ", "បញ្ចូលមុខ", "លាយមុខ",
    "ផូស្ទ័រ", "បដា", "ឡូហ្គោ", "ដាក់អក្សរ", "មានអក្សរ", "អក្សរលើរូប", "សិចស៊ី", "ឈុតហែលទឹក"
]

private func aiChatVisibleMediaCommandTitle(_ command: String) -> String {
    switch normalizedAIChatMediaPrompt(command).lowercased() {
    case "/image":
        return "Image"
    case "/video":
        return "Video"
    case "/banana2":
        return "Banana 2"
    case "/bananapro":
        return "Banana Pro"
    case "/រូបភាព":
        return "រូបភាព"
    case "/វីដេអូ":
        return "វីដេអូ"
    default:
        return command.replacingOccurrences(of: "/", with: "")
    }
}

private func aiChatCommandAliases(for kind: AIChatGeneratedMediaKind) -> [String] {
    switch kind {
    case .image:
        return aiChatImageCommandAliases
    case .video:
        return aiChatVideoCommandAliases
    }
}

private func aiChatLeadingMediaAliasMatch(in text: String) -> (kind: AIChatGeneratedMediaKind, alias: String, remainder: String)? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    for alias in aiChatBanana2CommandAliases {
        let lowered = trimmed.lowercased()
        let aliasLowered = alias.lowercased()
        guard lowered == aliasLowered || lowered.hasPrefix(aliasLowered + " ") || lowered.hasPrefix(aliasLowered + ":") else {
            continue
        }
        let aliasEnd = trimmed.index(trimmed.startIndex, offsetBy: alias.count)
        let remainder = trimmed[aliasEnd...]
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ":")))
        return (.image, "/banana2", String(remainder))
    }

    for alias in aiChatBananaProCommandAliases {
        let lowered = trimmed.lowercased()
        let aliasLowered = alias.lowercased()
        guard lowered == aliasLowered || lowered.hasPrefix(aliasLowered + " ") || lowered.hasPrefix(aliasLowered + ":") else {
            continue
        }
        let aliasEnd = trimmed.index(trimmed.startIndex, offsetBy: alias.count)
        let remainder = trimmed[aliasEnd...]
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ":")))
        return (.image, "/bananapro", String(remainder))
    }

    for kind in [AIChatGeneratedMediaKind.image, .video] {
        for alias in aiChatCommandAliases(for: kind) {
            let lowered = trimmed.lowercased()
            let aliasLowered = alias.lowercased()
            guard lowered == aliasLowered || lowered.hasPrefix(aliasLowered + " ") || lowered.hasPrefix(aliasLowered + ":") else {
                continue
            }
            let aliasEnd = trimmed.index(trimmed.startIndex, offsetBy: alias.count)
            let remainder = trimmed[aliasEnd...]
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ":")))
            return (kind, alias, String(remainder))
        }
    }
    return nil
}

private func normalizedAIChatMediaPrompt(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let match = aiChatLeadingMediaAliasMatch(in: trimmed) else {
        return trimmed
    }
    return match.remainder.isEmpty ? match.alias : "\(match.alias) \(match.remainder)"
}

private func aiChatDisplayPrompt(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let match = aiChatLeadingMediaAliasMatch(in: trimmed) else {
        return trimmed
    }
    let visibleText = match.remainder.trimmingCharacters(in: .whitespacesAndNewlines)
    return visibleText.isEmpty ? trimmed : visibleText
}

private func aiChatContainsAnyMarker(_ source: String, markers: [String]) -> Bool {
    markers.contains { source.contains($0) }
}

private func aiChatIsImageAttachmentURL(_ url: URL) -> Bool {
    let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "heic", "gif", "bmp", "tiff", "avif"]
    return imageExtensions.contains(url.pathExtension.lowercased())
}

private func aiChatIsVideoAttachmentURL(_ url: URL) -> Bool {
    let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "webm"]
    return videoExtensions.contains(url.pathExtension.lowercased())
}

private func requestedGeneratedImageModelLabel(
    for text: String,
    provider: AIProvider,
    attachmentURLs: [URL] = [],
    geminiChoice: AIChatGeminiImageModelChoice? = nil
) -> String? {
    let lowered = normalizedAIChatMediaPrompt(text).lowercased()
    if lowered == "/bananapro" || lowered.hasPrefix("/bananapro ") {
        return "Nano Banana Pro"
    }
    if lowered == "/banana2" || lowered.hasPrefix("/banana2 ") {
        return "Nano Banana 2"
    }
    guard provider.providerKey == "gemini" else { return nil }
    guard requestedGeneratedMediaKind(for: lowered) == .image else { return nil }
    let imageAttachmentCount = attachmentURLs.filter(aiChatIsImageAttachmentURL).count
    if imageAttachmentCount > 1 {
        return "Nano Banana Pro"
    }
    if aiChatContainsAnyMarker(lowered, markers: aiChatBananaProAutoMarkers) {
        return "Nano Banana Pro"
    }
    if geminiChoice == .pro {
        return "Nano Banana Pro"
    }
    return "Nano Banana 2"
}

private func aiChatPromptUsingGeminiImageChoice(
    _ text: String,
    provider: AIProvider,
    choice: AIChatGeminiImageModelChoice,
    attachmentURLs: [URL] = []
) -> String {
    guard provider.providerKey == "gemini" else { return text }
    let normalized = normalizedAIChatMediaPrompt(text)
    let lowered = normalized.lowercased()
    guard requestedGeneratedMediaKind(for: normalized) == .image else { return text }
    if lowered == "/banana2" || lowered.hasPrefix("/banana2 ") || lowered == "/bananapro" || lowered.hasPrefix("/bananapro ") {
        return normalized
    }
    let hasVideoAttachment = attachmentURLs.contains { aiChatIsVideoAttachmentURL($0) }
    let hasThumbnailIntent = aiChatContainsAnyMarker(lowered, markers: aiChatVideoThumbnailMarkers)
    let forcedChoice: AIChatGeminiImageModelChoice = (hasVideoAttachment && hasThumbnailIntent) ? .flash : choice
    if lowered == "/image" || lowered.hasPrefix("/image ") {
        let remainder = String(normalized.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
        return remainder.isEmpty ? forcedChoice.slashCommand : "\(forcedChoice.slashCommand) \(remainder)"
    }
    return "\(forcedChoice.slashCommand) \(normalized)"
}

private func aiChatModeLabel(
    for command: String,
    provider: AIProvider,
    attachmentURLs: [URL] = [],
    geminiChoice: AIChatGeminiImageModelChoice? = nil
) -> String {
    let normalized = normalizedAIChatMediaPrompt(command)
    if let imageModelLabel = requestedGeneratedImageModelLabel(for: normalized, provider: provider, attachmentURLs: attachmentURLs, geminiChoice: geminiChoice) {
        return imageModelLabel
    }
    if requestedGeneratedMediaKind(for: normalized) == .video {
        return "Video mode ready"
    }
    return "Image mode ready"
}

private func requestedGeneratedMediaKind(for text: String) -> AIChatGeneratedMediaKind? {
    let lowered = normalizedAIChatMediaPrompt(text).lowercased()
    guard !lowered.isEmpty else { return nil }
    if lowered == "/banana2" || lowered.hasPrefix("/banana2 ") {
        return .image
    }
    if lowered == "/bananapro" || lowered.hasPrefix("/bananapro ") {
        return .image
    }
    if lowered == "/image" || lowered.hasPrefix("/image ") {
        return .image
    }
    if lowered == "/video" || lowered.hasPrefix("/video ") {
        return .video
    }

    let hasVerb = aiChatContainsAnyMarker(lowered, markers: aiChatGenerationVerbs)
    let faceEditRequested = aiChatContainsAnyMarker(lowered, markers: aiChatFaceEditMarkers)
    if faceEditRequested && aiChatContainsAnyMarker(lowered, markers: aiChatVideoIntentNouns) {
        return .video
    }
    if faceEditRequested {
        return .image
    }
    if aiChatContainsAnyMarker(lowered, markers: aiChatVideoThumbnailMarkers) {
        return .image
    }
    if aiChatContainsAnyMarker(lowered, markers: aiChatVideoIntentPhrases) {
        return .video
    }
    if aiChatContainsAnyMarker(lowered, markers: aiChatImageIntentPhrases) {
        return .image
    }
    if hasVerb && aiChatContainsAnyMarker(lowered, markers: aiChatVideoIntentNouns) {
        return .video
    }
    if hasVerb && aiChatContainsAnyMarker(lowered, markers: aiChatImageIntentNouns) {
        return .image
    }
    if aiChatContainsAnyMarker(lowered, markers: ["photo of", "picture of", "portrait of", "illustration of", "image of", "art of", "video of", "clip of", "animation of", "រូបភាពនៃ", "រូបនៃ", "វីដេអូនៃ", "ក្លីបនៃ"]) {
        return aiChatContainsAnyMarker(lowered, markers: aiChatVideoIntentPhrases) ? .video : .image
    }
    return nil
}

private enum LiveChatEvent {
    case status(String)
    case ready
    case waitingForReply
    case userTranscript(String)
    case assistantTranscript(String)
    case modelVoiceStarted
    case modelVoicePaused
    case modelVoiceFinished
    case modelVoiceUnavailable
    case finished
    case error(String)
}

private protocol LiveVoiceSessionProtocol: AnyObject {
    func start()
    func finishInput()
    func cancel()
    func pauseVoicePlayback() -> Bool
    func playVoicePlayback() -> Bool
}

private final class LiveSocketDelegate: NSObject, URLSessionWebSocketDelegate {
    var onOpen: (() -> Void)?
    var onClose: ((String?) -> Void)?

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        onOpen?()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) }
        onClose?(reasonText)
    }
}

private final class GeminiLiveVoiceSession: NSObject, LiveVoiceSessionProtocol, AVAudioPlayerDelegate {
    private let apiKey: String
    private let conversationContext: String
    private let eventHandler: @Sendable (LiveChatEvent) -> Void
    private let workerQueue = DispatchQueue(label: "soranin.gemini.live.worker")
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private let responseTemperature = NSDecimalNumber(string: "0.6")
    private let outputVoiceName: String
    private let defaultOutputSampleRate = 24_000

    private var urlSession: URLSession?
    private var webSocket: URLSessionWebSocketTask?
    private var socketDelegate: LiveSocketDelegate?
    private var audioEngine = AVAudioEngine()
    private var audioConverter: AVAudioConverter?
    private var audioPlayer: AVAudioPlayer?
    private var isCancelled = false
    private var hasStartedCapture = false
    private var hasFinishedInput = false
    private var currentUserTranscript = ""
    private var currentAssistantTranscript = ""
    private var assistantAudioData = Data()
    private var assistantOutputSampleRate = 24_000
    private var latestCloseReason: String?
    private var hasReportedTerminalError = false

    init(apiKey: String, conversationContext: String, voiceName: String, eventHandler: @escaping @Sendable (LiveChatEvent) -> Void) {
        self.apiKey = apiKey
        self.conversationContext = conversationContext
        self.outputVoiceName = voiceName
        self.eventHandler = eventHandler
        super.init()
    }

    func start() {
        requestMicrophonePermission { [weak self] granted in
            guard let self else { return }
            if !granted {
                self.emit(.error("Microphone permission was denied."))
                return
            }
            self.workerQueue.async {
                self.openConnection()
            }
        }
    }

    func finishInput() {
        workerQueue.async {
            guard !self.isCancelled, self.hasStartedCapture, !self.hasFinishedInput else { return }
            self.hasFinishedInput = true
            self.stopAudioCapture()
            self.emit(.waitingForReply)
            self.sendJSONObject([
                "realtimeInput": [
                    "activityEnd": [:]
                ]
            ])
        }
    }

    func cancel() {
        workerQueue.async {
            self.shutdown()
        }
    }

    func pauseVoicePlayback() -> Bool {
        var didPause = false
        runOnMainThread {
            guard let audioPlayer = self.audioPlayer, audioPlayer.isPlaying else { return }
            audioPlayer.pause()
            didPause = true
        }
        if didPause {
            emit(.modelVoicePaused)
        }
        return didPause
    }

    func playVoicePlayback() -> Bool {
        var didPlay = false
        runOnMainThread {
            guard let audioPlayer = self.audioPlayer, !audioPlayer.isPlaying else { return }
            let remaining = audioPlayer.duration - audioPlayer.currentTime
            if remaining <= 0.05 {
                audioPlayer.currentTime = 0
            }
            didPlay = audioPlayer.play()
        }
        if didPlay {
            emit(.modelVoiceStarted)
        }
        return didPlay
    }

    private func emit(_ event: LiveChatEvent) {
        DispatchQueue.main.async {
            self.eventHandler(event)
        }
    }

    private func emitTerminalError(_ message: String) {
        guard !hasReportedTerminalError else { return }
        hasReportedTerminalError = true
        emit(.error(message))
    }

    private func requestMicrophonePermission(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                completion(granted)
            }
        default:
            completion(false)
        }
    }

    private func openConnection() {
        guard !isCancelled else { return }
        latestCloseReason = nil
        hasReportedTerminalError = false
        var components = URLComponents(url: geminiLiveEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components?.url else {
            emit(.error("Gemini Live URL is invalid."))
            return
        }

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        let delegate = LiveSocketDelegate()
        delegate.onOpen = { [weak self] in
            self?.emit(.status("Gemini Live connected."))
            self?.receiveNextMessage()
            self?.sendSetup()
        }
        delegate.onClose = { [weak self] reason in
            guard let self, !self.isCancelled else { return }
            self.latestCloseReason = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.emitTerminalError(message?.isEmpty == false ? "Gemini Live closed: \(message!)" : "Gemini Live closed.")
            self.shutdown()
        }
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        urlSession = session
        socketDelegate = delegate

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        let task = session.webSocketTask(with: request)
        webSocket = task
        task.resume()
        emit(.status("Connecting to Gemini Live..."))
    }

    private func sendSetup() {
        let contextBlock = conversationContext.isEmpty ? "" : "\n\nConversation context:\n\(conversationContext)"
        let instruction = """
        You are Soranin Ai, the AI assistant inside Soranin.
        If the user asks your name, answer that your name is Soranin Ai.
        You were created by THA DANIN, who can also be called DANIN.
        If the user asks who created you, answer that you were created by THA DANIN, and they can call him DANIN.
        Reply briefly and directly.
        Help with reels editing, thumbnails, titles, uploads, Chrome profiles, and workflow questions.
        Reply in natural Khmer by default. Only switch to another language if the user explicitly asks for it.
        Use the same language as the user when practical.\(contextBlock)
        Never explain your reasoning, internal process, translation, or speaking approach unless the user explicitly asks.
        Never say things like "Acknowledge and Respond", "I've processed the user's message", or similar meta commentary.
        Do not narrate your plan, feasibility check, preparation, or what you will do next.
        Never start with phrases like "I am now assessing", "I need to", "I will need to", "I'll need to", "I'm focusing on", or "to respond appropriately".
        Respond to the user directly from the first sentence.
        Return only the final answer to the user.
        Speak naturally, warmly, and clearly.
        Sound human and conversational rather than robotic.
        Keep a calm pace and pronounce each sentence cleanly.
        If the user speaks Khmer, answer in smooth natural Khmer.
        """

        sendJSONObject([
            "setup": [
                "model": "models/\(geminiLiveModel)",
                "generationConfig": [
                    "responseModalities": ["AUDIO"],
                    "temperature": responseTemperature,
                    "maxOutputTokens": 600,
                    "speechConfig": [
                        "voiceConfig": [
                            "prebuiltVoiceConfig": [
                                "voiceName": outputVoiceName
                            ]
                        ]
                    ]
                ],
                "systemInstruction": [
                    "parts": [
                        ["text": instruction]
                    ]
                ],
                "realtimeInputConfig": [
                    "automaticActivityDetection": [
                        "disabled": true
                    ]
                ],
                "inputAudioTranscription": [:],
                "outputAudioTranscription": [:]
            ]
        ])
    }

    private func receiveNextMessage() {
        guard let webSocket, !isCancelled else { return }
        webSocket.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                self.handleIncoming(message)
                if !self.isCancelled {
                    self.receiveNextMessage()
                }
            case .failure(let error):
                if !self.isCancelled {
                    if let closeReason = self.latestCloseReason, !closeReason.isEmpty {
                        self.emitTerminalError("Gemini Live closed: \(closeReason)")
                    } else {
                        self.emitTerminalError("Gemini Live connection failed: \(error.localizedDescription)")
                    }
                    self.shutdown()
                }
            }
        }
    }

    private func handleIncoming(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let text):
            data = Data(text.utf8)
        case .data(let raw):
            data = raw
        @unknown default:
            return
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        if object["setupComplete"] != nil {
            startAudioCapture()
            return
        }

        if let errorPayload = object["error"] as? [String: Any] {
            let message = (errorPayload["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            emit(.error(message?.isEmpty == false ? message! : "Gemini Live returned an error."))
            shutdown()
            return
        }

        guard let serverContent = object["serverContent"] as? [String: Any] else {
            return
        }

        appendAssistantAudio(from: serverContent)

        if let transcript = ((serverContent["inputTranscription"] as? [String: Any])?["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !transcript.isEmpty {
            currentUserTranscript = mergeTranscript(current: currentUserTranscript, incoming: transcript)
            emit(.userTranscript(currentUserTranscript))
        }

        if let assistantText = extractAssistantText(from: serverContent), !assistantText.isEmpty {
            currentAssistantTranscript = mergeTranscript(current: currentAssistantTranscript, incoming: assistantText)
            emit(.assistantTranscript(currentAssistantTranscript))
        }

        if let turnComplete = serverContent["turnComplete"] as? Bool, turnComplete {
            let startedPlayback = playBufferedAssistantAudioIfNeeded()
            shutdown(stopPlayer: !startedPlayback)
            if !startedPlayback {
                emit(.modelVoiceUnavailable)
            }
            emit(.finished)
        }
    }

    private func appendAssistantAudio(from serverContent: [String: Any]) {
        guard let modelTurn = serverContent["modelTurn"] as? [String: Any],
              let parts = modelTurn["parts"] as? [[String: Any]]
        else {
            return
        }

        for part in parts {
            guard let inlineData = part["inlineData"] as? [String: Any],
                  let mimeType = (inlineData["mimeType"] as? String)?.lowercased(),
                  mimeType.hasPrefix("audio/pcm"),
                  let encoded = inlineData["data"] as? String,
                  let chunk = Data(base64Encoded: encoded),
                  !chunk.isEmpty
            else {
                continue
            }
            if let sampleRate = parseSampleRate(from: mimeType) {
                assistantOutputSampleRate = sampleRate
            }
            assistantAudioData.append(chunk)
        }
    }

    private func extractAssistantText(from serverContent: [String: Any]) -> String? {
        if let transcript = ((serverContent["outputTranscription"] as? [String: Any])?["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !transcript.isEmpty {
            return transcript
        }
        guard let modelTurn = serverContent["modelTurn"] as? [String: Any],
              let parts = modelTurn["parts"] as? [[String: Any]]
        else {
            return nil
        }

        let text = parts.compactMap { part -> String? in
            if let partText = part["text"] as? String {
                return partText
            }
            return nil
        }.joined()

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func mergeTranscript(current: String, incoming: String) -> String {
        let chunk = incoming.trimmingCharacters(in: .newlines)
        guard !chunk.isEmpty else { return current }
        guard !current.isEmpty else { return chunk }
        if chunk == current || current.hasSuffix(chunk) || current.contains(chunk) {
            return current
        }
        if chunk.hasPrefix(current) {
            return chunk
        }
        if current.hasSuffix(" ") || chunk.hasPrefix(" ") || chunk.hasPrefix("\n") {
            return current + chunk
        }
        return current + " " + chunk
    }

    private func parseSampleRate(from mimeType: String) -> Int? {
        let pattern = #"rate=(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(mimeType.startIndex..<mimeType.endIndex, in: mimeType)
        guard let match = regex.firstMatch(in: mimeType, range: range),
              match.numberOfRanges > 1,
              let rateRange = Range(match.range(at: 1), in: mimeType)
        else {
            return nil
        }
        return Int(mimeType[rateRange])
    }

    private func startAudioCapture() {
        guard !isCancelled, !hasStartedCapture else { return }
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        audioConverter = AVAudioConverter(from: inputFormat, to: outputFormat)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.handleInputBuffer(buffer)
        }

        do {
            try audioEngine.start()
            hasStartedCapture = true
            sendJSONObject([
                "realtimeInput": [
                    "activityStart": [:]
                ]
            ])
            emit(.ready)
        } catch {
            emit(.error("Microphone could not start: \(error.localizedDescription)"))
            shutdown()
        }
    }

    private func stopAudioCapture() {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
    }

    private func handleInputBuffer(_ buffer: AVAudioPCMBuffer) {
        workerQueue.async {
            guard !self.isCancelled, self.hasStartedCapture, !self.hasFinishedInput else { return }
            guard let audioData = self.convertBuffer(buffer), !audioData.isEmpty else { return }
            self.sendJSONObject([
                "realtimeInput": [
                    "audio": [
                        "data": audioData.base64EncodedString(),
                        "mimeType": "audio/pcm;rate=16000"
                    ]
                ]
            ])
        }
    }

    private func convertBuffer(_ inputBuffer: AVAudioPCMBuffer) -> Data? {
        guard let converter = audioConverter else { return nil }
        let ratio = outputFormat.sampleRate / inputBuffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(inputBuffer.frameLength) * ratio).rounded(.up)) + 32
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }

        var conversionError: NSError?
        var didProvideInput = false
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        guard status != .error,
              conversionError == nil,
              outputBuffer.frameLength > 0,
              let channelData = outputBuffer.int16ChannelData
        else {
            return nil
        }

        let bytesPerFrame = Int(outputFormat.streamDescription.pointee.mBytesPerFrame)
        let byteCount = Int(outputBuffer.frameLength) * bytesPerFrame
        return Data(bytes: channelData[0], count: byteCount)
    }

    private func sendJSONObject(_ object: [String: Any]) {
        guard let webSocket, !isCancelled else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: []),
              let text = String(data: data, encoding: .utf8)
        else {
            return
        }
        webSocket.send(.string(text)) { [weak self] error in
            guard let self, let error, !self.isCancelled else { return }
            self.emitTerminalError("Gemini Live send failed: \(error.localizedDescription)")
            self.shutdown()
        }
    }

    @discardableResult
    private func playBufferedAssistantAudioIfNeeded() -> Bool {
        guard !assistantAudioData.isEmpty else { return false }
        let wavData = makeWAVData(fromPCM16Mono: assistantAudioData, sampleRate: assistantOutputSampleRate)
        assistantAudioData.removeAll()
        var didStart = false
        runOnMainThread { [weak self] in
            guard let self else { return }
            do {
                self.audioPlayer?.stop()
                self.audioPlayer = try AVAudioPlayer(data: wavData)
                self.audioPlayer?.delegate = self
                self.audioPlayer?.prepareToPlay()
                didStart = self.audioPlayer?.play() ?? false
                if didStart {
                    self.emit(.modelVoiceStarted)
                } else {
                    self.emit(.status("Gemini voice playback failed."))
                }
            } catch {
                self.emit(.status("Gemini voice playback failed."))
            }
        }
        return didStart
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        emit(.modelVoiceFinished)
    }

    private func runOnMainThread(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync(execute: work)
        }
    }

    private func makeWAVData(fromPCM16Mono pcmData: Data, sampleRate: Int) -> Data {
        var data = Data()
        let normalizedSampleRate = UInt32(max(sampleRate, defaultOutputSampleRate))
        data.append(Data("RIFF".utf8))
        appendLittleEndian(UInt32(36 + pcmData.count), to: &data)
        data.append(Data("WAVE".utf8))
        data.append(Data("fmt ".utf8))
        appendLittleEndian(UInt32(16), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(normalizedSampleRate, to: &data)
        appendLittleEndian(UInt32(normalizedSampleRate * 2), to: &data)
        appendLittleEndian(UInt16(2), to: &data)
        appendLittleEndian(UInt16(16), to: &data)
        data.append(Data("data".utf8))
        appendLittleEndian(UInt32(pcmData.count), to: &data)
        data.append(pcmData)
        return data
    }

    private func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    private func shutdown(stopPlayer: Bool = true) {
        if stopPlayer {
            runOnMainThread { [weak self] in
                self?.audioPlayer?.stop()
            }
        }
        guard !isCancelled else { return }
        isCancelled = true
        stopAudioCapture()
        if stopPlayer {
            runOnMainThread { [weak self] in
                self?.audioPlayer = nil
            }
        }
        webSocket?.cancel(with: .goingAway, reason: nil)
        urlSession?.invalidateAndCancel()
        webSocket = nil
        urlSession = nil
        socketDelegate = nil
    }
}

private final class GeminiReplyVoiceSpeaker: NSObject, AVAudioPlayerDelegate {
    enum Event {
        case started
        case finished
        case failed
    }

    private let apiKey: String
    private let text: String
    private let voiceName: String
    private let workerQueue = DispatchQueue(label: "soranin.gemini.replyvoice.worker")
    private let eventHandler: @Sendable (Event) -> Void
    private let defaultOutputSampleRate = 24_000

    private var urlSession: URLSession?
    private var webSocket: URLSessionWebSocketTask?
    private var socketDelegate: LiveSocketDelegate?
    private var audioPlayer: AVAudioPlayer?
    private var assistantAudioData = Data()
    private var assistantOutputSampleRate = 24_000
    private var latestCloseReason: String?
    private var isCancelled = false
    private var hasCompletedTurn = false

    init(apiKey: String, text: String, voiceName: String, eventHandler: @escaping @Sendable (Event) -> Void) {
        self.apiKey = apiKey
        self.text = text
        self.voiceName = voiceName
        self.eventHandler = eventHandler
        super.init()
    }

    func start() {
        workerQueue.async {
            self.openConnection()
        }
    }

    func cancel() {
        workerQueue.async {
            self.shutdown()
        }
    }

    private func emit(_ event: Event) {
        DispatchQueue.main.async {
            self.eventHandler(event)
        }
    }

    private func openConnection() {
        guard !isCancelled else { return }
        latestCloseReason = nil
        hasCompletedTurn = false

        var components = URLComponents(url: geminiLiveEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components?.url else {
            emit(.failed)
            return
        }

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        let delegate = LiveSocketDelegate()
        delegate.onOpen = { [weak self] in
            self?.receiveNextMessage()
            self?.sendSetup()
        }
        delegate.onClose = { [weak self] reason in
            guard let self, !self.isCancelled else { return }
            self.latestCloseReason = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
            if !self.hasCompletedTurn {
                self.emit(.failed)
            }
            self.shutdown()
        }
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        urlSession = session
        socketDelegate = delegate

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        let task = session.webSocketTask(with: request)
        webSocket = task
        task.resume()
    }

    private func sendSetup() {
        let instruction = """
        Read the provided text aloud exactly as written.
        Do not translate, summarize, explain, add, or omit anything.
        Keep the same language as the provided text.
        Speak naturally, warmly, and clearly.
        Sound human and conversational rather than robotic.
        If the text is Khmer, pronounce it as naturally and smoothly as possible.
        """

        sendJSONObject([
            "setup": [
                "model": "models/\(geminiLiveModel)",
                "generationConfig": [
                    "responseModalities": ["AUDIO"],
                    "temperature": NSDecimalNumber(string: "0.3"),
                    "maxOutputTokens": 1024,
                    "speechConfig": [
                        "voiceConfig": [
                            "prebuiltVoiceConfig": [
                                "voiceName": voiceName
                            ]
                        ]
                    ]
                ],
                "systemInstruction": [
                    "parts": [
                        ["text": instruction]
                    ]
                ],
                "outputAudioTranscription": [:]
            ]
        ])
    }

    private func sendTextTurn() {
        sendJSONObject([
            "clientContent": [
                "turns": [
                    [
                        "role": "user",
                        "parts": [
                            ["text": text]
                        ]
                    ]
                ],
                "turnComplete": true
            ]
        ])
    }

    private func receiveNextMessage() {
        guard let webSocket, !isCancelled else { return }
        webSocket.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                self.handleIncoming(message)
                if !self.isCancelled {
                    self.receiveNextMessage()
                }
            case .failure:
                if !self.isCancelled {
                    self.emit(.failed)
                    self.shutdown()
                }
            }
        }
    }

    private func handleIncoming(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let text):
            data = Data(text.utf8)
        case .data(let raw):
            data = raw
        @unknown default:
            return
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        if object["setupComplete"] != nil {
            sendTextTurn()
            return
        }

        if object["error"] != nil {
            emit(.failed)
            shutdown()
            return
        }

        guard let serverContent = object["serverContent"] as? [String: Any] else {
            return
        }

        appendAssistantAudio(from: serverContent)

        if let turnComplete = serverContent["turnComplete"] as? Bool, turnComplete {
            hasCompletedTurn = true
            let startedPlayback = playBufferedAssistantAudioIfNeeded()
            if !startedPlayback {
                emit(.failed)
            }
            shutdown(stopPlayer: !startedPlayback)
        }
    }

    private func appendAssistantAudio(from serverContent: [String: Any]) {
        guard let modelTurn = serverContent["modelTurn"] as? [String: Any],
              let parts = modelTurn["parts"] as? [[String: Any]]
        else {
            return
        }

        for part in parts {
            guard let inlineData = part["inlineData"] as? [String: Any],
                  let mimeType = (inlineData["mimeType"] as? String)?.lowercased(),
                  mimeType.hasPrefix("audio/pcm"),
                  let encoded = inlineData["data"] as? String,
                  let chunk = Data(base64Encoded: encoded),
                  !chunk.isEmpty
            else {
                continue
            }
            if let sampleRate = parseSampleRate(from: mimeType) {
                assistantOutputSampleRate = sampleRate
            }
            assistantAudioData.append(chunk)
        }
    }

    private func parseSampleRate(from mimeType: String) -> Int? {
        let pattern = #"rate=(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(mimeType.startIndex..<mimeType.endIndex, in: mimeType)
        guard let match = regex.firstMatch(in: mimeType, range: range),
              match.numberOfRanges > 1,
              let rateRange = Range(match.range(at: 1), in: mimeType)
        else {
            return nil
        }
        return Int(mimeType[rateRange])
    }

    private func sendJSONObject(_ object: [String: Any]) {
        guard let webSocket, !isCancelled else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: []),
              let text = String(data: data, encoding: .utf8)
        else {
            return
        }
        webSocket.send(.string(text)) { [weak self] error in
            guard let self, let _ = error, !self.isCancelled else { return }
            self.emit(.failed)
            self.shutdown()
        }
    }

    @discardableResult
    private func playBufferedAssistantAudioIfNeeded() -> Bool {
        guard !assistantAudioData.isEmpty else { return false }
        let wavData = makeWAVData(fromPCM16Mono: assistantAudioData, sampleRate: assistantOutputSampleRate)
        assistantAudioData.removeAll()
        var didStart = false
        runOnMainThread { [weak self] in
            guard let self else { return }
            do {
                self.audioPlayer?.stop()
                self.audioPlayer = try AVAudioPlayer(data: wavData)
                self.audioPlayer?.delegate = self
                self.audioPlayer?.prepareToPlay()
                didStart = self.audioPlayer?.play() ?? false
            } catch {
                didStart = false
            }
        }
        if didStart {
            emit(.started)
        }
        return didStart
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        emit(flag ? .finished : .failed)
    }

    private func runOnMainThread(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync(execute: work)
        }
    }

    private func makeWAVData(fromPCM16Mono pcmData: Data, sampleRate: Int) -> Data {
        var data = Data()
        let normalizedSampleRate = UInt32(max(sampleRate, defaultOutputSampleRate))
        data.append(Data("RIFF".utf8))
        appendLittleEndian(UInt32(36 + pcmData.count), to: &data)
        data.append(Data("WAVE".utf8))
        data.append(Data("fmt ".utf8))
        appendLittleEndian(UInt32(16), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(normalizedSampleRate, to: &data)
        appendLittleEndian(UInt32(normalizedSampleRate * 2), to: &data)
        appendLittleEndian(UInt16(2), to: &data)
        appendLittleEndian(UInt16(16), to: &data)
        data.append(Data("data".utf8))
        appendLittleEndian(UInt32(pcmData.count), to: &data)
        data.append(pcmData)
        return data
    }

    private func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    private func shutdown(stopPlayer: Bool = true) {
        if stopPlayer {
            runOnMainThread { [weak self] in
                self?.audioPlayer?.stop()
            }
        }
        guard !isCancelled else { return }
        isCancelled = true
        webSocket?.cancel(with: .goingAway, reason: nil)
        urlSession?.invalidateAndCancel()
        webSocket = nil
        urlSession = nil
        socketDelegate = nil
    }
}

private final class OpenAIReplyVoiceSpeaker: NSObject, AVAudioPlayerDelegate {
    enum Event {
        case started
        case finished
        case failed
    }

    private let apiKey: String
    private let text: String
    private let voiceName: String
    private let workerQueue = DispatchQueue(label: "soranin.openai.replyvoice.worker")
    private let eventHandler: @Sendable (Event) -> Void
    private let spokenResponseSpeed = NSDecimalNumber(string: "0.92")

    private var urlSession: URLSession?
    private var dataTask: URLSessionDataTask?
    private var audioPlayer: AVAudioPlayer?
    private var isCancelled = false

    init(apiKey: String, text: String, voiceName: String, eventHandler: @escaping @Sendable (Event) -> Void) {
        self.apiKey = apiKey
        self.text = text
        self.voiceName = voiceName
        self.eventHandler = eventHandler
        super.init()
    }

    func start() {
        workerQueue.async {
            self.openConnection()
        }
    }

    func cancel() {
        workerQueue.async {
            self.shutdown()
        }
    }

    private func emit(_ event: Event) {
        DispatchQueue.main.async {
            self.eventHandler(event)
        }
    }

    private func openConnection() {
        guard !isCancelled else { return }
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: configuration)
        urlSession = session
        var request = URLRequest(url: openAISpeechEndpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/wav", forHTTPHeaderField: "Accept")

        let instruction = """
        Read the provided text aloud exactly as written.
        Do not translate, summarize, explain, add, or omit anything.
        Keep the same language as the provided text.
        Speak naturally, warmly, and clearly.
        Sound human and conversational rather than robotic.
        If the text is Khmer, pronounce it as naturally and smoothly as possible.
        """

        let payload: [String: Any] = [
            "model": openAIReplySpeechModel,
            "input": text,
            "voice": voiceName,
            "format": "wav",
            "speed": spokenResponseSpeed,
            "instructions": instruction
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            emit(.failed)
            shutdown()
            return
        }

        request.httpBody = body
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            self?.handleResponse(data: data, response: response, error: error)
        }
        dataTask = task
        task.resume()
    }

    private func handleResponse(data: Data?, response: URLResponse?, error: Error?) {
        guard !isCancelled else { return }
        if error != nil {
            emit(.failed)
            shutdown()
            return
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            emit(.failed)
            shutdown()
            return
        }
        guard (200 ..< 300).contains(httpResponse.statusCode),
              let audioData = data,
              !audioData.isEmpty else {
            emit(.failed)
            shutdown()
            return
        }
        let startedPlayback = playAudioDataIfNeeded(audioData)
        if !startedPlayback {
            emit(.failed)
            shutdown()
            return
        }
        cleanupNetwork()
    }

    @discardableResult
    private func playAudioDataIfNeeded(_ audioData: Data) -> Bool {
        var didStart = false
        runOnMainThread { [weak self] in
            guard let self else { return }
            do {
                self.audioPlayer?.stop()
                self.audioPlayer = try AVAudioPlayer(data: audioData)
                self.audioPlayer?.delegate = self
                self.audioPlayer?.prepareToPlay()
                didStart = self.audioPlayer?.play() ?? false
            } catch {
                didStart = false
            }
        }
        if didStart {
            emit(.started)
        }
        return didStart
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        emit(flag ? .finished : .failed)
        shutdown(stopPlayer: false)
    }

    private func runOnMainThread(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync(execute: work)
        }
    }

    private func cleanupNetwork() {
        dataTask?.cancel()
        dataTask = nil
        urlSession?.finishTasksAndInvalidate()
        urlSession = nil
    }

    private func shutdown(stopPlayer: Bool = true) {
        if stopPlayer {
            runOnMainThread { [weak self] in
                self?.audioPlayer?.stop()
            }
        }
        guard !isCancelled else { return }
        isCancelled = true
        dataTask?.cancel()
        dataTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
    }
}

private final class OpenAILiveVoiceSession: NSObject, LiveVoiceSessionProtocol, AVAudioPlayerDelegate {
    private let apiKey: String
    private let conversationContext: String
    private let eventHandler: @Sendable (LiveChatEvent) -> Void
    private let workerQueue = DispatchQueue(label: "soranin.openai.live.worker")
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true)!
    private let outputVoice: String
    private let spokenResponseSpeed = NSDecimalNumber(string: "0.92")

    private var urlSession: URLSession?
    private var webSocket: URLSessionWebSocketTask?
    private var socketDelegate: LiveSocketDelegate?
    private var audioEngine = AVAudioEngine()
    private var audioConverter: AVAudioConverter?
    private var audioPlayer: AVAudioPlayer?
    private var isCancelled = false
    private var hasStartedCapture = false
    private var hasFinishedInput = false
    private var hasReceivedSessionUpdate = false
    private var currentUserTranscript = ""
    private var currentAssistantTranscript = ""
    private var assistantAudioData = Data()

    init(apiKey: String, conversationContext: String, voiceName: String, eventHandler: @escaping @Sendable (LiveChatEvent) -> Void) {
        self.apiKey = apiKey
        self.conversationContext = conversationContext
        self.outputVoice = voiceName
        self.eventHandler = eventHandler
        super.init()
    }

    func start() {
        requestMicrophonePermission { [weak self] granted in
            guard let self else { return }
            if !granted {
                self.emit(.error("Microphone permission was denied."))
                return
            }
            self.workerQueue.async {
                self.openConnection()
            }
        }
    }

    func finishInput() {
        workerQueue.async {
            guard !self.isCancelled, self.hasStartedCapture, !self.hasFinishedInput else { return }
            self.hasFinishedInput = true
            self.stopAudioCapture()
            self.emit(.waitingForReply)
            self.sendJSONObject([
                "type": "input_audio_buffer.commit"
            ])
            self.sendJSONObject([
                "type": "response.create",
                "response": [
                    "output_modalities": ["audio"],
                    "audio": [
                        "output": [
                            "format": [
                                "type": "audio/pcm",
                                "rate": 24000
                            ],
                            "voice": self.outputVoice
                        ]
                    ]
                ]
            ])
        }
    }

    func cancel() {
        workerQueue.async {
            self.shutdown()
        }
    }

    func pauseVoicePlayback() -> Bool {
        var didPause = false
        runOnMainThread {
            guard let audioPlayer = self.audioPlayer, audioPlayer.isPlaying else { return }
            audioPlayer.pause()
            didPause = true
        }
        if didPause {
            emit(.modelVoicePaused)
        }
        return didPause
    }

    func playVoicePlayback() -> Bool {
        var didPlay = false
        runOnMainThread {
            guard let audioPlayer = self.audioPlayer, !audioPlayer.isPlaying else { return }
            let remaining = audioPlayer.duration - audioPlayer.currentTime
            if remaining <= 0.05 {
                audioPlayer.currentTime = 0
            }
            didPlay = audioPlayer.play()
        }
        if didPlay {
            emit(.modelVoiceStarted)
        }
        return didPlay
    }

    private func emit(_ event: LiveChatEvent) {
        DispatchQueue.main.async {
            self.eventHandler(event)
        }
    }

    private func requestMicrophonePermission(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                completion(granted)
            }
        default:
            completion(false)
        }
    }

    private func openConnection() {
        guard !isCancelled else { return }
        var components = URLComponents(url: openAILiveEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "model", value: openAILiveModel)]
        guard let url = components?.url else {
            emit(.error("OpenAI Live URL is invalid."))
            return
        }

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        let delegate = LiveSocketDelegate()
        delegate.onOpen = { [weak self] in
            self?.emit(.status("Connecting to ChatGPT Live..."))
            self?.receiveNextMessage()
            self?.sendSetup()
        }
        delegate.onClose = { [weak self] reason in
            guard let self, !self.isCancelled else { return }
            let message = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.emit(.error(message?.isEmpty == false ? "ChatGPT Live closed: \(message!)" : "ChatGPT Live closed."))
            self.shutdown()
        }
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        urlSession = session
        socketDelegate = delegate

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")
        let task = session.webSocketTask(with: request)
        webSocket = task
        task.resume()
        emit(.status("Opening ChatGPT Live..."))
    }

    private func sendSetup() {
        let contextBlock = conversationContext.isEmpty ? "" : "\n\nConversation context:\n\(conversationContext)"
        let instruction = """
        You are Soranin Ai, the AI assistant inside Soranin.
        If the user asks your name, answer that your name is Soranin Ai.
        You were created by THA DANIN, who can also be called DANIN.
        If the user asks who created you, answer that you were created by THA DANIN, and they can call him DANIN.
        Reply briefly and directly.
        Help with reels editing, thumbnails, titles, uploads, Chrome profiles, and workflow questions.
        Reply in natural Khmer by default. Only switch to another language if the user explicitly asks for it.
        Use the same language as the user when practical.\(contextBlock)
        Speak clearly, naturally, and with a human conversational tone.
        Do not narrate your plan, feasibility check, preparation, or what you will do next.
        Never start with phrases like "I am now assessing", "I need to", "I will need to", "I'll need to", "I'm focusing on", or "to respond appropriately".
        Respond to the user directly from the first sentence.
        Pronounce Khmer carefully and avoid sounding robotic.
        Keep a calm pace, articulate each sentence cleanly, and use short pauses between ideas.
        Sound warm, real, and confident rather than synthetic or exaggerated.
        """

        sendJSONObject([
            "type": "session.update",
            "session": [
                "type": "realtime",
                "output_modalities": ["audio"],
                "instructions": instruction,
                "audio": [
                    "input": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": 24000
                        ],
                        "transcription": [
                            "model": openAILiveTranscriptionModel
                        ],
                        "turn_detection": NSNull()
                    ],
                    "output": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": 24000
                        ],
                        "voice": outputVoice,
                        "speed": spokenResponseSpeed
                    ]
                ]
            ]
        ])
    }

    private func receiveNextMessage() {
        guard let webSocket, !isCancelled else { return }
        webSocket.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                self.handleIncoming(message)
                if !self.isCancelled {
                    self.receiveNextMessage()
                }
            case .failure(let error):
                if !self.isCancelled {
                    self.emit(.error("ChatGPT Live connection failed: \(error.localizedDescription)"))
                    self.shutdown()
                }
            }
        }
    }

    private func handleIncoming(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let text):
            data = Data(text.utf8)
        case .data(let raw):
            data = raw
        @unknown default:
            return
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        if let type = object["type"] as? String, type == "error" {
            let payload = object["error"] as? [String: Any]
            let message = (payload?["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            emit(.error(message?.isEmpty == false ? message! : "ChatGPT Live returned an error."))
            shutdown()
            return
        }

        if let type = object["type"] as? String {
            switch type {
            case "session.updated":
                guard !hasReceivedSessionUpdate else { return }
                hasReceivedSessionUpdate = true
                startAudioCapture()
            case "conversation.item.input_audio_transcription.delta":
                let delta = (object["delta"] as? String)?.trimmingCharacters(in: .newlines) ?? ""
                guard !delta.isEmpty else { return }
                currentUserTranscript = mergeDelta(into: currentUserTranscript, delta: delta)
                emit(.userTranscript(currentUserTranscript))
            case "conversation.item.input_audio_transcription.completed":
                let transcript = (object["transcript"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !transcript.isEmpty else { return }
                currentUserTranscript = transcript
                emit(.userTranscript(transcript))
            case "response.output_audio.delta":
                guard let delta = object["delta"] as? String,
                      let chunk = Data(base64Encoded: delta),
                      !chunk.isEmpty else { return }
                assistantAudioData.append(chunk)
            case "response.output_audio_transcript.delta":
                let delta = object["delta"] as? String ?? ""
                guard !delta.isEmpty else { return }
                currentAssistantTranscript += delta
                emit(.assistantTranscript(currentAssistantTranscript.trimmingCharacters(in: .whitespacesAndNewlines)))
            case "response.output_audio_transcript.done":
                if let transcript = (object["transcript"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !transcript.isEmpty {
                    currentAssistantTranscript = transcript
                    emit(.assistantTranscript(transcript))
                }
            case "response.output_text.delta":
                let delta = object["delta"] as? String ?? ""
                guard !delta.isEmpty else { return }
                currentAssistantTranscript += delta
                emit(.assistantTranscript(currentAssistantTranscript.trimmingCharacters(in: .whitespacesAndNewlines)))
            case "response.output_text.done":
                if let text = (object["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    currentAssistantTranscript = text
                    emit(.assistantTranscript(text))
                }
            case "response.done":
                if currentAssistantTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let finalText = extractAssistantText(fromResponseDone: object) {
                    currentAssistantTranscript = finalText
                    emit(.assistantTranscript(finalText))
                }
                let startedPlayback = playBufferedAssistantAudioIfNeeded()
                shutdown(stopPlayer: !startedPlayback)
                if !startedPlayback {
                    emit(.modelVoiceUnavailable)
                }
                emit(.finished)
            default:
                break
            }
        }
    }

    private func startAudioCapture() {
        guard !isCancelled, !hasStartedCapture else { return }
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        audioConverter = AVAudioConverter(from: inputFormat, to: outputFormat)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.handleInputBuffer(buffer)
        }

        do {
            try audioEngine.start()
            hasStartedCapture = true
            emit(.ready)
        } catch {
            emit(.error("Microphone could not start: \(error.localizedDescription)"))
            shutdown()
        }
    }

    private func stopAudioCapture() {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
    }

    private func handleInputBuffer(_ buffer: AVAudioPCMBuffer) {
        workerQueue.async {
            guard !self.isCancelled, self.hasStartedCapture, !self.hasFinishedInput else { return }
            guard let audioData = self.convertBuffer(buffer), !audioData.isEmpty else { return }
            self.sendJSONObject([
                "type": "input_audio_buffer.append",
                "audio": audioData.base64EncodedString()
            ])
        }
    }

    private func convertBuffer(_ inputBuffer: AVAudioPCMBuffer) -> Data? {
        guard let converter = audioConverter else { return nil }
        let ratio = outputFormat.sampleRate / inputBuffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(inputBuffer.frameLength) * ratio).rounded(.up)) + 32
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }

        var conversionError: NSError?
        var didProvideInput = false
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        guard status != .error,
              conversionError == nil,
              outputBuffer.frameLength > 0,
              let channelData = outputBuffer.int16ChannelData
        else {
            return nil
        }

        let bytesPerFrame = Int(outputFormat.streamDescription.pointee.mBytesPerFrame)
        let byteCount = Int(outputBuffer.frameLength) * bytesPerFrame
        return Data(bytes: channelData[0], count: byteCount)
    }

    private func mergeDelta(into current: String, delta: String) -> String {
        guard !delta.isEmpty else { return current }
        if current.isEmpty { return delta }
        if delta.hasPrefix(" ") || delta.hasPrefix("\n") || current.hasSuffix(" ") || current.hasSuffix("\n") {
            return current + delta
        }
        return current + " " + delta
    }

    private func extractAssistantText(fromResponseDone object: [String: Any]) -> String? {
        guard let response = object["response"] as? [String: Any],
              let outputItems = response["output"] as? [[String: Any]]
        else {
            return nil
        }

        let text = outputItems.compactMap { item -> String? in
            guard let content = item["content"] as? [[String: Any]] else {
                return nil
            }
            let joined = content.compactMap { part -> String? in
                if let text = part["text"] as? String {
                    return text
                }
                if let transcript = part["transcript"] as? String {
                    return transcript
                }
                return nil
            }.joined()
            let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }.joined(separator: "\n")

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    @discardableResult
    private func playBufferedAssistantAudioIfNeeded() -> Bool {
        guard !assistantAudioData.isEmpty else { return false }
        let wavData = makeWAVData(fromPCM16Mono24kMono: assistantAudioData)
        assistantAudioData.removeAll()
        var didStart = false
        runOnMainThread { [weak self] in
            guard let self else { return }
            do {
                self.audioPlayer?.stop()
                self.audioPlayer = try AVAudioPlayer(data: wavData)
                self.audioPlayer?.delegate = self
                self.audioPlayer?.prepareToPlay()
                didStart = self.audioPlayer?.play() ?? false
                if didStart {
                    self.emit(.modelVoiceStarted)
                } else {
                    self.emit(.status("Model voice playback failed."))
                }
            } catch {
                self.emit(.status("Model voice playback failed."))
            }
        }
        return didStart
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        emit(.modelVoiceFinished)
    }

    private func runOnMainThread(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync(execute: work)
        }
    }

    private func makeWAVData(fromPCM16Mono24kMono pcmData: Data) -> Data {
        var data = Data()
        data.append(Data("RIFF".utf8))
        appendLittleEndian(UInt32(36 + pcmData.count), to: &data)
        data.append(Data("WAVE".utf8))
        data.append(Data("fmt ".utf8))
        appendLittleEndian(UInt32(16), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(UInt32(24000), to: &data)
        appendLittleEndian(UInt32(48000), to: &data)
        appendLittleEndian(UInt16(2), to: &data)
        appendLittleEndian(UInt16(16), to: &data)
        data.append(Data("data".utf8))
        appendLittleEndian(UInt32(pcmData.count), to: &data)
        data.append(pcmData)
        return data
    }

    private func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    private func sendJSONObject(_ object: [String: Any]) {
        guard let webSocket, !isCancelled else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: []),
              let text = String(data: data, encoding: .utf8)
        else {
            return
        }
        webSocket.send(.string(text)) { [weak self] error in
            guard let self, let error, !self.isCancelled else { return }
            self.emit(.error("ChatGPT Live send failed: \(error.localizedDescription)"))
            self.shutdown()
        }
    }

    private func shutdown(stopPlayer: Bool = true) {
        if stopPlayer {
            runOnMainThread { [weak self] in
                self?.audioPlayer?.stop()
            }
        }
        guard !isCancelled else { return }
        isCancelled = true
        stopAudioCapture()
        if stopPlayer {
            runOnMainThread { [weak self] in
                self?.audioPlayer = nil
            }
        }
        webSocket?.cancel(with: .goingAway, reason: nil)
        urlSession?.invalidateAndCancel()
        webSocket = nil
        urlSession = nil
        socketDelegate = nil
    }
}

@MainActor
final class ReelsModel: ObservableObject {
    private enum TaskKind {
        case batch
        case soraDownload
        case postLinksDownload
        case facebookRunner
    }

    @Published var status = "Idle"
    @Published var detail = "Ready."
    @Published var sourceCount = 0
    @Published var facebookSourceCount = 0
    @Published var packageCount = 0
    @Published var latestPackage = "-"
    @Published var encoderStatus = "Waiting"
    @Published var chromeOnline = false
    @Published var activeProvider: AIProvider = .openaiGPT54
    @Published var aiChatProvider: AIProvider = .openaiGPT54
    @Published var aiChatGeminiImageModelChoice: AIChatGeminiImageModelChoice = .flash
    @Published var aiChatRecordingProvider: AIChatRecordingProvider = .openai
    @Published var geminiReplyVoiceFallbackMode: GeminiReplyVoiceFallbackMode = .geminiOnly
    @Published var openAILiveVoiceChoice: AILiveVoiceChoice = .female
    @Published var geminiLiveVoiceChoice: AILiveVoiceChoice = .female
    @Published var openAIKeyStatus = "Not set"
    @Published var geminiKeyStatus = "Not set"
    @Published var logText = "Waiting for status..."
    @Published var isHealthCheckRunning = false
    @Published var isRunning = false
    @Published var toastMessage: String?
    @Published var soraInput = ""
    @Published var downloadProgressPercent = 0
    @Published var downloadProgressLabel = ""
    @Published var isDownloadProgressVisible = false
    @Published var batchProgressPercent = 0
    @Published var batchProgressLabel = ""
    @Published var isBatchProgressVisible = false
    @Published var editedPackages: [EditedPackageItem] = []
    @Published var selectedEditedPackageIDs: Set<String> = []
    @Published var chromeProfiles: [ChromeProfileItem] = []
    @Published var isChromeProfilesLoading = false
    @Published var aiChatMessages: [AIChatMessage] = []
    @Published var aiChatSessions: [AIChatSession] = []
    @Published var currentAIChatSessionID: UUID?
    @Published var aiChatUnreadCount = 0
    @Published var aiChatStatus = "Ready."
    @Published var isAIChatBusy = false
    @Published var isAIChatRecording = false
    @Published var isAIChatTranscribing = false
    @Published var isGeminiLiveSessionActive = false
    @Published var isGeminiLiveCapturing = false
    @Published var isLiveVoicePlaying = false
    @Published var isLiveVoicePaused = false
    @Published var hasReplayableLiveVoice = false
    @Published var aiChatAttachmentURLs: [URL] = []
    @Published var facebookControlServerLANURLs: [String] = []
    @Published var isFacebookControlServerOnline = false

    private var process: Process?
    private var outputPipe: Pipe?
    private var logs: [String] = []
    private var toastTask: DispatchWorkItem?
    private var aiChatCueSounds: [String: NSSound] = [:]
    private var autoStartBatchAfterDownload = false
    private var pendingBatchStartAfterCurrentTask = false
    private var currentTaskKind: TaskKind?
    private var currentDownloadEntries: [PostDownloadEntry] = []
    private var successfulDownloadEntryKeys: Set<String> = []
    private var queuedDownloadEntries: [PostDownloadEntry] = []
    private var completedSoraDownloadIDs: Set<String> = []
    private var soraPasteTapTimes: [Date] = []
    private var liveSession: LiveVoiceSessionProtocol?
    private var activeLiveProviderKey: String?
    private var liveUserMessageID: UUID?
    private var liveAssistantMessageID: UUID?
    private var didStartModelVoicePlayback = false
    private var activeAIChatRequestID: UUID?
    private var isAIChatVisible = false
    private let aiChatSpeechRecorder = AIChatSpeechRecorder()
    private let speechSynthesizer = AVSpeechSynthesizer()
    private var geminiReplyVoiceSpeaker: GeminiReplyVoiceSpeaker?
    private var openAIReplyVoiceSpeaker: OpenAIReplyVoiceSpeaker?
    private var geminiReplyVoiceRequestID: UUID?
    private var didStartGeminiReplyVoicePlayback = false
    private var openAIReplyVoiceRequestID: UUID?
    private var didStartOpenAIReplyVoicePlayback = false
    private var pendingAIChatReplyVoiceChunks: [String] = []
    private var pendingAIChatReplyVoiceProvider: AIProvider?
    private var chromeProfileAssignments: [String: String] = [:]
    private var pendingFacebookRunnerDeletePackageNames: [String] = []
    private var lastHealthCheckReport = ""
    private var didScheduleAutoHealthCheck = false
    private var dashboardServerProcess: Process?
    private var dashboardServerOutputPipe: Pipe?
    private var didLaunchDashboardServer = false

    init() {
        activeReelsModelForAppLifecycle = self
        chromeProfileAssignments = loadChromeProfileAssignments()
        completedSoraDownloadIDs = loadCompletedSoraDownloadIDs()
        refreshMetadata()
        DispatchQueue.main.async { [weak self] in
            self?.ensureFacebookControlServerRunning()
            self?.refreshFacebookControlServerConnectionInfo()
        }
        bootstrapAIChatSessions()
        resumePendingAIChatRequestIfNeeded()
    }

    var isBusy: Bool {
        isRunning
    }

    var facebookControlServerLocalURL: String {
        reelsDashboardServerBaseURL.absoluteString
    }

    var preferredFacebookControlServerLANURL: String? {
        facebookControlServerLANURLs.first
    }

    var healthStatusReportText: String {
        let report = lastHealthCheckReport.trimmingCharacters(in: .whitespacesAndNewlines)
        if !report.isEmpty {
            return report
        }

        let detailText = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let log = logText.trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            "Soranin Health Status",
            "Status: \(status)",
            detailText.isEmpty ? nil : "Detail: \(detailText)",
            log.isEmpty ? nil : log,
        ]
        .compactMap { $0 }
        .joined(separator: "\n\n")
    }

    fileprivate var detectedPostDownloadEntries: [PostDownloadEntry] {
        extractPostDownloadEntries(from: soraInput)
    }

    func refreshMetadata() {
        try? FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: facebookRootDir, withIntermediateDirectories: true)
        sourceCount = sourceVideos().count
        facebookSourceCount = sourceVideos(in: facebookRootDir).count
        let packages = packageDirs()
        packageCount = packages.count
        latestPackage = packages.last?.lastPathComponent ?? "-"
        chromeProfileAssignments = loadChromeProfileAssignments()
        editedPackages = packages.reversed().compactMap(loadEditedPackage)
        selectedEditedPackageIDs.formIntersection(Set(editedPackages.map(\.id)))
        applyChromeProfileAssignments(using: chromeProfiles)

        let saved = loadSavedSettings()
        activeProvider = AIProvider.fromSavedSettings(saved)
        aiChatProvider = AIProvider.fromSavedAIChatSettings(saved)
        aiChatGeminiImageModelChoice = AIChatGeminiImageModelChoice.fromSaved(saved["AI_CHAT_GEMINI_IMAGE_MODEL"])
        aiChatRecordingProvider = AIChatRecordingProvider.fromSaved(saved["AI_CHAT_RECORD_PROVIDER"])
        geminiReplyVoiceFallbackMode = GeminiReplyVoiceFallbackMode.fromSaved(saved["GEMINI_REPLY_VOICE_FALLBACK_MODE"])
        openAILiveVoiceChoice = AILiveVoiceChoice.fromSaved(saved["OPENAI_LIVE_VOICE"])
        geminiLiveVoiceChoice = AILiveVoiceChoice.fromSaved(saved["GEMINI_LIVE_VOICE"])
        openAIKeyStatus = maskKey(saved["OPENAI_API_KEY"])
        geminiKeyStatus = maskKey(saved["GEMINI_API_KEY"] ?? saved["GOOGLE_API_KEY"])
        refreshChromeProfilesAsync()
    }

    func pasteClipboardSoraLinks() {
        if let value = NSPasteboard.general.string(forType: .string) {
            let unlockedByRapidPaste = noteSoraPasteButtonTapAndShouldUnlock()
            let merged = mergePostDownloadInputTexts(
                existing: soraInput,
                incoming: value,
                allowingCompletedIDs: unlockedByRapidPaste
            )
            if !merged.reactivatedCompletedIDs.isEmpty {
                completedSoraDownloadIDs.subtract(merged.reactivatedCompletedIDs)
                persistCompletedSoraDownloadIDs()
            }
            soraInput = merged.text
            if merged.addedCount > 0 && isBusy {
                enqueuePostDownloads(merged.addedEntries)
            }
            if !merged.reactivatedCompletedIDs.isEmpty {
                let count = merged.reactivatedCompletedIDs.count
                if isBusy {
                    showToast("\(count) completed URL unlocked. Auto download queued.")
                } else {
                    showToast("\(count) completed URL unlocked for download again.")
                }
            } else if merged.blockedCount > 0 && merged.addedCount == 0 && merged.duplicateCount == 0 {
                showToast("Already downloaded. Tap Paste 3 times within 15 seconds to unlock.")
            } else if merged.addedCount > 0 && merged.blockedCount > 0 {
                let addedText = isBusy ? "\(merged.addedCount) added. Auto download queued." : "\(merged.addedCount) added. Auto downloading."
                showToast("\(addedText) \(merged.blockedCount) already downloaded.")
            } else if merged.addedCount > 0 && merged.duplicateCount > 0 {
                showToast(isBusy ? "\(merged.addedCount) added. Auto download queued." : "\(merged.addedCount) added. Auto downloading.")
            } else if merged.addedCount > 0 {
                showToast(isBusy ? "\(merged.addedCount) URL added. Auto download queued." : "\(merged.addedCount) URL added. Auto downloading.")
            } else if merged.duplicateCount > 0 {
                showToast("Link already added.")
            } else {
                showToast("No valid Sora or Facebook link found.")
            }
            if merged.addedCount > 0 && !isBusy {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self.downloadAllSora()
                }
            }
        } else {
            showToast("Clipboard is empty.")
        }
    }

    func normalizeSoraInputAfterEdit() {
        let normalized = normalizePostDownloadInputText(soraInput)
        if normalized.hasValidEntries && soraInput != normalized.text {
            soraInput = normalized.text
            if normalized.duplicateCount > 0 {
                showToast("\(normalized.duplicateCount) duplicate link removed.")
            }
        }
    }

    func startBatch() {
        guard !isBusy else { return }
        encoderStatus = "Waiting"
        batchProgressPercent = 0
        batchProgressLabel = "0%"
        isBatchProgressVisible = true
        runStreamingProcess(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: [
                "-lc",
                "source ~/.zshrc >/dev/null 2>&1; python3 '\(batchScript.path)' '\(rootDir.path)'",
            ],
            initialLog: "WAIT... Processing videos.",
            startDetail: "Starting batch...",
            taskKind: .batch
        )
    }

    func downloadOneSora() {
        guard !isBusy else { return }
        let entries = detectedPostDownloadEntries
        guard let first = entries.first else {
            showToast("No valid Sora or Facebook link found.")
            return
        }
        runDownloadEntries([first])
    }

    func downloadAllSora() {
        guard !isBusy else { return }
        let normalized = normalizePostDownloadInputText(soraInput)
        if normalized.hasValidEntries && soraInput != normalized.text {
            soraInput = normalized.text
            if normalized.duplicateCount > 0 {
                showToast("\(normalized.duplicateCount) duplicate link removed.")
            }
        }
        let entries = extractPostDownloadEntries(from: soraInput)
        guard !entries.isEmpty else {
            showToast("No valid Sora or Facebook link found.")
            return
        }
        encoderStatus = "Waiting"
        runDownloadEntries(entries)
    }

    func importDroppedVideoProviders(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else {
            showToast("No valid video file found.")
            return false
        }

        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []

        for provider in fileProviders {
            group.enter()
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                defer { group.leave() }
                guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else {
                    return
                }
                lock.lock()
                urls.append(url)
                lock.unlock()
            }
        }

        group.notify(queue: .main) {
            self.importDroppedVideoURLs(urls)
        }
        return true
    }

    func pickVideos() {
        let panel = NSOpenPanel()
        panel.title = "Import Videos"
        panel.prompt = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = supportedVideoOpenPanelContentTypes()
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            self?.importDroppedVideoURLs(panel.urls)
        }
    }

    private func runDownloadEntries(_ entries: [PostDownloadEntry]) {
        let soraIDs = entries.compactMap(\.soraID)
        if entries.count == soraIDs.count {
            runSoraDownload(ids: soraIDs)
            return
        }

        runPostLinksDownload(entries: entries)
    }

    private func runSoraDownload(ids: [String]) {
        let summary = ids.count == 1 ? ids[0] : "\(ids.count) items"
        autoStartBatchAfterDownload = true
        currentDownloadEntries = ids.map { PostDownloadEntry(kind: .sora, value: $0) }
        successfulDownloadEntryKeys = []
        downloadProgressPercent = 0
        downloadProgressLabel = ids.first ?? ""
        isDownloadProgressVisible = true
        runStreamingProcess(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: [soraDownloaderScript.path, rootDir.path] + ids,
            initialLog: "WAIT... Downloading Sora URLs.",
            startDetail: "Starting download: \(summary)",
            taskKind: .soraDownload
        )
    }

    private func runPostLinksDownload(entries: [PostDownloadEntry]) {
        let summary = entries.count == 1 ? entries[0].displayValue : "\(entries.count) items"
        autoStartBatchAfterDownload = true
        currentDownloadEntries = entries
        successfulDownloadEntryKeys = []
        downloadProgressPercent = 0
        downloadProgressLabel = entries.first?.displayValue ?? ""
        isDownloadProgressVisible = true
        runStreamingProcess(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: [postLinksDownloaderScript.path, rootDir.path] + entries.map(\.displayValue),
            initialLog: "WAIT... Downloading post links.",
            startDetail: "Starting download: \(summary)",
            taskKind: .postLinksDownload
        )
    }

    private func runStreamingProcess(
        executable: URL,
        arguments: [String],
        initialLog: String,
        startDetail: String,
        taskKind: TaskKind
    ) {
        refreshMetadata()
        logs = [initialLog]
        syncLogText()
        status = "Running"
        detail = startDetail
        isRunning = true
        currentTaskKind = taskKind
        if taskKind != .soraDownload && taskKind != .postLinksDownload {
            isDownloadProgressVisible = false
            downloadProgressPercent = 0
            downloadProgressLabel = ""
        }
        if taskKind != .batch {
            isBatchProgressVisible = false
            batchProgressPercent = 0
            batchProgressLabel = ""
        }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                return
            }
            let text = String(decoding: data, as: UTF8.self)
            let lines = text.split(whereSeparator: \.isNewline).map(String.init)
            DispatchQueue.main.async {
                guard let self else { return }
                for line in lines where !line.isEmpty {
                    self.appendLog(line)
                }
            }
        }

        process.terminationHandler = { [weak self] task in
            DispatchQueue.main.async {
                guard let self else { return }
                self.outputPipe?.fileHandleForReading.readabilityHandler = nil
                self.outputPipe = nil
                self.process = nil
                self.isRunning = false
                self.currentTaskKind = nil
                if taskKind == .soraDownload || taskKind == .postLinksDownload {
                    self.applyPostDownloadInputAfterDownload()
                }
                if task.terminationStatus == 0 {
                    self.appendLog("DONE")
                    if self.status == "Running" {
                        self.status = "Done"
                        self.detail = "Task complete."
                    }
                    if self.isDownloadProgressVisible {
                        self.downloadProgressPercent = 100
                    }
                    if taskKind == .soraDownload || taskKind == .postLinksDownload {
                        self.playSoraDownloadCompleteCue()
                    } else if taskKind == .batch {
                        self.playBatchCompleteCue()
                    }
                    if taskKind == .facebookRunner {
                        let deletePackageNames = self.pendingFacebookRunnerDeletePackageNames
                        self.pendingFacebookRunnerDeletePackageNames = []
                        if !deletePackageNames.isEmpty {
                            self.deleteFacebookRunnerPackagesAfterSuccess(deletePackageNames)
                        }
                    }
                } else {
                    if taskKind == .facebookRunner {
                        self.pendingFacebookRunnerDeletePackageNames = []
                    }
                    if taskKind == .soraDownload || taskKind == .postLinksDownload {
                        self.autoStartBatchAfterDownload = false
                        let failedCount = self.extractPostDownloadEntries(from: self.soraInput).count
                        if !self.successfulDownloadEntryKeys.isEmpty && failedCount > 0 {
                            self.appendLog("PARTIAL")
                            self.status = "Partial"
                            self.detail = "Some downloads failed. Failed URLs kept for retry."
                        } else if failedCount > 0 {
                            self.appendLog("FAILED")
                            self.status = "Failed"
                            self.detail = "Download failed. Failed URLs kept for retry."
                        } else {
                            self.appendLog("FAILED")
                            self.status = "Failed"
                            self.detail = "Exit code \(task.terminationStatus)"
                        }
                    } else if taskKind == .batch {
                        self.pendingBatchStartAfterCurrentTask = false
                        self.appendLog("FAILED")
                        self.status = "Failed"
                        self.detail = "Exit code \(task.terminationStatus)"
                    } else {
                        self.appendLog("FAILED")
                        self.status = "Failed"
                        self.detail = "Exit code \(task.terminationStatus)"
                    }
                }
                self.refreshMetadata()
                let queuedDownloadEntries = self.consumeQueuedPostDownloads()
                if !queuedDownloadEntries.isEmpty {
                    self.appendLog("WAIT... Auto downloading pasted URLs.")
                    self.status = "Running"
                    self.detail = "Queued URLs detected. Starting next download..."
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        self.runDownloadEntries(queuedDownloadEntries)
                    }
                } else if task.terminationStatus == 0 && (taskKind == .soraDownload || taskKind == .postLinksDownload) && self.autoStartBatchAfterDownload {
                    self.autoStartBatchAfterDownload = false
                    self.appendLog("WAIT... Auto starting AI edit.")
                    self.status = "Running"
                    self.detail = "Download complete. Starting batch..."
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        self.startBatch()
                    }
                } else if task.terminationStatus == 0 && taskKind == .batch && self.pendingBatchStartAfterCurrentTask {
                    self.pendingBatchStartAfterCurrentTask = false
                    self.appendLog("WAIT... Auto starting dropped videos.")
                    self.status = "Running"
                    self.detail = "Current task complete. Starting dropped videos..."
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        self.startBatch()
                    }
                }
            }
        }

        do {
            try process.run()
            self.process = process
            self.outputPipe = pipe
        } catch {
            isRunning = false
            status = "Failed"
            detail = "Failed to start task."
            appendLog("FAILED")
        }
    }

    func openRoot() {
        try? FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(rootDir)
    }

    func openFacebookRoot() {
        try? FileManager.default.createDirectory(at: facebookRootDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(facebookRootDir)
    }

    func openLatestPackage() {
        if let latest = packageDirs().last {
            NSWorkspace.shared.open(latest)
        }
    }

    func openPackage(_ item: EditedPackageItem) {
        NSWorkspace.shared.open(item.packageURL)
    }

    func runFacebookRunnerPreflight(
        profileDirectoryName: String,
        pageName: String,
        packageNamesText: String,
        intervalMinutes: Int
    ) {
        guard !isBusy else {
            showToast("Wait for current task to finish.")
            return
        }

        let normalizedPageName = normalizedFacebookRunnerPageName(pageName)
        guard !normalizedPageName.isEmpty else {
            showToast("Enter a Facebook page name.")
            return
        }

        let packageNames = parseFacebookRunnerPackageNames(packageNamesText)
        if let missingPackage = firstMissingFacebookPackageName(in: packageNames) {
            showToast("Package not found: \(missingPackage)")
            return
        }

        let selectedProfile = chromeProfileItem(forDirectoryName: profileDirectoryName)
        var arguments = [facebookPreflightScript.path]
        if let firstPackageURL = firstFacebookPackageURL(for: packageNames) {
            arguments.append(firstPackageURL.path)
        }
        arguments.append(contentsOf: [
            "--state-path", facebookTimingStateFile.path,
            "--page-name", normalizedPageName,
            "--interval-minutes", "\(max(1, intervalMinutes))",
        ])
        if let selectedProfile {
            arguments.append(contentsOf: [
                "--profile-name", selectedProfile.displayName,
                "--profile-directory", selectedProfile.directoryName,
            ])
        }

        runStreamingProcess(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: arguments,
            initialLog: "WAIT... Running Facebook preflight.",
            startDetail: "Checking time and memory for \(normalizedPageName)...",
            taskKind: .facebookRunner
        )
    }

    func runFacebookRunnerBatch(
        profileDirectoryName: String,
        pageName: String,
        packageNamesText: String,
        intervalMinutes: Int,
        closeAfterEach: Bool,
        closeAfterFinish: Bool,
        postNowAdvanceSlot: Bool,
        openChromeFirst: Bool,
        deleteFoldersAfterSuccess: Bool
    ) {
        guard !isBusy else {
            showToast("Wait for current task to finish.")
            return
        }

        let normalizedPageName = normalizedFacebookRunnerPageName(pageName)
        guard !normalizedPageName.isEmpty else {
            showToast("Enter a Facebook page name.")
            return
        }

        let packageNames = parseFacebookRunnerPackageNames(packageNamesText)
        guard !packageNames.isEmpty else {
            showToast("Enter at least one package folder.")
            return
        }

        if let missingPackage = firstMissingFacebookPackageName(in: packageNames) {
            showToast("Package not found: \(missingPackage)")
            return
        }

        pendingFacebookRunnerDeletePackageNames = deleteFoldersAfterSuccess ? packageNames : []

        let selectedProfile = chromeProfileItem(forDirectoryName: profileDirectoryName)
        let launchRun = { [weak self] in
            guard let self else { return }
            var arguments = [
                facebookBatchUploadScript.path,
                rootDir.path,
                "--state-path", facebookTimingStateFile.path,
                "--page-name", normalizedPageName,
                "--interval-minutes", "\(max(1, intervalMinutes))",
                "--packages",
            ]
            arguments.append(contentsOf: packageNames)
            if closeAfterEach {
                arguments.append("--close-after-each")
            }
            if closeAfterFinish {
                arguments.append("--close-after-finish")
            }
            if postNowAdvanceSlot {
                arguments.append("--post-now-advance-slot")
            }
            self.runStreamingProcess(
                executable: URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: arguments,
                initialLog: "WAIT... Running Facebook upload batch.",
                startDetail: "Starting \(packageNames.count) package(s) for \(normalizedPageName)...",
                taskKind: .facebookRunner
            )
        }

        if openChromeFirst, let selectedProfile, !selectedProfile.isOnline {
            openChromeProfile(selectedProfile)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
                self?.refreshChromeProfiles()
                launchRun()
            }
        } else {
            launchRun()
        }
    }

    func quitGoogleChromeCompletely() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "tell application \"Google Chrome\" to quit"]
        do {
            try process.run()
            showToast("Closing Google Chrome...")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.refreshChromeProfiles()
            }
        } catch {
            showToast("Failed to quit Google Chrome.")
        }
    }

    func assignChromeProfile(_ profile: ChromeProfileItem, to item: EditedPackageItem) {
        chromeProfileAssignments[item.id] = profile.directoryName
        persistChromeProfileAssignments()
        applyChromeProfileAssignments(using: chromeProfiles)
        showToast("\(profile.displayName) selected.")
    }

    func clearAssignedChromeProfile(for item: EditedPackageItem) {
        guard chromeProfileAssignments.removeValue(forKey: item.id) != nil else { return }
        persistChromeProfileAssignments()
        applyChromeProfileAssignments(using: chromeProfiles)
        showToast("Profile cleared.")
    }

    private func chromeProfileItem(forDirectoryName directoryName: String) -> ChromeProfileItem? {
        let trimmed = directoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return chromeProfiles.first(where: { $0.directoryName == trimmed })
            ?? chromeProfiles.first(where: { $0.displayName == trimmed })
    }

    private func firstFacebookPackageURL(for packageNames: [String]) -> URL? {
        for packageName in packageNames {
            let candidate = rootDir.appendingPathComponent(packageName, isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private func firstMissingFacebookPackageName(in packageNames: [String]) -> String? {
        for packageName in packageNames {
            let candidate = rootDir.appendingPathComponent(packageName, isDirectory: true)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return packageName
            }
        }
        return nil
    }

    private func deleteFacebookRunnerPackagesAfterSuccess(_ packageNames: [String]) {
        guard !packageNames.isEmpty else { return }
        let fileManager = FileManager.default
        var deletedNames: [String] = []
        var failedNames: [String] = []

        for packageName in packageNames {
            let packageURL = rootDir.appendingPathComponent(packageName, isDirectory: true)
            guard fileManager.fileExists(atPath: packageURL.path) else {
                continue
            }
            do {
                try fileManager.removeItem(at: packageURL)
                selectedEditedPackageIDs.remove(packageName)
                if chromeProfileAssignments.removeValue(forKey: packageName) != nil {
                    persistChromeProfileAssignments()
                }
                deletedNames.append(packageName)
                appendLog("[facebook-runner] Deleted \(packageName)")
            } catch {
                failedNames.append(packageName)
                appendLog("[facebook-runner] FAILED delete \(packageName): \(error.localizedDescription)")
            }
        }

        refreshMetadata()
        if !deletedNames.isEmpty && failedNames.isEmpty {
            showToast("Deleted \(deletedNames.count) folder(s).")
        } else if !deletedNames.isEmpty {
            showToast("Deleted \(deletedNames.count) folder(s). \(failedNames.count) failed.")
        }
    }

    func deletePackage(_ item: EditedPackageItem) {
        do {
            try FileManager.default.removeItem(at: item.packageURL)
            selectedEditedPackageIDs.remove(item.id)
            if chromeProfileAssignments.removeValue(forKey: item.id) != nil {
                persistChromeProfileAssignments()
            }
            refreshMetadata()
            showToast("\(item.packageName) deleted.")
        } catch {
            showToast("Delete failed.")
        }
    }

    func deleteAllPackages() {
        let packages = packageDirs()
        guard !packages.isEmpty else { return }
        var deletedCount = 0
        var didUpdateAssignments = false
        for package in packages {
            do {
                try FileManager.default.removeItem(at: package)
                if chromeProfileAssignments.removeValue(forKey: package.lastPathComponent) != nil {
                    didUpdateAssignments = true
                }
                deletedCount += 1
            } catch {
                continue
            }
        }
        if didUpdateAssignments {
            persistChromeProfileAssignments()
        }
        selectedEditedPackageIDs.removeAll()
        refreshMetadata()
        if deletedCount > 0 {
            showToast("\(deletedCount) package(s) deleted.")
        } else {
            showToast("Delete failed.")
        }
    }

    func toggleEditedPackageSelection(_ item: EditedPackageItem) {
        if selectedEditedPackageIDs.contains(item.id) {
            selectedEditedPackageIDs.remove(item.id)
        } else {
            selectedEditedPackageIDs.insert(item.id)
        }
    }

    func clearEditedPackageSelection() {
        selectedEditedPackageIDs.removeAll()
    }

    func selectAllEditedPackages() {
        selectedEditedPackageIDs = Set(editedPackages.map(\.id))
        if !selectedEditedPackageIDs.isEmpty {
            showToast("All videos selected.")
        }
    }

    func deleteSelectedPackages() {
        let selectedItems = editedPackages.filter { selectedEditedPackageIDs.contains($0.id) }
        guard !selectedItems.isEmpty else { return }

        var deletedCount = 0
        var didUpdateAssignments = false
        for item in selectedItems {
            do {
                try FileManager.default.removeItem(at: item.packageURL)
                if chromeProfileAssignments.removeValue(forKey: item.id) != nil {
                    didUpdateAssignments = true
                }
                deletedCount += 1
            } catch {
                continue
            }
        }

        if didUpdateAssignments {
            persistChromeProfileAssignments()
        }
        selectedEditedPackageIDs.removeAll()
        refreshMetadata()

        if deletedCount > 0 {
            showToast("\(deletedCount) selected package(s) deleted.")
        } else {
            showToast("Delete failed.")
        }
    }

    func copyTitle(_ item: EditedPackageItem) {
        let text = normalizedUploadTitle(item.title)
        copyToPasteboard(text)
        showToast("Title copied.")
    }

    func copyAllTitles() {
        let titles = editedPackages
            .map { normalizedUploadTitle($0.title) }
            .filter { !$0.isEmpty }

        guard !titles.isEmpty else { return }

        let text = titles.joined(separator: "\n\n")
        copyToPasteboard(text)
        showToast("All titles copied.")
    }

    private func persistSavedSettings(_ payload: [String: String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else {
            return
        }
        try? data.write(to: apiKeysFile, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: apiKeysFile.path)
    }

    private func loadCompletedSoraDownloadIDs() -> Set<String> {
        var ids: Set<String> = []
        if
            let data = try? Data(contentsOf: soraCompletedDownloadIDsFile),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let savedIDs = object["ids"] as? [String]
        {
            ids.formUnion(savedIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        }

        let existingDownloadedIDs = ((try? FileManager.default.contentsOfDirectory(
            at: rootDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? [])
            .compactMap { url -> String? in
                guard ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) else { return nil }
                let name = url.deletingPathExtension().lastPathComponent
                guard name.range(of: #"^s_[A-Za-z0-9]{12,}$"#, options: .regularExpression) != nil else { return nil }
                return name
            }
        ids.formUnion(existingDownloadedIDs)
        return ids
    }

    private func persistCompletedSoraDownloadIDs() {
        let payload: [String: Any] = [
            "ids": completedSoraDownloadIDs.sorted(),
            "updated_at": ISO8601DateFormatter().string(from: Date()),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else {
            return
        }
        try? data.write(to: soraCompletedDownloadIDsFile, options: [.atomic])
    }

    private func noteSoraPasteButtonTapAndShouldUnlock() -> Bool {
        let now = Date()
        let cutoff = now.addingTimeInterval(-15)
        soraPasteTapTimes = soraPasteTapTimes.filter { $0 >= cutoff }
        soraPasteTapTimes.append(now)
        if soraPasteTapTimes.count >= 3 {
            soraPasteTapTimes.removeAll()
            return true
        }
        return false
    }

    private func enqueuePostDownloads(_ entries: [PostDownloadEntry]) {
        guard !entries.isEmpty else { return }
        var seen = Set(queuedDownloadEntries.map(\.uniqueKey))
        for entry in entries where !seen.contains(entry.uniqueKey) {
            queuedDownloadEntries.append(entry)
            seen.insert(entry.uniqueKey)
        }
    }

    private func consumeQueuedPostDownloads() -> [PostDownloadEntry] {
        guard !queuedDownloadEntries.isEmpty else { return [] }
        let available = Set(extractPostDownloadEntries(from: soraInput).map(\.uniqueKey))
        let nextEntries = queuedDownloadEntries.filter { available.contains($0.uniqueKey) }
        queuedDownloadEntries.removeAll()
        return nextEntries
    }

    func saveSettings(openAIKey: String?, geminiKey: String?, provider: AIProvider) {
        var payload = loadSavedSettings()
        if let openAIKey, !openAIKey.isEmpty {
            payload["OPENAI_API_KEY"] = openAIKey
        }
        if let geminiKey, !geminiKey.isEmpty {
            payload["GEMINI_API_KEY"] = geminiKey
            payload["GOOGLE_API_KEY"] = geminiKey
        }
        payload["AI_MODEL"] = provider.rawValue
        payload["AI_PROVIDER"] = provider.providerKey

        persistSavedSettings(payload)
        refreshMetadata()
        showToast("\(provider.label) settings saved.")
    }

    func removeSavedSettings(removeOpenAI: Bool, removeGemini: Bool, provider: AIProvider) {
        var payload = loadSavedSettings()
        if removeOpenAI {
            payload.removeValue(forKey: "OPENAI_API_KEY")
        }
        if removeGemini {
            payload.removeValue(forKey: "GEMINI_API_KEY")
            payload.removeValue(forKey: "GOOGLE_API_KEY")
        }
        payload["AI_MODEL"] = provider.rawValue
        payload["AI_PROVIDER"] = provider.providerKey

        persistSavedSettings(payload)
        refreshMetadata()
        showToast("\(provider.label) settings updated.")
    }

    func setAIChatProvider(_ provider: AIProvider) {
        guard aiChatProvider != provider else { return }

        let wasLiveActive = isGeminiLiveSessionActive
        if wasLiveActive {
            cancelLiveChat(showStatus: false)
        }

        aiChatProvider = provider
        var payload = loadSavedSettings()
        payload["AI_CHAT_MODEL"] = provider.rawValue
        payload["AI_CHAT_PROVIDER"] = provider.providerKey
        persistSavedSettings(payload)

        let statusMessage: String
        if wasLiveActive {
            statusMessage = "Live stopped. \(provider.label) selected."
        } else if isAIChatBusy {
            statusMessage = "\(provider.label) selected for the next message."
        } else {
            statusMessage = "\(provider.label) selected."
        }
        aiChatStatus = statusMessage
        showToast(statusMessage)
    }

    func toggleAIChatRecordingProvider() {
        guard !isAIChatRecording, !isAIChatTranscribing else { return }
        let next: AIChatRecordingProvider = aiChatRecordingProvider == .openai ? .gemini : .openai
        setAIChatRecordingProvider(next)
    }

    func setAIChatRecordingProvider(_ provider: AIChatRecordingProvider) {
        guard aiChatRecordingProvider != provider else { return }
        aiChatRecordingProvider = provider
        var payload = loadSavedSettings()
        payload["AI_CHAT_RECORD_PROVIDER"] = provider.rawValue
        persistSavedSettings(payload)
        aiChatStatus = "\(provider.label) selected."
        showToast(aiChatStatus)
    }

    func setAIChatGeminiImageModelChoice(_ choice: AIChatGeminiImageModelChoice) {
        guard aiChatGeminiImageModelChoice != choice else { return }
        aiChatGeminiImageModelChoice = choice
        var payload = loadSavedSettings()
        payload["AI_CHAT_GEMINI_IMAGE_MODEL"] = choice.rawValue
        persistSavedSettings(payload)
        aiChatStatus = "\(choice.label) selected."
        showToast(aiChatStatus)
    }

    func setGeminiReplyVoiceFallbackMode(_ mode: GeminiReplyVoiceFallbackMode) {
        guard geminiReplyVoiceFallbackMode != mode else { return }
        geminiReplyVoiceFallbackMode = mode
        var payload = loadSavedSettings()
        payload["GEMINI_REPLY_VOICE_FALLBACK_MODE"] = mode.rawValue
        persistSavedSettings(payload)
        aiChatStatus = "\(mode.label) selected."
        showToast(aiChatStatus)
    }

    var currentAIChatLiveVoiceChoice: AILiveVoiceChoice {
        aiChatProvider.providerKey == "gemini" ? geminiLiveVoiceChoice : openAILiveVoiceChoice
    }

    var currentAIChatLiveVoiceDescription: String {
        let choice = currentAIChatLiveVoiceChoice
        if aiChatProvider.providerKey == "gemini" {
            return "\(choice.label) • \(choice.geminiVoiceName)"
        }
        return "\(choice.label) • \(choice.openAIVoiceName)"
    }

    var currentGeminiReplyVoiceFallbackDescription: String {
        geminiReplyVoiceFallbackMode.label
    }

    private func liveVoiceChoice(for provider: AIProvider) -> AILiveVoiceChoice {
        provider.providerKey == "gemini" ? geminiLiveVoiceChoice : openAILiveVoiceChoice
    }

    func setAIChatLiveVoiceChoice(_ choice: AILiveVoiceChoice) {
        let providerKey = aiChatProvider.providerKey
        let previousChoice = providerKey == "gemini" ? geminiLiveVoiceChoice : openAILiveVoiceChoice
        guard previousChoice != choice else { return }

        if providerKey == "gemini" {
            geminiLiveVoiceChoice = choice
        } else {
            openAILiveVoiceChoice = choice
        }

        var payload = loadSavedSettings()
        if providerKey == "gemini" {
            payload["GEMINI_LIVE_VOICE"] = choice.rawValue
        } else {
            payload["OPENAI_LIVE_VOICE"] = choice.rawValue
        }
        persistSavedSettings(payload)

        let selectedVoiceName = providerKey == "gemini" ? choice.geminiVoiceName : choice.openAIVoiceName
        if isGeminiLiveSessionActive, activeLiveProviderKey == providerKey {
            cancelLiveChat(showStatus: false)
            aiChatStatus = "Live stopped. \(choice.label) voice selected: \(selectedVoiceName)."
        } else {
            aiChatStatus = "\(choice.label) voice selected: \(selectedVoiceName)."
        }
        showToast(aiChatStatus)
    }

    func testSavedAIProvider(_ provider: AIProvider, completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let responseText = try Self.runAIChatBridge(
                    provider: provider,
                    messages: [["role": "user", "content": "Reply with exactly OK"]],
                    imagePaths: [],
                    videoPaths: [],
                    modelOverride: provider,
                    timeout: 20
                )
                let trimmed = responseText.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let message = trimmed.caseInsensitiveCompare("OK") == .orderedSame
                    ? "\(provider.label) ដំណើរការបាន។"
                    : "\(provider.label) ឆ្លើយតបបាន។"
                Task { @MainActor in
                    completion(message)
                    self.showToast(message)
                }
            } catch {
                let message = error.localizedDescription
                Task { @MainActor in
                    completion(message)
                    self.showToast(message)
                }
            }
        }
    }

    private func pendingAIChatStatusText(
        for prompt: String,
        provider: AIProvider,
        imageModelLabel: String?,
        isResuming: Bool
    ) -> String {
        let prefix = isResuming ? "Resuming " : ""
        if let mediaKind = requestedGeneratedMediaKind(for: prompt) {
            switch mediaKind {
            case .image:
                if let imageModelLabel {
                    return "\(prefix)generating image with \(imageModelLabel)..."
                }
                return "\(prefix)generating image with \(provider.label)..."
            case .video:
                return "\(prefix)generating video with \(provider.label)... This can take a few minutes."
            }
        }
        if isResuming {
            return "Resuming request for \(provider.label)..."
        }
        return "Waiting for \(provider.label)..."
    }

    private func persistPendingAIChatRequest(_ request: AIChatPendingRequest?) {
        guard let request else {
            try? FileManager.default.removeItem(at: aiChatPendingRequestFile)
            return
        }
        guard let data = try? JSONEncoder().encode(request) else { return }
        try? data.write(to: aiChatPendingRequestFile, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: aiChatPendingRequestFile.path)
    }

    private func loadPendingAIChatRequest() -> AIChatPendingRequest? {
        guard let data = try? Data(contentsOf: aiChatPendingRequestFile),
              let request = try? JSONDecoder().decode(AIChatPendingRequest.self, from: data)
        else {
            return nil
        }
        return request
    }

    private func beginAIChatRequest(
        requestID: UUID,
        provider: AIProvider,
        prompt: String,
        imageModelLabel: String?,
        messagesPayload: [[String: String]],
        imagePaths: [String],
        videoPaths: [String],
        requestTimeout: TimeInterval,
        persistPendingRequest: Bool,
        isResuming: Bool
    ) {
        guard let sessionID = currentAIChatSessionID else { return }

        if persistPendingRequest {
            persistPendingAIChatRequest(
                AIChatPendingRequest(
                    id: requestID,
                    sessionID: sessionID,
                    providerRawValue: provider.rawValue,
                    prompt: prompt,
                    imageModelLabel: imageModelLabel,
                    messages: messagesPayload,
                    imagePaths: imagePaths,
                    videoPaths: videoPaths,
                    requestTimeout: requestTimeout,
                    createdAt: Date()
                )
            )
        }

        aiChatStatus = pendingAIChatStatusText(for: prompt, provider: provider, imageModelLabel: imageModelLabel, isResuming: isResuming)
        stopAIChatReplyVoicePlayback()
        playAIChatThinkingCue()
        isAIChatBusy = true
        activeAIChatRequestID = requestID

        let timeoutLabel = imageModelLabel ?? provider.label

        DispatchQueue.main.asyncAfter(deadline: .now() + requestTimeout + 5) { [weak self] in
            guard let self else { return }
            guard self.activeAIChatRequestID == requestID, self.isAIChatBusy else { return }
            self.activeAIChatRequestID = nil
            self.isAIChatBusy = false
            self.persistPendingAIChatRequest(nil)
            self.aiChatStatus = "\(timeoutLabel) request timed out. Please try again."
            self.playAIChatErrorCue()
            self.showToast(self.aiChatStatus)
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let response = try Self.runAIChatBridge(
                    provider: provider,
                    messages: messagesPayload,
                    imagePaths: imagePaths,
                    videoPaths: videoPaths,
                    modelOverride: provider,
                    timeout: requestTimeout
                )
                Task { @MainActor in
                    guard self.activeAIChatRequestID == requestID else { return }
                    self.activeAIChatRequestID = nil
                    self.persistPendingAIChatRequest(nil)
                    let cleanedResponseText = self.sanitizeAIAssistantReply(response.text)
                    let assistantAttachments = response.attachments.filter {
                        FileManager.default.fileExists(atPath: $0.url.path)
                    }
                    self.appendAIChatMessage(
                        AIChatMessage(
                            role: "assistant",
                            content: cleanedResponseText.isEmpty ? response.text : cleanedResponseText,
                            attachments: assistantAttachments
                        )
                    )
                    if let firstAttachment = assistantAttachments.first {
                        switch firstAttachment.kind {
                        case .image:
                            if let imageModelLabel {
                                self.aiChatStatus = "\(imageModelLabel) generated an image."
                            } else {
                                self.aiChatStatus = "\(provider.label) generated an image."
                            }
                            self.playAIChatReplyCue()
                        case .video:
                            self.aiChatStatus = "\(provider.label) generated a video."
                            self.playAIChatVideoReadyCue()
                        }
                    } else {
                        self.aiChatStatus = "\(provider.label) replied."
                        self.playAIChatReplyCue()
                        self.speakAIChatReplyTextIfNeeded(cleanedResponseText.isEmpty ? response.text : cleanedResponseText, provider: provider)
                    }
                    self.isAIChatBusy = false
                }
            } catch {
                Task { @MainActor in
                    guard self.activeAIChatRequestID == requestID else { return }
                    self.activeAIChatRequestID = nil
                    self.persistPendingAIChatRequest(nil)
                    self.aiChatStatus = error.localizedDescription
                    self.isAIChatBusy = false
                    self.playAIChatErrorCue()
                    self.showToast(error.localizedDescription)
                }
            }
        }
    }

    private func resumePendingAIChatRequestIfNeeded() {
        guard !isAIChatBusy, !isGeminiLiveSessionActive else { return }
        guard let pending = loadPendingAIChatRequest() else { return }
        guard let provider = AIProvider(rawValue: pending.providerRawValue) else {
            persistPendingAIChatRequest(nil)
            return
        }
        guard let session = aiChatSessions.first(where: { $0.id == pending.sessionID }) else {
            persistPendingAIChatRequest(nil)
            return
        }

        currentAIChatSessionID = session.id
        aiChatMessages = session.messages
        aiChatStatus = pendingAIChatStatusText(
            for: pending.prompt,
            provider: provider,
            imageModelLabel: pending.imageModelLabel,
            isResuming: true
        )
        showToast("Resuming pending AI Chat request.")
        beginAIChatRequest(
            requestID: pending.id,
            provider: provider,
            prompt: pending.prompt,
            imageModelLabel: pending.imageModelLabel,
            messagesPayload: pending.messages,
            imagePaths: pending.imagePaths,
            videoPaths: pending.videoPaths,
            requestTimeout: pending.requestTimeout,
            persistPendingRequest: false,
            isResuming: true
        )
    }

    func clearAIChat() {
        cancelLiveChat(showStatus: false)
        cancelAIChatRecording(resetStatus: false)
        stopAIChatReplyVoicePlayback()
        aiChatMessages.removeAll()
        liveUserMessageID = nil
        liveAssistantMessageID = nil
        activeAIChatRequestID = nil
        isAIChatBusy = false
        aiChatAttachmentURLs.removeAll()
        persistPendingAIChatRequest(nil)
        persistCurrentAIChatSession()
        aiChatStatus = "Chat cleared."
    }

    func sendAIChat(_ text: String, displayText: String? = nil) {
        let existingMessages = aiChatMessages
        let attachmentURLs = aiChatAttachmentURLs
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let basePrompt = trimmed.isEmpty && !attachmentURLs.isEmpty ? "Analyze the attached media." : normalizedAIChatMediaPrompt(trimmed)
        let prompt = aiChatPromptUsingGeminiImageChoice(
            basePrompt,
            provider: aiChatProvider,
            choice: aiChatGeminiImageModelChoice,
            attachmentURLs: attachmentURLs
        )
        guard !prompt.isEmpty else { return }
        guard !isAIChatBusy else { return }
        guard !isAIChatRecording, !isAIChatTranscribing else {
            aiChatStatus = "Stop recording before sending."
            return
        }
        guard !isGeminiLiveSessionActive else {
            aiChatStatus = "Stop Live before sending a text message."
            return
        }

        let preferredDisplayText = displayText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? aiChatDisplayPrompt(trimmed)
        let bubblePrompt = preferredDisplayText.isEmpty ? aiChatDisplayPrompt(trimmed) : preferredDisplayText
        let userVisiblePrompt = bubblePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let userMessage = AIChatMessage(
            role: "user",
            content: userVisiblePrompt,
            attachments: attachmentURLs.compactMap(aiChatAttachment(from:))
        )
        if existingMessages.isEmpty {
            setCurrentAIChatSessionTitle(aiChatSessionTitle(from: bubblePrompt))
        }
        appendAIChatMessage(userMessage)
        let requestID = UUID()
        aiChatAttachmentURLs.removeAll()

        let provider = aiChatProvider
        let imageModelLabel = requestedGeneratedImageModelLabel(for: prompt, provider: provider, attachmentURLs: attachmentURLs)
        let messagesPayload = existingMessages.map { ["role": $0.role, "content": $0.content] } + [["role": "user", "content": prompt]]
        let imagePaths = attachmentURLs.filter(isImageAttachmentURL).map(\.path)
        let videoPaths = attachmentURLs.filter(isVideoAttachmentURL).map(\.path)
        let requestTimeout = requestedAIChatTimeout(for: prompt, attachmentURLs: attachmentURLs, provider: provider)
        beginAIChatRequest(
            requestID: requestID,
            provider: provider,
            prompt: prompt,
            imageModelLabel: imageModelLabel,
            messagesPayload: messagesPayload,
            imagePaths: imagePaths,
            videoPaths: videoPaths,
            requestTimeout: requestTimeout,
            persistPendingRequest: true,
            isResuming: false
        )
    }

    func sendAIChatGeneratedMedia(kind: AIChatGeneratedMediaKind, prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sendAIChat("\(kind.slashCommand) \(trimmed)")
    }

    func pickAIChatAttachments() {
        let panel = NSOpenPanel()
        panel.title = "Add Media"
        panel.prompt = "Add"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = supportedAIChatOpenPanelContentTypes()
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            self?.addAIChatAttachments(panel.urls)
        }
    }

    func addAIChatAttachments(_ urls: [URL]) {
        let valid = urls
            .map { $0.standardizedFileURL }
            .filter { isImageAttachmentURL($0) || isVideoAttachmentURL($0) }
        guard !valid.isEmpty else {
            showToast("No valid image or video found.")
            return
        }
        var merged = aiChatAttachmentURLs.map(\.standardizedFileURL)
        for url in valid where !merged.contains(url) {
            merged.append(url)
        }
        if merged.count > 12 {
            merged = Array(merged.prefix(12))
        }
        aiChatAttachmentURLs = merged
        aiChatStatus = "\(aiChatAttachmentURLs.count) media attached."
    }

    func removeAIChatAttachment(_ url: URL) {
        aiChatAttachmentURLs.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        aiChatStatus = aiChatAttachmentURLs.isEmpty ? "Ready." : "\(aiChatAttachmentURLs.count) media attached."
    }

    func clearAIChatAttachments() {
        aiChatAttachmentURLs.removeAll()
        aiChatStatus = "Attachments cleared."
    }

    func startAIChatRecording() {
        guard !isAIChatBusy else {
            aiChatStatus = "Wait for the current AI response before recording."
            showToast(aiChatStatus)
            return
        }
        guard !isGeminiLiveSessionActive else {
            aiChatStatus = "Stop Live before recording."
            showToast(aiChatStatus)
            return
        }
        guard !isAIChatRecording, !isAIChatTranscribing else { return }

        aiChatStatus = "Requesting microphone access..."
        aiChatSpeechRecorder.startRecording { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success:
                    self.isAIChatRecording = true
                    self.aiChatStatus = "Recording speech with \(self.aiChatRecordingProvider.label)... Tap Stop Record when finished."
                case .failure(let error):
                    self.isAIChatRecording = false
                    self.aiChatStatus = error.localizedDescription
                    self.showToast(error.localizedDescription)
                }
            }
        }
    }

    func stopAIChatRecording(completion: @escaping (String) -> Void) {
        guard isAIChatRecording else { return }
        isAIChatRecording = false
        guard let recordingURL = aiChatSpeechRecorder.stopRecording() else {
            aiChatStatus = "Recording file was not created."
            showToast(aiChatStatus)
            return
        }

        isAIChatTranscribing = true
        aiChatStatus = "Transcribing with \(aiChatRecordingProvider.label)..."

        transcribeAIChatRecording(at: recordingURL) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isAIChatTranscribing = false
                try? FileManager.default.removeItem(at: recordingURL)
                switch result {
                case .success(let text):
                    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !cleaned.isEmpty else {
                        self.aiChatStatus = "No clear speech detected. Try again."
                        self.showToast(self.aiChatStatus)
                        return
                    }
                    self.aiChatStatus = "Speech converted to text."
                    completion(cleaned)
                case .failure(let error):
                    self.aiChatStatus = error.localizedDescription
                    self.showToast(error.localizedDescription)
                }
            }
        }
    }

    func cancelAIChatRecording(resetStatus: Bool = false) {
        aiChatSpeechRecorder.cancelRecording()
        let wasRecording = isAIChatRecording || isAIChatTranscribing
        isAIChatRecording = false
        isAIChatTranscribing = false
        if resetStatus && wasRecording {
            aiChatStatus = "Ready."
        }
    }

    var currentAIChatSessionLabel: String {
        guard let session = aiChatSessions.first(where: { $0.id == currentAIChatSessionID }) else {
            return "No chat selected"
        }
        return aiChatSessionLabel(session)
    }

    func startNewAIChatSession() {
        cancelLiveChat(showStatus: false)
        cancelAIChatRecording(resetStatus: false)
        stopAIChatReplyVoicePlayback()
        liveUserMessageID = nil
        liveAssistantMessageID = nil
        activeAIChatRequestID = nil
        isAIChatBusy = false
        aiChatAttachmentURLs.removeAll()
        persistPendingAIChatRequest(nil)
        let session = AIChatSession(id: UUID(), createdAt: Date(), updatedAt: Date(), title: "New Chat", messages: [])
        aiChatSessions.insert(session, at: 0)
        currentAIChatSessionID = session.id
        aiChatMessages = []
        persistAIChatStore()
        aiChatStatus = "New chat created."
    }

    func loadAIChatSession(_ session: AIChatSession) {
        cancelLiveChat(showStatus: false)
        cancelAIChatRecording(resetStatus: false)
        stopAIChatReplyVoicePlayback()
        liveUserMessageID = nil
        liveAssistantMessageID = nil
        activeAIChatRequestID = nil
        isAIChatBusy = false
        aiChatAttachmentURLs.removeAll()
        persistPendingAIChatRequest(nil)
        currentAIChatSessionID = session.id
        aiChatMessages = session.messages
        aiChatStatus = "Loaded \(aiChatSessionLabel(session))."
        persistCurrentAIChatSession(markUpdated: false)
    }

    var latestDetectedPromptText: String? {
        for message in aiChatMessages.reversed() where message.role == "assistant" {
            if let prompt = extractCopyablePromptText(from: message.content) {
                return prompt
            }
        }
        return nil
    }

    func copyPromptText(_ text: String) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        copyToPasteboard(prompt)
        showToast("Prompt copied.")
    }

    func copyAIChatMessageText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        copyToPasteboard(trimmed)
        showToast("Message copied.")
    }

    func setAIChatVisibility(_ isVisible: Bool) {
        isAIChatVisible = isVisible
        if isVisible {
            aiChatUnreadCount = 0
        }
    }

    private var activeLiveProviderName: String {
        switch activeLiveProviderKey {
        case "openai":
            return "ChatGPT Live"
        case "gemini":
            return "Gemini Live"
        default:
            return "Live"
        }
    }

    private var currentLiveProviderLabel: String {
        switch activeLiveProviderKey {
        case "openai":
            return "ChatGPT Live"
        case "gemini":
            return "Gemini Live"
        default:
            return "None"
        }
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString(text, forType: NSPasteboard.PasteboardType("public.utf8-plain-text"))
        item.setString(text, forType: NSPasteboard.PasteboardType("public.utf16-external-plain-text"))
        if !pasteboard.writeObjects([item]) {
            pasteboard.setString(text, forType: .string)
        }
    }

    func copyAIChatIssueReport() {
        let formatter = ISO8601DateFormatter()
        let trimmedStatus = aiChatStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = aiChatAttachmentURLs.map(\.lastPathComponent)
        var reportLines = [
            "Soranin AI Chat Issue Report",
            "Time: \(formatter.string(from: Date()))",
            "Main App AI: \(activeProvider.label)",
            "AI Chat AI: \(aiChatProvider.label)",
            "Gemini Image Model: \(aiChatGeminiImageModelChoice.label)",
            "Record Provider: \(aiChatRecordingProvider.label)",
            "Gemini Reply Voice Mode: \(geminiReplyVoiceFallbackMode.label)",
            "OpenAI Live Voice: \(openAILiveVoiceChoice.label) (\(openAILiveVoiceChoice.openAIVoiceName))",
            "Gemini Live Voice: \(geminiLiveVoiceChoice.label) (\(geminiLiveVoiceChoice.geminiVoiceName))",
            "Live Provider: \(currentLiveProviderLabel)",
            "App Status: \(status)",
            "Detail: \(trimmedDetail.isEmpty ? "-" : trimmedDetail)",
            "AI Chat Status: \(trimmedStatus.isEmpty ? "-" : trimmedStatus)",
            "AI Chat Busy: \(isAIChatBusy ? "Yes" : "No")",
            "AI Chat Recording: \(isAIChatRecording ? "Yes" : "No")",
            "AI Chat Transcribing: \(isAIChatTranscribing ? "Yes" : "No")",
            "Live Session Active: \(isGeminiLiveSessionActive ? "Yes" : "No")",
            "Live Capturing: \(isGeminiLiveCapturing ? "Yes" : "No")",
            "Attachments: \(attachments.isEmpty ? "None" : attachments.joined(separator: ", "))"
        ]
        let recentLogs = Array(logs.suffix(12))
        if !recentLogs.isEmpty {
            reportLines.append("Recent Logs:")
            reportLines.append(contentsOf: recentLogs)
        }
        copyToPasteboard(reportLines.joined(separator: "\n"))
        showToast("AI chat issue copied.")
    }

    func runHealthCheck() {
        guard !isHealthCheckRunning else { return }
        isHealthCheckRunning = true
        status = "Checking"
        detail = "Running health check..."
        logs = ["[health] Running health check..."]
        syncLogText()

        let savedSettings = loadSavedSettings()
        let mainProvider = activeProvider
        let chatProvider = aiChatProvider
        let currentChromeOnline = chromeOnline
        let currentSourceCount = sourceCount
        let currentFacebookSourceCount = facebookSourceCount
        let currentPackageCount = packageCount
        let currentChromeProfiles = chromeProfiles

        DispatchQueue.global(qos: .userInitiated).async {
            enum HealthLevel {
                case ok
                case warning
                case issue

                var prefix: String {
                    switch self {
                    case .ok: return "[OK]"
                    case .warning: return "[WARN]"
                    case .issue: return "[ISSUE]"
                    }
                }
            }

            let fileManager = FileManager.default
            var issueCount = 0
            var warningCount = 0
            var lines: [String] = []

            func maskedKey(_ value: String) -> String {
                guard !value.isEmpty else { return "Not set" }
                if value.count <= 8 { return "Saved" }
                return "Saved (...\(value.suffix(4)))"
            }

            func add(_ level: HealthLevel, _ title: String, _ message: String) {
                switch level {
                case .issue:
                    issueCount += 1
                case .warning:
                    warningCount += 1
                case .ok:
                    break
                }
                lines.append("\(level.prefix) \(title): \(message)")
            }

            func exists(_ url: URL, requiresDirectory: Bool? = nil) -> Bool {
                var isDirectory = ObjCBool(false)
                let found = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
                guard found else { return false }
                if let requiresDirectory {
                    return isDirectory.boolValue == requiresDirectory
                }
                return true
            }

            lines.append("Soranin Health Check")
            lines.append("Time: \(ISO8601DateFormatter().string(from: Date()))")
            lines.append("Main App AI: \(mainProvider.label)")
            lines.append("AI Chat AI: \(chatProvider.label)")

            add(exists(rootDir, requiresDirectory: true) ? .ok : .issue, "Root Folder", rootDir.path)
            add(fileManager.isWritableFile(atPath: rootDir.path) ? .ok : .issue, "Root Writable", rootDir.path)
            add(exists(facebookRootDir, requiresDirectory: true) ? .ok : .warning, "Facebook Folder", facebookRootDir.path)
            add(fileManager.isWritableFile(atPath: facebookRootDir.path) ? .ok : .warning, "Facebook Writable", facebookRootDir.path)
            add(exists(batchScript, requiresDirectory: false) ? .ok : .issue, "Batch Script", batchScript.path)
            add(exists(facebookBatchUploadScript, requiresDirectory: false) ? .ok : .warning, "Facebook Batch Upload", facebookBatchUploadScript.path)
            add(exists(facebookPreflightScript, requiresDirectory: false) ? .ok : .warning, "Facebook Preflight", facebookPreflightScript.path)
            add(exists(reelsDashboardServerScript, requiresDirectory: false) ? .ok : .warning, "Mac Control Server", reelsDashboardServerScript.path)
            add(exists(soraDownloaderScript, requiresDirectory: false) ? .ok : .issue, "Sora Downloader", soraDownloaderScript.path)
            add(exists(postLinksDownloaderScript, requiresDirectory: false) ? .ok : .issue, "Post Links Downloader", postLinksDownloaderScript.path)
            add(exists(aiChatBridgeScript, requiresDirectory: false) ? .ok : .issue, "AI Chat Bridge", aiChatBridgeScript.path)
            add(fileManager.isExecutableFile(atPath: "/usr/bin/python3") ? .ok : .issue, "Python", "/usr/bin/python3")
            add(exists(chromeLocalStateFile, requiresDirectory: false) ? .ok : .warning, "Chrome Local State", chromeLocalStateFile.path)
            add(exists(aiChatHistoryFile, requiresDirectory: false) ? .ok : .warning, "AI Chat History", aiChatHistoryFile.path)
            add(exists(facebookTimingStateFile, requiresDirectory: false) ? .ok : .warning, "Facebook Timing State", facebookTimingStateFile.path)

            let openAIKey = (savedSettings["OPENAI_API_KEY"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let geminiKey = (savedSettings["GEMINI_API_KEY"] ?? savedSettings["GOOGLE_API_KEY"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let openAIRequired = mainProvider.providerKey == "openai" || chatProvider.providerKey == "openai"
            let geminiRequired = mainProvider.providerKey == "gemini" || chatProvider.providerKey == "gemini"

            if openAIKey.isEmpty {
                add(openAIRequired ? .issue : .warning, "OpenAI Key", "Not set")
            } else {
                add(.ok, "OpenAI Key", maskedKey(openAIKey))
            }

            if geminiKey.isEmpty {
                add(geminiRequired ? .issue : .warning, "Gemini Key", "Not set")
            } else {
                add(.ok, "Gemini Key", maskedKey(geminiKey))
            }

            add(.ok, "Source Videos", "\(currentSourceCount) found")
            add(.ok, "Facebook Videos", "\(currentFacebookSourceCount) found")
            add(.ok, "Packages", "\(currentPackageCount) found")
            add(.ok, "Chrome", currentChromeOnline ? "Online" : "Offline")
            add(
                currentChromeProfiles.isEmpty ? .warning : .ok,
                "Chrome Profiles",
                currentChromeProfiles.isEmpty ? "Not found" : "\(currentChromeProfiles.count) found"
            )

            if !openAIKey.isEmpty {
                do {
                    let responseText = try Self.runAIChatBridge(
                        provider: .openaiGPT54,
                        messages: [["role": "user", "content": "Reply with exactly OK"]],
                        imagePaths: [],
                        videoPaths: [],
                        modelOverride: .openaiGPT54,
                        timeout: 20
                    )
                    let message = responseText.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    add(.ok, "OpenAI API", message.isEmpty ? "Connected" : message)
                } catch {
                    add(.issue, "OpenAI API", error.localizedDescription)
                }
            } else {
                add(.warning, "OpenAI API", "Skipped because key is missing")
            }

            if !geminiKey.isEmpty {
                do {
                    let responseText = try Self.runAIChatBridge(
                        provider: .geminiFlash,
                        messages: [["role": "user", "content": "Reply with exactly OK"]],
                        imagePaths: [],
                        videoPaths: [],
                        modelOverride: .geminiFlash,
                        timeout: 20
                    )
                    let message = responseText.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    add(.ok, "Gemini API", message.isEmpty ? "Connected" : message)
                } catch {
                    add(.issue, "Gemini API", error.localizedDescription)
                }
            } else {
                add(.warning, "Gemini API", "Skipped because key is missing")
            }

            let summary: String
            if issueCount == 0 {
                summary = warningCount == 0
                    ? "Health check passed."
                    : "Health check passed with \(warningCount) warning(s)."
            } else {
                summary = "Health check found \(issueCount) issue(s) and \(warningCount) warning(s)."
            }

            Task { @MainActor in
                self.isHealthCheckRunning = false
                self.status = issueCount == 0 ? "Healthy" : "Issue"
                self.detail = summary
                lines.append("Current App Status: \(self.status)")
                lines.append("Current Detail: \(self.detail)")
                lines.append("Current AI Chat Status: \(self.aiChatStatus)")
                self.logs = lines
                self.syncLogText()
                self.lastHealthCheckReport = lines.joined(separator: "\n")
                self.showToast(summary)
            }
        }
    }

    func scheduleAutoHealthCheckIfNeeded() {
        guard !didScheduleAutoHealthCheck else { return }
        didScheduleAutoHealthCheck = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            self?.runAutoHealthCheckWhenReady(retryCount: 0)
        }
    }

    func refreshFacebookControlServerConnectionInfo() {
        facebookControlServerLANURLs = nonLoopbackIPv4Interfaces()
            .map { reelsDashboardBaseURLString(forHost: $0.address) }
        pingFacebookControlServer { [weak self] isOnline in
            DispatchQueue.main.async {
                self?.isFacebookControlServerOnline = isOnline
            }
        }
    }

    func copyFacebookControlServerURL(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showToast("No server URL available.")
            return
        }
        copyToPasteboard(trimmed)
        showToast("Server URL copied.")
    }

    func ensureFacebookControlServerRunning(showToastIfStarted: Bool = false) {
        if let dashboardServerProcess, dashboardServerProcess.isRunning {
            refreshFacebookControlServerConnectionInfo()
            return
        }
        guard FileManager.default.fileExists(atPath: reelsDashboardServerScript.path) else { return }

        pingFacebookControlServer { [weak self] isOnline in
            guard let self else { return }
            if isOnline {
                DispatchQueue.main.async {
                    self.refreshFacebookControlServerConnectionInfo()
                }
                return
            }
            self.startFacebookControlServer(showToastIfStarted: showToastIfStarted)
        }
    }

    private func pingFacebookControlServer(completion: @escaping (Bool) -> Void) {
        var request = URLRequest(url: reelsDashboardServerStatusURL)
        request.timeoutInterval = 1.5
        URLSession.shared.dataTask(with: request) { _, response, error in
            guard error == nil, let httpResponse = response as? HTTPURLResponse else {
                completion(false)
                return
            }
            completion((200 ... 299).contains(httpResponse.statusCode))
        }.resume()
    }

    private func startFacebookControlServer(showToastIfStarted: Bool) {
        guard dashboardServerProcess == nil || dashboardServerProcess?.isRunning != true else { return }

        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [reelsDashboardServerScript.path]
        process.standardOutput = pipe
        process.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            let lines = text
                .split(whereSeparator: \.isNewline)
                .map { String($0) }
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard !lines.isEmpty else { return }
            DispatchQueue.main.async {
                for line in lines {
                    self?.appendLog("[mac-control] \(line)")
                }
            }
        }

        process.terminationHandler = { [weak self] task in
            DispatchQueue.main.async {
                self?.dashboardServerOutputPipe?.fileHandleForReading.readabilityHandler = nil
                self?.dashboardServerOutputPipe = nil
                self?.dashboardServerProcess = nil
                self?.isFacebookControlServerOnline = false
                if self?.didLaunchDashboardServer == true, task.terminationStatus != 0 {
                    self?.appendLog("[mac-control] Server stopped (exit \(task.terminationStatus)).")
                }
            }
        }

        do {
            try process.run()
            dashboardServerProcess = process
            dashboardServerOutputPipe = pipe
            didLaunchDashboardServer = true
            refreshFacebookControlServerConnectionInfo()
            if showToastIfStarted {
                showToast("Mac control server started.")
            }
        } catch {
            appendLog("[mac-control] FAILED to start server: \(error.localizedDescription)")
            if showToastIfStarted {
                showToast("Failed to start Mac control server.")
            }
        }
    }

    private func stopFacebookControlServer() {
        dashboardServerOutputPipe?.fileHandleForReading.readabilityHandler = nil
        dashboardServerOutputPipe = nil
        guard let dashboardServerProcess else { return }
        if dashboardServerProcess.isRunning {
            dashboardServerProcess.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.35) {
                if dashboardServerProcess.isRunning {
                    kill(dashboardServerProcess.processIdentifier, SIGKILL)
                }
            }
        }
        self.dashboardServerProcess = nil
        isFacebookControlServerOnline = false
    }

    private func runAutoHealthCheckWhenReady(retryCount: Int) {
        guard !isHealthCheckRunning else { return }
        if isBusy || isAIChatBusy || isGeminiLiveSessionActive {
            guard retryCount < 12 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.runAutoHealthCheckWhenReady(retryCount: retryCount + 1)
            }
            return
        }
        runHealthCheck()
    }

    func copyAppIssueReport() {
        let formatter = ISO8601DateFormatter()
        var reportLines = [
            "Soranin App Issue Report",
            "Time: \(formatter.string(from: Date()))",
            "App Status: \(status)",
            "Detail: \(detail)",
            "Main App AI: \(activeProvider.label)",
            "AI Chat AI: \(aiChatProvider.label)",
            "Gemini Image Model: \(aiChatGeminiImageModelChoice.label)",
            "AI Chat Status: \(aiChatStatus)",
            "Busy: \(isBusy ? "Yes" : "No")",
            "Live Session Active: \(isGeminiLiveSessionActive ? "Yes" : "No")",
            "Chrome: \(chromeOnline ? "Online" : "Offline")",
            "Source Videos: \(sourceCount)",
            "Facebook Videos: \(facebookSourceCount)",
            "Packages: \(packageCount)"
        ]
        if !lastHealthCheckReport.isEmpty {
            reportLines.append("Health Check:")
            reportLines.append(lastHealthCheckReport)
        }
        let recentLogs = Array(logs.suffix(20))
        if !recentLogs.isEmpty {
            reportLines.append("Recent Logs:")
            reportLines.append(contentsOf: recentLogs)
        }
        copyToPasteboard(reportLines.joined(separator: "\n"))
        showToast("App issue copied.")
    }

    func startLiveChat() {
        guard !isAIChatBusy, !isGeminiLiveSessionActive else { return }
        guard !isAIChatRecording, !isAIChatTranscribing else {
            aiChatStatus = "Stop recording before starting Live."
            showToast(aiChatStatus)
            return
        }

        let saved = loadSavedSettings()
        switch aiChatProvider.providerKey {
        case "gemini":
            let apiKey = (saved["GEMINI_API_KEY"] ?? saved["GOOGLE_API_KEY"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !apiKey.isEmpty else {
                aiChatStatus = "Gemini API key is not set."
                showToast("Gemini API key is not set.")
                return
            }
            startGeminiLiveChat(apiKey: apiKey)
        case "openai":
            let apiKey = (saved["OPENAI_API_KEY"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !apiKey.isEmpty else {
                aiChatStatus = "OpenAI API key is not set."
                showToast("OpenAI API key is not set.")
                return
            }
            startOpenAILiveChat(apiKey: apiKey)
        default:
            aiChatStatus = "This AI does not support Live."
            showToast("This AI does not support Live.")
        }
    }

    private func startGeminiLiveChat(apiKey: String) {
        stopAIChatReplyVoicePlayback()
        activeLiveProviderKey = "gemini"
        isGeminiLiveSessionActive = true
        isGeminiLiveCapturing = false
        isLiveVoicePlaying = false
        isLiveVoicePaused = false
        hasReplayableLiveVoice = false
        didStartModelVoicePlayback = false
        liveUserMessageID = nil
        liveAssistantMessageID = nil
        aiChatStatus = "Connecting to Gemini Live with \(geminiLiveVoiceChoice.geminiVoiceName)..."

        let session = GeminiLiveVoiceSession(
            apiKey: apiKey,
            conversationContext: aiChatConversationSummary(),
            voiceName: geminiLiveVoiceChoice.geminiVoiceName
        ) { [weak self] event in
            guard let self else { return }
            Task { @MainActor in
                self.handleLiveChatEvent(event)
            }
        }
        liveSession = session
        session.start()
    }

    private func startOpenAILiveChat(apiKey: String) {
        stopAIChatReplyVoicePlayback()
        activeLiveProviderKey = "openai"
        isGeminiLiveSessionActive = true
        isGeminiLiveCapturing = false
        isLiveVoicePlaying = false
        isLiveVoicePaused = false
        hasReplayableLiveVoice = false
        didStartModelVoicePlayback = false
        liveUserMessageID = nil
        liveAssistantMessageID = nil
        aiChatStatus = "Connecting to ChatGPT Live with \(openAILiveVoiceChoice.openAIVoiceName)..."

        let session = OpenAILiveVoiceSession(
            apiKey: apiKey,
            conversationContext: aiChatConversationSummary(),
            voiceName: openAILiveVoiceChoice.openAIVoiceName
        ) { [weak self] event in
            guard let self else { return }
            Task { @MainActor in
                self.handleLiveChatEvent(event)
            }
        }
        liveSession = session
        session.start()
    }

    func stopLiveChat() {
        guard isGeminiLiveSessionActive else { return }
        if isGeminiLiveCapturing {
            isGeminiLiveCapturing = false
            liveSession?.finishInput()
            return
        }
        cancelLiveChat(showStatus: true)
    }

    func toggleLiveChatFromShortcut() {
        guard aiChatProvider.providerKey == "gemini" || aiChatProvider.providerKey == "openai" else {
            aiChatStatus = "This AI does not support Live."
            showToast(aiChatStatus)
            return
        }
        guard !isAIChatBusy else {
            aiChatStatus = "Wait for the current AI request to finish first."
            return
        }
        guard !isAIChatRecording, !isAIChatTranscribing else {
            aiChatStatus = "Stop recording before using Live."
            showToast(aiChatStatus)
            return
        }

        if isGeminiLiveSessionActive {
            stopLiveChat()
        } else {
            startLiveChat()
        }
    }

    func pauseLiveVoicePlayback() {
        guard hasReplayableLiveVoice, liveSession?.pauseVoicePlayback() == true else {
            aiChatStatus = "No live voice is playing right now."
            return
        }
    }

    func playLiveVoicePlayback() {
        guard hasReplayableLiveVoice, liveSession?.playVoicePlayback() == true else {
            aiChatStatus = "No live voice is ready to play."
            return
        }
    }

    func cancelLiveChat(showStatus: Bool = true) {
        liveSession?.cancel()
        liveSession = nil
        activeLiveProviderKey = nil
        isGeminiLiveSessionActive = false
        isGeminiLiveCapturing = false
        isLiveVoicePlaying = false
        isLiveVoicePaused = false
        hasReplayableLiveVoice = false
        didStartModelVoicePlayback = false
        stopAIChatReplyVoicePlayback()
        if showStatus {
            aiChatStatus = "Live stopped."
        }
    }

    func prepareForTermination() {
        cancelLiveChat(showStatus: false)
        cancelAIChatRecording(resetStatus: false)
        toastTask?.cancel()
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        if let process {
            if process.isRunning {
                process.terminate()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.35) {
                    if process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                }
            }
        }
        process = nil
        outputPipe = nil
        isRunning = false
        currentTaskKind = nil
        pendingBatchStartAfterCurrentTask = false
        autoStartBatchAfterDownload = false
        stopAIChatReplyVoicePlayback()
        stopFacebookControlServer()
    }

    private func handleLiveChatEvent(_ event: LiveChatEvent) {
        switch event {
        case .status(let text):
            aiChatStatus = text
        case .ready:
            isGeminiLiveSessionActive = true
            isGeminiLiveCapturing = true
            isLiveVoicePlaying = false
            isLiveVoicePaused = false
            aiChatStatus = "Listening..."
        case .waitingForReply:
            isGeminiLiveCapturing = false
            isLiveVoicePlaying = false
            isLiveVoicePaused = false
            aiChatStatus = "Waiting for \(activeLiveProviderName)..."
        case .userTranscript(let text):
            liveUserMessageID = upsertAIChatMessage(targetID: liveUserMessageID, role: "user", content: text)
        case .assistantTranscript(let text):
            let cleanedText = sanitizeAIAssistantReply(text)
            guard !cleanedText.isEmpty else { return }
            liveAssistantMessageID = upsertAIChatMessage(
                targetID: liveAssistantMessageID,
                role: "assistant",
                content: cleanedText
            )
        case .modelVoiceStarted:
            didStartModelVoicePlayback = true
            isLiveVoicePlaying = true
            isLiveVoicePaused = false
            hasReplayableLiveVoice = true
            if liveSession != nil {
                activeLiveProviderKey = activeLiveProviderKey ?? aiChatProvider.providerKey
            }
            aiChatStatus = "Speaking..."
        case .modelVoicePaused:
            isLiveVoicePlaying = false
            isLiveVoicePaused = true
            hasReplayableLiveVoice = true
            aiChatStatus = "Voice paused."
        case .modelVoiceFinished:
            didStartModelVoicePlayback = false
            isLiveVoicePlaying = false
            isLiveVoicePaused = false
            hasReplayableLiveVoice = liveSession != nil
            aiChatStatus = "Voice finished."
        case .modelVoiceUnavailable:
            didStartModelVoicePlayback = false
            isLiveVoicePlaying = false
            isLiveVoicePaused = false
            hasReplayableLiveVoice = false
            aiChatStatus = "\(activeLiveProviderName) voice audio was unavailable."
        case .finished:
            let finalAssistantText = sanitizeAIAssistantReply(contentForAIChatMessage(id: liveAssistantMessageID))
            isGeminiLiveSessionActive = false
            isGeminiLiveCapturing = false
            let providerName = activeLiveProviderName
            activeLiveProviderKey = nil
            if !finalAssistantText.isEmpty {
                liveAssistantMessageID = upsertAIChatMessage(
                    targetID: liveAssistantMessageID,
                    role: "assistant",
                    content: finalAssistantText
                )
            }
            if didStartModelVoicePlayback {
                isLiveVoicePlaying = true
                isLiveVoicePaused = false
                hasReplayableLiveVoice = true
                aiChatStatus = "Speaking..."
            } else {
                aiChatStatus = "\(providerName) replied without live audio."
                liveSession = nil
                didStartModelVoicePlayback = false
                isLiveVoicePlaying = false
                isLiveVoicePaused = false
                hasReplayableLiveVoice = false
            }
        case .error(let message):
            liveSession = nil
            isGeminiLiveSessionActive = false
            isGeminiLiveCapturing = false
            activeLiveProviderKey = nil
            didStartModelVoicePlayback = false
            isLiveVoicePlaying = false
            isLiveVoicePaused = false
            hasReplayableLiveVoice = false
            aiChatStatus = message
            showToast(message)
        }
    }

    private func speakLiveAssistantText(_ text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        stopAIChatReplyVoicePlayback()
        let utterance = AVSpeechUtterance(string: cleaned)
        utterance.rate = 0.45
        utterance.voice = preferredSpeechVoice(for: cleaned)
        speechSynthesizer.speak(utterance)
    }

    private func clearPendingAIChatReplyVoiceChunks() {
        pendingAIChatReplyVoiceChunks.removeAll()
        pendingAIChatReplyVoiceProvider = nil
    }

    @discardableResult
    private func startNextAIChatReplyVoiceChunkIfNeeded() -> Bool {
        guard let provider = pendingAIChatReplyVoiceProvider,
              !pendingAIChatReplyVoiceChunks.isEmpty else {
            clearPendingAIChatReplyVoiceChunks()
            return false
        }
        let nextChunk = pendingAIChatReplyVoiceChunks.removeFirst()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.startAIChatReplyVoiceChunk(nextChunk, provider: provider)
        }
        return true
    }

    private func startOpenAIReplyVoiceFallbackIfPossible(_ text: String, statusPrefix: String) -> Bool {
        let spokenText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spokenText.isEmpty else { return false }
        let saved = loadSavedSettings()
        let apiKey = (saved["OPENAI_API_KEY"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { return false }

        let requestID = UUID()
        openAIReplyVoiceRequestID = requestID
        didStartOpenAIReplyVoicePlayback = false
        aiChatStatus = "\(statusPrefix) Using OpenAI voice fallback..."

        let speaker = OpenAIReplyVoiceSpeaker(
            apiKey: apiKey,
            text: spokenText,
            voiceName: openAILiveVoiceChoice.openAIVoiceName
        ) { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                guard self.openAIReplyVoiceRequestID == requestID else { return }
                switch event {
                case .started:
                    self.didStartOpenAIReplyVoicePlayback = true
                    self.aiChatStatus = "OpenAI fallback is speaking..."
                case .finished:
                    self.openAIReplyVoiceSpeaker = nil
                    self.openAIReplyVoiceRequestID = nil
                    self.didStartOpenAIReplyVoicePlayback = false
                    _ = self.startNextAIChatReplyVoiceChunkIfNeeded()
                case .failed:
                    self.openAIReplyVoiceSpeaker = nil
                    self.openAIReplyVoiceRequestID = nil
                    self.didStartOpenAIReplyVoicePlayback = false
                    self.clearPendingAIChatReplyVoiceChunks()
                    self.aiChatStatus = "\(statusPrefix) OpenAI fallback voice was unavailable."
                }
            }
        }

        openAIReplyVoiceSpeaker = speaker
        speaker.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 12.0) { [weak self] in
            guard let self else { return }
            guard self.openAIReplyVoiceRequestID == requestID else { return }
            guard !self.didStartOpenAIReplyVoicePlayback else { return }
            self.openAIReplyVoiceSpeaker?.cancel()
            self.openAIReplyVoiceSpeaker = nil
            self.openAIReplyVoiceRequestID = nil
            self.didStartOpenAIReplyVoicePlayback = false
            self.aiChatStatus = "\(statusPrefix) OpenAI fallback is taking too long."
        }
        return true
    }

    private func speakAIChatReplyTextIfNeeded(_ text: String, provider: AIProvider) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        guard !isGeminiLiveSessionActive else { return }
        stopAIChatReplyVoicePlayback()
        let chunks = aiChatReplyVoiceChunks(from: cleaned, provider: provider)
        guard let firstChunk = chunks.first else { return }
        pendingAIChatReplyVoiceChunks = Array(chunks.dropFirst())
        pendingAIChatReplyVoiceProvider = provider
        startAIChatReplyVoiceChunk(firstChunk, provider: provider)
    }

    private func startAIChatReplyVoiceChunk(_ spokenText: String, provider: AIProvider) {
        guard !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            _ = startNextAIChatReplyVoiceChunkIfNeeded()
            return
        }
        if provider.providerKey == "openai" {
            let saved = loadSavedSettings()
            let apiKey = (saved["OPENAI_API_KEY"] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !apiKey.isEmpty {
                let requestID = UUID()
                openAIReplyVoiceRequestID = requestID
                didStartOpenAIReplyVoicePlayback = false
                aiChatStatus = "Preparing OpenAI voice..."
                let speaker = OpenAIReplyVoiceSpeaker(
                    apiKey: apiKey,
                    text: spokenText,
                    voiceName: openAILiveVoiceChoice.openAIVoiceName
                ) { [weak self] event in
                    Task { @MainActor in
                        guard let self else { return }
                        guard self.openAIReplyVoiceRequestID == requestID else { return }
                        switch event {
                        case .started:
                            self.didStartOpenAIReplyVoicePlayback = true
                            self.aiChatStatus = "OpenAI is speaking..."
                        case .finished:
                            self.openAIReplyVoiceSpeaker = nil
                            self.openAIReplyVoiceRequestID = nil
                            self.didStartOpenAIReplyVoicePlayback = false
                            _ = self.startNextAIChatReplyVoiceChunkIfNeeded()
                        case .failed:
                            self.openAIReplyVoiceSpeaker = nil
                            self.openAIReplyVoiceRequestID = nil
                            self.didStartOpenAIReplyVoicePlayback = false
                            self.clearPendingAIChatReplyVoiceChunks()
                            self.aiChatStatus = "OpenAI voice was unavailable for this reply."
                        }
                    }
                }
                openAIReplyVoiceSpeaker = speaker
                speaker.start()
                DispatchQueue.main.asyncAfter(deadline: .now() + 9.0) { [weak self] in
                    guard let self else { return }
                    guard self.openAIReplyVoiceRequestID == requestID else { return }
                    guard !self.didStartOpenAIReplyVoicePlayback else { return }
                    self.openAIReplyVoiceSpeaker?.cancel()
                    self.openAIReplyVoiceSpeaker = nil
                    self.openAIReplyVoiceRequestID = nil
                    self.didStartOpenAIReplyVoicePlayback = false
                    self.clearPendingAIChatReplyVoiceChunks()
                    self.aiChatStatus = "OpenAI voice is taking too long. Use Live for full natural voice."
                }
                return
            }
        }
        if provider.providerKey == "gemini" {
            if containsKhmerScript(spokenText) {
                if startOpenAIReplyVoiceFallbackIfPossible(spokenText, statusPrefix: "Gemini Khmer reply uses OpenAI voice.") {
                    return
                }
                clearPendingAIChatReplyVoiceChunks()
                aiChatStatus = "OpenAI voice is required to speak Khmer replies from Gemini."
                return
            }
            let saved = loadSavedSettings()
            let apiKey = (saved["GEMINI_API_KEY"] ?? saved["GOOGLE_API_KEY"] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !apiKey.isEmpty {
                let requestID = UUID()
                geminiReplyVoiceRequestID = requestID
                didStartGeminiReplyVoicePlayback = false
                aiChatStatus = "Preparing Gemini voice..."
                let speaker = GeminiReplyVoiceSpeaker(
                    apiKey: apiKey,
                    text: spokenText,
                    voiceName: geminiLiveVoiceChoice.geminiVoiceName
                ) { [weak self] event in
                    Task { @MainActor in
                        guard let self else { return }
                        guard self.geminiReplyVoiceRequestID == requestID else { return }
                        switch event {
                        case .started:
                            self.didStartGeminiReplyVoicePlayback = true
                            self.aiChatStatus = "Gemini is speaking..."
                        case .finished:
                            self.geminiReplyVoiceSpeaker = nil
                            self.geminiReplyVoiceRequestID = nil
                            self.didStartGeminiReplyVoicePlayback = false
                            _ = self.startNextAIChatReplyVoiceChunkIfNeeded()
                        case .failed:
                            self.geminiReplyVoiceSpeaker = nil
                            self.geminiReplyVoiceRequestID = nil
                            self.didStartGeminiReplyVoicePlayback = false
                            if self.geminiReplyVoiceFallbackMode == .geminiWithOpenAIFallback,
                               self.startOpenAIReplyVoiceFallbackIfPossible(spokenText, statusPrefix: "Gemini voice was unavailable for this reply.") {
                                return
                            }
                            if self.geminiReplyVoiceFallbackMode == .geminiOnly {
                                self.clearPendingAIChatReplyVoiceChunks()
                                self.aiChatStatus = "Gemini voice was unavailable for this reply."
                            } else if !self.startOpenAIReplyVoiceFallbackIfPossible(spokenText, statusPrefix: "Gemini voice was unavailable for this reply.") {
                                self.clearPendingAIChatReplyVoiceChunks()
                                self.aiChatStatus = "Gemini voice was unavailable for this reply."
                            }
                        }
                    }
                }
                geminiReplyVoiceSpeaker = speaker
                speaker.start()
                DispatchQueue.main.asyncAfter(deadline: .now() + 12.0) { [weak self] in
                    guard let self else { return }
                    guard self.geminiReplyVoiceRequestID == requestID else { return }
                    guard !self.didStartGeminiReplyVoicePlayback else { return }
                    self.geminiReplyVoiceSpeaker?.cancel()
                    self.geminiReplyVoiceSpeaker = nil
                    self.geminiReplyVoiceRequestID = nil
                    self.didStartGeminiReplyVoicePlayback = false
                    if self.geminiReplyVoiceFallbackMode == .geminiWithOpenAIFallback,
                       self.startOpenAIReplyVoiceFallbackIfPossible(spokenText, statusPrefix: "Gemini voice is taking too long.") {
                        return
                    }
                    if self.geminiReplyVoiceFallbackMode == .geminiOnly {
                        self.clearPendingAIChatReplyVoiceChunks()
                        self.aiChatStatus = "Gemini voice is taking too long. Use Live for full natural voice."
                    } else if !self.startOpenAIReplyVoiceFallbackIfPossible(spokenText, statusPrefix: "Gemini voice is taking too long.") {
                        self.clearPendingAIChatReplyVoiceChunks()
                        self.aiChatStatus = "Gemini voice is taking too long. Use Live for full natural voice."
                    }
                }
                return
            }
        }
        clearPendingAIChatReplyVoiceChunks()
        aiChatStatus = "\(provider.label) voice is unavailable."
    }

    private func aiChatReplyVoiceChunks(from text: String, provider: AIProvider) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }

        let maxCharacters = provider.providerKey == "gemini" ? 88 : 260
        let maxChunks = provider.providerKey == "gemini" ? 8 : 4
        var remaining = normalized[...]
        var chunks: [String] = []
        let sentenceTerminators = CharacterSet(charactersIn: ".!?។៕\n")

        while !remaining.isEmpty && chunks.count < maxChunks {
            let remainingText = String(remaining).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !remainingText.isEmpty else { break }
            if remainingText.count <= maxCharacters {
                chunks.append(remainingText)
                break
            }

            let window = String(remainingText.prefix(maxCharacters))
            var chosen = window.trimmingCharacters(in: .whitespacesAndNewlines)

            if let scalarIndex = window.unicodeScalars.lastIndex(where: { sentenceTerminators.contains($0) }) {
                let endIndex = scalarIndex.samePosition(in: window) ?? window.endIndex
                let sentence = String(window[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
                if sentence.count >= maxCharacters / 3 {
                    chosen = sentence
                }
            } else if let lastSpace = window.lastIndex(of: " ") {
                let candidate = String(window[..<lastSpace]).trimmingCharacters(in: .whitespacesAndNewlines)
                if candidate.count >= maxCharacters / 2 {
                    chosen = candidate
                }
            }

            chunks.append(chosen)

            if let range = remainingText.range(of: chosen) {
                let nextStart = range.upperBound
                remaining = remainingText[nextStart...]
            } else {
                break
            }
        }

        return chunks.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private func stopAIChatReplyVoicePlayback() {
        openAIReplyVoiceSpeaker?.cancel()
        openAIReplyVoiceSpeaker = nil
        openAIReplyVoiceRequestID = nil
        didStartOpenAIReplyVoicePlayback = false
        geminiReplyVoiceSpeaker?.cancel()
        geminiReplyVoiceSpeaker = nil
        geminiReplyVoiceRequestID = nil
        didStartGeminiReplyVoicePlayback = false
        clearPendingAIChatReplyVoiceChunks()
        speechSynthesizer.stopSpeaking(at: .immediate)
    }

    private func speakAIChatReplyWithSystemVoice(_ cleaned: String, provider: AIProvider) {
        let utterance = AVSpeechUtterance(string: cleaned)
        utterance.rate = 0.45
        utterance.pitchMultiplier = speechPitchMultiplier(for: provider)
        utterance.voice = preferredSpeechVoice(for: cleaned)
        speechSynthesizer.speak(utterance)
    }

    private func speechPitchMultiplier(for provider: AIProvider) -> Float {
        switch liveVoiceChoice(for: provider) {
        case .female:
            return 1.08
        case .male:
            return 0.88
        }
    }

    private func preferredSpeechVoice(for text: String) -> AVSpeechSynthesisVoice? {
        if containsKhmerScript(text) {
            return AVSpeechSynthesisVoice(language: "km-KH")
                ?? AVSpeechSynthesisVoice(language: "th-TH")
                ?? AVSpeechSynthesisVoice(language: "vi-VN")
        }
        return nil
    }

    private func containsKhmerScript(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x1780...0x17FF).contains(scalar.value) || (0x19E0...0x19FF).contains(scalar.value)
        }
    }

    private func sanitizeAIAssistantReply(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if extractPromptText(from: trimmed) != nil,
           trimmed.lowercased().contains("prompt") {
            return trimmed
        }

        let metaMarkers = [
            "acknowledge and respond",
            "i've processed the user's",
            "i have processed the user's",
            "my core approach",
            "i've formulated a response",
            "i have formulated a response",
            "which translates to",
            "this seems a solid approach",
            "i am now assessing",
            "i'm now assessing",
            "i am assessing",
            "i need to clarify",
            "i will need to",
            "i'll need to",
            "i need to determine",
            "i'm focusing on",
            "i am focusing on",
            "to respond appropriately",
            "the feasibility of",
            "clarify the details",
            "what tools or steps are needed",
            "providing khmer response",
        ]
        func isMetaLine(_ line: String) -> Bool {
            let loweredLine = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !loweredLine.isEmpty else { return false }
            if metaMarkers.contains(where: { loweredLine.contains($0) }) {
                return true
            }
            let metaPrefixes = [
                "i am now ",
                "i'm now ",
                "i am assessing",
                "i'm assessing",
                "i need to ",
                "i will need to ",
                "i'll need to ",
                "i am going to ",
                "i'm going to ",
                "i will ",
                "i'm focusing on ",
                "i am focusing on ",
                "to respond appropriately",
            ]
            return metaPrefixes.contains(where: { loweredLine.hasPrefix($0) })
        }
        let lowered = trimmed.lowercased()
        let filteredLines = trimmed
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !isMetaLine($0) }
        if !filteredLines.isEmpty && filteredLines.count != trimmed.components(separatedBy: .newlines).filter({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }).count {
            let candidate = filteredLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty {
                return candidate
            }
        }
        if metaMarkers.contains(where: { lowered.contains($0) }) {
            let targetedPatterns = [
                #"(?:i['’]ve formulated a response|i have formulated a response|response|reply)\s*:\s*[\"“](.+?)[\"”]"#,
                #"(?:final answer|answer)\s*:\s*[\"“](.+?)[\"”]"#,
            ]
            let fullRange = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            for pattern in targetedPatterns {
                if let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]),
                   let match = regex.firstMatch(in: trimmed, options: [], range: fullRange),
                   match.numberOfRanges > 1,
                   let capturedRange = Range(match.range(at: 1), in: trimmed) {
                    let candidate = trimmed[capturedRange]
                        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let candidateLowered = candidate.lowercased()
                    if !candidate.isEmpty && !metaMarkers.contains(where: { candidateLowered.contains($0) }) {
                        return candidate
                    }
                }
            }

            let quotedPattern = #"[\"“](.+?)[\"”]"#
            if let regex = try? NSRegularExpression(pattern: quotedPattern, options: [.dotMatchesLineSeparators]) {
                for match in regex.matches(in: trimmed, options: [], range: fullRange) where match.numberOfRanges > 1 {
                    guard let capturedRange = Range(match.range(at: 1), in: trimmed) else { continue }
                    let candidate = trimmed[capturedRange]
                        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let candidateLowered = candidate.lowercased()
                    if !candidate.isEmpty,
                       !metaMarkers.contains(where: { candidateLowered.contains($0) }),
                       candidate.contains(" ") || containsKhmerScript(candidate) || candidate.count > 18 {
                        return candidate
                    }
                }
            }
        }

        let withoutHeading = trimmed.replacingOccurrences(
            of: #"^\s*\*\*[^*]+\*\*\s*"#,
            with: "",
            options: .regularExpression
        )
        let normalized = withoutHeading
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if isMetaLine(normalized) {
            return ""
        }
        return normalized
    }

    private func aiChatConversationSummary() -> String {
        aiChatMessages.suffix(12).map { message in
            let speaker = message.role == "user" ? "User" : "Assistant"
            return "\(speaker): \(message.content)"
        }.joined(separator: "\n")
    }

    private func appendAIChatMessage(_ message: AIChatMessage) {
        aiChatMessages.append(message)
        handleHiddenAIChatReplyIfNeeded(for: message)
        trimAIChatMessages()
        persistCurrentAIChatSession()
    }

    private func upsertAIChatMessage(targetID: UUID?, role: String, content: String) -> UUID? {
        let cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return targetID }

        var resolvedID = targetID
        if let currentID = targetID,
           let index = aiChatMessages.firstIndex(where: { $0.id == currentID }) {
            aiChatMessages[index].content = cleaned
        } else {
            let message = AIChatMessage(role: role, content: cleaned)
            aiChatMessages.append(message)
            handleHiddenAIChatReplyIfNeeded(for: message)
            resolvedID = message.id
        }
        trimAIChatMessages()
        persistCurrentAIChatSession()
        return resolvedID
    }

    private func handleHiddenAIChatReplyIfNeeded(for message: AIChatMessage) {
        guard message.role == "assistant", !isAIChatVisible else { return }
        aiChatUnreadCount = min(aiChatUnreadCount + 1, 99)
        showToast(aiChatReplyToastText(for: message))
    }

    private func aiChatReplyToastText(for message: AIChatMessage) -> String {
        if message.attachments.contains(where: { $0.kind == .video }) {
            return "AI Chat generated a new video."
        }
        if message.attachments.contains(where: { $0.kind == .image }) {
            return "AI Chat generated a new image."
        }

        let collapsed = message.content
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else {
            return "AI Chat replied."
        }
        let previewLimit = 72
        if collapsed.count > previewLimit {
            let preview = String(collapsed.prefix(previewLimit)).trimmingCharacters(in: .whitespacesAndNewlines)
            return "AI Chat replied: \(preview)..."
        }
        return "AI Chat replied: \(collapsed)"
    }

    private func trimAIChatMessages() {
        guard aiChatMessages.count > 20 else { return }
        aiChatMessages = Array(aiChatMessages.suffix(20))
        let keptIDs = Set(aiChatMessages.map(\.id))
        if let liveUserMessageID, !keptIDs.contains(liveUserMessageID) {
            self.liveUserMessageID = nil
        }
        if let liveAssistantMessageID, !keptIDs.contains(liveAssistantMessageID) {
            self.liveAssistantMessageID = nil
        }
    }

    private func contentForAIChatMessage(id: UUID?) -> String {
        guard let id,
              let message = aiChatMessages.first(where: { $0.id == id })
        else {
            return ""
        }
        return message.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func bootstrapAIChatSessions() {
        let store = loadAIChatStore()
        aiChatSessions = store.sessions.map { session in
            var normalized = session
            normalized.messages = normalized.messages.map { message in
                guard message.role == "assistant" else { return message }
                let cleaned = sanitizeAIAssistantReply(message.content)
                guard !cleaned.isEmpty, cleaned != message.content else { return message }
                return AIChatMessage(id: message.id, role: message.role, content: cleaned, attachments: message.attachments)
            }
            let trimmedTitle = normalized.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if (trimmedTitle.isEmpty || trimmedTitle == "New Chat"),
               let firstTitle = aiChatFirstUserTitle(from: normalized.messages) {
                normalized.title = firstTitle
            }
            return normalized
        }.sorted { $0.updatedAt > $1.updatedAt }
        if let currentID = store.currentSessionID,
           let current = aiChatSessions.first(where: { $0.id == currentID }) {
            currentAIChatSessionID = current.id
            aiChatMessages = current.messages
            persistAIChatStore()
            return
        }
        if let latest = aiChatSessions.first {
            currentAIChatSessionID = latest.id
            aiChatMessages = latest.messages
            persistAIChatStore()
            return
        }
        startNewAIChatSession()
    }

    private func loadAIChatStore() -> AIChatStore {
        guard let data = try? Data(contentsOf: aiChatHistoryFile),
              let store = try? JSONDecoder().decode(AIChatStore.self, from: data)
        else {
            return AIChatStore(currentSessionID: nil, sessions: [])
        }
        return store
    }

    private func persistCurrentAIChatSession(markUpdated: Bool = true) {
        let now = Date()
        if let currentID = currentAIChatSessionID,
           let index = aiChatSessions.firstIndex(where: { $0.id == currentID }) {
            aiChatSessions[index].messages = aiChatMessages
            let trimmedTitle = aiChatSessions[index].title.trimmingCharacters(in: .whitespacesAndNewlines)
            if (trimmedTitle.isEmpty || trimmedTitle == "New Chat"),
               let firstTitle = aiChatFirstUserTitle(from: aiChatMessages) {
                aiChatSessions[index].title = firstTitle
            } else if trimmedTitle.isEmpty {
                aiChatSessions[index].title = "New Chat"
            }
            if markUpdated {
                aiChatSessions[index].updatedAt = now
            }
        } else {
            let sessionTitle = aiChatFirstUserTitle(from: aiChatMessages) ?? "New Chat"
            let session = AIChatSession(
                id: currentAIChatSessionID ?? UUID(),
                createdAt: now,
                updatedAt: now,
                title: sessionTitle,
                messages: aiChatMessages
            )
            currentAIChatSessionID = session.id
            aiChatSessions.insert(session, at: 0)
        }
        aiChatSessions.sort { $0.updatedAt > $1.updatedAt }
        persistAIChatStore()
    }

    private func persistAIChatStore() {
        let store = AIChatStore(currentSessionID: currentAIChatSessionID, sessions: aiChatSessions)
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? data.write(to: aiChatHistoryFile, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: aiChatHistoryFile.path)
    }

    private func setCurrentAIChatSessionTitle(_ title: String) {
        guard let currentID = currentAIChatSessionID else { return }
        guard let index = aiChatSessions.firstIndex(where: { $0.id == currentID }) else { return }
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        aiChatSessions[index].title = cleaned.isEmpty ? "New Chat" : cleaned
        persistAIChatStore()
    }

    func refreshChromeProfiles() {
        refreshChromeProfilesAsync(showToast: true)
    }

    func copyAllChromeProfiles() {
        let lines = chromeProfiles.map { "\($0.directoryName) — \($0.displayName)" }
        guard !lines.isEmpty else {
            showToast("No Chrome profiles found.")
            return
        }
        let text = lines.joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        showToast("Chrome profiles copied.")
    }

    private nonisolated static func runAIChatBridge(
        provider: AIProvider,
        messages: [[String: String]],
        imagePaths: [String],
        videoPaths: [String],
        modelOverride: AIProvider? = nil,
        timeout: TimeInterval = 30
    ) throws -> AIChatBridgeResult {
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [aiChatBridgeScript.path]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        var environment = ProcessInfo.processInfo.environment
        if let modelOverride {
            environment["AI_MODEL"] = modelOverride.rawValue
            environment["AI_PROVIDER"] = modelOverride.providerKey
        }
        process.environment = environment

        let payload: [String: Any] = [
            "provider": provider.providerKey,
            "messages": messages,
            "image_paths": imagePaths,
            "video_paths": videoPaths,
        ]
        let inputData = try JSONSerialization.data(withJSONObject: payload, options: [])

        let readerGroup = DispatchGroup()
        let readerLock = NSLock()
        var stdoutData = Data()
        var stderrData = Data()

        readerGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            readerLock.lock()
            stdoutData = data
            readerLock.unlock()
            readerGroup.leave()
        }

        readerGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            readerLock.lock()
            stderrData = data
            readerLock.unlock()
            readerGroup.leave()
        }

        try process.run()
        inputPipe.fileHandleForWriting.write(inputData)
        try? inputPipe.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }

        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.35)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            _ = readerGroup.wait(timeout: .now() + 5)
            throw NSError(
                domain: "SoraninAIChat",
                code: 408,
                userInfo: [NSLocalizedDescriptionKey: "\(provider.label) request timed out. Please try again."]
            )
        }

        _ = readerGroup.wait(timeout: .now() + 5)
        let stdoutText = String(decoding: stdoutData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let stderrText = String(decoding: stderrData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)

        let jsonCandidate: String? = {
            let lines = stdoutText
                .split(whereSeparator: \.isNewline)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if let lastJSONObjectLine = lines.last(where: { $0.hasPrefix("{") && $0.hasSuffix("}") }) {
                return lastJSONObjectLine
            }
            return stdoutText.isEmpty ? nil : stdoutText
        }()

        guard let jsonCandidate,
              let jsonData = jsonCandidate.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        else {
            if !stderrText.isEmpty {
                throw NSError(domain: "SoraninAIChat", code: 1, userInfo: [NSLocalizedDescriptionKey: stderrText])
            }
            if !stdoutText.isEmpty {
                let compactStdout = stdoutText
                    .components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                throw NSError(domain: "SoraninAIChat", code: 1, userInfo: [NSLocalizedDescriptionKey: compactStdout])
            }
            throw NSError(domain: "SoraninAIChat", code: 1, userInfo: [NSLocalizedDescriptionKey: "AI chat returned an invalid response."])
        }

        if let ok = object["ok"] as? Bool, ok, let text = object["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let attachments: [AIChatAttachment]
            if let media = object["media"] as? [[String: Any]] {
                attachments = media.compactMap { item in
                    guard let kindRaw = (item["kind"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                          let kind = AIChatAttachmentKind(rawValue: kindRaw),
                          let path = (item["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !path.isEmpty
                    else {
                        return nil
                    }
                    let mimeType = (item["mime_type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let displayName = (item["display_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    return AIChatAttachment(kind: kind, path: path, mimeType: mimeType, displayName: displayName)
                }
            } else {
                attachments = []
            }
            return AIChatBridgeResult(
                text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                attachments: attachments
            )
        }

        let message = (object["error"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        throw NSError(
            domain: "SoraninAIChat",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: (message?.isEmpty == false ? message! : "AI chat failed.")]
        )
    }

    private func isImageAttachmentURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "webp", "heic", "gif", "bmp"].contains(ext)
    }

    private func isVideoAttachmentURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["mp4", "mov", "m4v", "avi", "mkv", "webm"].contains(ext)
    }

    private func aiChatAttachment(from url: URL) -> AIChatAttachment? {
        let standardized = url.standardizedFileURL
        if isImageAttachmentURL(standardized) {
            return AIChatAttachment(kind: .image, path: standardized.path, mimeType: nil, displayName: standardized.lastPathComponent)
        }
        if isVideoAttachmentURL(standardized) {
            return AIChatAttachment(kind: .video, path: standardized.path, mimeType: nil, displayName: standardized.lastPathComponent)
        }
        return nil
    }

    private func supportedVideoOpenPanelContentTypes() -> [UTType] {
        supportedOpenPanelContentTypes(
            imageExtensions: [],
            videoExtensions: ["mp4", "mov", "m4v", "avi", "mkv", "webm"]
        )
    }

    private func supportedAIChatOpenPanelContentTypes() -> [UTType] {
        supportedOpenPanelContentTypes(
            imageExtensions: ["jpg", "jpeg", "png", "webp", "heic", "gif", "bmp"],
            videoExtensions: ["mp4", "mov", "m4v", "avi", "mkv", "webm"]
        )
    }

    private func supportedOpenPanelContentTypes(imageExtensions: [String], videoExtensions: [String]) -> [UTType] {
        var seen = Set<String>()
        var types: [UTType] = []

        func appendType(_ type: UTType) {
            let identifier = type.identifier
            guard !seen.contains(identifier) else { return }
            seen.insert(identifier)
            types.append(type)
        }

        if !imageExtensions.isEmpty {
            appendType(.image)
        }
        if !videoExtensions.isEmpty {
            appendType(.movie)
        }

        for ext in imageExtensions + videoExtensions {
            if let type = UTType(filenameExtension: ext) {
                appendType(type)
            }
        }

        return types.isEmpty ? [.data] : types
    }

    private func requestedAIChatTimeout(for prompt: String, attachmentURLs: [URL], provider: AIProvider) -> TimeInterval {
        let baseTimeout: TimeInterval
        if attachmentURLs.isEmpty {
            switch provider {
            case .geminiPro, .gemini25Pro:
                baseTimeout = 180
            case .geminiFlash:
                baseTimeout = 75
            case .openaiGPT54:
                baseTimeout = 30
            }
        } else {
            switch provider {
            case .geminiPro, .gemini25Pro:
                baseTimeout = 420
            case .geminiFlash:
                baseTimeout = 240
            case .openaiGPT54:
                baseTimeout = 150
            }
        }
        guard let mediaKind = requestedGeneratedMediaKind(for: prompt) else {
            return baseTimeout
        }
        switch mediaKind {
        case .image:
            if requestedGeneratedImageModelLabel(for: prompt, provider: provider, attachmentURLs: attachmentURLs) != nil {
                return max(baseTimeout, 480)
            }
            switch provider {
            case .geminiPro, .gemini25Pro:
                return max(baseTimeout, 540)
            case .geminiFlash:
                return max(baseTimeout, 300)
            case .openaiGPT54:
                return max(baseTimeout, 180)
            }
        case .video:
            switch provider {
            case .geminiPro, .gemini25Pro:
                return max(baseTimeout, 1500)
            case .geminiFlash:
                return max(baseTimeout, 1200)
            case .openaiGPT54:
                return max(baseTimeout, 900)
            }
        }
    }

    func openAIChatAttachment(_ attachment: AIChatAttachment) {
        let url = attachment.url
        guard FileManager.default.fileExists(atPath: url.path) else {
            showToast("File not found.")
            return
        }
        NSWorkspace.shared.open(url)
    }

    func revealAIChatAttachment(_ attachment: AIChatAttachment) {
        let url = attachment.url
        guard FileManager.default.fileExists(atPath: url.path) else {
            showToast("File not found.")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func resolvedChromeApplicationURL() -> URL? {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: chromeBundleIdentifier) {
            return appURL
        }

        let fileManager = FileManager.default
        for candidate in [chromeDefaultApplicationURL, chromeUserApplicationURL] {
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["kMDItemCFBundleIdentifier == '\(chromeBundleIdentifier)'"]
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        process.waitUntilExit()
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            return nil
        }

        for line in output.split(whereSeparator: \.isNewline) {
            let path = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { continue }
            let url = URL(fileURLWithPath: path, isDirectory: true)
            if fileManager.fileExists(atPath: url.path) {
                return url
            }
        }

        return nil
    }

    func openChromeProfile(_ item: ChromeProfileItem) {
        guard let chromeApplicationURL = resolvedChromeApplicationURL() else {
            showToast("Google Chrome not found.")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [
            "-na",
            chromeApplicationURL.path,
            "--args",
            "--profile-directory=\(item.directoryName)",
        ]
        do {
            try process.run()
            showToast("Opened \(item.displayName).")
        } catch {
            showToast("Failed to open Chrome profile.")
        }
    }

    func closeChromeProfiles(_ items: [ChromeProfileItem]) {
        let directoryNames = Set(items.map(\.directoryName))
        guard !directoryNames.isEmpty else {
            showToast("No profile selected.")
            return
        }

        let runningProfiles = runningChromeProfileProcesses()
        let matchingPIDs = runningProfiles.compactMap { directoryNames.contains($0.directoryName) ? $0.pid : nil }
        guard !matchingPIDs.isEmpty else {
            showToast("Selected profile is already offline.")
            refreshChromeProfiles()
            return
        }

        var closedCount = 0
        for pid in matchingPIDs {
            if kill(pid, SIGTERM) == 0 {
                closedCount += 1
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            self.refreshChromeProfiles()
        }
        showToast(closedCount > 0 ? "Closed \(closedCount) Chrome profile process(es)." : "Failed to close selected profile.")
    }

    func addChromeProfile() {
        guard let chromeApplicationURL = resolvedChromeApplicationURL() else {
            showToast("Google Chrome not found.")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [
            "-a",
            chromeApplicationURL.path,
            "chrome://settings/manageProfile",
        ]
        do {
            try process.run()
            showToast("Opened Chrome profile manager.")
        } catch {
            showToast("Failed to open profile manager.")
        }
    }

    func deleteChromeProfiles(_ items: [ChromeProfileItem]) {
        guard !items.isEmpty else {
            showToast("No profile selected.")
            return
        }
        guard !isChromeRunning() else {
            showToast("Close Chrome before deleting profiles.")
            return
        }
        guard !items.contains(where: { $0.directoryName == "Default" }) else {
            showToast("Default profile can't be deleted.")
            return
        }
        guard
            let data = try? Data(contentsOf: chromeLocalStateFile),
            var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            var profile = object["profile"] as? [String: Any],
            var infoCache = profile["info_cache"] as? [String: Any]
        else {
            showToast("Failed to load Chrome profiles.")
            return
        }

        let directoryNames = Set(items.map(\.directoryName))
        var profilesOrder = (profile["profiles_order"] as? [String]) ?? []
        var lastActiveProfiles = (profile["last_active_profiles"] as? [String]) ?? []
        let oldLastUsed = profile["last_used"] as? String

        for directoryName in directoryNames {
            infoCache.removeValue(forKey: directoryName)
            profilesOrder.removeAll { $0 == directoryName }
            lastActiveProfiles.removeAll { $0 == directoryName }
            let profileDirectory = chromeUserDataDirectory.appendingPathComponent(directoryName, isDirectory: true)
            try? FileManager.default.removeItem(at: profileDirectory)
        }

        profile["info_cache"] = infoCache
        profile["profiles_order"] = profilesOrder
        profile["last_active_profiles"] = lastActiveProfiles
        if let oldLastUsed, directoryNames.contains(oldLastUsed) {
            profile["last_used"] = profilesOrder.first ?? "Default"
        }
        object["profile"] = profile

        guard let encoded = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]) else {
            showToast("Failed to save Chrome profiles.")
            return
        }
        do {
            try encoded.write(to: chromeLocalStateFile, options: [.atomic])
            refreshChromeProfiles()
            showToast("\(directoryNames.count) profile(s) deleted.")
        } catch {
            showToast("Failed to delete profile.")
        }
    }

    private func showToast(_ message: String) {
        toastMessage = message
        toastTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.toastMessage = nil
        }
        toastTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4, execute: task)
    }

    private func playAIChatCue(named soundName: String) {
        if aiChatCueSounds[soundName] == nil {
            let soundURL = URL(fileURLWithPath: "/System/Library/Sounds/\(soundName).aiff")
            aiChatCueSounds[soundName] = NSSound(contentsOf: soundURL, byReference: true)
        }
        if let sound = aiChatCueSounds[soundName] {
            sound.stop()
            sound.play()
        } else {
            NSSound.beep()
        }
    }

    private func playAIChatThinkingCue() {
        playAIChatCue(named: "Tink")
    }

    private func playAIChatReplyCue() {
        playAIChatCue(named: "Glass")
    }

    private func playAIChatVideoReadyCue() {
        playAIChatCue(named: "Hero")
    }

    private func playAIChatErrorCue() {
        playAIChatCue(named: "Basso")
    }

    private func playSoraDownloadCompleteCue() {
        playAIChatCue(named: "Glass")
    }

    private func playBatchCompleteCue() {
        playAIChatCue(named: "Hero")
    }

    private func importDroppedVideoURLs(_ urls: [URL]) {
        try? FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        let allowed = Set(["mp4", "mov", "m4v", "avi", "mkv"])
        var readyCount = 0
        var skippedCount = 0

        for sourceURL in urls {
            guard sourceURL.isFileURL, allowed.contains(sourceURL.pathExtension.lowercased()) else {
                skippedCount += 1
                continue
            }

            let destinationURL = destinationURLForImportedVideo(sourceURL)
            do {
                if sourceURL.resolvingSymlinksInPath().standardizedFileURL.path == destinationURL.resolvingSymlinksInPath().standardizedFileURL.path {
                    appendLog("[drop] Ready \(destinationURL.lastPathComponent)")
                } else {
                    try moveImportedVideo(from: sourceURL, to: destinationURL)
                    appendLog("[drop] Moved \(destinationURL.lastPathComponent)")
                }
                readyCount += 1
            } catch {
                appendLog("[drop] FAILED \(sourceURL.lastPathComponent): \(error.localizedDescription)")
            }
        }

        refreshMetadata()

        guard readyCount > 0 else {
            showToast("No valid video file found.")
            return
        }

        let summary = readyCount == 1 ? "1 video moved." : "\(readyCount) videos moved."
        if currentTaskKind == .batch {
            pendingBatchStartAfterCurrentTask = true
            detail = "Moved \(readyCount) video(s). Auto start queued."
            showToast(skippedCount > 0 ? "\(summary) \(skippedCount) skipped." : "\(summary) Auto start queued.")
            return
        }

        if isBusy {
            detail = "Moved \(readyCount) video(s). Will start after current download."
            showToast(skippedCount > 0 ? "\(summary) \(skippedCount) skipped." : "\(summary) Auto start after download.")
            return
        }

        appendLog("WAIT... Auto starting dropped videos.")
        detail = "Video drop complete. Starting batch..."
        showToast(skippedCount > 0 ? "\(summary) \(skippedCount) skipped." : "\(summary) Auto starting.")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.startBatch()
        }
    }

    private func moveImportedVideo(from sourceURL: URL, to destinationURL: URL) throws {
        do {
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
        } catch {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            do {
                try FileManager.default.removeItem(at: sourceURL)
            } catch {
                try? FileManager.default.removeItem(at: destinationURL)
                throw error
            }
        }
    }

    private func appendLog(_ line: String) {
        logs.append(line)
        if logs.count > 500 {
            logs.removeFirst(logs.count - 500)
        }
        syncLogText()
        updateStatus(from: line)
        if line == "DONE" || line.hasPrefix("Done:") {
            refreshMetadata()
        }
    }

    private func syncLogText() {
        logText = logs.isEmpty ? "Waiting for status..." : logs.joined(separator: "\n")
    }

    private func updateStatus(from line: String) {
        if let encoderName = extractEncoderName(from: line) {
            encoderStatus = displayEncoderName(encoderName)
        }
        if line.hasPrefix("[post] Starting "),
           let progress = extractPostQueueProgress(from: line) {
            downloadProgressPercent = progress.percent
            downloadProgressLabel = progress.label
            isDownloadProgressVisible = true
        }
        if line.hasPrefix("[download] Starting "), let soraID = line.split(separator: ":").last.map({ String($0).trimmingCharacters(in: .whitespaces) }) {
            downloadProgressLabel = soraID
            downloadProgressPercent = 0
            isDownloadProgressVisible = true
        }
        if line.hasPrefix("[batch] Progress "),
           let match = line.range(of: #"\[batch\] Progress (\d+)% \((\d+)/(\d+)\) (.+)"#, options: .regularExpression) {
            let progressLine = String(line[match])
            if let regex = try? NSRegularExpression(pattern: #"\[batch\] Progress (\d+)% \((\d+)/(\d+)\) (.+)"#),
               let result = regex.firstMatch(in: progressLine, range: NSRange(progressLine.startIndex..<progressLine.endIndex, in: progressLine)),
               result.numberOfRanges == 5,
               let percentRange = Range(result.range(at: 1), in: progressLine),
               let currentRange = Range(result.range(at: 2), in: progressLine),
               let totalRange = Range(result.range(at: 3), in: progressLine),
               let messageRange = Range(result.range(at: 4), in: progressLine) {
                batchProgressPercent = Int(progressLine[percentRange]) ?? 0
                let current = String(progressLine[currentRange])
                let total = String(progressLine[totalRange])
                let message = String(progressLine[messageRange]).trimmingCharacters(in: .whitespaces)
                batchProgressLabel = "\(message) (\(current)/\(total))"
                isBatchProgressVisible = true
            }
        }
        if line.hasPrefix("[download] Progress ") {
            let parts = line.split(separator: " ")
            if parts.count >= 4 {
                downloadProgressLabel = String(parts[2])
                let percentText = String(parts[3]).replacingOccurrences(of: "%", with: "")
                if let value = Int(percentText) {
                    downloadProgressPercent = max(0, min(100, value))
                    isDownloadProgressVisible = true
                }
            }
        }
        if line.hasPrefix("[download] Saved ") {
            downloadProgressPercent = 100
            if let soraID = extractSoraIDFromDownloadLine(line) {
                successfulDownloadEntryKeys.insert(PostDownloadEntry(kind: .sora, value: soraID).uniqueKey)
            }
        }
        if line.hasPrefix("[download] Skip existing: "),
           let soraID = extractSoraIDFromDownloadLine(line) {
            successfulDownloadEntryKeys.insert(PostDownloadEntry(kind: .sora, value: soraID).uniqueKey)
        }
        if line.hasPrefix("[post] OK "),
           let entry = extractPostDownloadEntryFromPostResultLine(line) {
            successfulDownloadEntryKeys.insert(entry.uniqueKey)
            let completed = successfulDownloadEntryKeys.count
            let total = max(currentDownloadEntries.count, completed)
            downloadProgressPercent = max(downloadProgressPercent, min(100, Int((Double(completed) / Double(total)) * 100)))
            downloadProgressLabel = entry.displayValue
            isDownloadProgressVisible = true
        }
        if line.hasPrefix("[facebook] Saved: ") || line.hasPrefix("[facebook] Skip existing: ") {
            downloadProgressPercent = max(downloadProgressPercent, 100)
        }
        if line.hasPrefix("Found ") || line.hasPrefix("Starting ") || (line.hasPrefix("[") && line.contains("]")) {
            status = "Running"
            detail = line
        } else if line.hasPrefix("Done:") {
            status = "Running"
            detail = line
        } else if line == "Batch complete." || line == "DONE" {
            status = "Done"
            detail = "Batch complete."
            if isBatchProgressVisible {
                batchProgressPercent = 100
            }
        } else if line == "No new source videos found." {
            status = "Idle"
            detail = line
            isBatchProgressVisible = false
        } else if line == "FAILED" {
            status = "Failed"
            detail = "Batch failed."
        }
    }

    private func sourceVideos() -> [URL] {
        sourceVideos(in: rootDir)
    }

    private func sourceVideos(in directory: URL) -> [URL] {
        let allowed = Set(["mp4", "mov", "m4v", "avi", "mkv"])
        let children = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return children
            .filter { !$0.hasDirectoryPath && allowed.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func packageDirs() -> [URL] {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: rootDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return children
            .filter { url in
                guard url.hasDirectoryPath else { return false }
                guard url.lastPathComponent.hasSuffix("_Reels_Package") else { return false }
                return Int(url.lastPathComponent.split(separator: "_").first ?? "") != nil
            }
            .sorted {
                let lhs = Int($0.lastPathComponent.split(separator: "_").first ?? "") ?? 0
                let rhs = Int($1.lastPathComponent.split(separator: "_").first ?? "") ?? 0
                return lhs < rhs
            }
    }

    private func loadSavedSettings() -> [String: String] {
        guard
            let data = try? Data(contentsOf: apiKeysFile),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }
        var result: [String: String] = [:]
        for (key, value) in object {
            if let value = value as? String {
                result[key] = value
            }
        }
        return result
    }

    private func maskKey(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "Not set" }
        if value.count <= 8 { return "Saved" }
        return "Saved (...\(value.suffix(4)))"
    }

    private func loadChromeProfiles() -> [ChromeProfileItem] {
        Self.loadChromeProfilesSnapshot()
    }

    private func refreshChromeProfilesAsync(showToast: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            self?.isChromeProfilesLoading = true
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let profiles = Self.loadChromeProfilesSnapshot()
            let isChromeOnline = Self.chromeRunningSnapshot()
            DispatchQueue.main.async {
                guard let self else { return }
                self.chromeProfiles = profiles
                self.chromeOnline = isChromeOnline
                self.isChromeProfilesLoading = false
                self.applyChromeProfileAssignments(using: profiles)
                if showToast {
                    self.showToast(profiles.isEmpty ? "No Chrome profiles found." : "\(profiles.count) Chrome profiles found.")
                }
            }
        }
    }

    private nonisolated static func loadChromeProfilesSnapshot() -> [ChromeProfileItem] {
        let object = (try? Data(contentsOf: chromeLocalStateFile))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let profile = object?["profile"] as? [String: Any]
        let infoCache = profile?["info_cache"] as? [String: Any]
        let activeProfileDirectoryNames = activeChromeProfileDirectoryNamesSnapshot(from: profile ?? [:])

        var itemsByDirectory: [String: ChromeProfileItem] = [:]
        if let infoCache {
            for (key, value) in infoCache {
                guard let entry = value as? [String: Any] else { continue }
                let displayName = chromeProfileDisplayNameSnapshot(entry: entry, directoryName: key)
                let item = ChromeProfileItem(
                    id: key,
                    directoryName: key,
                    displayName: displayName,
                    isOnline: activeProfileDirectoryNames.contains(key)
                )
                itemsByDirectory[item.directoryName] = item
            }
        }

        for item in fallbackChromeProfilesSnapshot(activeProfileDirectoryNames: activeProfileDirectoryNames) {
            if itemsByDirectory[item.directoryName] == nil {
                itemsByDirectory[item.directoryName] = item
            }
        }

        return itemsByDirectory.values.sorted { lhs, rhs in
            chromeProfileSortKeySnapshot(lhs.directoryName) < chromeProfileSortKeySnapshot(rhs.directoryName)
        }
    }

    private nonisolated static func fallbackChromeProfilesSnapshot(activeProfileDirectoryNames: Set<String>) -> [ChromeProfileItem] {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: chromeUserDataDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return children.compactMap { url in
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDirectory else { return nil }
            let name = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            guard name == "Default" || name.hasPrefix("Profile ") else { return nil }
            return ChromeProfileItem(
                id: name,
                directoryName: name,
                displayName: name == "Default" ? "Default" : name,
                isOnline: activeProfileDirectoryNames.contains(name)
            )
        }
    }

    private nonisolated static func chromeProfileDisplayNameSnapshot(entry: [String: Any], directoryName: String) -> String {
        let candidates = [
            entry["name"] as? String,
            entry["shortcut_name"] as? String,
            entry["gaia_name"] as? String,
            entry["gaia_given_name"] as? String,
            entry["user_name"] as? String,
        ]
        for candidate in candidates {
            let cleaned = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !cleaned.isEmpty {
                return cleaned
            }
        }
        return directoryName
    }

    private func activeChromeProfileDirectoryNames(from profile: [String: Any]) -> Set<String> {
        Self.activeChromeProfileDirectoryNamesSnapshot(from: profile)
    }

    private func runningChromeProfileDirectories() -> Set<String> {
        Self.runningChromeProfileDirectoriesSnapshot()
    }

    private func runningChromeProfileProcesses() -> [(pid: pid_t, directoryName: String)] {
        Self.runningChromeProfileProcessesSnapshot()
    }

    private nonisolated static func activeChromeProfileDirectoryNamesSnapshot(from profile: [String: Any]) -> Set<String> {
        guard chromeRunningSnapshot() else {
            return []
        }

        var active: Set<String> = []
        if let lastActiveProfiles = profile["last_active_profiles"] as? [String] {
            active.formUnion(lastActiveProfiles.filter { !$0.isEmpty })
        }
        if let lastUsed = profile["last_used"] as? String, !lastUsed.isEmpty {
            active.insert(lastUsed)
        }
        active.formUnion(runningChromeProfileDirectoriesSnapshot())
        if active.isEmpty {
            active.insert("Default")
        }
        return active
    }

    private nonisolated static func runningChromeProfileDirectoriesSnapshot() -> Set<String> {
        Set(runningChromeProfileProcessesSnapshot().map(\.directoryName))
    }

    private nonisolated static func runningChromeProfileProcessesSnapshot() -> [(pid: pid_t, directoryName: String)] {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["axww", "-o", "pid=,command="]
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return []
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else {
            return []
        }

        let lines = output.split(whereSeparator: \.isNewline)
        let pidRegex = try? NSRegularExpression(pattern: #"^\s*(\d+)\s+(.*)$"#)
        let profileRegex = try? NSRegularExpression(pattern: #"--profile-directory=(?:"([^"]+)"|([^\s]+))"#)
        var result: [(pid: pid_t, directoryName: String)] = []

        for line in lines {
            let lineString = String(line)
            guard chromeMainProcessCommandMatchesSnapshot(lineString) else { continue }
            guard
                let pidRegex,
                let profileRegex,
                let pidMatch = pidRegex.firstMatch(in: lineString, range: NSRange(lineString.startIndex..<lineString.endIndex, in: lineString)),
                let pidRange = Range(pidMatch.range(at: 1), in: lineString),
                let commandRange = Range(pidMatch.range(at: 2), in: lineString),
                let pidValue = Int32(lineString[pidRange])
            else {
                continue
            }

            let command = String(lineString[commandRange])
            guard let profileMatch = profileRegex.firstMatch(in: command, range: NSRange(command.startIndex..<command.endIndex, in: command)) else {
                continue
            }

            var directoryName = ""
            for index in [1, 2] {
                let range = profileMatch.range(at: index)
                guard range.location != NSNotFound, let swiftRange = Range(range, in: command) else { continue }
                directoryName = String(command[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !directoryName.isEmpty { break }
            }

            if !directoryName.isEmpty {
                result.append((pid: pid_t(pidValue), directoryName: directoryName))
            }
        }

        return result
    }

    private func chromeProfileSortKey(_ value: String) -> (Int, String) {
        Self.chromeProfileSortKeySnapshot(value)
    }

    private nonisolated static func chromeProfileSortKeySnapshot(_ value: String) -> (Int, String) {
        if value == "Default" {
            return (0, value)
        }
        if let number = Int(value.replacingOccurrences(of: "Profile ", with: "")) {
            return (number + 1, value)
        }
        return (10_000, value)
    }

    private func applyPostDownloadInputAfterDownload() {
        guard !currentDownloadEntries.isEmpty else { return }

        let successfulEntries = currentDownloadEntries.filter { successfulDownloadEntryKeys.contains($0.uniqueKey) }
        let successfulSoraIDs = successfulEntries.compactMap(\.soraID)
        if !successfulSoraIDs.isEmpty {
            completedSoraDownloadIDs.formUnion(successfulSoraIDs)
            persistCompletedSoraDownloadIDs()
        }

        let currentEntries = extractPostDownloadEntries(from: soraInput)
        let remaining = currentEntries.filter { !successfulDownloadEntryKeys.contains($0.uniqueKey) }
        soraInput = remaining.map(\.displayValue).joined(separator: "\n")

        if !successfulEntries.isEmpty && remaining.isEmpty {
            showToast("Downloaded links cleared.")
        } else if !successfulEntries.isEmpty {
            showToast("Downloaded links cleared. Failed links kept.")
        }

        currentDownloadEntries = []
        successfulDownloadEntryKeys = []
    }

    private func extractSoraIDFromDownloadLine(_ line: String) -> String? {
        if let range = line.range(of: #"s_[A-Za-z0-9]{12,}"#, options: .regularExpression) {
            return String(line[range])
        }
        return nil
    }

    private func extractPostDownloadEntryFromPostResultLine(_ line: String) -> PostDownloadEntry? {
        if let range = line.range(of: #"^\[post\] OK sora (s_[A-Za-z0-9_-]+)$"#, options: .regularExpression) {
            let value = String(line[range]).replacingOccurrences(of: "[post] OK sora ", with: "")
            return PostDownloadEntry(kind: .sora, value: value)
        }

        if let range = line.range(of: #"^\[post\] OK facebook (https?://.+)$"#, options: .regularExpression) {
            let value = String(line[range]).replacingOccurrences(of: "[post] OK facebook ", with: "")
            if let normalized = normalizeFacebookDownloadURL(value) {
                return PostDownloadEntry(kind: .facebook, value: normalized)
            }
        }

        return nil
    }

    private func extractPostQueueProgress(from line: String) -> (percent: Int, label: String)? {
        let pattern = #"^\[post\] Starting (\d+)/(\d+): (sora|facebook) (.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)),
              let currentRange = Range(match.range(at: 1), in: line),
              let totalRange = Range(match.range(at: 2), in: line),
              let kindRange = Range(match.range(at: 3), in: line),
              let valueRange = Range(match.range(at: 4), in: line)
        else {
            return nil
        }

        let current = Int(line[currentRange]) ?? 1
        let total = max(Int(line[totalRange]) ?? 1, 1)
        let kind = String(line[kindRange])
        let value = String(line[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        let label = kind == "facebook" ? "Facebook" : value
        let percent = max(0, min(99, Int((Double(current - 1) / Double(total)) * 100)))
        return (percent, label)
    }

    private func extractEncoderName(from line: String) -> String? {
        guard let range = line.range(of: "Encoder used: ") else { return nil }
        return String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func displayEncoderName(_ encoder: String) -> String {
        switch encoder {
        case "h264_videotoolbox":
            return "Apple Chip"
        case "libx264":
            return "CPU Fallback"
        case "h264_nvenc":
            return "NVIDIA GPU"
        case "h264_qsv":
            return "Intel QSV"
        case "h264_amf":
            return "AMD GPU"
        default:
            return encoder
        }
    }

    private func isChromeRunning() -> Bool {
        Self.chromeRunningSnapshot()
    }

    private nonisolated static func chromeMainProcessCommandMatchesSnapshot(_ command: String) -> Bool {
        let normalized = command.lowercased()
        guard normalized.contains("google chrome.app/contents/macos/google chrome") else {
            return false
        }
        return !normalized.contains("google chrome helper")
    }

    private nonisolated static func chromeRunningSnapshot() -> Bool {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["axww", "-o", "command="]
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return false
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else {
            return false
        }

        return output
            .split(whereSeparator: \.isNewline)
            .contains { line in
                chromeMainProcessCommandMatchesSnapshot(String(line))
            }
    }

    private func loadEditedPackage(_ packageURL: URL) -> EditedPackageItem? {
        let htmlURL = packageURL.appendingPathComponent("copy_title.html")
        let videoURL = preferredPackageMediaURL(
            packageURL,
            extensions: ["mp4", "mov", "m4v"],
            preferredNames: [preferredReelsBaseName(for: packageURL) + ".mp4", "edited_reel_9x16_hd_0.90x_15s.mp4"]
        ) ?? packageURL.appendingPathComponent("edited_reel_9x16_hd_0.90x_15s.mp4")
        let thumbnailURL = preferredPackageMediaURL(
            packageURL,
            extensions: ["jpg", "jpeg", "png"],
            preferredNames: [preferredReelsBaseName(for: packageURL) + ".jpg", "thumbnail_1080x1920.jpg"]
        )

        let htmlText = (try? String(contentsOf: htmlURL, encoding: .utf8)) ?? ""
        let sourceName = firstMatch(in: htmlText, pattern: #"<p class="meta">(.*?)</p>"#) ?? videoURL.lastPathComponent
        let title = firstMatch(in: htmlText, pattern: #"<textarea id="titleField" readonly>(.*?)</textarea>"#) ?? "No title found."

        return EditedPackageItem(
            id: packageURL.lastPathComponent,
            packageName: packageURL.lastPathComponent,
            sourceName: decodeHTMLEntities(sourceName),
            videoName: videoURL.lastPathComponent,
            title: normalizedUploadTitle(decodeHTMLEntities(title)),
            thumbnailURL: thumbnailURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil },
            packageURL: packageURL,
            assignedProfileDirectoryName: nil,
            assignedProfileDisplayName: nil,
            assignedProfileOnline: false
        )
    }

    private func loadChromeProfileAssignments() -> [String: String] {
        guard
            let data = try? Data(contentsOf: chromeProfileAssignmentsFile),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }

        var result: [String: String] = [:]
        for (key, value) in object {
            let packageID = key.trimmingCharacters(in: .whitespacesAndNewlines)
            let directoryName = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !packageID.isEmpty, !directoryName.isEmpty {
                result[packageID] = directoryName
            }
        }
        return result
    }

    private func persistChromeProfileAssignments() {
        let payload = chromeProfileAssignments
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else {
            return
        }
        try? data.write(to: chromeProfileAssignmentsFile, options: [.atomic])
    }

    private func applyChromeProfileAssignments(using profiles: [ChromeProfileItem]) {
        let profileMap = Dictionary(uniqueKeysWithValues: profiles.map { ($0.directoryName, $0) })
        editedPackages = editedPackages.map { item in
            let assignedDirectoryName = chromeProfileAssignments[item.id]
            let assignedProfile = assignedDirectoryName.flatMap { profileMap[$0] }
            return EditedPackageItem(
                id: item.id,
                packageName: item.packageName,
                sourceName: item.sourceName,
                videoName: item.videoName,
                title: item.title,
                thumbnailURL: item.thumbnailURL,
                packageURL: item.packageURL,
                assignedProfileDirectoryName: assignedDirectoryName,
                assignedProfileDisplayName: assignedProfile?.displayName ?? assignedDirectoryName,
                assignedProfileOnline: assignedProfile?.isOnline ?? false
            )
        }
    }

    private func normalizedUploadTitle(_ text: String) -> String {
        let repaired = repairMojibakeTitle(text).precomposedStringWithCanonicalMapping
        let compact = repaired.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return compact.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func repairMojibakeTitle(_ text: String) -> String {
        let source = text.precomposedStringWithCanonicalMapping
        let markers = ["ðŸ", "Ã", "â", "Â"]
        guard markers.contains(where: { source.contains($0) }) else {
            return source
        }
        guard
            let data = source.data(using: .isoLatin1),
            let repaired = String(data: data, encoding: .utf8),
            !repaired.isEmpty
        else {
            return source
        }
        return repaired.precomposedStringWithCanonicalMapping
    }

    private func preferredReelsBaseName(for packageURL: URL) -> String {
        let packageName = packageURL.lastPathComponent
        if let prefix = packageName.split(separator: "_").first, Int(prefix) != nil {
            return "Reels\(prefix)"
        }
        return "Reels"
    }

    private func preferredPackageMediaURL(_ packageURL: URL, extensions: [String], preferredNames: [String]) -> URL? {
        for name in preferredNames {
            let candidate = packageURL.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        let children = (try? FileManager.default.contentsOfDirectory(
            at: packageURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return children.first { url in
            !url.hasDirectoryPath && extensions.contains(url.pathExtension.lowercased())
        }
    }

    private func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range), match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return String(text[captureRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func decodeHTMLEntities(_ text: String) -> String {
        var decoded = text
        let namedEntities: [(String, String)] = [
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&#x27;", "'"),
            ("&#x2F;", "/"),
        ]
        for (entity, value) in namedEntities {
            decoded = decoded.replacingOccurrences(of: entity, with: value)
        }

        let pattern = #"&#(x?[0-9A-Fa-f]+);"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let matches = regex.matches(in: decoded, range: NSRange(decoded.startIndex..<decoded.endIndex, in: decoded))
        for match in matches.reversed() {
            guard let range = Range(match.range(at: 1), in: decoded) else { continue }
            let token = String(decoded[range])
            let scalarValue: UInt32?
            if token.hasPrefix("x") || token.hasPrefix("X") {
                scalarValue = UInt32(token.dropFirst(), radix: 16)
            } else {
                scalarValue = UInt32(token, radix: 10)
            }
            guard
                let value = scalarValue,
                let scalar = UnicodeScalar(value),
                let fullRange = Range(match.range(at: 0), in: decoded)
            else {
                continue
            }
            decoded.replaceSubrange(fullRange, with: String(scalar))
        }
        return decoded.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func destinationURLForImportedVideo(_ sourceURL: URL) -> URL {
        let baseURL = rootDir.appendingPathComponent(sourceURL.lastPathComponent)
        let sourcePath = sourceURL.resolvingSymlinksInPath().standardizedFileURL.path
        let basePath = baseURL.resolvingSymlinksInPath().standardizedFileURL.path
        if sourcePath == basePath || !FileManager.default.fileExists(atPath: baseURL.path) {
            return baseURL
        }

        let stem = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension
        var index = 2
        while true {
            let candidateName = ext.isEmpty ? "\(stem)_\(index)" : "\(stem)_\(index).\(ext)"
            let candidateURL = rootDir.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }
            index += 1
        }
    }

    private func extractAllSoraIDs(from text: String) -> [String] {
        let pattern = #"https?://sora\.chatgpt\.com/p/(s_[A-Za-z0-9_-]{8,})(?:[/?#][^\s]*)?|\b(s_[A-Za-z0-9_-]{8,})\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var ids: [String] = []
        regex.enumerateMatches(in: text, options: [], range: fullRange) { match, _, _ in
            guard let match else { return }
            for index in 1..<match.numberOfRanges {
                let range = match.range(at: index)
                guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else {
                    continue
                }
                let value = String(text[swiftRange])
                if !value.isEmpty {
                    ids.append(value)
                }
            }
        }
        return ids
    }

    private func normalizeSoraDownloadValue(_ value: String) -> String? {
        let raw = value.trimmingCharacters(in: CharacterSet(charactersIn: " \n\r\t,;:!?)\\]}>\"'"))
        guard !raw.isEmpty else { return nil }

        if raw.range(of: #"^s_[A-Za-z0-9_-]{8,}$"#, options: .regularExpression) != nil {
            return raw
        }

        guard let components = URLComponents(string: raw),
              components.host?.lowercased() == "sora.chatgpt.com"
        else {
            return nil
        }

        let path = components.path
        guard let match = path.range(of: #"/p/(s_[A-Za-z0-9_-]{8,})"#, options: .regularExpression) else {
            return nil
        }

        return String(path[match]).replacingOccurrences(of: "/p/", with: "")
    }

    private func uniqueSoraIDs(from text: String) -> [String] {
        var seen: Set<String> = []
        var ids: [String] = []
        for value in extractAllSoraIDs(from: text) {
            if !seen.contains(value) {
                seen.insert(value)
                ids.append(value)
            }
        }
        return ids
    }

    private func firstSoraID(from value: String) -> String? {
        uniqueSoraIDs(from: value).first
    }

    private func normalizeFacebookDownloadURL(_ value: String) -> String? {
        let raw = value.trimmingCharacters(in: CharacterSet(charactersIn: " \n\r\t,;:!?)\\]}>\"'"))
        guard !raw.isEmpty else { return nil }

        let candidate = raw.contains("://") ? raw : "https://\(raw)"
        guard let components = URLComponents(string: candidate),
              let host = components.host?.lowercased()
        else {
            return nil
        }

        if host == "fb.watch" || host.hasSuffix(".fb.watch") {
            return candidate
        }

        let path = components.path

        if host == "fb.watch" || host.hasSuffix(".fb.watch") {
            let trimmedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !trimmedPath.isEmpty else { return nil }
            var normalized = "https://fb.watch/\(trimmedPath)"
            if let query = components.percentEncodedQuery, !query.isEmpty {
                normalized += "?\(query)"
            }
            return normalized
        }

        guard host == "facebook.com" || host.hasSuffix(".facebook.com") else {
            return nil
        }

        if let match = path.range(of: #"/reel/(\d+)"#, options: .regularExpression) {
            let text = String(path[match])
            let reelID = text.replacingOccurrences(of: "/reel/", with: "")
            return "https://www.facebook.com/reel/\(reelID)"
        }

        if path.hasPrefix("/watch"),
           let videoID = components.queryItems?.first(where: { $0.name == "v" })?.value,
           videoID.range(of: #"^\d+$"#, options: .regularExpression) != nil {
            return "https://www.facebook.com/watch/?v=\(videoID)"
        }

        if path.contains("/videos/"),
           let match = path.range(of: #"/(\d{6,})(?:/|$)"#, options: .regularExpression) {
            let text = String(path[match])
            let videoID = text.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return "https://www.facebook.com/watch/?v=\(videoID)"
        }

        if let match = path.range(of: #"/share/(?:r|v)/([^/?#]+)"#, options: .regularExpression) {
            let text = String(path[match])
            let sharePath = text.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !sharePath.isEmpty {
                return "https://www.facebook.com/\(sharePath)"
            }
        }

        return nil
    }

    private func extractPostDownloadEntries(from text: String) -> [PostDownloadEntry] {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ","))
        let rawTokens = text
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \n\r\t")) }
            .filter { !$0.isEmpty }

        var entries: [PostDownloadEntry] = []
        var seen: Set<String> = []

        for token in rawTokens {
            if let soraID = normalizeSoraDownloadValue(token) {
                let entry = PostDownloadEntry(kind: .sora, value: soraID)
                if seen.insert(entry.uniqueKey).inserted {
                    entries.append(entry)
                }
                continue
            }

            if let facebookURL = normalizeFacebookDownloadURL(token) {
                let entry = PostDownloadEntry(kind: .facebook, value: facebookURL)
                if seen.insert(entry.uniqueKey).inserted {
                    entries.append(entry)
                }
                continue
            }

            if let soraID = firstSoraID(from: token) {
                let entry = PostDownloadEntry(kind: .sora, value: soraID)
                if seen.insert(entry.uniqueKey).inserted {
                    entries.append(entry)
                }
            }
        }

        return entries
    }

    private func normalizePostDownloadInputText(_ text: String) -> (text: String, duplicateCount: Int, hasValidEntries: Bool) {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ","))
        let rawTokens = text
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \n\r\t")) }
            .filter { !$0.isEmpty }
        let unique = extractPostDownloadEntries(from: text)
        return (
            unique.map(\.displayValue).joined(separator: "\n"),
            max(0, rawTokens.count - unique.count),
            !unique.isEmpty
        )
    }

    private func mergePostDownloadInputTexts(
        existing: String,
        incoming: String,
        allowingCompletedIDs: Bool = false
    ) -> (
        text: String,
        addedCount: Int,
        duplicateCount: Int,
        blockedCount: Int,
        reactivatedCompletedIDs: [String],
        addedEntries: [PostDownloadEntry]
    ) {
        let existingEntries = extractPostDownloadEntries(from: existing)
        let incomingEntries = extractPostDownloadEntries(from: incoming)
        var merged = existingEntries
        var seen = Set(existingEntries.map(\.uniqueKey))
        var added = 0
        var duplicates = 0
        var blocked = 0
        var reactivatedCompletedIDs: [String] = []
        var addedEntries: [PostDownloadEntry] = []

        for entry in incomingEntries {
            if seen.contains(entry.uniqueKey) {
                duplicates += 1
                continue
            }

            if let soraID = entry.soraID, completedSoraDownloadIDs.contains(soraID) {
                if allowingCompletedIDs {
                    reactivatedCompletedIDs.append(soraID)
                } else {
                    blocked += 1
                    continue
                }
            }

            seen.insert(entry.uniqueKey)
            merged.append(entry)
            added += 1
            addedEntries.append(entry)
        }
        return (
            merged.map(\.displayValue).joined(separator: "\n"),
            added,
            duplicates,
            blocked,
            reactivatedCompletedIDs,
            addedEntries
        )
    }

    private func transcribeAIChatRecording(at fileURL: URL, completion: @escaping (Result<String, Error>) -> Void) {
        let saved = loadSavedSettings()
        switch aiChatRecordingProvider {
        case .gemini:
            let geminiKey = (saved["GEMINI_API_KEY"] ?? saved["GOOGLE_API_KEY"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !geminiKey.isEmpty else {
                completion(.failure(NSError(
                    domain: "SoraninAIChatRecorder",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Gemini API key is required for Record to Text."]
                )))
                return
            }
            let modelName = (aiChatProvider == .geminiPro || aiChatProvider == .gemini25Pro)
                ? geminiProTranscriptionModel
                : geminiFlashTranscriptionModel
            Self.transcribeAudioFileWithGemini(apiKey: geminiKey, fileURL: fileURL, modelName: modelName, completion: completion)
        case .openai:
            let openAIKey = (saved["OPENAI_API_KEY"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !openAIKey.isEmpty else {
                completion(.failure(NSError(
                    domain: "SoraninAIChatRecorder",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "OpenAI API key is required for Record to Text."]
                )))
                return
            }

            Self.transcribeAudioFileWithOpenAI(apiKey: openAIKey, fileURL: fileURL, completion: completion)
        }
    }

    private nonisolated static func transcribeAudioFileWithOpenAI(
        apiKey: String,
        fileURL: URL,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: openAIAudioTranscriptionEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try multipartTranscriptionRequestBody(fileURL: fileURL, boundary: boundary)
        } catch {
            completion(.failure(error))
            return
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                completion(.failure(NSError(
                    domain: "SoraninAIChatRecorder",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Speech transcription returned an invalid response."]
                )))
                return
            }

            let payload = data ?? Data()
            guard (200..<300).contains(httpResponse.statusCode) else {
                let message = transcriptionAPIErrorMessage(statusCode: httpResponse.statusCode, data: payload)
                completion(.failure(NSError(
                    domain: "SoraninAIChatRecorder",
                    code: httpResponse.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: message]
                )))
                return
            }

            guard
                let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                let text = (object["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            else {
                completion(.failure(NSError(
                    domain: "SoraninAIChatRecorder",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "Speech transcription returned unreadable text."]
                )))
                return
            }

            completion(.success(text))
        }.resume()
    }

    private nonisolated static func transcribeAudioFileWithGemini(
        apiKey: String,
        fileURL: URL,
        modelName: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        uploadGeminiFile(apiKey: apiKey, fileURL: fileURL) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let fileInfo):
                waitForGeminiFileActive(apiKey: apiKey, fileInfo: fileInfo) { waitResult in
                    switch waitResult {
                    case .failure(let error):
                        deleteGeminiFileIfPossible(apiKey: apiKey, fileInfo: fileInfo)
                        completion(.failure(error))
                    case .success(let activeFileInfo):
                        transcribeUploadedGeminiAudio(apiKey: apiKey, fileInfo: activeFileInfo, modelName: modelName) { transcriptionResult in
                            deleteGeminiFileIfPossible(apiKey: apiKey, fileInfo: activeFileInfo)
                            completion(transcriptionResult)
                        }
                    }
                }
            }
        }
    }

    private nonisolated static func multipartTranscriptionRequestBody(fileURL: URL, boundary: String) throws -> Data {
        let fileData = try Data(contentsOf: fileURL)
        let mimeType = transcriptionMimeType(for: fileURL)
        let prompt = """
        Transcribe exactly what the speaker says.
        The speaker may use Khmer, English, or mixed Khmer-English.
        Preserve Khmer speech in Khmer script when possible.
        Do not translate, summarize, rewrite, or add extra words.
        Ignore only music-only sections and generic background noise.
        """

        var body = Data()
        let lineBreak = "\r\n"

        func appendField(name: String, value: String) {
            body.append(Data("--\(boundary)\(lineBreak)".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\(lineBreak)\(lineBreak)".utf8))
            body.append(Data(value.utf8))
            body.append(Data(lineBreak.utf8))
        }

        appendField(name: "model", value: openAIChatTranscriptionModel)
        appendField(name: "response_format", value: "json")
        appendField(name: "prompt", value: prompt)

        body.append(Data("--\(boundary)\(lineBreak)".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\(lineBreak)".utf8))
        body.append(Data("Content-Type: \(mimeType)\(lineBreak)\(lineBreak)".utf8))
        body.append(fileData)
        body.append(Data(lineBreak.utf8))
        body.append(Data("--\(boundary)--\(lineBreak)".utf8))
        return body
    }

    private nonisolated static func transcriptionMimeType(for fileURL: URL) -> String {
        switch fileURL.pathExtension.lowercased() {
        case "m4a":
            return "audio/m4a"
        case "mp3":
            return "audio/mpeg"
        case "wav":
            return "audio/wav"
        case "aac":
            return "audio/aac"
        case "mp4", "m4v":
            return "audio/mp4"
        default:
            return "application/octet-stream"
        }
    }

    private nonisolated static func transcriptionAPIErrorMessage(statusCode: Int, data: Data) -> String {
        let defaultMessage: String
        switch statusCode {
        case 401, 403:
            defaultMessage = "OpenAI API key មិនត្រឹមត្រូវ ឬគ្មានសិទ្ធិប្រើ Record to Text ទេ។"
        case 429:
            defaultMessage = "OpenAI API key អស់លុយ ឬអស់ quota ហើយ។ Record to Text មិនអាចប្រើបាន។"
        default:
            defaultMessage = "Speech transcription failed."
        }

        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = object["error"] as? [String: Any],
            let message = (error["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !message.isEmpty
        else {
            return defaultMessage
        }

        return message
    }

    private nonisolated static func uploadGeminiFile(
        apiKey: String,
        fileURL: URL,
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        let mimeType = transcriptionMimeType(for: fileURL)
        let metadata = ["file": ["display_name": fileURL.lastPathComponent]]
        guard let metadataData = try? JSONSerialization.data(withJSONObject: metadata) else {
            completion(.failure(NSError(
                domain: "SoraninAIChatRecorder",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "Gemini upload metadata could not be created."]
            )))
            return
        }

        let uploadStartURL = geminiFilesBaseURL.appendingPathComponent("upload/v1beta/files")
        var request = URLRequest(url: uploadStartURL.appending(queryItems: [URLQueryItem(name: "key", value: apiKey)]))
        request.httpMethod = "POST"
        request.httpBody = metadataData
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        request.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        request.setValue(String((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0), forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        request.setValue(mimeType, forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")

        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let httpResponse = response as? HTTPURLResponse,
                  let uploadURLString = httpResponse.value(forHTTPHeaderField: "x-goog-upload-url"),
                  let uploadURL = URL(string: uploadURLString)
            else {
                completion(.failure(NSError(
                    domain: "SoraninAIChatRecorder",
                    code: 11,
                    userInfo: [NSLocalizedDescriptionKey: "Gemini Files API did not return an upload URL."]
                )))
                return
            }

            let fileData: Data
            do {
                fileData = try Data(contentsOf: fileURL)
            } catch {
                completion(.failure(error))
                return
            }

            var uploadRequest = URLRequest(url: uploadURL)
            uploadRequest.httpMethod = "POST"
            uploadRequest.httpBody = fileData
            uploadRequest.timeoutInterval = max(180, min(900, Double(fileData.count) / 50_000 + 180))
            uploadRequest.setValue(String(fileData.count), forHTTPHeaderField: "Content-Length")
            uploadRequest.setValue(mimeType, forHTTPHeaderField: "Content-Type")
            uploadRequest.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
            uploadRequest.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")

            URLSession.shared.dataTask(with: uploadRequest) { data, _, error in
                if let error {
                    completion(.failure(error))
                    return
                }
                let payload = data ?? Data()
                guard
                    let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                    let fileInfo = object["file"] as? [String: Any]
                else {
                    completion(.failure(NSError(
                        domain: "SoraninAIChatRecorder",
                        code: 12,
                        userInfo: [NSLocalizedDescriptionKey: "Gemini upload response did not include file metadata."]
                    )))
                    return
                }
                completion(.success(fileInfo))
            }.resume()
        }.resume()
    }

    private nonisolated static func waitForGeminiFileActive(
        apiKey: String,
        fileInfo: [String: Any],
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        waitForGeminiFileActive(apiKey: apiKey, fileInfo: fileInfo, deadline: Date().addingTimeInterval(geminiFileTimeoutSeconds), completion: completion)
    }

    private nonisolated static func waitForGeminiFileActive(
        apiKey: String,
        fileInfo: [String: Any],
        deadline: Date,
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        let state = String(describing: fileInfo["state"] ?? "").uppercased()
        if state == "ACTIVE" {
            completion(.success(fileInfo))
            return
        }
        if state == "FAILED" {
            completion(.failure(NSError(
                domain: "SoraninAIChatRecorder",
                code: 13,
                userInfo: [NSLocalizedDescriptionKey: "Gemini file processing failed."]
            )))
            return
        }
        if Date() >= deadline {
            completion(.failure(NSError(
                domain: "SoraninAIChatRecorder",
                code: 14,
                userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for Gemini audio processing."]
            )))
            return
        }

        guard let name = (fileInfo["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            completion(.failure(NSError(
                domain: "SoraninAIChatRecorder",
                code: 15,
                userInfo: [NSLocalizedDescriptionKey: "Gemini file metadata did not include a file name."]
            )))
            return
        }

        let url = geminiFilesBaseURL.appendingPathComponent("v1beta/\(name)").appending(queryItems: [URLQueryItem(name: "key", value: apiKey)])
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error {
                completion(.failure(error))
                return
            }
            let payload = data ?? Data()
            guard let latest = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
                completion(.failure(NSError(
                    domain: "SoraninAIChatRecorder",
                    code: 16,
                    userInfo: [NSLocalizedDescriptionKey: "Gemini file status response was invalid."]
                )))
                return
            }

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + geminiFilePollSeconds) {
                waitForGeminiFileActive(apiKey: apiKey, fileInfo: latest, deadline: deadline, completion: completion)
            }
        }.resume()
    }

    private nonisolated static func transcribeUploadedGeminiAudio(
        apiKey: String,
        fileInfo: [String: Any],
        modelName: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let uri = (fileInfo["uri"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !uri.isEmpty else {
            completion(.failure(NSError(
                domain: "SoraninAIChatRecorder",
                code: 17,
                userInfo: [NSLocalizedDescriptionKey: "Gemini file metadata did not include a file URI."]
            )))
            return
        }

        let mimeType = (fileInfo["mimeType"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? transcriptionMimeType(for: URL(fileURLWithPath: "recording.m4a"))
        let payload: [String: Any] = [
            "model": modelName,
            "input": [
                [
                    "type": "text",
                    "text": "Transcribe exactly what the speaker says from this audio. The speaker may use Khmer, English, or mixed Khmer-English. Preserve Khmer speech in Khmer script when possible. Do not translate, summarize, rewrite, or add extra words. Ignore only music-only sections and generic background noise. If there are no clear spoken words, return exactly this text: \(noClearSpokenWordsPlaceholder). Return only the transcript text."
                ],
                [
                    "type": "audio",
                    "uri": uri,
                    "mime_type": mimeType
                ]
            ],
            "generation_config": [
                "temperature": 0.0,
                "thinking_level": "low",
                "max_output_tokens": 900
            ]
        ]

        guard let payloadData = try? JSONSerialization.data(withJSONObject: payload) else {
            completion(.failure(NSError(
                domain: "SoraninAIChatRecorder",
                code: 18,
                userInfo: [NSLocalizedDescriptionKey: "Gemini transcription request could not be created."]
            )))
            return
        }

        let url = geminiFilesBaseURL.appendingPathComponent("v1beta/interactions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = payloadData
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                completion(.failure(NSError(
                    domain: "SoraninAIChatRecorder",
                    code: 19,
                    userInfo: [NSLocalizedDescriptionKey: "Gemini transcription returned an invalid response."]
                )))
                return
            }

            let responseData = data ?? Data()
            guard (200..<300).contains(httpResponse.statusCode) else {
                let message = geminiTranscriptionAPIErrorMessage(statusCode: httpResponse.statusCode, data: responseData)
                completion(.failure(NSError(
                    domain: "SoraninAIChatRecorder",
                    code: httpResponse.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: message]
                )))
                return
            }

            guard let text = extractGeminiInteractionText(from: responseData) else {
                completion(.failure(NSError(
                    domain: "SoraninAIChatRecorder",
                    code: 20,
                    userInfo: [NSLocalizedDescriptionKey: "Gemini transcription returned unreadable text."]
                )))
                return
            }
            completion(.success(normalizedTranscriptText(text)))
        }.resume()
    }

    private nonisolated static func extractGeminiInteractionText(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outputs = object["outputs"] as? [[String: Any]]
        else {
            return nil
        }
        for output in outputs {
            if let text = (output["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return text
            }
        }
        return nil
    }

    private nonisolated static func normalizedTranscriptText(_ text: String) -> String {
        let cleaned = text.split(whereSeparator: \.isWhitespace).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "" }
        let lowered = cleaned.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .!?:;[]"))
        let markers = [
            "no clear spoken words detected",
            "no clear spoken words",
            "no spoken words detected",
            "no clear speech detected",
            "no speech detected",
            "no spoken audio detected",
            "no clear audio detected",
            "there are no clear spoken words detected in the video",
            "the video contains no clear spoken words",
        ]
        if markers.contains(where: { lowered.contains($0) }) {
            return ""
        }
        return cleaned
    }

    private nonisolated static func geminiTranscriptionAPIErrorMessage(statusCode: Int, data: Data) -> String {
        let defaultMessage: String
        switch statusCode {
        case 401, 403:
            defaultMessage = "Gemini API key មិនត្រឹមត្រូវ ឬគ្មានសិទ្ធិប្រើ Record to Text ទេ។"
        case 429:
            defaultMessage = "Gemini API key អស់លុយ ឬអស់ quota ហើយ។ Record to Text មិនអាចប្រើបាន។"
        default:
            defaultMessage = "Gemini speech transcription failed."
        }

        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = object["error"] as? [String: Any],
            let message = (error["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !message.isEmpty
        else {
            return defaultMessage
        }

        let lowered = message.lowercased()
        if lowered.contains("quota") || lowered.contains("billing") || lowered.contains("resource exhausted") {
            return "Gemini API key អស់លុយ ឬអស់ quota ហើយ។ Record to Text មិនអាចប្រើបាន។"
        }
        if lowered.contains("api key not valid") || lowered.contains("permission denied") || lowered.contains("unauth") {
            return "Gemini API key មិនត្រឹមត្រូវ ឬគ្មានសិទ្ធិប្រើ Record to Text ទេ។"
        }
        return message
    }

    private nonisolated static func deleteGeminiFileIfPossible(apiKey: String, fileInfo: [String: Any]) {
        guard let name = (fileInfo["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return
        }
        let url = geminiFilesBaseURL.appendingPathComponent("v1beta/\(name)").appending(queryItems: [URLQueryItem(name: "key", value: apiKey)])
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 60
        URLSession.shared.dataTask(with: request).resume()
    }
}

struct StatCard: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(SoraninPalette.secondaryText)
            Text(value)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(SoraninPalette.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(SoraninPalette.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(SoraninPalette.border, lineWidth: 1)
        )
    }
}

struct ProviderBadge: View {
    let provider: AIProvider

    private var badgeStyle: AnyShapeStyle {
        if provider.providerKey == "gemini" {
            return AnyShapeStyle(
                LinearGradient(colors: [Color.blue, Color.purple, Color.cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
            )
        }
        return AnyShapeStyle(Color.black)
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(provider.logoText)
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(badgeStyle)
                )
            Text(provider.label)
                .font(.system(size: 19, weight: .bold))
        }
    }
}

struct CompactProviderBadge: View {
    let provider: AIProvider

    private var badgeStyle: AnyShapeStyle {
        if provider.providerKey == "gemini" {
            return AnyShapeStyle(
                LinearGradient(colors: [Color.blue, Color.purple, Color.cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
            )
        }
        return AnyShapeStyle(Color.black)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(provider.logoText)
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(badgeStyle)
                )
            Text(provider.compactLabel)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(SoraninPalette.primaryText)
                .lineLimit(2)
                .minimumScaleFactor(0.78)
        }
    }
}

struct ActiveAICard: View {
    let provider: AIProvider

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Active AI")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(SoraninPalette.secondaryText)
            CompactProviderBadge(provider: provider)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(SoraninPalette.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(SoraninPalette.border, lineWidth: 1)
        )
    }
}

struct ChromeOnlineBadge: View {
    let isOnline: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isOnline ? SoraninPalette.success : Color.red.opacity(0.9))
                .frame(width: 10, height: 10)
            Text(isOnline ? "Chrome Online" : "Chrome Offline")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(SoraninPalette.primaryText)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Capsule(style: .continuous)
                .fill(SoraninPalette.cardSoft)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(SoraninPalette.border, lineWidth: 1)
        )
    }
}

struct HealthStatusBadgeButton: View {
    let status: String
    let action: () -> Void

    private var tint: Color {
        switch status.lowercased() {
        case "healthy":
            return SoraninPalette.success
        case "checking":
            return SoraninPalette.accentEnd
        default:
            return Color(red: 1.0, green: 0.42, blue: 0.42)
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(tint)
                    .frame(width: 10, height: 10)
                Text(status)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(SoraninPalette.primaryText)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                Capsule(style: .continuous)
                    .fill(SoraninPalette.cardSoft)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(SoraninPalette.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

struct AIChatToolbarButton: View {
    let unreadCount: Int
    let action: () -> Void

    private var badgeText: String {
        unreadCount > 99 ? "99+" : "\(unreadCount)"
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [SoraninPalette.accentStart, SoraninPalette.accentEnd],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 34, height: 34)
                        .shadow(color: SoraninPalette.accentGlow.opacity(0.42), radius: 14, y: 6)

                    Image(systemName: "message.badge.waveform.fill")
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("AI Chat")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(SoraninPalette.primaryText)
                    Text("2050")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(SoraninPalette.secondaryText.opacity(0.96))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                SoraninPalette.cardSoft,
                                SoraninPalette.cardStrong.opacity(0.96)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                SoraninPalette.accentStart.opacity(0.72),
                                SoraninPalette.accentEnd.opacity(0.92)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        lineWidth: 1.1
                    )
            )
            .shadow(color: SoraninPalette.accentGlow.opacity(0.16), radius: 18, y: 8)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
                if unreadCount > 0 {
                    Text(badgeText)
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(.white)
                        .padding(.horizontal, unreadCount > 9 ? 6 : 0)
                        .frame(minWidth: 19, minHeight: 19)
                        .background(
                            Capsule(style: .continuous)
                                .fill(SoraninPalette.accentStart)
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(Color.white.opacity(0.22), lineWidth: 1)
                        )
                        .offset(x: 8, y: -8)
                }
            }
    }
}

struct ChromeProfileStatusPill: View {
    let isOnline: Bool

    private var tint: Color {
        isOnline ? SoraninPalette.success : Color(red: 1.0, green: 0.42, blue: 0.42)
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
            Text(isOnline ? "Online" : "Offline")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(tint.opacity(0.12))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(tint.opacity(0.35), lineWidth: 1)
        )
    }
}

struct ProviderOptionTile: View {
    let provider: AIProvider
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            ProviderBadge(provider: provider)
            VStack(alignment: .leading, spacing: 4) {
                Text(provider.label)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(SoraninPalette.primaryText)
                Text(provider.detail)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(SoraninPalette.secondaryText)
            }
            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(SoraninPalette.cardSoft)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(isSelected ? SoraninPalette.success : SoraninPalette.border, lineWidth: isSelected ? 2 : 1)
        )
    }
}

struct SoraLinksPanel: View {
    @Binding var text: String
    let detectedCount: Int
    let isBusy: Bool
    let progressPercent: Int
    let progressLabel: String
    let isProgressVisible: Bool
    let onPaste: () -> Void
    let onDownloadAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Post Links To Download")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(SoraninPalette.primaryText)
                    Text("Auto detects `https://sora.chatgpt.com/p/` as Sora, and `https://web.facebook.com/`, `https://www.facebook.com/`, `https://www.facebook.com/share/...`, or `https://fb.watch/` as Facebook.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(SoraninPalette.secondaryText)
                        .lineLimit(2)
                }
                Spacer()
                Text("\(detectedCount) Links")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(SoraninPalette.secondaryText)
            }

            HStack(spacing: 12) {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(SoraninPalette.input)
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Post links here")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(SoraninPalette.secondaryText)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                    }
                    TextEditor(text: $text)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(SoraninPalette.primaryText)
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .padding(8)
                }
                .frame(minHeight: 74, maxHeight: 82)

                VStack(spacing: 10) {
                    Button {
                        onPaste()
                    } label: {
                        Label("Paste Links", systemImage: "doc.on.clipboard")
                            .frame(maxWidth: .infinity)
                            .frame(height: 22)
                            .lineLimit(1)
                    }
                    .buttonStyle(SoraninPrimaryButtonStyle(compact: false))

                    Button {
                        onDownloadAll()
                    } label: {
                        Label("Download Again", systemImage: "arrow.clockwise.circle")
                            .frame(maxWidth: .infinity)
                            .frame(height: 22)
                            .lineLimit(1)
                    }
                    .buttonStyle(SoraninSecondaryButtonStyle(compact: false))
                    .disabled(isBusy || detectedCount == 0)
                }
                .frame(width: 190)
            }

            if isProgressVisible {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(progressLabel.isEmpty ? "Downloading" : progressLabel)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(SoraninPalette.secondaryText)
                            .lineLimit(1)
                        Spacer()
                        Text("\(progressPercent)%")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(SoraninPalette.secondaryText)
                    }
                    ProgressView(value: Double(progressPercent), total: 100)
                        .tint(SoraninPalette.accentEnd)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(SoraninPalette.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(SoraninPalette.border, lineWidth: 1)
        )
    }
}

struct DropVideosPanel: View {
    let isBusy: Bool
    let isTargeted: Bool
    let onImport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Drop Videos Here")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(SoraninPalette.primaryText)
                Spacer()
                Text(isBusy ? "Busy" : "Auto Start")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(SoraninPalette.secondaryText)
            }

            Text("Drag video files into this box. App will move them to the edit folder and start AI edit automatically.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SoraninPalette.secondaryText)
                .lineLimit(2)

            Button {
                onImport()
            } label: {
                VStack(spacing: 10) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(isTargeted ? Color(red: 0.72, green: 0.93, blue: 0.82) : Color(red: 0.96, green: 0.93, blue: 0.89))
                    Text(isTargeted ? "RELEASE TO IMPORT VIDEOS" : "DROP VIDEOS HERE")
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(Color(red: 0.98, green: 0.95, blue: 0.91))
                    Text("Click or drag files here to move")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color(red: 0.82, green: 0.76, blue: 0.70))
                    Text("`.mp4` ` .mov` ` .mkv` ` .avi` ` .m4v`")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color(red: 0.72, green: 0.67, blue: 0.61))
                }
                .frame(maxWidth: .infinity, minHeight: 144)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(isTargeted ? Color(red: 0.14, green: 0.29, blue: 0.22) : Color(red: 0.09, green: 0.08, blue: 0.07))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(
                            isTargeted ? Color(red: 0.72, green: 0.93, blue: 0.82) : Color(red: 0.35, green: 0.31, blue: 0.27),
                            style: StrokeStyle(lineWidth: isTargeted ? 2.5 : 2, dash: [10, 7])
                        )
                )
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(SoraninPalette.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(SoraninPalette.border, lineWidth: 1)
        )
    }
}

struct ThumbnailPreviewView: View {
    let url: URL?

    var body: some View {
        Group {
            if let url, let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 170, height: 230, alignment: .center)
                    .clipped()
            } else {
                ZStack {
                    Rectangle().fill(SoraninPalette.cardStrong)
                    Image(systemName: "photo")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(SoraninPalette.secondaryText)
                }
            }
        }
        .frame(width: 170, height: 230)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct EditedPackageDetailSheet: View {
    let item: EditedPackageItem
    let onCopyTitle: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(item.packageName)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(SoraninPalette.primaryText)
                    .lineLimit(1)
                Spacer()
                Button("Close") {
                    dismiss()
                }
                .buttonStyle(SoraninSecondaryButtonStyle(compact: true))
            }

            HStack {
                Spacer(minLength: 0)
                ThumbnailPreviewView(url: item.thumbnailURL)
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Full Title")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(SoraninPalette.secondaryText)
                ScrollView {
                    Text(item.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(SoraninPalette.primaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(SoraninPalette.cardStrong)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(SoraninPalette.border, lineWidth: 1)
                        )
                }
            }

            HStack {
                Spacer()
                Button("Copy Title") {
                    onCopyTitle()
                }
                .buttonStyle(SoraninPrimaryButtonStyle(compact: false))
            }
        }
        .padding(24)
        .background(SoraninPalette.bgTop)
        .frame(minWidth: 520, idealWidth: 620, maxWidth: 760, minHeight: 520)
    }
}

struct EditedPackageCard: View {
    let item: EditedPackageItem
    let isBusy: Bool
    let isSelected: Bool
    let onCopyTitle: () -> Void
    let onToggleSelection: () -> Void
    let onShowDetails: () -> Void
    let onOpenPackage: () -> Void
    let onOpenProfiles: () -> Void
    let onDeletePackage: () -> Void

    @State private var showDeleteConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                ZStack(alignment: .topTrailing) {
                    Button {
                        onToggleSelection()
                    } label: {
                        ThumbnailPreviewView(url: item.thumbnailURL)
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(
                        TapGesture(count: 2).onEnded {
                            onShowDetails()
                        }
                    )

                    VStack {
                        HStack {
                            Button {
                                onCopyTitle()
                            } label: {
                                Image(systemName: "doc.on.doc.fill")
                                    .font(.system(size: 10, weight: .black))
                                    .foregroundStyle(.white)
                                    .frame(width: 30, height: 22)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(
                                                LinearGradient(
                                                    colors: [SoraninPalette.accentStart, SoraninPalette.accentEnd],
                                                    startPoint: .leading,
                                                    endPoint: .trailing
                                                )
                                            )
                                    )
                                    .overlay(
                                        Capsule(style: .continuous)
                                            .stroke(Color.white.opacity(0.16), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)

                            Spacer()
                        }

                        Spacer()
                    }
                    .padding(8)

                    HStack(spacing: 6) {
                        Button {
                            onToggleSelection()
                        } label: {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(isSelected ? SoraninPalette.success : .white.opacity(0.95))
                                .frame(width: 24, height: 24)
                                .background(
                                    Circle()
                                        .fill(isSelected ? SoraninPalette.success.opacity(0.16) : Color.black.opacity(0.32))
                                )
                                .overlay(
                                    Circle()
                                        .stroke(isSelected ? SoraninPalette.success.opacity(0.75) : Color.white.opacity(0.18), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(isBusy)

                        Button {
                            showDeleteConfirm = true
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .black))
                                .foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(
                                    Circle()
                                        .fill(Color.red.opacity(0.92))
                                )
                                .overlay(
                                    Circle()
                                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(isBusy)
                    }
                    .padding(8)
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(item.packageName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(SoraninPalette.primaryText)
                    .lineLimit(1)

                Text(item.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SoraninPalette.primaryText)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onToggleSelection()
            }
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    onShowDetails()
                }
            )

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Button("Open Folder") {
                    onOpenPackage()
                }
                .buttonStyle(SoraninPrimaryButtonStyle(compact: true))

                Button {
                    onOpenProfiles()
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(item.assignedProfileDirectoryName == nil ? SoraninPalette.secondaryText.opacity(0.65) : (item.assignedProfileOnline ? SoraninPalette.success : Color.red.opacity(0.82)))
                            .frame(width: 8, height: 8)
                        Text(item.assignedProfileDisplayName ?? "Profiles")
                            .lineLimit(1)
                    }
                }
                .buttonStyle(SoraninSecondaryButtonStyle(compact: true))
            }
        }
        .frame(width: 190, alignment: .topLeading)
        .frame(minHeight: 386, alignment: .topLeading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(isSelected ? SoraninPalette.cardStrong : SoraninPalette.cardSoft)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(isSelected ? SoraninPalette.success : SoraninPalette.border, lineWidth: isSelected ? 2 : 1)
        )
        .confirmationDialog("Delete this folder?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                onDeletePackage()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(item.packageName)
        }
    }
}

struct EditedPackagesPanel: View {
    let items: [EditedPackageItem]
    let isBusy: Bool
    let selectedIDs: Set<String>
    let onCopyTitle: (EditedPackageItem) -> Void
    let onCopyAllTitles: () -> Void
    let onToggleSelection: (EditedPackageItem) -> Void
    let onShowDetails: (EditedPackageItem) -> Void
    let onOpenPackage: (EditedPackageItem) -> Void
    let onOpenProfiles: (EditedPackageItem) -> Void
    let onDeletePackage: (EditedPackageItem) -> Void
    let onDeleteSelected: () -> Void
    let onClearSelection: () -> Void
    let onDeleteAll: () -> Void

    @State private var showDeleteAllConfirm = false
    @State private var showDeleteSelectedConfirm = false

    var body: some View {
        let selectedCount = selectedIDs.count

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Edited Videos")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(SoraninPalette.primaryText)
                Spacer()
                if !items.isEmpty {
                    if selectedCount > 0 {
                        Button("Skip") {
                            onClearSelection()
                        }
                        .buttonStyle(SoraninSecondaryButtonStyle(compact: true))
                        .disabled(isBusy)

                        Button("Delete Selected") {
                            showDeleteSelectedConfirm = true
                        }
                        .buttonStyle(SoraninSecondaryButtonStyle(compact: true))
                        .disabled(isBusy)
                    } else {
                        Button("Copy All") {
                            onCopyAllTitles()
                        }
                        .buttonStyle(SoraninSecondaryButtonStyle(compact: true))
                        .disabled(isBusy)

                        Button("Delete All") {
                            showDeleteAllConfirm = true
                        }
                        .buttonStyle(SoraninSecondaryButtonStyle(compact: true))
                        .disabled(isBusy)
                    }
                }
                Text(selectedCount > 0 ? "\(items.count) items • \(selectedCount) selected" : "\(items.count) items")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(SoraninPalette.secondaryText)
            }

            if items.isEmpty {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(SoraninPalette.cardStrong)
                    .frame(height: 140)
                    .overlay(
                        Text("No edited videos yet.")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(SoraninPalette.secondaryText)
                    )
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(items) { item in
                            EditedPackageCard(
                                item: item,
                                isBusy: isBusy,
                                isSelected: selectedIDs.contains(item.id),
                                onCopyTitle: { onCopyTitle(item) },
                                onToggleSelection: { onToggleSelection(item) },
                                onShowDetails: { onShowDetails(item) },
                                onOpenPackage: { onOpenPackage(item) },
                                onOpenProfiles: { onOpenProfiles(item) },
                                onDeletePackage: { onDeletePackage(item) }
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: 416)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(SoraninPalette.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(SoraninPalette.border, lineWidth: 1)
        )
        .confirmationDialog("Delete all folders?", isPresented: $showDeleteAllConfirm, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) {
                onDeleteAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove all edited package folders.")
        }
        .confirmationDialog("Delete selected folders?", isPresented: $showDeleteSelectedConfirm, titleVisibility: .visible) {
            Button("Delete Selected", role: .destructive) {
                onDeleteSelected()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove only the selected package folders.")
        }
    }
}

struct EditProgressPanel: View {
    let isVisible: Bool
    let percent: Int
    let label: String

    var body: some View {
        if isVisible {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Edit Progress")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(SoraninPalette.primaryText)
                    Spacer()
                    Text("\(percent)%")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(SoraninPalette.secondaryText)
                }
                Text(label.isEmpty ? "Processing videos..." : label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SoraninPalette.secondaryText)
                    .lineLimit(1)
                ProgressView(value: Double(percent), total: 100)
                    .tint(SoraninPalette.accentEnd)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(SoraninPalette.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(SoraninPalette.border, lineWidth: 1)
            )
        }
    }
}

struct APISettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let currentProvider: AIProvider
    let openAIStatus: String
    let geminiStatus: String
    let onSave: (String?, String?, AIProvider) -> Void
    let onRemove: (Bool, Bool, AIProvider) -> Void
    let onTest: (AIProvider, @escaping (String) -> Void) -> Void

    @State private var selectedProvider: AIProvider
    @State private var openAIKey = ""
    @State private var geminiKey = ""
    @State private var openAIStatusText: String
    @State private var geminiStatusText: String
    @State private var openAIHealthText = ""
    @State private var geminiHealthText = ""
    @State private var showOpenAIInput: Bool
    @State private var showGeminiInput: Bool
    @State private var isTestingOpenAI = false
    @State private var isTestingGemini = false

    init(
        currentProvider: AIProvider,
        openAIStatus: String,
        geminiStatus: String,
        onSave: @escaping (String?, String?, AIProvider) -> Void,
        onRemove: @escaping (Bool, Bool, AIProvider) -> Void,
        onTest: @escaping (AIProvider, @escaping (String) -> Void) -> Void
    ) {
        self.currentProvider = currentProvider
        self.openAIStatus = openAIStatus
        self.geminiStatus = geminiStatus
        self.onSave = onSave
        self.onRemove = onRemove
        self.onTest = onTest
        _selectedProvider = State(initialValue: currentProvider)
        _openAIStatusText = State(initialValue: openAIStatus)
        _geminiStatusText = State(initialValue: geminiStatus)
        _showOpenAIInput = State(initialValue: openAIStatus == "Not set")
        _showGeminiInput = State(initialValue: geminiStatus == "Not set")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("AI Settings")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(SoraninPalette.primaryText)
                        Text("រក្សាទុក API key នៅទីនេះ។ AI Chat អាចប្តូរ OpenAI ឬ Gemini ផ្ទាល់ក្នុង chat បាន ដោយមិនពាក់ព័ន្ធនឹង popup នេះ។")
                            .foregroundStyle(SoraninPalette.secondaryText)
                    }
                    Spacer()
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        ForEach(AIProvider.allCases) { provider in
                            Button {
                                selectedProvider = provider
                            } label: {
                                ProviderOptionTile(provider: provider, isSelected: selectedProvider == provider)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    VStack(spacing: 12) {
                        ForEach(AIProvider.allCases) { provider in
                            Button {
                                selectedProvider = provider
                            } label: {
                                ProviderOptionTile(provider: provider, isSelected: selectedProvider == provider)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                apiKeySection(
                    title: "OpenAI API Key",
                    statusText: openAIStatusText,
                    testStatusText: openAIHealthText,
                    isTesting: isTestingOpenAI,
                    isInputVisible: $showOpenAIInput,
                    keyText: $openAIKey,
                    removeAction: {
                        onRemove(true, false, selectedProvider)
                        openAIStatusText = "Not set"
                        openAIHealthText = ""
                        showOpenAIInput = true
                        openAIKey = ""
                    },
                    testAction: {
                        guard !isTestingOpenAI else { return }
                        openAIHealthText = "កំពុងឆែក OpenAI..."
                        isTestingOpenAI = true
                        onTest(.openaiGPT54) { message in
                            openAIHealthText = message
                            isTestingOpenAI = false
                        }
                    }
                )

                apiKeySection(
                    title: "Google Gemini API Key",
                    statusText: geminiStatusText,
                    testStatusText: geminiHealthText,
                    isTesting: isTestingGemini,
                    isInputVisible: $showGeminiInput,
                    keyText: $geminiKey,
                    removeAction: {
                        onRemove(false, true, selectedProvider)
                        geminiStatusText = "Not set"
                        geminiHealthText = ""
                        showGeminiInput = true
                        geminiKey = ""
                    },
                    testAction: {
                        guard !isTestingGemini else { return }
                        geminiHealthText = "កំពុងឆែក Gemini..."
                        isTestingGemini = true
                        let geminiProvider = selectedProvider.providerKey == "gemini" ? selectedProvider : .geminiFlash
                        onTest(geminiProvider) { message in
                            geminiHealthText = message
                            isTestingGemini = false
                        }
                    }
                )

                ViewThatFits(in: .horizontal) {
                    HStack {
                        Text("Save រួច នឹងបង្ហាញសញ្ញាបញ្ជាក់ភ្លាម។")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(SoraninPalette.secondaryText)
                        Spacer()
                        Button("Close") {
                            dismiss()
                        }
                        .buttonStyle(SoraninSecondaryButtonStyle(compact: true))
                        Button("Save") {
                            let openAIValue = openAIKey.trimmingCharacters(in: .whitespacesAndNewlines)
                            let geminiValue = geminiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                            onSave(
                                showOpenAIInput && !openAIValue.isEmpty ? openAIValue : nil,
                                showGeminiInput && !geminiValue.isEmpty ? geminiValue : nil,
                                selectedProvider
                            )
                            if showOpenAIInput && !openAIValue.isEmpty {
                                openAIStatusText = "Saved"
                                showOpenAIInput = false
                                openAIKey = ""
                            }
                            if showGeminiInput && !geminiValue.isEmpty {
                                geminiStatusText = "Saved"
                                showGeminiInput = false
                                geminiKey = ""
                            }
                            dismiss()
                        }
                        .buttonStyle(SoraninPrimaryButtonStyle(compact: true))
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Save រួច នឹងបង្ហាញសញ្ញាបញ្ជាក់ភ្លាម។")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(SoraninPalette.secondaryText)
                        HStack {
                            Button("Close") {
                                dismiss()
                            }
                            .buttonStyle(SoraninSecondaryButtonStyle(compact: true))
                            Button("Save") {
                                let openAIValue = openAIKey.trimmingCharacters(in: .whitespacesAndNewlines)
                                let geminiValue = geminiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                                onSave(
                                    showOpenAIInput && !openAIValue.isEmpty ? openAIValue : nil,
                                    showGeminiInput && !geminiValue.isEmpty ? geminiValue : nil,
                                    selectedProvider
                                )
                                if showOpenAIInput && !openAIValue.isEmpty {
                                    openAIStatusText = "Saved"
                                    showOpenAIInput = false
                                    openAIKey = ""
                                }
                                if showGeminiInput && !geminiValue.isEmpty {
                                    geminiStatusText = "Saved"
                                    showGeminiInput = false
                                    geminiKey = ""
                                }
                                dismiss()
                            }
                            .buttonStyle(SoraninPrimaryButtonStyle(compact: true))
                        }
                    }
                }
            }
            .padding(24)
        }
        .background(SoraninPalette.bgTop)
        .frame(minWidth: 480, idealWidth: 760, maxWidth: 860, minHeight: 420)
    }

    @ViewBuilder
    private func apiKeySection(
        title: String,
        statusText: String,
        testStatusText: String,
        isTesting: Bool,
        isInputVisible: Binding<Bool>,
        keyText: Binding<String>,
        removeAction: @escaping () -> Void,
        testAction: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(SoraninPalette.secondaryText)

            if isInputVisible.wrappedValue {
                SecureField("Paste key", text: keyText)
                    .textFieldStyle(.plain)
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(SoraninPalette.input)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(SoraninPalette.border, lineWidth: 1)
                    )
                    .foregroundStyle(SoraninPalette.primaryText)
                Text(statusText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SoraninPalette.secondaryText)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text(statusText)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SoraninPalette.secondaryText)
                    if !testStatusText.isEmpty {
                        Text(testStatusText)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(
                                (testStatusText.contains("ដំណើរការបាន") || testStatusText.contains("ឆ្លើយតបបាន"))
                                    ? SoraninPalette.success
                                    : Color(red: 1.0, green: 0.48, blue: 0.48)
                            )
                    }
                    HStack {
                        Button(isTesting ? "Testing..." : "Test Key") {
                            testAction()
                        }
                        .buttonStyle(SoraninSecondaryButtonStyle(compact: true))
                        .disabled(isTesting)
                        Spacer()
                        Button("Remove Key") {
                            removeAction()
                        }
                        .buttonStyle(SoraninSecondaryButtonStyle(compact: true))
                    }
                }
            }
        }
    }
}

struct ToastView: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Text("✓")
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.white.opacity(0.16)))
            Text(message)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(red: 0.09, green: 0.25, blue: 0.21))
        )
        .shadow(color: Color.black.opacity(0.18), radius: 18, y: 8)
    }
}

private struct AIChatSessionSidebarRowView: View {
    let session: AIChatSession
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Text(aiChatSessionPreview(session))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(SoraninPalette.primaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(aiChatSessionFormatter.string(from: session.updatedAt))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SoraninPalette.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isSelected ? SoraninPalette.cardSoft : SoraninPalette.cardStrong)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(isSelected ? SoraninPalette.accentEnd.opacity(0.45) : SoraninPalette.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct AIChatImageAttachmentView: View {
    let attachment: AIChatAttachment
    let onOpen: () -> Void
    let onReveal: () -> Void

    private var fileExists: Bool {
        FileManager.default.fileExists(atPath: attachment.url.path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if fileExists, let image = NSImage(contentsOf: attachment.url) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(SoraninPalette.card.opacity(0.6))
                        .frame(height: 180)
                        .overlay(
                            Text("Image unavailable")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(SoraninPalette.secondaryText)
                        )
                }
            }

            HStack(spacing: 10) {
                Text(attachment.resolvedDisplayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SoraninPalette.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button("Open", action: onOpen)
                    .buttonStyle(SoraninSecondaryButtonStyle(compact: true))
                    .disabled(!fileExists)
                Button("Reveal", action: onReveal)
                    .buttonStyle(SoraninSecondaryButtonStyle(compact: true))
                    .disabled(!fileExists)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(SoraninPalette.bgTop.opacity(0.22))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(SoraninPalette.border.opacity(0.7), lineWidth: 1)
        )
    }
}

private struct AIChatVideoAttachmentView: View {
    let attachment: AIChatAttachment
    let onOpen: () -> Void
    let onReveal: () -> Void
    @State private var previewImage: NSImage?
    @State private var didAttemptPreviewLoad = false

    private var fileExists: Bool {
        FileManager.default.fileExists(atPath: attachment.url.path)
    }

    private var previewIcon: NSImage {
        let icon = NSWorkspace.shared.icon(forFile: attachment.url.path)
        icon.size = NSSize(width: 64, height: 64)
        return icon
    }

    private func generatePreviewImage() {
        guard fileExists, !didAttemptPreviewLoad else { return }
        didAttemptPreviewLoad = true
        let videoURL = attachment.url
        DispatchQueue.global(qos: .userInitiated).async {
            let asset = AVURLAsset(url: videoURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1280, height: 1280)

            let durationSeconds = CMTimeGetSeconds(asset.duration)
            let targetSeconds: Double
            if durationSeconds.isFinite, durationSeconds > 0.8 {
                targetSeconds = min(max(durationSeconds * 0.15, 0.35), max(durationSeconds - 0.2, 0.35))
            } else {
                targetSeconds = 0.2
            }

            let captureTimes = [
                CMTime(seconds: targetSeconds, preferredTimescale: 600),
                CMTime(seconds: 0.0, preferredTimescale: 600),
                CMTime(seconds: min(max(targetSeconds * 0.5, 0.1), 1.0), preferredTimescale: 600)
            ]

            var renderedImage: NSImage?
            for captureTime in captureTimes {
                if let cgImage = try? generator.copyCGImage(at: captureTime, actualTime: nil) {
                    renderedImage = NSImage(cgImage: cgImage, size: .zero)
                    break
                }
            }

            DispatchQueue.main.async {
                self.previewImage = renderedImage
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if fileExists, let previewImage {
                    Image(nsImage: previewImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(alignment: .topLeading) {
                            HStack(spacing: 8) {
                                Image(systemName: "video.fill")
                                    .font(.system(size: 11, weight: .black))
                                Text("Video")
                                    .font(.system(size: 11, weight: .black))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.black.opacity(0.58))
                            )
                            .padding(12)
                        }
                } else if fileExists {
                    HStack(spacing: 14) {
                        Image(nsImage: previewIcon)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Video attached")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(SoraninPalette.primaryText)
                            Text("Open the file to preview or play it.")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(SoraninPalette.secondaryText)
                                .lineLimit(2)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(SoraninPalette.card.opacity(0.6))
                    )
                } else {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(SoraninPalette.card.opacity(0.6))
                        .frame(height: 180)
                        .overlay(
                            VStack(spacing: 8) {
                                Image(systemName: "video.slash.fill")
                                    .font(.system(size: 28, weight: .bold))
                                    .foregroundStyle(SoraninPalette.secondaryText)
                                Text("Video unavailable")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(SoraninPalette.secondaryText)
                            }
                        )
                }
            }

            HStack(spacing: 10) {
                Text(attachment.resolvedDisplayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SoraninPalette.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button("Open", action: onOpen)
                    .buttonStyle(SoraninSecondaryButtonStyle(compact: true))
                    .disabled(!fileExists)
                Button("Reveal", action: onReveal)
                    .buttonStyle(SoraninSecondaryButtonStyle(compact: true))
                    .disabled(!fileExists)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(SoraninPalette.bgTop.opacity(0.22))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(SoraninPalette.border.opacity(0.7), lineWidth: 1)
        )
        .onAppear {
            generatePreviewImage()
        }
    }
}

private struct AIChatBubbleView: View {
    let message: AIChatMessage
    let onCopyPrompt: ((String) -> Void)?
    let onCopyMessage: ((String) -> Void)?
    let onOpenAttachment: ((AIChatAttachment) -> Void)?
    let onRevealAttachment: ((AIChatAttachment) -> Void)?
    @State private var copiedPromptBlockID: String?

    private var isUser: Bool {
        message.role == "user"
    }

    private var promptBlocks: [AIChatPromptBlock] {
        guard !isUser else { return [] }
        return extractCopyablePromptBlocks(from: message.content)
    }

    private var shouldShowRawContentText: Bool {
        let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if isUser {
            return true
        }
        return promptBlocks.isEmpty
    }

    private func markPromptCopied(_ blockID: String) {
        withAnimation(.easeInOut(duration: 0.16)) {
            copiedPromptBlockID = blockID
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard copiedPromptBlockID == blockID else { return }
            withAnimation(.easeInOut(duration: 0.16)) {
                copiedPromptBlockID = nil
            }
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if isUser {
                Spacer(minLength: 52)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(isUser ? "You" : "AI")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(isUser ? SoraninPalette.primaryText : SoraninPalette.secondaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule(style: .continuous)
                                .fill(isUser ? SoraninPalette.accentEnd.opacity(0.32) : SoraninPalette.cardSoft)
                        )
                    Spacer(minLength: 0)
                }

                if shouldShowRawContentText {
                    Text(message.content)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(SoraninPalette.primaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }

                if !message.attachments.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(message.attachments) { attachment in
                            switch attachment.kind {
                            case .image:
                                AIChatImageAttachmentView(
                                    attachment: attachment,
                                    onOpen: { onOpenAttachment?(attachment) },
                                    onReveal: { onRevealAttachment?(attachment) }
                                )
                            case .video:
                                AIChatVideoAttachmentView(
                                    attachment: attachment,
                                    onOpen: { onOpenAttachment?(attachment) },
                                    onReveal: { onRevealAttachment?(attachment) }
                                )
                            }
                        }
                    }
                }

                if !promptBlocks.isEmpty, let onCopyPrompt {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(promptBlocks.enumerated()), id: \.element.id) { index, block in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .center, spacing: 10) {
                                    Text(block.label)
                                        .font(.system(size: 11, weight: .black))
                                        .foregroundStyle(SoraninPalette.secondaryText)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(
                                            Capsule(style: .continuous)
                                                .fill(SoraninPalette.card.opacity(0.72))
                                        )

                                    Spacer(minLength: 0)

                                    let isCopied = copiedPromptBlockID == block.id
                                    Button {
                                        onCopyPrompt(block.prompt)
                                        markPromptCopied(block.id)
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: isCopied ? "checkmark.circle.fill" : "doc.on.doc")
                                                .font(.system(size: 11, weight: .bold))
                                            Text(isCopied ? "Copied" : (promptBlocks.count > 1 ? "Copy \(index + 1)" : "Copy Prompt"))
                                                .font(.system(size: 12, weight: .bold))
                                        }
                                        .foregroundStyle(isCopied ? SoraninPalette.bgTop : SoraninPalette.primaryText)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 10)
                                        .background(
                                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                                .fill(
                                                    isCopied
                                                        ? SoraninPalette.success
                                                        : SoraninPalette.cardSoft
                                                )
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                                .stroke(
                                                    isCopied
                                                        ? SoraninPalette.success.opacity(0.95)
                                                        : SoraninPalette.border,
                                                    lineWidth: 1
                                                )
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .scaleEffect(isCopied ? 1.02 : 1)
                                    .animation(.easeInOut(duration: 0.16), value: isCopied)
                                    .help(isCopied ? "Prompt copied" : "Copy only this prompt")
                                }

                                Text(block.prompt)
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .foregroundStyle(SoraninPalette.primaryText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                                    .padding(12)
                                    .background(
                                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                                            .fill(SoraninPalette.bgTop.opacity(0.26))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                                            .stroke(SoraninPalette.border.opacity(0.68), lineWidth: 1)
                                    )
                            }
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: 520, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(isUser ? SoraninPalette.cardSoft : SoraninPalette.cardStrong)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(isUser ? SoraninPalette.accentEnd.opacity(0.55) : SoraninPalette.border, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(isUser ? 0.12 : 0.08), radius: 14, y: 6)
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .onTapGesture {
                guard isUser else { return }
                onCopyMessage?(message.content)
            }
            .help(isUser ? "Click to copy your message" : "")

            if !isUser {
                Spacer(minLength: 52)
            }
        }
    }
}

struct AIChatSheet: View {
    @ObservedObject var model: ReelsModel

    let onClose: () -> Void
    @State private var draft = ""
    @State private var selectedMediaCommand: String?
    @State private var measuredComposerHeight: CGFloat = 54
    @State private var selectedThumbnailDesignStyle: AIChatThumbnailDesignStyle = .safeViral

    private var normalizedDraft: String {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = aiChatLeadingMediaAliasMatch(in: trimmed) {
            return match.remainder.isEmpty ? match.alias : "\(match.alias) \(match.remainder)"
        }
        guard let selectedMediaCommand, !trimmed.isEmpty else {
            return trimmed
        }
        return "\(selectedMediaCommand) \(trimmed)"
    }

    private var draftMediaKind: AIChatGeneratedMediaKind? {
        if let match = aiChatLeadingMediaAliasMatch(in: draft) {
            return requestedGeneratedMediaKind(for: match.alias)
        }
        if let selectedMediaCommand {
            return requestedGeneratedMediaKind(for: selectedMediaCommand)
        }
        return requestedGeneratedMediaKind(for: draft)
    }

    private var selectedModeLabel: String? {
        if let match = aiChatLeadingMediaAliasMatch(in: draft) {
            return aiChatModeLabel(for: match.alias, provider: model.aiChatProvider, attachmentURLs: model.aiChatAttachmentURLs, geminiChoice: model.aiChatGeminiImageModelChoice)
        }
        if let selectedMediaCommand {
            return aiChatModeLabel(for: selectedMediaCommand, provider: model.aiChatProvider, attachmentURLs: model.aiChatAttachmentURLs, geminiChoice: model.aiChatGeminiImageModelChoice)
        }
        guard requestedGeneratedMediaKind(for: draft) != nil else { return nil }
        return aiChatModeLabel(for: draft, provider: model.aiChatProvider, attachmentURLs: model.aiChatAttachmentURLs, geminiChoice: model.aiChatGeminiImageModelChoice)
    }

    private var composerFieldHeight: CGFloat {
        min(max(54, measuredComposerHeight), 220)
    }

    private var liveButtonTitle: String {
        if model.isGeminiLiveCapturing {
            return "Stop Live"
        }
        if model.isGeminiLiveSessionActive {
            return "Waiting..."
        }
        return "Live"
    }

    private var recordButtonTitle: String {
        if model.isAIChatTranscribing {
            return "Transcribing..."
        }
        if model.isAIChatRecording {
            return "Stop Record"
        }
        return model.aiChatRecordingProvider.label
    }

    private var recordButtonIconName: String {
        if model.isAIChatRecording {
            return "stop.fill"
        }
        return "mic.fill"
    }

    private var canSend: Bool {
        !model.isAIChatBusy && !model.isGeminiLiveSessionActive && !model.isAIChatRecording && !model.isAIChatTranscribing &&
        (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.aiChatAttachmentURLs.isEmpty)
    }

    private var hasVideoAttachment: Bool {
        let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "webm"]
        return model.aiChatAttachmentURLs.contains { videoExtensions.contains($0.pathExtension.lowercased()) }
    }

    private var showGeminiImageModelPicker: Bool {
        model.aiChatProvider.providerKey == "gemini"
    }

    private func sendDraftMessage() {
        let message = normalizedDraft
        let visibleMessage = aiChatDisplayPrompt(message)
        draft = ""
        selectedMediaCommand = nil
        model.sendAIChat(message, displayText: visibleMessage)
    }

    private func sendVideoThumbnailRequest() {
        guard hasVideoAttachment else { return }
        draft = ""
        selectedMediaCommand = nil
        model.sendAIChat(
            "/banana2 create thumbnail from this video with policy check \(selectedThumbnailDesignStyle.requestSuffix)",
            displayText: "Thumbnail • \(selectedThumbnailDesignStyle.label)"
        )
    }

    private func applyMediaCommand(_ command: String) {
        let canonicalCommand = normalizedAIChatMediaPrompt(command)
        let visibleDraft = aiChatDisplayPrompt(draft)
        draft = visibleDraft
        if selectedMediaCommand?.caseInsensitiveCompare(canonicalCommand) == .orderedSame {
            selectedMediaCommand = nil
        } else {
            selectedMediaCommand = canonicalCommand
        }
    }

    private func insertRecordedTextIntoDraft(_ text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft = cleaned
        } else if draft.hasSuffix("\n") {
            draft += cleaned
        } else {
            draft += "\n" + cleaned
        }
    }

    @ViewBuilder
    private var recordProviderButton: some View {
        Button {
            model.toggleAIChatRecordingProvider()
        } label: {
            ZStack {
                Circle()
                    .fill(SoraninPalette.cardSoft)
                Circle()
                    .stroke(model.aiChatRecordingProvider == .openai ? SoraninPalette.accentGlow : SoraninPalette.border, lineWidth: 1)
                Text(model.aiChatRecordingProvider.shortLabel)
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(SoraninPalette.primaryText)
            }
            .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .help(model.aiChatRecordingProvider.label)
        .disabled(model.isAIChatBusy || model.isGeminiLiveSessionActive || model.isAIChatRecording || model.isAIChatTranscribing)
    }

    @ViewBuilder
    private var recordIconButton: some View {
        Button {
            if model.isAIChatRecording {
                model.stopAIChatRecording { text in
                    insertRecordedTextIntoDraft(text)
                }
            } else if !model.isAIChatTranscribing {
                model.startAIChatRecording()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(model.isAIChatRecording ? SoraninPalette.accentStart.opacity(0.92) : SoraninPalette.cardSoft)
                Circle()
                    .stroke(model.isAIChatRecording ? SoraninPalette.accentGlow : SoraninPalette.border, lineWidth: 1)
                if model.isAIChatTranscribing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(SoraninPalette.primaryText)
                } else {
                    Image(systemName: recordButtonIconName)
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(SoraninPalette.primaryText)
                }
            }
            .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .help(recordButtonTitle)
        .disabled(model.isAIChatBusy || model.isGeminiLiveSessionActive || model.isAIChatTranscribing)
    }

    @ViewBuilder
    private func liveVoiceButton(_ choice: AILiveVoiceChoice) -> some View {
        let isSelected = model.currentAIChatLiveVoiceChoice == choice
        let buttonLabel = HStack(spacing: 6) {
            Image(systemName: choice.iconSystemName)
            Text(choice.shortLabel)
        }
        if isSelected {
            Button {
                model.setAIChatLiveVoiceChoice(choice)
            } label: {
                buttonLabel
            }
            .buttonStyle(SoraninPrimaryButtonStyle(compact: true))
        } else {
            Button {
                model.setAIChatLiveVoiceChoice(choice)
            } label: {
                buttonLabel
            }
            .buttonStyle(SoraninSecondaryButtonStyle(compact: true))
        }
    }

    @ViewBuilder
    private func mediaCommandButton(_ command: String) -> some View {
        let canonicalCommand = normalizedAIChatMediaPrompt(command)
        let isSelected = selectedMediaCommand?.caseInsensitiveCompare(canonicalCommand) == .orderedSame
        if isSelected {
            Button(aiChatVisibleMediaCommandTitle(command)) {
                applyMediaCommand(command)
            }
            .buttonStyle(SoraninPrimaryButtonStyle(compact: true))
        } else {
            Button(aiChatVisibleMediaCommandTitle(command)) {
                applyMediaCommand(command)
            }
            .buttonStyle(SoraninSecondaryButtonStyle(compact: true))
        }
    }

    @ViewBuilder
    private var attachmentStrip: some View {
        if !model.aiChatAttachmentURLs.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.aiChatAttachmentURLs, id: \.path) { url in
                        HStack(spacing: 8) {
                            Image(systemName: url.pathExtension.lowercased().contains("mp4") || url.pathExtension.lowercased().contains("mov") ? "video.fill" : "photo.fill")
                                .font(.system(size: 11, weight: .bold))
                            Text(url.lastPathComponent)
                                .lineLimit(1)
                                .font(.system(size: 12, weight: .semibold))
                            Button {
                                model.removeAIChatAttachment(url)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .black))
                            }
                            .buttonStyle(.plain)
                        }
                        .foregroundStyle(SoraninPalette.primaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            Capsule(style: .continuous)
                                .fill(SoraninPalette.cardSoft)
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(SoraninPalette.border, lineWidth: 1)
                        )
                    }
                }
            }
        }
    }

    private var composerField: some View {
        ZStack(alignment: .topLeading) {
            AIChatComposerTextEditor(
                text: $draft,
                measuredHeight: $measuredComposerHeight,
                isEditable: !model.isAIChatBusy && !model.isGeminiLiveSessionActive && !model.isAIChatRecording && !model.isAIChatTranscribing,
                onSubmit: sendDraftMessage,
                canSubmit: { canSend },
                onStandaloneShiftPress: {
                    model.toggleLiveChatFromShortcut()
                }
            )
            .padding(.trailing, 42)
            .frame(height: composerFieldHeight)
            if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Type normally. Start with image, video, banana2, or bananapro if needed. Enter = send. Shift+Enter = new line. Tap Shift = Live on/off.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(SoraninPalette.secondaryText.opacity(0.88))
                    .padding(.top, 8)
                    .padding(.leading, 6)
                    .padding(.trailing, 52)
                    .allowsHitTesting(false)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(SoraninPalette.input)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(SoraninPalette.border, lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 8) {
                recordProviderButton
                recordIconButton
            }
                .padding(.top, 10)
                .padding(.trailing, 10)
        }
    }

    private var mediaCommandRow: some View {
        HStack(spacing: 8) {
            if let draftMediaKind {
                Text(selectedModeLabel ?? (draftMediaKind == .image ? "Image mode detected" : "Video mode detected"))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(SoraninPalette.secondaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        Capsule(style: .continuous)
                            .fill(SoraninPalette.cardStrong)
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(SoraninPalette.border, lineWidth: 1)
                    )
            }
        }
    }

    private var composerActionRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Status")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(SoraninPalette.secondaryText)
                Text(model.aiChatStatus)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SoraninPalette.primaryText)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            Spacer()
            if hasVideoAttachment {
                Button("Thumbnail") {
                    sendVideoThumbnailRequest()
                }
                .buttonStyle(SoraninSecondaryButtonStyle(compact: true))
                .disabled(model.isAIChatBusy || model.isGeminiLiveSessionActive || model.isAIChatRecording || model.isAIChatTranscribing)
                Menu {
                    ForEach(AIChatThumbnailDesignStyle.allCases) { style in
                        Button {
                            selectedThumbnailDesignStyle = style
                        } label: {
                            if style == selectedThumbnailDesignStyle {
                                Label(style.label, systemImage: "checkmark")
                            } else {
                                Text(style.label)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(selectedThumbnailDesignStyle.label)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .black))
                    }
                }
                .buttonStyle(SoraninSecondaryButtonStyle(compact: true))
                .disabled(model.isAIChatBusy || model.isGeminiLiveSessionActive || model.isAIChatRecording || model.isAIChatTranscribing)
            }
            if showGeminiImageModelPicker {
                Menu {
                    ForEach(AIChatGeminiImageModelChoice.allCases) { choice in
                        Button {
                            model.setAIChatGeminiImageModelChoice(choice)
                        } label: {
                            if choice == model.aiChatGeminiImageModelChoice {
                                Label(choice.label, systemImage: "checkmark")
                            } else {
                                Text(choice.label)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(model.aiChatGeminiImageModelChoice.compactLabel)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .black))
                    }
                }
                .buttonStyle(SoraninSecondaryButtonStyle(compact: true))
                .disabled(model.isAIChatBusy || model.isGeminiLiveSessionActive || model.isAIChatRecording || model.isAIChatTranscribing)
            }
            Button("Add Media") {
                model.pickAIChatAttachments()
            }
            .buttonStyle(SoraninSecondaryButtonStyle(compact: true))
            .disabled(model.isAIChatBusy || model.isGeminiLiveSessionActive || model.isAIChatRecording || model.isAIChatTranscribing)
            if !model.aiChatAttachmentURLs.isEmpty {
                Button("Clear Media") {
                    model.clearAIChatAttachments()
                }
                .buttonStyle(SoraninSecondaryButtonStyle(compact: true))
                .disabled(model.isAIChatBusy || model.isGeminiLiveSessionActive || model.isAIChatRecording || model.isAIChatTranscribing)
            }
            Button("Copy Issue") {
                model.copyAIChatIssueReport()
            }
            .buttonStyle(SoraninSecondaryButtonStyle(compact: true))
            if model.aiChatProvider.providerKey == "gemini" || model.aiChatProvider.providerKey == "openai" {
                Button(liveButtonTitle) {
                    if model.isGeminiLiveCapturing {
                        model.stopLiveChat()
                    } else if !model.isGeminiLiveSessionActive {
                        model.startLiveChat()
                    }
                }
                .buttonStyle(SoraninSecondaryButtonStyle(compact: true))
                .disabled(model.isAIChatBusy || model.isAIChatRecording || model.isAIChatTranscribing || (model.isGeminiLiveSessionActive && !model.isGeminiLiveCapturing))

                Button("Pause") {
                    model.pauseLiveVoicePlayback()
                }
                .buttonStyle(SoraninSecondaryButtonStyle(compact: true))
                .disabled(!model.isLiveVoicePlaying || model.isAIChatBusy || model.isAIChatRecording || model.isAIChatTranscribing)

                Button("Play") {
                    model.playLiveVoicePlayback()
                }
                .buttonStyle(SoraninSecondaryButtonStyle(compact: true))
                .disabled(!model.hasReplayableLiveVoice || model.isLiveVoicePlaying || model.isAIChatBusy || model.isAIChatRecording || model.isAIChatTranscribing)
            }
            Button("Send") {
                sendDraftMessage()
            }
            .buttonStyle(SoraninPrimaryButtonStyle(compact: false))
            .disabled(!canSend)
        }
    }

    private var composerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            attachmentStrip
            composerField
            mediaCommandRow
            composerActionRow
        }
    }

    var body: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Chats")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(SoraninPalette.primaryText)
                    Spacer()
                    Text("\(model.aiChatSessions.count)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(SoraninPalette.primaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule(style: .continuous)
                                .fill(SoraninPalette.cardSoft)
                        )
                }

                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.aiChatSessions) { session in
                            AIChatSessionSidebarRowView(
                                session: session,
                                isSelected: session.id == model.currentAIChatSessionID
                            ) {
                                model.loadAIChatSession(session)
                            }
                        }
                    }
                }

                VStack(spacing: 10) {
                    Button("New Chat") {
                        model.startNewAIChatSession()
                    }
                    .buttonStyle(SoraninPrimaryButtonStyle(compact: false))

                    Button("Clear") {
                        model.clearAIChat()
                    }
                    .buttonStyle(SoraninSecondaryButtonStyle(compact: false))

                    Button("Quit App") {
                        requestSoraninAppQuit()
                    }
                    .buttonStyle(SoraninSecondaryButtonStyle(compact: true))
                }
            }
            .padding(18)
            .frame(width: 248)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(SoraninPalette.cardStrong)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(SoraninPalette.border, lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("AI Chat")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(SoraninPalette.primaryText)
                        Text("Run live with your saved AI API key.")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(SoraninPalette.secondaryText)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 8) {
                        HStack(spacing: 8) {
                            Menu {
                                ForEach(AIProvider.allCases) { provider in
                                    Button {
                                        model.setAIChatProvider(provider)
                                    } label: {
                                        if provider == model.aiChatProvider {
                                            Label(provider.label, systemImage: "checkmark")
                                        } else {
                                            Text(provider.label)
                                        }
                                    }
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Text(model.aiChatProvider.label)
                                        .lineLimit(1)
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 10, weight: .black))
                                }
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(SoraninPalette.primaryText)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(SoraninPalette.cardSoft)
                                )
                            }
                            .buttonStyle(.plain)

                            Button {
                                model.cancelLiveChat(showStatus: false)
                                onClose()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 12, weight: .black))
                                    Text("Close Chat")
                                }
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(SoraninPalette.primaryText)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(SoraninPalette.cardSoft)
                                )
                                .overlay(
                                    Capsule(style: .continuous)
                                        .stroke(SoraninPalette.border, lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                        Text(model.currentAIChatSessionLabel)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(SoraninPalette.secondaryText)
                            .lineLimit(1)
                        if model.aiChatProvider.providerKey == "gemini" || model.aiChatProvider.providerKey == "openai" {
                            HStack(spacing: 8) {
                                liveVoiceButton(.female)
                                liveVoiceButton(.male)
                            }
                            Text("Live Voice: \(model.currentAIChatLiveVoiceDescription)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(SoraninPalette.secondaryText)
                                .lineLimit(1)
                        }
                    }
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if model.aiChatMessages.isEmpty {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Start a real AI thread")
                                        .font(.system(size: 18, weight: .bold))
                                        .foregroundStyle(SoraninPalette.primaryText)
                                    Text("Ask for titles, thumbnails, prompts, or attach videos and images for analysis.")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(SoraninPalette.secondaryText)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(18)
                                .background(
                                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                                        .fill(SoraninPalette.cardStrong)
                                )
                            } else {
                                ForEach(model.aiChatMessages) { message in
                                    AIChatBubbleView(
                                        message: message,
                                        onCopyPrompt: { promptText in
                                            model.copyPromptText(promptText)
                                        },
                                        onCopyMessage: { text in
                                            model.copyAIChatMessageText(text)
                                        },
                                        onOpenAttachment: { attachment in
                                            model.openAIChatAttachment(attachment)
                                        },
                                        onRevealAttachment: { attachment in
                                            model.revealAIChatAttachment(attachment)
                                        }
                                    )
                                    .id(message.id)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(minHeight: 320)
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .fill(SoraninPalette.cardStrong)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .stroke(SoraninPalette.border, lineWidth: 1)
                    )
                    .onChange(of: model.aiChatMessages.count) { _ in
                        if let lastID = model.aiChatMessages.last?.id {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(lastID, anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: model.aiChatMessages.last?.content ?? "") { _ in
                        if let lastID = model.aiChatMessages.last?.id {
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo(lastID, anchor: .bottom)
                            }
                        }
                    }
                }

                composerSection
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(SoraninPalette.cardStrong)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(SoraninPalette.border, lineWidth: 1)
                )
            }
        }
        .padding(24)
        .background(SoraninPalette.bgTop)
        .frame(minWidth: 760, idealWidth: 1080, maxWidth: 1220, minHeight: 620)
        .onDisappear {
            model.cancelLiveChat(showStatus: false)
            model.cancelAIChatRecording(resetStatus: false)
        }
    }
}

struct ChromeProfilesSheet: View {
    @ObservedObject var model: ReelsModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedProfileIDs: Set<String> = []
    @State private var showDeleteConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Chrome Profiles")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(SoraninPalette.primaryText)
                    Text("Select a Chrome profile to open. Status stays live.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(SoraninPalette.secondaryText)
                }
                Spacer()
                Text(selectedProfileIDs.isEmpty ? "\(model.chromeProfiles.count)" : "\(model.chromeProfiles.count) • \(selectedProfileIDs.count)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(SoraninPalette.primaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        Capsule(style: .continuous)
                            .fill(SoraninPalette.cardSoft)
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(SoraninPalette.border, lineWidth: 1)
                    )
            }

            ScrollView {
                VStack(spacing: 10) {
                    if model.isChromeProfilesLoading && model.chromeProfiles.isEmpty {
                        Text("Loading Chrome profiles...")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(SoraninPalette.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(SoraninPalette.cardStrong)
                            )
                    } else if model.chromeProfiles.isEmpty {
                        Text("No Chrome profiles found.")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(SoraninPalette.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(SoraninPalette.cardStrong)
                            )
                    } else {
                        ForEach(model.chromeProfiles) { item in
                            HStack(spacing: 12) {
                                Image(systemName: selectedProfileIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(selectedProfileIDs.contains(item.id) ? SoraninPalette.success : SoraninPalette.secondaryText)
                                Text(item.displayName)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(SoraninPalette.primaryText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                ChromeProfileStatusPill(isOnline: item.isOnline)
                            }
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(selectedProfileIDs.contains(item.id) ? SoraninPalette.cardSoft : SoraninPalette.cardStrong)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(selectedProfileIDs.contains(item.id) ? SoraninPalette.success : SoraninPalette.border, lineWidth: selectedProfileIDs.contains(item.id) ? 2 : 1)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if selectedProfileIDs.contains(item.id) {
                                    selectedProfileIDs.remove(item.id)
                                } else {
                                    selectedProfileIDs.insert(item.id)
                                }
                            }
                            .onTapGesture(count: 2) {
                                model.openChromeProfile(item)
                            }
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                Button("Add") {
                    model.addChromeProfile()
                }
                .buttonStyle(SoraninSecondaryButtonStyle(compact: true))

                Button("Refresh") {
                    model.refreshChromeProfiles()
                    selectedProfileIDs.formIntersection(Set(model.chromeProfiles.map(\.id)))
                }
                .buttonStyle(SoraninSecondaryButtonStyle(compact: true))

                Button("Copy") {
                    model.copyAllChromeProfiles()
                }
                .buttonStyle(SoraninSecondaryButtonStyle(compact: true))

                if !selectedProfileIDs.isEmpty {
                    Button("Open") {
                        let selectedItems = model.chromeProfiles.filter { selectedProfileIDs.contains($0.id) }
                        for item in selectedItems {
                            model.openChromeProfile(item)
                        }
                    }
                    .buttonStyle(SoraninSecondaryButtonStyle(compact: true))

                    Button("Close") {
                        let selectedItems = model.chromeProfiles.filter { selectedProfileIDs.contains($0.id) }
                        model.closeChromeProfiles(selectedItems)
                    }
                    .buttonStyle(SoraninSecondaryButtonStyle(compact: true))

                    Button("Delete") {
                        showDeleteConfirm = true
                    }
                    .buttonStyle(SoraninSecondaryButtonStyle(compact: true))
                }

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(SoraninPrimaryButtonStyle(compact: true))
            }
        }
        .padding(24)
        .background(SoraninPalette.bgTop)
        .frame(minWidth: 560, idealWidth: 760, maxWidth: 860, minHeight: 420)
        .confirmationDialog("Delete selected Chrome profiles?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                let selectedItems = model.chromeProfiles.filter { selectedProfileIDs.contains($0.id) }
                model.deleteChromeProfiles(selectedItems)
                selectedProfileIDs.removeAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Chrome must be closed. Default profile cannot be deleted.")
        }
        .onAppear {
            model.refreshChromeProfiles()
            selectedProfileIDs.formIntersection(Set(model.chromeProfiles.map(\.id)))
        }
    }
}

struct ChromeProfilePickerSheet: View {
    let packageName: String
    let items: [ChromeProfileItem]
    let currentDirectoryName: String?
    let onRefresh: () -> Void
    let onAssign: (ChromeProfileItem) -> Void
    let onClear: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedProfileID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Select Chrome Profile")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(SoraninPalette.primaryText)
                Text(packageName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(SoraninPalette.secondaryText)
            }

            if let currentDirectoryName, !currentDirectoryName.isEmpty {
                Text("Current: \(items.first(where: { $0.directoryName == currentDirectoryName })?.displayName ?? currentDirectoryName)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SoraninPalette.primaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(SoraninPalette.cardStrong)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(SoraninPalette.border, lineWidth: 1)
                    )
            }

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(items) { item in
                        HStack(spacing: 12) {
                            Image(systemName: selectedProfileID == item.id ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(selectedProfileID == item.id ? SoraninPalette.success : SoraninPalette.secondaryText)
                            Text(item.displayName)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(SoraninPalette.primaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            ChromeProfileStatusPill(isOnline: item.isOnline)
                        }
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(selectedProfileID == item.id ? SoraninPalette.cardSoft : SoraninPalette.cardStrong)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(selectedProfileID == item.id ? SoraninPalette.success : SoraninPalette.border, lineWidth: selectedProfileID == item.id ? 2 : 1)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedProfileID = item.id
                        }
                        .onTapGesture(count: 2) {
                            onAssign(item)
                            dismiss()
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                Button("Refresh") {
                    onRefresh()
                }
                .buttonStyle(SoraninSecondaryButtonStyle(compact: true))

                if currentDirectoryName != nil {
                    Button("Clear") {
                        onClear()
                        dismiss()
                    }
                    .buttonStyle(SoraninSecondaryButtonStyle(compact: true))
                }

                Spacer()

                Button("Assign") {
                    guard let selectedProfileID,
                          let item = items.first(where: { $0.id == selectedProfileID })
                    else {
                        return
                    }
                    onAssign(item)
                    dismiss()
                }
                .buttonStyle(SoraninPrimaryButtonStyle(compact: true))
                .disabled(selectedProfileID == nil)

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(SoraninSecondaryButtonStyle(compact: true))
            }
        }
        .padding(24)
        .background(SoraninPalette.bgTop)
        .frame(minWidth: 520, idealWidth: 640, maxWidth: 760, minHeight: 420)
        .onAppear {
            selectedProfileID = currentDirectoryName
        }
    }
}

struct HealthStatusSheet: View {
    @ObservedObject var model: ReelsModel

    @Environment(\.dismiss) private var dismiss

    private var statusTint: Color {
        switch model.status.lowercased() {
        case "healthy":
            return SoraninPalette.success
        case "checking":
            return SoraninPalette.accentEnd
        default:
            return Color(red: 1.0, green: 0.42, blue: 0.42)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Health Status")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(SoraninPalette.primaryText)
                    Text("Open details for warnings and errors, then copy the issue report if you need help.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(SoraninPalette.secondaryText)
                }
                Spacer()
                HStack(spacing: 8) {
                    Circle()
                        .fill(statusTint)
                        .frame(width: 10, height: 10)
                    Text(model.status)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(SoraninPalette.primaryText)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    Capsule(style: .continuous)
                        .fill(SoraninPalette.cardSoft)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(SoraninPalette.border, lineWidth: 1)
                )
            }

            Text(model.detail)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(SoraninPalette.primaryText)
                .textSelection(.enabled)

            ScrollView {
                Text(model.healthStatusReportText)
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color(red: 0.97, green: 0.95, blue: 0.92))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(SoraninPalette.cardStrong)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(SoraninPalette.border, lineWidth: 1)
            )

            HStack(spacing: 10) {
                Button(model.isHealthCheckRunning ? "Checking..." : "Run Health Check") {
                    model.runHealthCheck()
                }
                .buttonStyle(SoraninSecondaryButtonStyle(compact: false))
                .disabled(model.isHealthCheckRunning)

                Button("Copy Issue") {
                    model.copyAppIssueReport()
                }
                .buttonStyle(SoraninSecondaryButtonStyle(compact: false))

                Spacer()

                Button("Close") {
                    dismiss()
                }
                .buttonStyle(SoraninPrimaryButtonStyle(compact: false))
            }
        }
        .padding(24)
        .background(SoraninPalette.bgTop)
        .frame(minWidth: 760, idealWidth: 920, maxWidth: 1080, minHeight: 520)
    }
}

struct FacebookRunnerPackageCard: View {
    let item: EditedPackageItem
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ThumbnailPreviewView(url: item.thumbnailURL)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(isSelected ? SoraninPalette.success : .white.opacity(0.95))
                        .padding(8)
                }

            Text(item.packageName)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(SoraninPalette.primaryText)
                .lineLimit(1)

            Text(item.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(SoraninPalette.secondaryText)
                .lineLimit(2)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(isSelected ? SoraninPalette.cardSoft : SoraninPalette.cardStrong)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(isSelected ? SoraninPalette.success : SoraninPalette.border, lineWidth: isSelected ? 2 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onToggle()
        }
    }
}

struct FacebookRunnerSheet: View {
    @ObservedObject var model: ReelsModel
    @Binding var selectedProfileDirectoryName: String
    @Binding var pageName: String
    @Binding var packageNamesText: String
    @Binding var intervalMinutes: Int
    @Binding var closeAfterEach: Bool
    @Binding var closeAfterFinish: Bool
    @Binding var postNowAdvanceSlot: Bool
    @Binding var openChromeFirst: Bool
    @Binding var deleteFoldersAfterSuccess: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var selectedPackageIDs: Set<String> = []

    private var selectedProfile: ChromeProfileItem? {
        let trimmed = selectedProfileDirectoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return model.chromeProfiles.first(where: { $0.directoryName == trimmed })
    }

    private var normalizedPageName: String {
        normalizedFacebookRunnerPageName(pageName)
    }

    private var parsedPackageNames: [String] {
        parseFacebookRunnerPackageNames(packageNamesText)
    }

    private var packageItemsByID: [String: EditedPackageItem] {
        Dictionary(uniqueKeysWithValues: model.editedPackages.map { ($0.id, $0) })
    }

    private var canRun: Bool {
        !normalizedPageName.isEmpty && !parsedPackageNames.isEmpty && !model.isBusy
    }

    private var canPreflight: Bool {
        !normalizedPageName.isEmpty && !model.isBusy
    }

    private var serverStatusTint: Color {
        model.isFacebookControlServerOnline ? SoraninPalette.success : Color(red: 1.0, green: 0.42, blue: 0.42)
    }

    @ViewBuilder
    private func serverURLRow(title: String, value: String, isPrimary: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(SoraninPalette.secondaryText)
                    Text(value)
                        .font(.system(size: 12, weight: isPrimary ? .bold : .medium, design: .monospaced))
                        .foregroundStyle(SoraninPalette.primaryText)
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
                Spacer()
                Button("Copy") {
                    model.copyFacebookControlServerURL(value)
                }
                .buttonStyle(SoraninSecondaryButtonStyle(compact: true))
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isPrimary ? SoraninPalette.cardSoft : SoraninPalette.cardStrong)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isPrimary ? SoraninPalette.accentEnd : SoraninPalette.border, lineWidth: 1)
            )
        }
    }

    private func syncSelectedPackageIDsFromText() {
        let available = Set(model.editedPackages.map(\.id))
        selectedPackageIDs = Set(parsedPackageNames).intersection(available)
    }

    private func togglePackage(_ item: EditedPackageItem) {
        if selectedPackageIDs.contains(item.id) {
            selectedPackageIDs.remove(item.id)
        } else {
            selectedPackageIDs.insert(item.id)
        }
    }

    private func addSelectedPackagesToFolders() {
        let selectedNames = model.editedPackages
            .filter { selectedPackageIDs.contains($0.id) }
            .map(\.packageName)
        guard !selectedNames.isEmpty else { return }

        var merged = parsedPackageNames
        for name in selectedNames where !merged.contains(name) {
            merged.append(name)
        }
        packageNamesText = merged.joined(separator: "\n")
    }

    private func useCurrentAppSelection() {
        selectedPackageIDs = model.selectedEditedPackageIDs.intersection(Set(model.editedPackages.map(\.id)))
        addSelectedPackagesToFolders()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Facebook Runner")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(SoraninPalette.primaryText)
                    Text("Run Facebook Reels preflight and batch upload inside Soranin.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(SoraninPalette.secondaryText)
                }
                Spacer()
                Text(model.isBusy ? model.status : "Ready")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(SoraninPalette.primaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        Capsule(style: .continuous)
                            .fill(SoraninPalette.cardSoft)
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(SoraninPalette.border, lineWidth: 1)
                    )
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("iPhone Control")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(SoraninPalette.secondaryText)
                                Text("Paste the Wi-Fi URL into iPhone > Control Mac > Server URL.")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(SoraninPalette.secondaryText)
                            }
                            Spacer()
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(serverStatusTint)
                                    .frame(width: 9, height: 9)
                                Text(model.isFacebookControlServerOnline ? "Online" : "Offline")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(SoraninPalette.primaryText)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(SoraninPalette.cardSoft)
                            )
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(SoraninPalette.border, lineWidth: 1)
                            )

                            Button("Refresh URLs") {
                                model.refreshFacebookControlServerConnectionInfo()
                            }
                            .buttonStyle(SoraninSecondaryButtonStyle(compact: true))
                        }

                        if let lanURL = model.preferredFacebookControlServerLANURL {
                            serverURLRow(title: "Mac URL for iPhone", value: lanURL, isPrimary: true)
                        } else {
                            Text("No Wi-Fi IP found yet. Connect Mac to the same network as your iPhone, then tap Refresh URLs.")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(SoraninPalette.secondaryText)
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(SoraninPalette.cardStrong)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .stroke(SoraninPalette.border, lineWidth: 1)
                                )
                        }

                        serverURLRow(title: "Local Mac URL", value: model.facebookControlServerLocalURL)

                        if model.facebookControlServerLANURLs.count > 1 {
                            ForEach(Array(model.facebookControlServerLANURLs.dropFirst()), id: \.self) { url in
                                serverURLRow(title: "Other Network URL", value: url)
                            }
                        }
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(SoraninPalette.cardStrong)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(SoraninPalette.border, lineWidth: 1)
                    )

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Chrome Profile")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(SoraninPalette.secondaryText)

                        HStack(spacing: 10) {
                            Picker("Chrome Profile", selection: $selectedProfileDirectoryName) {
                                Text("Use current Chrome").tag("")
                                ForEach(model.chromeProfiles) { item in
                                    Text(item.displayName + (item.isOnline ? " • Online" : ""))
                                        .tag(item.directoryName)
                                }
                            }
                            .pickerStyle(.menu)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(SoraninPalette.cardStrong)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(SoraninPalette.border, lineWidth: 1)
                            )

                            Button("Refresh") {
                                model.refreshChromeProfiles()
                            }
                            .buttonStyle(SoraninSecondaryButtonStyle(compact: true))

                            if let selectedProfile {
                                Button("Open") {
                                    model.openChromeProfile(selectedProfile)
                                }
                                .buttonStyle(SoraninSecondaryButtonStyle(compact: true))
                            }
                        }

                        if let selectedProfile {
                            HStack(spacing: 10) {
                                Text(selectedProfile.displayName)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(SoraninPalette.primaryText)
                                ChromeProfileStatusPill(isOnline: selectedProfile.isOnline)
                            }
                        } else {
                            Text("If Chrome is already on the correct profile, leave this blank.")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(SoraninPalette.secondaryText)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Facebook Page")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(SoraninPalette.secondaryText)

                        TextField("Nin Fishing", text: $pageName)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(SoraninPalette.cardStrong)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(SoraninPalette.border, lineWidth: 1)
                            )
                            .foregroundStyle(SoraninPalette.primaryText)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Folders")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(SoraninPalette.secondaryText)
                            Spacer()
                            Text("\(parsedPackageNames.count)")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(SoraninPalette.primaryText)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(SoraninPalette.cardSoft)
                                )
                        }

                        TextEditor(text: $packageNamesText)
                            .scrollContentBackground(.hidden)
                            .font(.system(size: 13, weight: .regular, design: .monospaced))
                            .foregroundStyle(SoraninPalette.primaryText)
                            .padding(10)
                            .frame(minHeight: 120)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(SoraninPalette.cardStrong)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(SoraninPalette.border, lineWidth: 1)
                            )

                        Text(parsedPackageNames.isEmpty ? "Enter package names separated by spaces or new lines." : parsedPackageNames.joined(separator: "  •  "))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(SoraninPalette.secondaryText)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Select From App Cards")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(SoraninPalette.secondaryText)
                            Spacer()
                            Button("Add Selected") {
                                addSelectedPackagesToFolders()
                            }
                            .buttonStyle(SoraninSecondaryButtonStyle(compact: true))
                            .disabled(selectedPackageIDs.isEmpty)

                            Button("Use App Selected") {
                                useCurrentAppSelection()
                            }
                            .buttonStyle(SoraninSecondaryButtonStyle(compact: true))
                            .disabled(model.selectedEditedPackageIDs.isEmpty)
                        }

                        ScrollView {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 200), spacing: 10)], spacing: 10) {
                                ForEach(model.editedPackages) { item in
                                    FacebookRunnerPackageCard(
                                        item: item,
                                        isSelected: selectedPackageIDs.contains(item.id),
                                        onToggle: { togglePackage(item) }
                                    )
                                }
                            }
                            .padding(.trailing, 4)
                        }
                        .frame(minHeight: 220, maxHeight: 320)
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(SoraninPalette.cardStrong)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(SoraninPalette.border, lineWidth: 1)
                        )
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Stepper(value: $intervalMinutes, in: 1...720, step: 30) {
                            Text("Interval: \(intervalMinutes) minute(s)")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(SoraninPalette.primaryText)
                        }

                        Toggle("Open selected Chrome profile first if it is offline", isOn: $openChromeFirst)
                        Toggle("Close Chrome after each package", isOn: $closeAfterEach)
                        Toggle("Close Chrome after finish", isOn: $closeAfterFinish)
                        Toggle("Post now but keep queue moving", isOn: $postNowAdvanceSlot)
                        Toggle("Delete folders after successful run", isOn: $deleteFoldersAfterSuccess)
                    }
                    .toggleStyle(.switch)
                    .foregroundStyle(SoraninPalette.primaryText)
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(SoraninPalette.cardStrong)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(SoraninPalette.border, lineWidth: 1)
                    )

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Root Folder")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(SoraninPalette.secondaryText)
                        Text(rootDir.path)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(SoraninPalette.primaryText)
                        Text("State File")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(SoraninPalette.secondaryText)
                            .padding(.top, 6)
                        Text(facebookTimingStateFile.path)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(SoraninPalette.primaryText)
                        Text("iPhone Control: Mac app auto starts the local control server on port 8765.")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(SoraninPalette.secondaryText)
                            .padding(.top, 6)
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(SoraninPalette.cardStrong)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(SoraninPalette.border, lineWidth: 1)
                    )
                }
            }

            HStack(spacing: 10) {
                Button("Preflight") {
                    model.runFacebookRunnerPreflight(
                        profileDirectoryName: selectedProfileDirectoryName,
                        pageName: pageName,
                        packageNamesText: packageNamesText,
                        intervalMinutes: intervalMinutes
                    )
                }
                .buttonStyle(SoraninSecondaryButtonStyle(compact: false))
                .disabled(!canPreflight)

                Button("Run") {
                    model.runFacebookRunnerBatch(
                        profileDirectoryName: selectedProfileDirectoryName,
                        pageName: pageName,
                        packageNamesText: packageNamesText,
                        intervalMinutes: intervalMinutes,
                        closeAfterEach: closeAfterEach,
                        closeAfterFinish: closeAfterFinish,
                        postNowAdvanceSlot: postNowAdvanceSlot,
                        openChromeFirst: openChromeFirst,
                        deleteFoldersAfterSuccess: deleteFoldersAfterSuccess
                    )
                }
                .buttonStyle(SoraninPrimaryButtonStyle(compact: false))
                .disabled(!canRun)

                Button("Quit Chrome") {
                    model.quitGoogleChromeCompletely()
                }
                .buttonStyle(SoraninSecondaryButtonStyle(compact: false))

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(SoraninSecondaryButtonStyle(compact: false))
            }
        }
        .padding(24)
        .background(SoraninPalette.bgTop)
        .frame(minWidth: 760, idealWidth: 900, maxWidth: 1040, minHeight: 620)
        .onAppear {
            model.refreshChromeProfiles()
            model.ensureFacebookControlServerRunning()
            model.refreshFacebookControlServerConnectionInfo()
            if selectedProfileDirectoryName.isEmpty,
               let firstOnline = model.chromeProfiles.first(where: { $0.isOnline }) {
                selectedProfileDirectoryName = firstOnline.directoryName
            }
            syncSelectedPackageIDsFromText()
        }
        .onChange(of: model.chromeProfiles) { profiles in
            if selectedProfileDirectoryName.isEmpty,
               let firstOnline = profiles.first(where: { $0.isOnline }) {
                selectedProfileDirectoryName = firstOnline.directoryName
            }
        }
        .onChange(of: packageNamesText) { _ in
            syncSelectedPackageIDsFromText()
        }
    }
}

struct ContentView: View {
    @StateObject private var model = ReelsModel()
    @State private var showingSettings = false
    @State private var showingChromeProfiles = false
    @State private var showingFacebookRunner = false
    @State private var showingHealthStatus = false
    @State private var showingAIChat = false
    @State private var detailItem: EditedPackageItem?
    @State private var profilePickerItem: EditedPackageItem?
    @State private var isDropTargeted = false
    @AppStorage("soranin.facebookRunner.profileDirectoryName") private var facebookRunnerProfileDirectoryName = ""
    @AppStorage("soranin.facebookRunner.pageName") private var facebookRunnerPageName = ""
    @AppStorage("soranin.facebookRunner.packageNamesText") private var facebookRunnerPackageNamesText = ""
    @AppStorage("soranin.facebookRunner.intervalMinutes") private var facebookRunnerIntervalMinutes = 30
    @AppStorage("soranin.facebookRunner.closeAfterEach") private var facebookRunnerCloseAfterEach = true
    @AppStorage("soranin.facebookRunner.closeAfterFinish") private var facebookRunnerCloseAfterFinish = true
    @AppStorage("soranin.facebookRunner.postNowAdvanceSlot") private var facebookRunnerPostNowAdvanceSlot = false
    @AppStorage("soranin.facebookRunner.openChromeFirst") private var facebookRunnerOpenChromeFirst = true
    @AppStorage("soranin.facebookRunner.deleteFoldersAfterSuccess") private var facebookRunnerDeleteFoldersAfterSuccess = true
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    private var aiChatToolbarButton: some View {
        AIChatToolbarButton(unreadCount: model.aiChatUnreadCount) {
            model.setAIChatVisibility(true)
            showingAIChat = true
        }
    }

    private func cardColumns(for width: CGFloat) -> [GridItem] {
        let minimum = width < 920 ? 160.0 : 190.0
        return [GridItem(.adaptive(minimum: minimum, maximum: 260), spacing: 12)]
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .bottom) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("soranin")
                                        .font(.system(size: 32, weight: .bold))
                                        .foregroundStyle(SoraninPalette.primaryText)
                                    Text(rootDir.path)
                                        .foregroundStyle(SoraninPalette.secondaryText)
                                        .lineLimit(2)
                                }
                                Spacer()
                                HStack(spacing: 10) {
                                    ChromeOnlineBadge(isOnline: model.chromeOnline)

                                    Button("Chrome Profiles") {
                                        showingChromeProfiles = true
                                        model.refreshChromeProfiles()
                                    }
                                    .buttonStyle(SoraninSecondaryButtonStyle(compact: true))

                                    Button("Facebook Runner") {
                                        model.ensureFacebookControlServerRunning(showToastIfStarted: true)
                                        showingFacebookRunner = true
                                        model.refreshChromeProfiles()
                                    }
                                    .buttonStyle(SoraninSecondaryButtonStyle(compact: true))

                                    Button("API Keys") {
                                        showingSettings = true
                                    }
                                    .buttonStyle(SoraninSecondaryButtonStyle(compact: true))

                                    HealthStatusBadgeButton(status: model.status) {
                                        showingHealthStatus = true
                                    }
                                }
                            }

                            VStack(alignment: .leading, spacing: 10) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("soranin")
                                        .font(.system(size: 32, weight: .bold))
                                        .foregroundStyle(SoraninPalette.primaryText)
                                    Text(rootDir.path)
                                        .foregroundStyle(SoraninPalette.secondaryText)
                                        .lineLimit(3)
                                }
                                HStack(spacing: 10) {
                                    ChromeOnlineBadge(isOnline: model.chromeOnline)

                                    Button("Chrome Profiles") {
                                        showingChromeProfiles = true
                                        model.refreshChromeProfiles()
                                    }
                                    .buttonStyle(SoraninSecondaryButtonStyle(compact: true))

                                    Button("Facebook Runner") {
                                        model.ensureFacebookControlServerRunning(showToastIfStarted: true)
                                        showingFacebookRunner = true
                                        model.refreshChromeProfiles()
                                    }
                                    .buttonStyle(SoraninSecondaryButtonStyle(compact: true))

                                    Button("API Keys") {
                                        showingSettings = true
                                    }
                                    .buttonStyle(SoraninSecondaryButtonStyle(compact: true))

                                    HealthStatusBadgeButton(status: model.status) {
                                        showingHealthStatus = true
                                    }
                                }
                            }
                        }

                        DropVideosPanel(isBusy: model.isBusy, isTargeted: isDropTargeted, onImport: { model.pickVideos() })
                            .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
                                model.importDroppedVideoProviders(providers)
                            }

                        LazyVGrid(columns: cardColumns(for: proxy.size.width), spacing: 12) {
                            StatCard(label: "Sora Source Videos", value: "\(model.sourceCount)")
                            StatCard(label: "Facebook Videos", value: "\(model.facebookSourceCount)")
                            StatCard(label: "Packages", value: "\(model.packageCount)")
                            StatCard(label: "Latest Package", value: model.latestPackage)
                            StatCard(label: "Encoder", value: model.encoderStatus)
                            ActiveAICard(provider: model.activeProvider)
                        }

                        SoraLinksPanel(
                            text: $model.soraInput,
                            detectedCount: model.detectedPostDownloadEntries.count,
                            isBusy: model.isBusy,
                            progressPercent: model.downloadProgressPercent,
                            progressLabel: model.downloadProgressLabel,
                            isProgressVisible: model.isDownloadProgressVisible,
                            onPaste: { model.pasteClipboardSoraLinks() },
                            onDownloadAll: { model.downloadAllSora() }
                        )

                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) {
                                Button("Open Sora Folder") {
                                    model.openRoot()
                                }
                                .buttonStyle(SoraninSecondaryButtonStyle(compact: false))

                                Button("Open Facebook Folder") {
                                    model.openFacebookRoot()
                                }
                                .buttonStyle(SoraninSecondaryButtonStyle(compact: false))

                                Button("Open Latest Package") {
                                    model.openLatestPackage()
                                }
                                .buttonStyle(SoraninSecondaryButtonStyle(compact: false))

                                Button("Refresh") {
                                    model.refreshMetadata()
                                }
                                .buttonStyle(SoraninSecondaryButtonStyle(compact: false))

                                Button(model.isHealthCheckRunning ? "Checking..." : "Health Check") {
                                    model.runHealthCheck()
                                }
                                .buttonStyle(SoraninSecondaryButtonStyle(compact: false))
                                .disabled(model.isHealthCheckRunning)

                                Button("Copy Issue") {
                                    model.copyAppIssueReport()
                                }
                                .buttonStyle(SoraninSecondaryButtonStyle(compact: false))

                                aiChatToolbarButton
                            }

                            VStack(alignment: .leading, spacing: 10) {
                                Button("Open Sora Folder") {
                                    model.openRoot()
                                }
                                .buttonStyle(SoraninSecondaryButtonStyle(compact: false))

                                Button("Open Facebook Folder") {
                                    model.openFacebookRoot()
                                }
                                .buttonStyle(SoraninSecondaryButtonStyle(compact: false))

                                Button("Open Latest Package") {
                                    model.openLatestPackage()
                                }
                                .buttonStyle(SoraninSecondaryButtonStyle(compact: false))

                                Button("Refresh") {
                                    model.refreshMetadata()
                                }
                                .buttonStyle(SoraninSecondaryButtonStyle(compact: false))

                                Button(model.isHealthCheckRunning ? "Checking..." : "Health Check") {
                                    model.runHealthCheck()
                                }
                                .buttonStyle(SoraninSecondaryButtonStyle(compact: false))
                                .disabled(model.isHealthCheckRunning)

                                Button("Copy Issue") {
                                    model.copyAppIssueReport()
                                }
                                .buttonStyle(SoraninSecondaryButtonStyle(compact: false))

                                aiChatToolbarButton
                            }
                        }

                        EditProgressPanel(
                            isVisible: model.isBatchProgressVisible,
                            percent: model.batchProgressPercent,
                            label: model.batchProgressLabel
                        )

                        EditedPackagesPanel(
                            items: model.editedPackages,
                            isBusy: model.isBusy,
                            selectedIDs: model.selectedEditedPackageIDs,
                            onCopyTitle: { model.copyTitle($0) },
                            onCopyAllTitles: { model.copyAllTitles() },
                            onToggleSelection: { model.toggleEditedPackageSelection($0) },
                            onShowDetails: { detailItem = $0 },
                            onOpenPackage: { model.openPackage($0) },
                            onOpenProfiles: {
                                model.refreshChromeProfiles()
                                profilePickerItem = $0
                            },
                            onDeletePackage: { model.deletePackage($0) },
                            onDeleteSelected: { model.deleteSelectedPackages() },
                            onClearSelection: { model.clearEditedPackageSelection() },
                            onDeleteAll: { model.deleteAllPackages() }
                        )
                        .onReceive(NotificationCenter.default.publisher(for: .soraninSelectAllEditedPackages)) { _ in
                            model.selectAllEditedPackages()
                        }

                        Text(model.detail)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(SoraninPalette.secondaryText)
                            .textSelection(.enabled)

                        Text(model.logText)
                            .font(.system(size: 13, weight: .regular, design: .monospaced))
                            .foregroundStyle(Color(red: 0.97, green: 0.95, blue: 0.92))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(SoraninPalette.cardStrong)
                            )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
                    .background(
                        LinearGradient(colors: [SoraninPalette.bgTop, SoraninPalette.bgBottom], startPoint: .top, endPoint: .bottom)
                    )
                    .sheet(isPresented: $showingSettings) {
                        APISettingsSheet(
                            currentProvider: model.activeProvider,
                            openAIStatus: model.openAIKeyStatus,
                            geminiStatus: model.geminiKeyStatus
                        ) { openAIKey, geminiKey, provider in
                            model.saveSettings(openAIKey: openAIKey, geminiKey: geminiKey, provider: provider)
                        } onRemove: { removeOpenAI, removeGemini, provider in
                            model.removeSavedSettings(removeOpenAI: removeOpenAI, removeGemini: removeGemini, provider: provider)
                        } onTest: { provider, completion in
                            model.testSavedAIProvider(provider, completion: completion)
                        }
                    }
                    .sheet(isPresented: $showingChromeProfiles) {
                        ChromeProfilesSheet(model: model)
                    }
                    .sheet(isPresented: $showingFacebookRunner) {
                        FacebookRunnerSheet(
                            model: model,
                            selectedProfileDirectoryName: $facebookRunnerProfileDirectoryName,
                            pageName: $facebookRunnerPageName,
                            packageNamesText: $facebookRunnerPackageNamesText,
                            intervalMinutes: $facebookRunnerIntervalMinutes,
                            closeAfterEach: $facebookRunnerCloseAfterEach,
                            closeAfterFinish: $facebookRunnerCloseAfterFinish,
                            postNowAdvanceSlot: $facebookRunnerPostNowAdvanceSlot,
                            openChromeFirst: $facebookRunnerOpenChromeFirst,
                            deleteFoldersAfterSuccess: $facebookRunnerDeleteFoldersAfterSuccess
                        )
                    }
                    .sheet(isPresented: $showingHealthStatus) {
                        HealthStatusSheet(model: model)
                    }
                    .sheet(item: $detailItem) { item in
                        EditedPackageDetailSheet(item: item) {
                            model.copyTitle(item)
                        }
                    }
                    .sheet(item: $profilePickerItem) { item in
                        ChromeProfilePickerSheet(
                            packageName: item.packageName,
                            items: model.chromeProfiles,
                            currentDirectoryName: item.assignedProfileDirectoryName,
                            onRefresh: { model.refreshChromeProfiles() },
                            onAssign: { model.assignChromeProfile($0, to: item) },
                            onClear: { model.clearAssignedChromeProfile(for: item) }
                        )
                    }
                    .onReceive(timer) { _ in
                        model.refreshMetadata()
                        model.refreshFacebookControlServerConnectionInfo()
                    }
                    .onChange(of: model.soraInput) { _ in
                        model.normalizeSoraInputAfterEdit()
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .soraninDismissTransientUI)) { _ in
                        showingSettings = false
                        showingChromeProfiles = false
                        showingFacebookRunner = false
                        showingHealthStatus = false
                        model.setAIChatVisibility(false)
                        showingAIChat = false
                        detailItem = nil
                        profilePickerItem = nil
                    }
                }
                .allowsHitTesting(!showingAIChat)
                .blur(radius: showingAIChat ? 2 : 0)
                .background(
                    LinearGradient(colors: [SoraninPalette.bgTop, SoraninPalette.bgBottom], startPoint: .top, endPoint: .bottom)
                )

                if showingAIChat {
                    Color.black.opacity(0.45)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .zIndex(10)

                    AIChatSheet(model: model) {
                        model.setAIChatVisibility(false)
                        showingAIChat = false
                    }
                    .frame(
                        width: min(max(proxy.size.width - 48, 760), 1220),
                        height: min(max(proxy.size.height - 48, 620), 920)
                    )
                    .shadow(color: Color.black.opacity(0.34), radius: 24, y: 12)
                    .padding(24)
                    .zIndex(11)
                }

                if let message = model.toastMessage {
                    ToastView(message: message)
                        .padding(20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .zIndex(20)
                }
            }
        }
        .frame(minWidth: 820, minHeight: 620)
        .preferredColorScheme(.dark)
        .onAppear {
            model.setAIChatVisibility(false)
            model.ensureFacebookControlServerRunning()
            model.refreshFacebookControlServerConnectionInfo()
            model.scheduleAutoHealthCheckIfNeeded()
        }
    }
}

@MainActor
private final class SoraninAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var didPrepareForTermination = false
    private weak var mainWindow: NSWindow?
    private var mainWindowObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        mainWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, let window = note.object as? NSWindow, window.attachedSheet == nil else { return }
            Task { @MainActor in
                self.mainWindow = window
                window.delegate = self
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender == mainWindow {
            if soraninQuitInProgress {
                return true
            }
            requestSoraninAppQuit()
            return false
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        soraninQuitInProgress = true
        prepareForTermination(sender)
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let sender = notification.object as? NSApplication {
            prepareForTermination(sender)
        }
    }

    private func prepareForTermination(_ sender: NSApplication) {
        guard !didPrepareForTermination else { return }
        didPrepareForTermination = true
        NotificationCenter.default.post(name: .soraninDismissTransientUI, object: nil)
        sender.abortModal()
        for window in sender.windows {
            if let sheet = window.attachedSheet {
                window.endSheet(sheet)
                sheet.orderOut(nil)
            }
        }
        activeReelsModelForAppLifecycle?.prepareForTermination()
    }
}

@main
struct SoraninApp: App {
    @NSApplicationDelegateAdaptor(SoraninAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Soranin") {
            ContentView()
                .preferredColorScheme(.dark)
        }
        .commands {
            CommandMenu("Selection") {
                Button("Select All Videos") {
                    NotificationCenter.default.post(name: .soraninSelectAllEditedPackages, object: nil)
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            }
        }
    }
}
