import AVFoundation
import Foundation
import UniformTypeIdentifiers

enum GoogleAIVideoThumbnailGeneratorError: LocalizedError {
    case missingAPIKey
    case unreadableVideo
    case invalidResponse
    case emptyOutput
    case invalidJSON
    case missingUploadURL
    case missingUploadedFile
    case fileProcessingFailed(String?)
    case fileProcessingTimedOut
    case missingFileURI
    case httpStatus(Int, String?)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add your Google AI Studio API key first."
        case .unreadableVideo:
            return "soranin could not read the exported video for Google AI thumbnails."
        case .invalidResponse:
            return "Google AI Studio returned a response soranin could not read."
        case .emptyOutput:
            return "Google AI Studio did not return a thumbnail suggestion."
        case .invalidJSON:
            return "Google AI Studio returned thumbnail text soranin could not decode."
        case .missingUploadURL:
            return "Google AI Studio did not return an upload URL."
        case .missingUploadedFile:
            return "Google AI Studio did not return uploaded file details."
        case .fileProcessingFailed(let message):
            if let message, !message.isEmpty {
                return "Google AI Studio could not process the video: \(message)"
            }
            return "Google AI Studio could not process the video."
        case .fileProcessingTimedOut:
            return "Google AI Studio is taking too long to process the video. Try again."
        case .missingFileURI:
            return "Google AI Studio did not return a usable video URI."
        case .httpStatus(let statusCode, let message):
            if let message, !message.isEmpty {
                return "Google AI Studio error \(statusCode): \(message)"
            }
            return "Google AI Studio error \(statusCode)."
        }
    }
}

struct VideoThumbnailSuggestion: Equatable {
    let timestampSeconds: Double
    let headline: String
    let reason: String
}

private struct GoogleAIThumbnailGenerateResponse: Decodable {
    struct Candidate: Decodable {
        struct Content: Decodable {
            struct Part: Decodable {
                let text: String?
            }

            let parts: [Part]?
        }

        let content: Content?
    }

    struct APIErrorEnvelope: Decodable {
        struct APIError: Decodable {
            let message: String?
        }

        let error: APIError?
    }

    let candidates: [Candidate]?
}

private struct GoogleAIThumbnailUploadedFile: Decodable {
    let name: String
    let uri: String?
    let mimeType: String?
    let state: String?
}

private struct GoogleAIThumbnailUploadedFileEnvelope: Decodable {
    let file: GoogleAIThumbnailUploadedFile?
}

private struct GoogleAIThumbnailSuggestionEnvelope: Decodable {
    let timestamp_seconds: Double
    let headline: String?
    let reason: String?
}

enum GoogleAIVideoThumbnailGenerator {
    private static let uploadEndpoint = URL(string: "https://generativelanguage.googleapis.com/upload/v1beta/files")!

    static func suggestThumbnail(
        for videoURL: URL,
        apiKey: String,
        modelName: String,
        appLanguage: AppLanguage,
        previousSuggestion: VideoThumbnailSuggestion? = nil,
        variationIndex: Int = 0
    ) async throws -> VideoThumbnailSuggestion {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw GoogleAIVideoThumbnailGeneratorError.missingAPIKey
        }

        let uploadedFile = try await uploadVideo(videoURL, apiKey: trimmedKey)
        defer {
            let fileName = uploadedFile.name
            Task.detached(priority: .utility) {
                try? await deleteUploadedFile(named: fileName, apiKey: trimmedKey)
            }
        }

        let activeFile = try await waitUntilVideoFileIsReady(
            named: uploadedFile.name,
            initialFile: uploadedFile,
            apiKey: trimmedKey
        )

        let fileURI = activeFile.uri ?? uploadedFile.uri
        let mimeType = activeFile.mimeType ?? uploadedFile.mimeType ?? mimeType(for: videoURL)
        guard let fileURI, !fileURI.isEmpty else {
            throw GoogleAIVideoThumbnailGeneratorError.missingFileURI
        }

        let prompt = prompt(
            for: videoURL,
            appLanguage: appLanguage,
            previousSuggestion: previousSuggestion,
            variationIndex: variationIndex
        )
        let body: [String: Any] = [
            "contents": [
                [
                    "role": "user",
                    "parts": [
                        ["text": prompt],
                        [
                            "file_data": [
                                "mime_type": mimeType,
                                "file_uri": fileURI
                            ]
                        ]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0.75,
                "maxOutputTokens": 512,
                "responseMimeType": "application/json"
            ]
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body, options: [])
        guard let encodedModelName = modelName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let generateEndpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(encodedModelName):generateContent") else {
            throw GoogleAIVideoThumbnailGeneratorError.invalidResponse
        }

        var components = URLComponents(url: generateEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "key", value: trimmedKey)
        ]

        guard let url = components?.url else {
            throw GoogleAIVideoThumbnailGeneratorError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 240
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GoogleAIVideoThumbnailGeneratorError.invalidResponse
        }

        if !(200...299).contains(httpResponse.statusCode) {
            let apiError = try? JSONDecoder().decode(GoogleAIThumbnailGenerateResponse.APIErrorEnvelope.self, from: data)
            throw GoogleAIVideoThumbnailGeneratorError.httpStatus(
                httpResponse.statusCode,
                apiError?.error?.message
            )
        }

        let envelope = try JSONDecoder().decode(GoogleAIThumbnailGenerateResponse.self, from: data)
        let outputText = envelope.candidates?
            .flatMap { $0.content?.parts ?? [] }
            .compactMap(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let outputText, !outputText.isEmpty else {
            throw GoogleAIVideoThumbnailGeneratorError.emptyOutput
        }

        let asset = AVURLAsset(url: videoURL)
        let durationSeconds = max(CMTimeGetSeconds(asset.duration), 0)
        let suggestion = decodeSuggestion(from: outputText)
        let fallback = fallbackSuggestion(from: outputText, durationSeconds: durationSeconds, appLanguage: appLanguage)

        guard let finalSuggestion = suggestion ?? fallback else {
            throw GoogleAIVideoThumbnailGeneratorError.invalidJSON
        }

        let clampedTimestamp = min(max(finalSuggestion.timestamp_seconds, 0), max(durationSeconds, 0))
        let headline = finalSuggestion.headline?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let reason = finalSuggestion.reason?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return VideoThumbnailSuggestion(
            timestampSeconds: clampedTimestamp,
            headline: headline,
            reason: reason.isEmpty
                ? defaultReason(for: appLanguage)
                : reason
        )
    }

    private static func prompt(
        for videoURL: URL,
        appLanguage: AppLanguage,
        previousSuggestion: VideoThumbnailSuggestion?,
        variationIndex: Int
    ) -> String {
        let asset = AVURLAsset(url: videoURL)
        let durationSeconds = max(CMTimeGetSeconds(asset.duration), 0)
        let fileNameHint = cleanedVideoName(from: videoURL)
        let languageInstruction = appLanguage == .khmer
            ? "Write the headline and reason in natural Khmer."
            : "Write the headline and reason in natural English."

        var variationInstruction = ""
        if let previousSuggestion {
            variationInstruction = """

            Previous thumbnail choice:
            - timestamp_seconds: \(String(format: "%.2f", previousSuggestion.timestampSeconds))
            - headline: \(previousSuggestion.headline)
            - reason: \(previousSuggestion.reason)

            Do not repeat that same moment. Choose a clearly different strong moment for variation \(variationIndex + 1).
            """
        }

        return """
        Watch the whole uploaded video from start to finish and understand the real meaning of the video before choosing a thumbnail.

        Use:
        - full motion and action across the whole video
        - emotional peaks
        - sound, spoken words, music mood, or important audio cues if they are clearly present
        - the most attention-grabbing moment that real people would be most likely to click

        Stay truthful to the real video. Do not invent objects, actions, people, or events that are not really visible or clearly implied by the real video and sound.
        If helpful, you may suggest a very short headline overlay, but keep it natural, believable, and not fake.
        \(languageInstruction)

        The source video name is only a hint if helpful: \(fileNameHint)
        Video duration: \(playbackTimestamp(durationSeconds)).
        \(variationInstruction)

        Return JSON only. No markdown. No extra text.

        {
          "timestamp_seconds": 0.0,
          "headline": "short optional headline",
          "reason": "why this moment is the strongest thumbnail and why people would want to tap it"
        }

        Rules:
        - timestamp_seconds must be inside the real video duration.
        - headline should be 0 to 5 words only.
        - headline must not include hashtags.
        - Choose the strongest real moment, not a random frame.
        """
    }

    private static func decodeSuggestion(from rawText: String) -> GoogleAIThumbnailSuggestionEnvelope? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let envelope = try? JSONDecoder().decode(GoogleAIThumbnailSuggestionEnvelope.self, from: data) {
            return envelope
        }

        guard let jsonString = extractJSONString(from: trimmed),
              let data = jsonString.data(using: .utf8) else {
            return decodeLooseSuggestion(from: trimmed)
        }

        if let envelope = try? JSONDecoder().decode(GoogleAIThumbnailSuggestionEnvelope.self, from: data) {
            return envelope
        }

        return decodeLooseSuggestion(from: jsonString)
    }

    private static func extractJSONString(from rawText: String) -> String? {
        if let fencedRange = rawText.range(
            of: #"```(?:json)?\s*(\{[\s\S]*\}|\[[\s\S]*\])\s*```"#,
            options: .regularExpression
        ) {
            let fenced = String(rawText[fencedRange])
            let cleaned = fenced
                .replacingOccurrences(of: #"^```(?:json)?\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s*```$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                return cleaned
            }
        }

        if let start = rawText.firstIndex(of: "{"),
           let end = rawText.lastIndex(of: "}") {
            return String(rawText[start...end])
        }

        if let start = rawText.firstIndex(of: "["),
           let end = rawText.lastIndex(of: "]") {
            return String(rawText[start...end])
        }

        return nil
    }

    private static func decodeLooseSuggestion(from rawText: String) -> GoogleAIThumbnailSuggestionEnvelope? {
        guard let data = rawText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return decodeSuggestionFromPlainText(rawText)
        }

        if let dictionary = object as? [String: Any],
           let envelope = normalizeSuggestion(from: dictionary) {
            return envelope
        }

        if let array = object as? [[String: Any]] {
            for item in array {
                if let envelope = normalizeSuggestion(from: item) {
                    return envelope
                }
            }
        }

        return decodeSuggestionFromPlainText(rawText)
    }

    private static func normalizeSuggestion(from dictionary: [String: Any]) -> GoogleAIThumbnailSuggestionEnvelope? {
        let timestampCandidates = [
            "timestamp_seconds",
            "timestampSeconds",
            "timestamp",
            "time_seconds",
            "timeSeconds",
            "seconds",
            "second",
            "best_timestamp_seconds",
            "bestTimestampSeconds",
            "chosen_timestamp_seconds",
            "chosenTimestampSeconds",
            "best_frame_timestamp",
            "bestFrameTimestamp",
            "best_frame_time",
            "bestFrameTime",
            "frame_timestamp",
            "frameTimestamp",
            "selected_timestamp",
            "selectedTimestamp",
            "selected_time",
            "selectedTime",
            "best_time",
            "bestTime",
            "thumbnail_timestamp",
            "thumbnailTimestamp",
            "thumbnail_time",
            "thumbnailTime",
            "timecode"
        ]

        let headlineCandidates = [
            "headline",
            "title",
            "caption",
            "hook",
            "overlay",
            "overlay_text",
            "overlayText",
            "thumbnail_headline",
            "thumbnailHeadline",
            "thumbnail_title",
            "thumbnailTitle",
            "short_title",
            "shortTitle",
            "label"
        ]

        let reasonCandidates = [
            "reason",
            "why",
            "explanation",
            "justification",
            "analysis",
            "thought",
            "rationale",
            "summary",
            "notes",
            "thumbnail_reason",
            "thumbnailReason",
            "explain"
        ]

        var timestamp: Double?
        for key in timestampCandidates {
            if let parsed = parseTimestamp(from: dictionary[key]) {
                timestamp = parsed
                break
            }
        }

        if timestamp == nil {
            let nestedTimestampSources = [
                "thumbnail",
                "suggestion",
                "best_frame",
                "bestFrame",
                "best_moment",
                "bestMoment",
                "selected_frame",
                "selectedFrame",
                "selected_moment",
                "selectedMoment",
                "thumbnail_choice",
                "thumbnailChoice",
                "moment"
            ]

            for key in nestedTimestampSources {
                if let parsed = parseTimestamp(from: dictionary[key]) {
                    timestamp = parsed
                    break
                }
            }
        }

        if timestamp == nil {
            timestamp = nestedSuggestion(in: dictionary)
        }

        guard let timestamp else {
            return nil
        }

        let headline = headlineCandidates
            .compactMap { parseString(from: dictionary[$0]) }
            .first
            ?? parseString(from: dictionary["thumbnail"])
            ?? parseString(from: dictionary["suggestion"])
            ?? nestedText(in: dictionary, keys: headlineCandidates)

        let reason = reasonCandidates
            .compactMap { parseString(from: dictionary[$0]) }
            .first
            ?? parseString(from: dictionary["thumbnail"])
            ?? parseString(from: dictionary["suggestion"])
            ?? nestedText(in: dictionary, keys: reasonCandidates)

        return GoogleAIThumbnailSuggestionEnvelope(
            timestamp_seconds: timestamp,
            headline: headline,
            reason: reason
        )
    }

    private static func parseTimestamp(from value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if let doubleValue = Double(trimmed) {
                return doubleValue
            }
            return parseTimecode(trimmed) ?? extractTimestampFromRawText(trimmed)
        case let dictionary as [String: Any]:
            for key in [
                "timestamp_seconds",
                "timestampSeconds",
                "seconds",
                "time",
                "timestamp",
                "timecode",
                "selected_time",
                "selectedTime",
                "best_time",
                "bestTime",
                "frame_timestamp",
                "frameTimestamp",
                "start_time",
                "startTime",
                "value"
            ] {
                if let nested = parseTimestamp(from: dictionary[key]) {
                    return nested
                }
            }
            for nested in dictionary.values {
                if let nested = parseTimestamp(from: nested) {
                    return nested
                }
            }
            return nil
        case let array as [Any]:
            for item in array {
                if let nested = parseTimestamp(from: item) {
                    return nested
                }
            }
            return nil
        default:
            return nil
        }
    }

    private static func parseString(from value: Any?) -> String? {
        switch value {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let number as NSNumber:
            return number.stringValue
        case let dictionary as [String: Any]:
            for key in [
                "text",
                "value",
                "content",
                "headline",
                "title",
                "caption",
                "reason",
                "why",
                "explanation",
                "summary",
                "description",
                "label"
            ] {
                if let nested = parseString(from: dictionary[key]) {
                    return nested
                }
            }
            return nil
        case let array as [Any]:
            let strings = array.compactMap { parseString(from: $0) }
            guard !strings.isEmpty else { return nil }
            return strings.joined(separator: " ")
        default:
            return nil
        }
    }

    private static func parseTimecode(_ value: String) -> Double? {
        let sanitized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"(?i)\bseconds?\b"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\bsecs?\b"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\bs\b"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = sanitized.split(separator: ":").map { String($0) }
        guard pieces.count >= 2 && pieces.count <= 3 else { return nil }

        let numbers = pieces.compactMap { Double($0) }
        guard numbers.count == pieces.count else { return nil }

        if numbers.count == 2 {
            return numbers[0] * 60 + numbers[1]
        }

        return numbers[0] * 3600 + numbers[1] * 60 + numbers[2]
    }

    private static func decodeSuggestionFromPlainText(_ rawText: String) -> GoogleAIThumbnailSuggestionEnvelope? {
        let timestamp = extractTimestampFromRawText(rawText)

        guard let timestamp else { return nil }

        let headline = extractLabeledValue(
            in: rawText,
            labels: ["headline", "title", "caption", "hook", "overlay", "thumbnail title"]
        )
        let reason = extractLabeledValue(
            in: rawText,
            labels: ["reason", "why", "explanation", "analysis", "justification", "summary"]
        ) ?? bestReasonFallback(from: rawText)

        return GoogleAIThumbnailSuggestionEnvelope(
            timestamp_seconds: timestamp,
            headline: headline,
            reason: reason
        )
    }

    private static func fallbackSuggestion(
        from rawText: String,
        durationSeconds: Double,
        appLanguage: AppLanguage
    ) -> GoogleAIThumbnailSuggestionEnvelope? {
        let cleaned = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        let timestamp = extractTimestampFromRawText(cleaned)
            ?? inferFallbackTimestamp(for: durationSeconds)

        let headline = extractLabeledValue(
            in: cleaned,
            labels: ["headline", "title", "caption", "hook", "overlay", "thumbnail title"]
        )
        let reason = extractLabeledValue(
            in: cleaned,
            labels: ["reason", "why", "explanation", "analysis", "justification", "summary"]
        ) ?? bestReasonFallback(from: cleaned)
            ?? defaultReason(for: appLanguage)

        return GoogleAIThumbnailSuggestionEnvelope(
            timestamp_seconds: timestamp,
            headline: headline,
            reason: reason
        )
    }

    private static func inferFallbackTimestamp(for durationSeconds: Double) -> Double {
        guard durationSeconds > 0 else { return 0 }
        let preferred = durationSeconds * 0.35
        return min(max(preferred, 0), durationSeconds)
    }

    private static func nestedSuggestion(in dictionary: [String: Any]) -> Double? {
        for key in [
            "thumbnail",
            "suggestion",
            "best_frame",
            "bestFrame",
            "best_moment",
            "bestMoment",
            "selected_frame",
            "selectedFrame",
            "selected_moment",
            "selectedMoment",
            "thumbnail_choice",
            "thumbnailChoice",
            "moment",
            "frame",
            "selection",
            "choice"
        ] {
            if let nested = parseTimestamp(from: dictionary[key]) {
                return nested
            }
        }

        for value in dictionary.values {
            if let nested = parseTimestamp(from: value) {
                return nested
            }
        }

        return nil
    }

    private static func nestedText(in dictionary: [String: Any], keys: [String]) -> String? {
        for key in [
            "thumbnail",
            "suggestion",
            "best_frame",
            "bestFrame",
            "best_moment",
            "bestMoment",
            "selected_frame",
            "selectedFrame",
            "selected_moment",
            "selectedMoment",
            "thumbnail_choice",
            "thumbnailChoice",
            "moment",
            "frame",
            "selection",
            "choice"
        ] {
            if let nestedDictionary = dictionary[key] as? [String: Any] {
                if let value = keys.compactMap({ parseString(from: nestedDictionary[$0]) }).first {
                    return value
                }
                if let value = nestedText(in: nestedDictionary, keys: keys) {
                    return value
                }
            }

            if let nestedArray = dictionary[key] as? [Any] {
                for item in nestedArray {
                    if let nestedDictionary = item as? [String: Any] {
                        if let value = keys.compactMap({ parseString(from: nestedDictionary[$0]) }).first {
                            return value
                        }
                        if let value = nestedText(in: nestedDictionary, keys: keys) {
                            return value
                        }
                    }
                }
            }
        }

        return nil
    }

    private static func extractTimestampFromRawText(_ rawText: String) -> Double? {
        let patterns = [
            #"timestamp_seconds"\s*[:=]\s*([0-9]+(?:\.[0-9]+)?)"#,
            #"timestampSeconds"\s*[:=]\s*([0-9]+(?:\.[0-9]+)?)"#,
            #"timestamp"\s*[:=]\s*([0-9]+(?:\.[0-9]+)?)"#,
            #"timecode"\s*[:=]\s*"([0-9]{1,2}:[0-9]{2}(?::[0-9]{2})?(?:\.[0-9]+)?)""#,
            #"timecode"\s*[:=]\s*([0-9]{1,2}:[0-9]{2}(?::[0-9]{2})?(?:\.[0-9]+)?)"#,
            #"best\s+(?:frame|moment).{0,20}?([0-9]{1,2}:[0-9]{2}(?::[0-9]{2})?(?:\.[0-9]+)?)"#,
            #"selected\s+(?:frame|moment).{0,20}?([0-9]{1,2}:[0-9]{2}(?::[0-9]{2})?(?:\.[0-9]+)?)"#,
            #"at\s+([0-9]{1,2}:[0-9]{2}(?::[0-9]{2})?(?:\.[0-9]+)?)"#,
            #"([0-9]+(?:\.[0-9]+)?)\s*(?:seconds?|secs?|s)\b"#,
            #"frame\s*(?:at|time)?\s*[:=-]?\s*([0-9]+(?:\.[0-9]+)?)"#,
            #"moment\s*(?:at|time)?\s*[:=-]?\s*([0-9]+(?:\.[0-9]+)?)"#
        ]

        for pattern in patterns {
            if let match = firstCapture(in: rawText, pattern: pattern) {
                if let timestamp = Double(match) ?? parseTimecode(match) {
                    return timestamp
                }
            }
        }

        return nil
    }

    private static func extractLabeledValue(in rawText: String, labels: [String]) -> String? {
        for label in labels {
            let escaped = NSRegularExpression.escapedPattern(for: label)
            let patterns = [
                #"(?im)^\s*"# + escaped + #"\s*[:=-]\s*"([^"]+)""#,
                #"(?im)^\s*"# + escaped + #"\s*[:=-]\s*'([^']+)'"#,
                #"(?im)^\s*"# + escaped + #"\s*[:=-]\s*(.+)$"#
            ]

            for pattern in patterns {
                if let match = firstCapture(in: rawText, pattern: pattern) {
                    let cleaned = sanitizePlainTextValue(match)
                    if !cleaned.isEmpty {
                        return cleaned
                    }
                }
            }
        }

        return nil
    }

    private static func bestReasonFallback(from rawText: String) -> String? {
        let lines = rawText
            .components(separatedBy: .newlines)
            .map { sanitizePlainTextValue($0) }
            .filter { !$0.isEmpty }

        for line in lines {
            let lower = line.lowercased()
            if lower.contains("reason") || lower.contains("explanation") || lower.contains("because") || lower.contains("attention") {
                return line
            }
        }

        return lines.first { line in
            extractTimestampFromRawText(line) == nil &&
            line.count > 18
        }
    }

    private static func sanitizePlainTextValue(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^[\-•\*\d\.\)\s]+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'` ").union(.whitespacesAndNewlines))
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text) else {
            return nil
        }

        return String(text[captureRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func defaultReason(for appLanguage: AppLanguage) -> String {
        switch appLanguage {
        case .english:
            return "Gemini picked the strongest real moment from the full video."
        case .khmer:
            return "Gemini បានរើសពេលដែលខ្លាំងបំផុតពីវីដេអូពេញ។"
        }
    }

    private static func uploadVideo(
        _ videoURL: URL,
        apiKey: String
    ) async throws -> GoogleAIThumbnailUploadedFile {
        guard let videoData = try? Data(contentsOf: videoURL), !videoData.isEmpty else {
            throw GoogleAIVideoThumbnailGeneratorError.unreadableVideo
        }

        let mimeType = mimeType(for: videoURL)
        let fileSize = videoData.count
        let displayName = cleanedVideoName(from: videoURL)

        var components = URLComponents(url: uploadEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "key", value: apiKey)
        ]

        guard let startURL = components?.url else {
            throw GoogleAIVideoThumbnailGeneratorError.invalidResponse
        }

        let metadataBody = try JSONSerialization.data(
            withJSONObject: [
                "file": [
                    "display_name": displayName
                ]
            ],
            options: []
        )

        var startRequest = URLRequest(url: startURL)
        startRequest.httpMethod = "POST"
        startRequest.timeoutInterval = 60
        startRequest.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        startRequest.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        startRequest.setValue(String(fileSize), forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        startRequest.setValue(mimeType, forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        startRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        startRequest.httpBody = metadataBody

        let (startData, startResponse) = try await URLSession.shared.data(for: startRequest)
        guard let startHTTPResponse = startResponse as? HTTPURLResponse else {
            throw GoogleAIVideoThumbnailGeneratorError.invalidResponse
        }

        if !(200...299).contains(startHTTPResponse.statusCode) {
            let apiError = try? JSONDecoder().decode(GoogleAIThumbnailGenerateResponse.APIErrorEnvelope.self, from: startData)
            throw GoogleAIVideoThumbnailGeneratorError.httpStatus(
                startHTTPResponse.statusCode,
                apiError?.error?.message
            )
        }

        guard let uploadURLString = startHTTPResponse.value(forHTTPHeaderField: "X-Goog-Upload-URL"),
              let uploadURL = URL(string: uploadURLString) else {
            throw GoogleAIVideoThumbnailGeneratorError.missingUploadURL
        }

        var uploadRequest = URLRequest(url: uploadURL)
        uploadRequest.httpMethod = "POST"
        uploadRequest.timeoutInterval = 300
        uploadRequest.setValue(String(fileSize), forHTTPHeaderField: "Content-Length")
        uploadRequest.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        uploadRequest.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        uploadRequest.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        uploadRequest.httpBody = videoData

        let (uploadData, uploadResponse) = try await URLSession.shared.data(for: uploadRequest)
        guard let uploadHTTPResponse = uploadResponse as? HTTPURLResponse else {
            throw GoogleAIVideoThumbnailGeneratorError.invalidResponse
        }

        if !(200...299).contains(uploadHTTPResponse.statusCode) {
            let apiError = try? JSONDecoder().decode(GoogleAIThumbnailGenerateResponse.APIErrorEnvelope.self, from: uploadData)
            throw GoogleAIVideoThumbnailGeneratorError.httpStatus(
                uploadHTTPResponse.statusCode,
                apiError?.error?.message
            )
        }

        let uploadedFile = try JSONDecoder().decode(GoogleAIThumbnailUploadedFileEnvelope.self, from: uploadData).file
        guard let uploadedFile else {
            throw GoogleAIVideoThumbnailGeneratorError.missingUploadedFile
        }

        return uploadedFile
    }

    private static func waitUntilVideoFileIsReady(
        named fileName: String,
        initialFile: GoogleAIThumbnailUploadedFile,
        apiKey: String
    ) async throws -> GoogleAIThumbnailUploadedFile {
        let initialState = initialFile.state?.uppercased() ?? "ACTIVE"
        if initialState == "ACTIVE" {
            return initialFile
        }

        if initialState == "FAILED" {
            throw GoogleAIVideoThumbnailGeneratorError.fileProcessingFailed(nil)
        }

        for _ in 0..<45 {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            let file = try await fetchUploadedFile(named: fileName, apiKey: apiKey)
            let state = file.state?.uppercased() ?? "ACTIVE"

            if state == "ACTIVE" {
                return file
            }

            if state == "FAILED" {
                throw GoogleAIVideoThumbnailGeneratorError.fileProcessingFailed(file.state)
            }
        }

        throw GoogleAIVideoThumbnailGeneratorError.fileProcessingTimedOut
    }

    private static func fetchUploadedFile(
        named fileName: String,
        apiKey: String
    ) async throws -> GoogleAIThumbnailUploadedFile {
        guard var components = URLComponents(
            string: "https://generativelanguage.googleapis.com/v1beta/\(fileName)"
        ) else {
            throw GoogleAIVideoThumbnailGeneratorError.invalidResponse
        }

        components.queryItems = [
            URLQueryItem(name: "key", value: apiKey)
        ]

        guard let url = components.url else {
            throw GoogleAIVideoThumbnailGeneratorError.invalidResponse
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GoogleAIVideoThumbnailGeneratorError.invalidResponse
        }

        if !(200...299).contains(httpResponse.statusCode) {
            let apiError = try? JSONDecoder().decode(GoogleAIThumbnailGenerateResponse.APIErrorEnvelope.self, from: data)
            throw GoogleAIVideoThumbnailGeneratorError.httpStatus(
                httpResponse.statusCode,
                apiError?.error?.message
            )
        }

        return try JSONDecoder().decode(GoogleAIThumbnailUploadedFile.self, from: data)
    }

    private static func deleteUploadedFile(named fileName: String, apiKey: String) async throws {
        guard var components = URLComponents(
            string: "https://generativelanguage.googleapis.com/v1beta/\(fileName)"
        ) else {
            return
        }

        components.queryItems = [
            URLQueryItem(name: "key", value: apiKey)
        ]

        guard let url = components.url else {
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        _ = try? await URLSession.shared.data(for: request)
    }

    private static func cleanedVideoName(from videoURL: URL) -> String {
        let rawName = videoURL.deletingPathExtension().lastPathComponent
        let replaced = rawName.replacingOccurrences(
            of: #"[_\-.]+"#,
            with: " ",
            options: .regularExpression
        )
        let squashed = replaced.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        return squashed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func mimeType(for videoURL: URL) -> String {
        if let resourceValues = try? videoURL.resourceValues(forKeys: [.contentTypeKey]),
           let contentType = resourceValues.contentType,
           let mimeType = contentType.preferredMIMEType {
            return mimeType
        }

        if let type = UTType(filenameExtension: videoURL.pathExtension),
           let mimeType = type.preferredMIMEType {
            return mimeType
        }

        return "video/mp4"
    }

    private static func playbackTimestamp(_ seconds: Double) -> String {
        let totalSeconds = max(Int(seconds.rounded(.down)), 0)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }

        return String(format: "%02d:%02d", minutes, secs)
    }
}
