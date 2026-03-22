import AVFoundation
import Foundation
import Photos
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct EditorClip: Identifiable, Equatable {
    let id: UUID
    let fileURL: URL
    let title: String
    let duration: Double
    var settings: ReelsEditorSettings

    init(
        id: UUID = UUID(),
        fileURL: URL,
        title: String,
        duration: Double,
        settings: ReelsEditorSettings = ReelsEditorSettings()
    ) {
        self.id = id
        self.fileURL = fileURL
        self.title = title
        self.duration = duration
        self.settings = settings
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case english
    case khmer

    var id: String { rawValue }
}

enum AIProvider: String, CaseIterable, Identifiable {
    case googleGemini
    case openAI

    var id: String { rawValue }
}

enum DownloadQueueState: String {
    case queued
    case downloading
    case completed
    case failed
}

enum DownloadSourceKind: String, Codable {
    case sora
    case facebook
}

struct DownloadQueueItem: Identifiable, Equatable {
    let id: String
    let videoID: String
    let sourceInput: String
    let sourceKind: DownloadSourceKind
    var progress: Double
    var state: DownloadQueueState
    var errorMessage: String?

    init(
        videoID: String,
        sourceInput: String? = nil,
        sourceKind: DownloadSourceKind = .sora,
        progress: Double = 0,
        state: DownloadQueueState = .queued,
        errorMessage: String? = nil
    ) {
        self.id = "\(sourceKind.rawValue):\(videoID.lowercased())"
        self.videoID = videoID
        self.sourceKind = sourceKind
        self.sourceInput = sourceInput?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? sourceInput!.trimmingCharacters(in: .whitespacesAndNewlines)
            : videoID
        self.progress = progress
        self.state = state
        self.errorMessage = errorMessage
    }

    var percentText: String {
        "\(Int((progress * 100).rounded()))%"
    }

    var displayTitle: String {
        switch sourceKind {
        case .sora:
            return videoID
        case .facebook:
            let suffix = videoID
                .replacingOccurrences(of: "facebook_", with: "")
                .replacingOccurrences(of: "_", with: " ")
            return suffix.isEmpty ? "Facebook video" : "Facebook \(suffix)"
        }
    }
}

enum DownloadStatusBadgeTone {
    case accent
    case success
    case warning
    case danger
}

struct DownloadStatusBadge: Identifiable, Equatable {
    let id: String
    let label: String
    let tone: DownloadStatusBadgeTone
}

struct GeneratedHistoryEntry: Identifiable, Equatable, Codable {
    let id: UUID
    let text: String
    let sourceName: String
    let thumbnailFileName: String?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        text: String,
        sourceName: String,
        thumbnailFileName: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.text = text
        self.sourceName = sourceName
        self.thumbnailFileName = thumbnailFileName
        self.createdAt = createdAt
    }
}

private struct PersistentHistorySnapshot: Codable {
    var titles: [GeneratedHistoryEntry] = []
    var trashedTitles: [GeneratedHistoryEntry] = []
    var prompts: [GeneratedHistoryEntry] = []
    var trashedPrompts: [GeneratedHistoryEntry] = []
}

enum AIChatPromptExtractor {
    static func wantsPromptOnly(_ text: String) -> Bool {
        let lowered = normalizedGenerationCommandText(text).lowercased()
        guard !lowered.isEmpty else { return false }

        let promptMarkers = [
            "prompt only",
            "image prompt",
            "video prompt",
            "prompt for image",
            "prompt for video",
            "copy prompt",
            "សរសេរ prompt",
            "prompt មួយ",
            "បង្កើត prompt"
        ]

        if promptMarkers.contains(where: lowered.contains) {
            return true
        }

        if lowered.contains("prompt"),
           !lowered.hasPrefix("/image"),
           !lowered.hasPrefix("/video"),
           !lowered.contains("generate the image"),
           !lowered.contains("generate the video") {
            return true
        }

        return false
    }

    static func requestedPromptCount(from text: String) -> Int {
        let source = normalizedGenerationCommandText(text)
        guard !source.isEmpty else { return 1 }

        let lowered = source.lowercased()
        if let regex = try? NSRegularExpression(pattern: #"(?i)\b(\d{1,2})\s+prompts?\b"#),
           let match = regex.firstMatch(in: lowered, range: NSRange(lowered.startIndex..., in: lowered)),
           let range = Range(match.range(at: 1), in: lowered),
           let count = Int(lowered[range]) {
            return max(1, min(count, 20))
        }

        let khmerMarkers: [(String, Int)] = [
            ("១០", 10),
            ("៩", 9),
            ("៨", 8),
            ("៧", 7),
            ("៦", 6),
            ("៥", 5),
            ("៤", 4),
            ("៣", 3),
            ("២", 2)
        ]

        for (marker, count) in khmerMarkers where source.contains(marker) && lowered.contains("prompt") {
            return count
        }

        if lowered.contains("several prompts") || lowered.contains("many prompts") {
            return 5
        }

        return 1
    }

    static func extractGenerationPrompt(from text: String) -> String? {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return nil }

        if let firstPrompt = extractPromptBlocks(from: source).first {
            return firstPrompt
        }

        let normalized = source.replacingOccurrences(
            of: #"(?is)\*\*\s*((?:image|video)?\s*prompt\s*:)\s*\*\*"#,
            with: "$1",
            options: .regularExpression
        )
        let patterns = [
            #"(?is)\*{0,2}(?:image|video)?\s*prompt\*{0,2}\s*:\s*["“](.+?)["”]"#,
            #"(?is)\*{0,2}(?:image|video)?\s*prompt\*{0,2}\s*:\s*['‘](.+?)['’]"#,
            #"(?is)\*{0,2}(?:image|video)?\s*prompt\*{0,2}\s*:\s*```(?:[\w-]+)?\s*(.+?)\s*```"#,
            #"(?is)\*{0,2}(?:image|video)?\s*prompt\*{0,2}\s*:\s*(.+)$"#
        ]

        for pattern in patterns {
            guard
                let regex = try? NSRegularExpression(pattern: pattern),
                let match = regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
                let range = Range(match.range(at: 1), in: normalized)
            else {
                continue
            }

            let prompt = normalized[range]
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’").union(.whitespacesAndNewlines))

            if !prompt.isEmpty {
                return prompt
            }
        }

        return normalized
    }

    static func extractPromptBlocks(from text: String) -> [String] {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return [] }

        let sectionBlocks = extractPromptSections(from: source)
        if !sectionBlocks.isEmpty {
            return sectionBlocks
        }

        let normalized = source.replacingOccurrences(
            of: #"(?is)\*\*\s*((?:image|video)?\s*prompt(?:\s*\d+)?\s*:)\s*\*\*"#,
            with: "$1",
            options: .regularExpression
        )

        let patterns = [
            #"(?is)\*{0,2}(?:image|video)?\s*prompt(?:\s*\d+)?\*{0,2}\s*:\s*["“](.+?)["”]"#,
            #"(?is)\*{0,2}(?:image|video)?\s*prompt(?:\s*\d+)?\*{0,2}\s*:\s*['‘](.+?)['’]"#,
            #"(?is)\*{0,2}(?:image|video)?\s*prompt(?:\s*\d+)?\*{0,2}\s*:\s*```(?:[\w-]+)?\s*(.+?)\s*```"#,
            #"(?im)^\s*(?:\d+[.)-]?\s*)?[\"“](.+?)[\"”]\s*$"#,
            #"(?im)^\s*(?:\d+[.)-]?\s*)['‘](.+?)['’]\s*$"#
        ]

        var results: [String] = []
        var seen: Set<String> = []

        for pattern in patterns {
            collectMatches(
                pattern: pattern,
                in: normalized,
                results: &results,
                seen: &seen
            )
        }

        collectMatches(
            pattern: #"(?is)```(?:plaintext|text|prompt|[\w+-]+)?\s*(.*?)\s*```"#,
            in: normalized,
            minimumLength: 12,
            results: &results,
            seen: &seen
        )

        return results
    }

    private static func extractPromptSections(from source: String) -> [String] {
        let lines = source.components(separatedBy: .newlines)
        guard !lines.isEmpty else { return [] }

        var results: [String] = []
        var seen: Set<String> = []
        var currentLines: [String] = []
        var isCollecting = false

        func finishCurrentPrompt() {
            let prompt = normalizedPrompt(
                currentLines
                    .joined(separator: "\n")
                    .replacingOccurrences(of: #"\n{2,}"#, with: "\n", options: .regularExpression)
            )
            currentLines.removeAll()
            guard prompt.count >= 12 else { return }

            let dedupeKey = prompt.lowercased()
            guard !seen.contains(dedupeKey) else { return }
            seen.insert(dedupeKey)
            results.append(prompt)
        }

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            if let headerContent = promptContentFromHeaderLine(trimmed) {
                if isCollecting {
                    finishCurrentPrompt()
                }
                isCollecting = true
                if !headerContent.isEmpty {
                    currentLines = [headerContent]
                } else {
                    currentLines = []
                }
                continue
            }

            if isCollecting, isSupplementaryPromptSectionHeader(trimmed) {
                finishCurrentPrompt()
                isCollecting = false
                continue
            }

            guard isCollecting else { continue }
            currentLines.append(rawLine)
        }

        if isCollecting {
            finishCurrentPrompt()
        }

        return results
    }

    private static func collectMatches(
        pattern: String,
        in source: String,
        minimumLength: Int = 1,
        results: inout [String],
        seen: inout Set<String>
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let nsRange = NSRange(source.startIndex..., in: source)

        for match in regex.matches(in: source, range: nsRange) {
            guard let range = Range(match.range(at: 1), in: source) else { continue }
            let prompt = normalizedPrompt(source[range])
            guard prompt.count >= minimumLength else { continue }

            let dedupeKey = prompt.lowercased()
            guard !seen.contains(dedupeKey) else { continue }
            seen.insert(dedupeKey)
            results.append(prompt)
        }
    }

    private static func normalizedPrompt<S: StringProtocol>(_ prompt: S) -> String {
        String(prompt)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’").union(.whitespacesAndNewlines))
    }

    private static func promptContentFromHeaderLine(_ line: String) -> String? {
        guard !line.isEmpty else { return nil }

        var cleaned = line
            .replacingOccurrences(of: #"^\s*#{1,6}\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^\s*[-*•]+\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^\s*\d+\s*[.)-]?\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        cleaned = cleaned.replacingOccurrences(of: "**", with: "")
        cleaned = cleaned.replacingOccurrences(of: "__", with: "")

        let patterns = [
            #"(?i)^(?:english\s+)?(?:image|video)?\s*prompt(?:\s*\(english\))?(?:\s*\d+)?\s*:\s*(.*)$"#,
            #"(?i)^prompt\s+\d+\s*:\s*(.*)$"#,
            #"(?i)^prompt\s*\(english\)\s*:\s*(.*)$"#,
            #"(?i)^prompt\s*:\s*(.*)$"#
        ]

        for pattern in patterns {
            guard
                let regex = try? NSRegularExpression(pattern: pattern),
                let match = regex.firstMatch(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)),
                let range = Range(match.range(at: 1), in: cleaned)
            else {
                continue
            }

            return normalizedPrompt(cleaned[range])
        }

        return nil
    }

    private static func isSupplementaryPromptSectionHeader(_ line: String) -> Bool {
        guard !line.isEmpty else { return false }

        let cleaned = line
            .replacingOccurrences(of: #"^\s*#{1,6}\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^\s*[-*•]+\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")

        let markers = [
            "khmer:",
            "khmer :",
            "ខ្មែរ:",
            "ខ្មែរ :",
            "explanation:",
            "note:",
            "notes:",
            "reason:",
            "meaning:"
        ]

        let lowered = cleaned.lowercased()
        return markers.contains(where: lowered.hasPrefix)
    }

    private static func normalizedGenerationCommandText(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
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
    var createdAt: Date

    init(
        id: UUID = UUID(),
        role: String,
        content: String,
        attachments: [AIChatAttachment] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.attachments = attachments
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case role
        case content
        case attachments
        case createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        role = try container.decode(String.self, forKey: .role)
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        attachments = try container.decodeIfPresent([AIChatAttachment].self, forKey: .attachments) ?? []
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

struct AIChatSession: Identifiable, Equatable, Codable {
    let id: UUID
    var createdAt: Date
    var updatedAt: Date
    var title: String
    var messages: [AIChatMessage]

    var previewText: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty, trimmedTitle != "New Chat" {
            return String(trimmedTitle.prefix(42))
        }

        if let firstUserTitle = AIChatSession.derivedTitle(from: messages) {
            return String(firstUserTitle.prefix(42))
        }

        return "New Chat"
    }

    var labelText: String {
        "\(Self.sessionFormatter.string(from: updatedAt)) • \(previewText)"
    }

    static func derivedTitle(from messages: [AIChatMessage]) -> String? {
        guard let firstUserMessage = messages.first(where: { $0.role == "user" }) else {
            return nil
        }

        let cleaned = firstUserMessage.content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

        if cleaned.isEmpty {
            return fallbackTitle(from: firstUserMessage.attachments)
        }

        return String(cleaned.prefix(60))
    }

    static func fallbackTitle(from attachments: [AIChatAttachment]) -> String? {
        guard let firstAttachment = attachments.first else { return nil }
        let baseName = firstAttachment.url.deletingPathExtension().lastPathComponent
        let cleaned = baseName
            .replacingOccurrences(of: #"[_\-.]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else { return nil }

        if attachments.count == 1 {
            return String(cleaned.prefix(60))
        }

        return String("\(cleaned) +\(attachments.count - 1)".prefix(60))
    }

    private static let sessionFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}

private struct AIChatStore: Codable {
    var currentSessionID: UUID?
    var sessions: [AIChatSession] = []
}

enum OpenAIChatServiceError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case emptyOutput
    case httpStatus(Int, String?)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add your OpenAI API key first."
        case .invalidResponse:
            return "OpenAI returned a response soranin could not read."
        case .emptyOutput:
            return "OpenAI did not return any chat reply."
        case .httpStatus(let statusCode, let message):
            if let message, !message.isEmpty {
                return "OpenAI error \(statusCode): \(message)"
            }
            return "OpenAI error \(statusCode)."
        }
    }
}

private struct OpenAIChatResponsesEnvelope: Decodable {
    struct ResponseError: Decodable {
        let message: String?
    }

    struct OutputItem: Decodable {
        let content: [ContentPart]?
    }

    struct ContentPart: Decodable {
        let type: String
        let text: String?
    }

    let error: ResponseError?
    let output: [OutputItem]?
}

private struct OpenAIChatMediaFrame {
    let second: Double
    let dataURL: String
}

private enum OpenAIChatService {
    private static let endpoint = URL(string: "https://api.openai.com/v1/responses")!

    static func sendConversation(
        messages: [AIChatMessage],
        systemPrompt: String,
        apiKey: String,
        modelID: String
    ) async throws -> String {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw OpenAIChatServiceError.missingAPIKey
        }

        let latestAttachmentMessageID = messages.last(where: {
            $0.role == "user" && !$0.attachments.isEmpty
        })?.id

        var input: [[String: Any]] = [
            [
                "role": "system",
                "content": [
                    [
                        "type": "input_text",
                        "text": systemPrompt
                    ]
                ]
            ]
        ]

        for message in messages {
            input.append(
                [
                    "role": message.role == "assistant" ? "assistant" : "user",
                    "content": try await preparedContentParts(
                        for: message,
                        includeAttachments: message.id == latestAttachmentMessageID
                    )
                ]
            )
        }

        let body: [String: Any] = [
            "model": modelID,
            "store": false,
            "temperature": 0.6,
            "max_output_tokens": 2400,
            "input": input
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body, options: [])
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = messages.contains(where: { !$0.attachments.isEmpty }) ? 240 : 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = bodyData

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIChatServiceError.invalidResponse
        }

        let decoder = JSONDecoder()
        let envelope = try? decoder.decode(OpenAIChatResponsesEnvelope.self, from: data)

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            throw OpenAIChatServiceError.httpStatus(
                httpResponse.statusCode,
                envelope?.error?.message
            )
        }

        guard let envelope else {
            throw OpenAIChatServiceError.invalidResponse
        }

        let outputText = envelope.output?
            .flatMap { $0.content ?? [] }
            .filter { $0.type == "output_text" }
            .compactMap(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let outputText, !outputText.isEmpty else {
            throw OpenAIChatServiceError.emptyOutput
        }

        return outputText
    }

    private static func preparedContentParts(
        for message: AIChatMessage,
        includeAttachments: Bool
    ) async throws -> [[String: Any]] {
        var parts: [[String: Any]] = []
        let trimmedText = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let availableAttachments = message.attachments.filter { FileManager.default.fileExists(atPath: $0.url.path) }

        if !trimmedText.isEmpty {
            parts.append(
                [
                    "type": "input_text",
                    "text": trimmedText
                ]
            )
        }

        guard !availableAttachments.isEmpty else {
            return parts.isEmpty
                ? [["type": "input_text", "text": "Continue."]]
                : parts
        }

        if includeAttachments {
            var notes: [String] = []
            var mediaParts: [[String: Any]] = []

            for (index, attachment) in availableAttachments.enumerated() {
                switch attachment.kind {
                case .image:
                    if let imagePart = imageContentPart(for: attachment) {
                        notes.append("Image \(index + 1): \(attachment.resolvedDisplayName).")
                        mediaParts.append(imagePart)
                    }
                case .video:
                    let frames = try await sampledFrames(from: attachment.url)
                    guard !frames.isEmpty else { continue }
                    let timeline = frames
                        .enumerated()
                        .map { frameIndex, frame in
                            "Frame \(frameIndex + 1): \(playbackTimestamp(frame.second))"
                        }
                        .joined(separator: ", ")
                    notes.append(
                        "Video \(index + 1): \(attachment.resolvedDisplayName). Use these frames in chronological order to understand the full clip. Timeline: \(timeline)."
                    )
                    mediaParts.append(
                        contentsOf: frames.map { frame in
                            [
                                "type": "input_image",
                                "image_url": frame.dataURL
                            ]
                        }
                    )
                }
            }

            if !notes.isEmpty {
                parts.append(
                    [
                        "type": "input_text",
                        "text": notes.joined(separator: "\n")
                    ]
                )
            }

            parts.append(contentsOf: mediaParts)
        } else {
            let summary = attachmentSummary(for: availableAttachments)
            if !summary.isEmpty {
                parts.append(
                    [
                        "type": "input_text",
                        "text": "Previous attached media context: \(summary)"
                    ]
                )
            }
        }

        return parts.isEmpty
            ? [["type": "input_text", "text": "Analyze the attached media carefully."]]
            : parts
    }

    private static func imageContentPart(for attachment: AIChatAttachment) -> [String: Any]? {
        guard let imageDataURL = imageDataURL(from: attachment.url) else { return nil }
        return [
            "type": "input_image",
            "image_url": imageDataURL
        ]
    }

    private static func sampledFrames(from videoURL: URL) async throws -> [OpenAIChatMediaFrame] {
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration)
        let durationSeconds = max(CMTimeGetSeconds(duration), 0.3)
        let fractions: [Double] = [0.05, 0.18, 0.32, 0.46, 0.60, 0.74, 0.88]
        var frames: [OpenAIChatMediaFrame] = []
        var seenMoments = Set<String>()

        for fraction in fractions {
            let second = max(0, min(durationSeconds * fraction, max(durationSeconds - 0.05, 0)))
            let momentKey = String(format: "%.2f", second)
            guard seenMoments.insert(momentKey).inserted else { continue }

            guard let rawData = try? await ReelsVideoExporter.capturePhotoData(sourceURL: videoURL, at: second),
                  let dataURL = imageDataURL(from: rawData) else {
                continue
            }

            frames.append(OpenAIChatMediaFrame(second: second, dataURL: dataURL))
        }

        return frames
    }

    private static func imageDataURL(from fileURL: URL) -> String? {
        guard let image = UIImage(contentsOfFile: fileURL.path) else { return nil }
        return imageDataURL(from: image)
    }

    private static func imageDataURL(from rawData: Data) -> String? {
        guard let image = UIImage(data: rawData) else { return nil }
        return imageDataURL(from: image)
    }

    private static func imageDataURL(from image: UIImage) -> String? {
        let resized = resizedImage(image, maxDimension: 1280)
        guard let jpegData = resized.jpegData(compressionQuality: 0.74) else { return nil }
        return "data:image/jpeg;base64,\(jpegData.base64EncodedString())"
    }

    private static func resizedImage(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }

        let longestSide = max(size.width, size.height)
        guard longestSide > maxDimension else { return image }

        let scale = maxDimension / longestSide
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    private static func attachmentSummary(for attachments: [AIChatAttachment]) -> String {
        attachments
            .map { attachment in
                switch attachment.kind {
                case .image:
                    return "image \(attachment.resolvedDisplayName)"
                case .video:
                    return "video \(attachment.resolvedDisplayName)"
                }
            }
            .joined(separator: ", ")
    }

    private static func playbackTimestamp(_ seconds: Double) -> String {
        let safeSeconds = max(Int(seconds.rounded(.down)), 0)
        let minutes = safeSeconds / 60
        let remainingSeconds = safeSeconds % 60
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }
}

enum GoogleAIChatServiceError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case emptyOutput
    case httpStatus(Int, String?)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add your Google AI Studio API key first."
        case .invalidResponse:
            return "Google AI Studio returned a response soranin could not read."
        case .emptyOutput:
            return "Google AI Studio did not return any chat reply."
        case .httpStatus(let statusCode, let message):
            if let message, !message.isEmpty {
                return "Google AI Studio error \(statusCode): \(message)"
            }
            return "Google AI Studio error \(statusCode)."
        }
    }
}

private struct GoogleAIChatResponseEnvelope: Decodable {
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

private struct GoogleAIChatUploadedFile: Decodable {
    let name: String
    let uri: String?
    let mimeType: String?
    let state: String?
}

private struct GoogleAIChatUploadedFileEnvelope: Decodable {
    let file: GoogleAIChatUploadedFile?
}

private struct GoogleAIChatPreparedParts {
    let parts: [[String: Any]]
    let uploadedFileNames: [String]
}

private enum GoogleAIChatService {
    private static let uploadEndpoint = URL(string: "https://generativelanguage.googleapis.com/upload/v1beta/files")!

    static func sendConversation(
        messages: [AIChatMessage],
        systemPrompt: String,
        apiKey: String,
        modelName: String
    ) async throws -> String {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw GoogleAIChatServiceError.missingAPIKey
        }

        guard let encodedModelName = modelName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(encodedModelName):generateContent") else {
            throw GoogleAIChatServiceError.invalidResponse
        }

        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "key", value: trimmedKey)
        ]

        guard let url = components?.url else {
            throw GoogleAIChatServiceError.invalidResponse
        }

        let latestAttachmentMessageID = messages.last(where: {
            $0.role == "user" && !$0.attachments.isEmpty
        })?.id

        var uploadedFileNames: [String] = []
        var contents: [[String: Any]] = []

        for message in messages {
            let prepared = try await preparedParts(
                for: message,
                includeAttachments: message.id == latestAttachmentMessageID,
                apiKey: trimmedKey
            )
            uploadedFileNames.append(contentsOf: prepared.uploadedFileNames)
            contents.append(
                [
                    "role": message.role == "assistant" ? "model" : "user",
                    "parts": prepared.parts
                ]
            )
        }

        defer {
            if !uploadedFileNames.isEmpty {
                let fileNames = uploadedFileNames
                Task.detached(priority: .utility) {
                    for fileName in fileNames {
                        try? await deleteUploadedFile(named: fileName, apiKey: trimmedKey)
                    }
                }
            }
        }

        let body: [String: Any] = [
            "systemInstruction": [
                "parts": [
                    [
                        "text": systemPrompt
                    ]
                ]
            ],
            "contents": contents,
            "generationConfig": [
                "temperature": 0.6,
                "maxOutputTokens": 2400,
                "responseMimeType": "text/plain"
            ]
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body, options: [])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = uploadedFileNames.isEmpty ? 120 : 240
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GoogleAIChatServiceError.invalidResponse
        }

        if !(200 ... 299).contains(httpResponse.statusCode) {
            let apiError = try? JSONDecoder().decode(GoogleAIChatResponseEnvelope.APIErrorEnvelope.self, from: data)
            throw GoogleAIChatServiceError.httpStatus(
                httpResponse.statusCode,
                apiError?.error?.message
            )
        }

        let envelope = try JSONDecoder().decode(GoogleAIChatResponseEnvelope.self, from: data)
        let outputText = envelope.candidates?
            .flatMap { $0.content?.parts ?? [] }
            .compactMap(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let outputText, !outputText.isEmpty else {
            throw GoogleAIChatServiceError.emptyOutput
        }

        return outputText
    }

    private static func preparedParts(
        for message: AIChatMessage,
        includeAttachments: Bool,
        apiKey: String
    ) async throws -> GoogleAIChatPreparedParts {
        var parts: [[String: Any]] = []
        var uploadedFileNames: [String] = []
        let trimmedText = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let availableAttachments = message.attachments.filter { FileManager.default.fileExists(atPath: $0.url.path) }

        if !trimmedText.isEmpty {
            parts.append(["text": trimmedText])
        }

        guard !availableAttachments.isEmpty else {
            return GoogleAIChatPreparedParts(
                parts: parts.isEmpty ? [["text": "Continue."]] : parts,
                uploadedFileNames: []
            )
        }

        if includeAttachments {
            var notes: [String] = []

            for (index, attachment) in availableAttachments.enumerated() {
                switch attachment.kind {
                case .image:
                    guard let imagePart = inlineImagePart(for: attachment) else { continue }
                    notes.append("Image \(index + 1): \(attachment.resolvedDisplayName).")
                    parts.append(imagePart)
                case .video:
                    let uploadedFile = try await uploadVideo(attachment.url, apiKey: apiKey)
                    uploadedFileNames.append(uploadedFile.name)
                    let activeFile = try await waitUntilVideoFileIsReady(
                        named: uploadedFile.name,
                        initialFile: uploadedFile,
                        apiKey: apiKey
                    )
                    let fileURI = activeFile.uri ?? uploadedFile.uri
                    let mimeType = activeFile.mimeType ?? uploadedFile.mimeType ?? mimeType(for: attachment.url)
                    guard let fileURI, !fileURI.isEmpty else { continue }

                    notes.append(
                        "Video \(index + 1): \(attachment.resolvedDisplayName). Use the full uploaded video from start to finish, including any clear audio, spoken words, and motion."
                    )
                    parts.append(
                        [
                            "file_data": [
                                "mime_type": mimeType,
                                "file_uri": fileURI
                            ]
                        ]
                    )
                }
            }

            if !notes.isEmpty {
                parts.insert(["text": notes.joined(separator: "\n")], at: min(parts.count, trimmedText.isEmpty ? 0 : 1))
            }
        } else {
            let summary = attachmentSummary(for: availableAttachments)
            if !summary.isEmpty {
                parts.append(["text": "Previous attached media context: \(summary)"])
            }
        }

        return GoogleAIChatPreparedParts(
            parts: parts.isEmpty ? [["text": "Analyze the attached media carefully."]] : parts,
            uploadedFileNames: uploadedFileNames
        )
    }

    private static func inlineImagePart(for attachment: AIChatAttachment) -> [String: Any]? {
        guard let data = preparedImageData(from: attachment.url) else { return nil }
        return [
            "inline_data": [
                "mime_type": attachment.mimeType ?? mimeType(for: attachment.url),
                "data": data.base64EncodedString()
            ]
        ]
    }

    private static func preparedImageData(from fileURL: URL) -> Data? {
        guard let image = UIImage(contentsOfFile: fileURL.path) else { return nil }
        let resized = resizedImage(image, maxDimension: 1280)
        return resized.jpegData(compressionQuality: 0.74)
    }

    private static func resizedImage(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }

        let longestSide = max(size.width, size.height)
        guard longestSide > maxDimension else { return image }

        let scale = maxDimension / longestSide
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    private static func uploadVideo(_ videoURL: URL, apiKey: String) async throws -> GoogleAIChatUploadedFile {
        guard let videoData = try? Data(contentsOf: videoURL), !videoData.isEmpty else {
            throw GoogleAIChatServiceError.invalidResponse
        }

        let mimeType = mimeType(for: videoURL)
        let fileSize = videoData.count
        let displayName = cleanedMediaName(from: videoURL)

        var components = URLComponents(url: uploadEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "key", value: apiKey)
        ]

        guard let startURL = components?.url else {
            throw GoogleAIChatServiceError.invalidResponse
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
            throw GoogleAIChatServiceError.invalidResponse
        }

        if !(200...299).contains(startHTTPResponse.statusCode) {
            let apiError = try? JSONDecoder().decode(GoogleAIChatResponseEnvelope.APIErrorEnvelope.self, from: startData)
            throw GoogleAIChatServiceError.httpStatus(
                startHTTPResponse.statusCode,
                apiError?.error?.message
            )
        }

        guard let uploadURLString = startHTTPResponse.value(forHTTPHeaderField: "X-Goog-Upload-URL"),
              let uploadURL = URL(string: uploadURLString) else {
            throw GoogleAIChatServiceError.invalidResponse
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
            throw GoogleAIChatServiceError.invalidResponse
        }

        if !(200...299).contains(uploadHTTPResponse.statusCode) {
            let apiError = try? JSONDecoder().decode(GoogleAIChatResponseEnvelope.APIErrorEnvelope.self, from: uploadData)
            throw GoogleAIChatServiceError.httpStatus(
                uploadHTTPResponse.statusCode,
                apiError?.error?.message
            )
        }

        guard let uploadedFile = try JSONDecoder().decode(GoogleAIChatUploadedFileEnvelope.self, from: uploadData).file else {
            throw GoogleAIChatServiceError.invalidResponse
        }

        return uploadedFile
    }

    private static func waitUntilVideoFileIsReady(
        named fileName: String,
        initialFile: GoogleAIChatUploadedFile,
        apiKey: String
    ) async throws -> GoogleAIChatUploadedFile {
        let initialState = initialFile.state?.uppercased() ?? "ACTIVE"
        if initialState == "ACTIVE" {
            return initialFile
        }

        for _ in 0 ..< 45 {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            let file = try await fetchUploadedFile(named: fileName, apiKey: apiKey)
            let state = file.state?.uppercased() ?? "ACTIVE"
            if state == "ACTIVE" {
                return file
            }
            if state == "FAILED" {
                throw GoogleAIChatServiceError.invalidResponse
            }
        }

        throw GoogleAIChatServiceError.invalidResponse
    }

    private static func fetchUploadedFile(
        named fileName: String,
        apiKey: String
    ) async throws -> GoogleAIChatUploadedFile {
        guard var components = URLComponents(
            string: "https://generativelanguage.googleapis.com/v1beta/\(fileName)"
        ) else {
            throw GoogleAIChatServiceError.invalidResponse
        }

        components.queryItems = [
            URLQueryItem(name: "key", value: apiKey)
        ]

        guard let url = components.url else {
            throw GoogleAIChatServiceError.invalidResponse
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GoogleAIChatServiceError.invalidResponse
        }

        if !(200...299).contains(httpResponse.statusCode) {
            let apiError = try? JSONDecoder().decode(GoogleAIChatResponseEnvelope.APIErrorEnvelope.self, from: data)
            throw GoogleAIChatServiceError.httpStatus(
                httpResponse.statusCode,
                apiError?.error?.message
            )
        }

        return try JSONDecoder().decode(GoogleAIChatUploadedFile.self, from: data)
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

    private static func attachmentSummary(for attachments: [AIChatAttachment]) -> String {
        attachments
            .map { attachment in
                switch attachment.kind {
                case .image:
                    return "image \(attachment.resolvedDisplayName)"
                case .video:
                    return "video \(attachment.resolvedDisplayName)"
                }
            }
            .joined(separator: ", ")
    }

    private static func cleanedMediaName(from url: URL) -> String {
        let rawName = url.deletingPathExtension().lastPathComponent
        return rawName
            .replacingOccurrences(of: #"[_\-.]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func mimeType(for url: URL) -> String {
        if let resourceValues = try? url.resourceValues(forKeys: [.contentTypeKey]),
           let contentType = resourceValues.contentType,
           let mimeType = contentType.preferredMIMEType {
            return mimeType
        }

        if let type = UTType(filenameExtension: url.pathExtension),
           let mimeType = type.preferredMIMEType {
            return mimeType
        }

        return "application/octet-stream"
    }
}

private struct DownloadInputEntry {
    let videoID: String
    let sourceInput: String
    let sourceKind: DownloadSourceKind
}

private struct DownloadEnqueueResult {
    var added: [String] = []
    var duplicates: [String] = []
    var blockedCompleted: [String] = []
    var reactivatedCompleted: [String] = []

    var hasChanges: Bool {
        !added.isEmpty || !duplicates.isEmpty || !blockedCompleted.isEmpty || !reactivatedCompleted.isEmpty
    }
}

private struct MacRemoteRunResponse: Decodable {
    let ok: Bool?
    let message: String?
    let count: Int?
}

private struct FacebookResolvedCandidate: Decodable {
    let quality: String?
    let url: String?
    let size: Int?
    let sizeHuman: String?
    let mimeType: String?
    let expiresAt: String?

    private enum CodingKeys: String, CodingKey {
        case quality
        case url
        case size
        case sizeHuman = "size_human"
        case mimeType = "mime_type"
        case expiresAt = "expires_at"
    }
}

private struct FacebookResolveResponse: Decodable {
    let ok: Bool?
    let message: String?
    let normalizedURL: String?
    let preferredFilename: String?
    let candidates: [FacebookResolvedCandidate]?

    private enum CodingKeys: String, CodingKey {
        case ok
        case message
        case normalizedURL = "normalized_url"
        case preferredFilename = "preferred_filename"
        case candidates
    }
}

private struct MacControlBootstrapResponse: Decodable {
    let ok: Bool?
    let message: String?
    let profiles: [String]?
    let memorySummary: String?

    private enum CodingKeys: String, CodingKey {
        case ok
        case message
        case profiles
        case memorySummary = "memory_summary"
    }
}

private struct MacFacebookPostResponse: Decodable {
    let ok: Bool?
    let message: String?
    let summary: String?
}

@MainActor
final class SoraDownloadViewModel: ObservableObject {
    private static let downloadAutoSaveDefaultsKey = "downloadAutoSaveToPhotos"
    private static let aiAutoModeDefaultsKey = "aiAutoModeEnabled"
    private static let appLanguageDefaultsKey = "appLanguage"
    private static let selectedAIProviderDefaultsKey = "selectedAIProvider"
    private static let selectedOpenAIModelDefaultsKey = "selectedOpenAIModel"
    private static let selectedGoogleModelDefaultsKey = "selectedGoogleModel"
    private static let didClearLegacyOpenAIKeyDefaultsKey = "didClearLegacyOpenAIKey"
    private static let completedDownloadIDsDefaultsKey = "completedSoraDownloadIDs"
    private static let macControlServerURLDefaultsKey = "macControlServerURL"
    private static let historiesFileName = "generated-text-history.json"
    private static let historiesFolderName = "History"
    private static let historyThumbnailsFolderName = "HistoryThumbs"
    private static let aiChatFileName = "ai-chat-sessions.json"

    @Published var rawInput = ""
    @Published private(set) var shouldConcealPastedDownloadInput = false
    @Published var statusMessage = ""
    @Published var isDownloading = false
    @Published var isMerging = false
    @Published var isConverting = false
    @Published var isCapturingPhoto = false
    @Published var downloadProgress = 0.0
    @Published var conversionProgress = 0.0
    @Published var downloadQueue: [DownloadQueueItem] = []
    @Published var editorClips: [EditorClip] = []
    @Published var selectedClipID: EditorClip.ID?
    @Published var editorClipCount = 0
    @Published var editorVideoURL: URL?
    @Published var lastSavedFileURL: URL?
    @Published var exportPreviewURL: URL?
    @Published var isShowingExportPreview = false
    @Published var exportPreviewAlreadySavedToPhotos = false
    @Published var exportPreviewPhotoSaveMessage = ""
    @Published var isGeneratingTitles = false
    @Published var generatedTitlesText = ""
    @Published var isShowingGeneratedTitles = false
    @Published var isGeneratingThumbnail = false
    @Published var generatedThumbnailImageURL: URL?
    @Published var generatedThumbnailHeadline = ""
    @Published var generatedThumbnailReason = ""
    @Published var generatedThumbnailPhotoSaveMessage = ""
    @Published var generatedThumbnailSavedToPhotos = false
    @Published var isShowingGeneratedThumbnail = false
    @Published var generatedTitlesHistory: [GeneratedHistoryEntry] = []
    @Published var trashedGeneratedTitlesHistory: [GeneratedHistoryEntry] = []
    @Published var isShowingTitlesHistory = false
    @Published var isGeneratingPrompt = false
    @Published var promptGenerationProgress = 0.0
    @Published var thumbnailGenerationProgress = 0.0
    @Published var generatedPromptText = ""
    @Published var isShowingGeneratedPrompt = false
    @Published var generatedPromptsHistory: [GeneratedHistoryEntry] = []
    @Published var trashedGeneratedPromptsHistory: [GeneratedHistoryEntry] = []
    @Published var isShowingPromptHistory = false
    @Published var isShowingAIChat = false
    @Published var aiChatSessions: [AIChatSession] = []
    @Published var aiChatMessages: [AIChatMessage] = []
    @Published var currentAIChatSessionID: UUID?
    @Published var aiChatStatus = ""
    @Published var isSendingAIChat = false
    @Published var aiChatDraftAttachments: [AIChatAttachment] = []
    @Published var promptInputVideoURL: URL?
    @Published var promptInputVideoTitle = ""
    @Published var promptInputFramePreviewURL: URL?
    @Published var isShowingGoogleAIKeyPrompt = false
    @Published var isShowingOpenAIKeyPrompt = false
    @Published var isCheckingGoogleAIKey = false
    @Published var isCheckingOpenAIKey = false
    @Published var googleAIKeyCheckMessage = ""
    @Published var openAIKeyCheckMessage = ""
    @Published var hasConfiguredGoogleAIKey: Bool
    @Published var hasConfiguredOpenAIKey: Bool
    @Published var selectedAIProvider: AIProvider
    @Published var openAIModelOptions: [AIModelOption]
    @Published var googleAIModelOptions: [AIModelOption]
    @Published var selectedOpenAIModelID: String
    @Published var selectedGoogleModelID: String
    @Published var isRefreshingOpenAIModels = false
    private var aiChatSendTask: Task<Void, Never>?
    @Published var isRefreshingGoogleModels = false
    @Published var photoPreviewURL: URL?
    @Published var isShowingPhotoPreview = false
    @Published var selectedSpeed = VideoSpeedOption.slow90
    @Published var downloadAutoSavesToPhotos: Bool
    @Published var isAIAutoModeEnabled: Bool
    @Published var isShowingAIAutoDonePopup = false
    @Published var aiAutoDoneMessage = ""
    @Published var appLanguage: AppLanguage
    @Published private(set) var blockedCompletedDownloadCount = 0
    @Published private(set) var unlockedCompletedDownloadCount = 0
    @Published private(set) var queuedNextDownloadCount = 0
    @Published private(set) var lastDownloadSuccessCount = 0
    @Published private(set) var lastDownloadFailureCount = 0

    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var pendingCloseCleanup = false
    private var aiAutoInputTask: Task<Void, Never>?
    private var isAIAutoRunInProgress = false
    private var shouldAutoConvertAfterDownload = false
    private var shouldAutoCreateTitlesAfterExport = false
    private var shouldAutoCopyTitlesAfterGeneration = false
    private var shouldCreateTitlesAfterSavingGoogleKey = false
    private var shouldCreateEditorTitlesAfterSavingGoogleKey = false
    private var shouldCreatePromptAfterSavingGoogleKey = false
    private var shouldCreateThumbnailAfterSavingGoogleKey = false
    private var shouldCreateTitlesAfterSavingKey = false
    private var shouldCreateEditorTitlesAfterSavingKey = false
    private var shouldCreatePromptAfterSavingKey = false
    private var promptProgressTask: Task<Void, Never>?
    private var thumbnailProgressTask: Task<Void, Never>?
    private var generatedPromptSourceURL: URL?
    private var generatedPromptSourceName = ""
    private var generatedPromptSourceClipCount = 0
    private var generatedThumbnailSourceURL: URL?
    private var generatedThumbnailSuggestion: VideoThumbnailSuggestion?
    private var generatedThumbnailVariationIndex = 0
    private var pendingPromptSourceURL: URL?
    private var pendingPromptSourceName = ""
    private var pendingPromptSourceClipCount = 0
    private var generatedTitlesSourceURL: URL?
    private var generatedTitlesSourceName = ""
    private var promptInputFramePreviewFileName: String?
    private var completedDownloadIDs: Set<String> = []
    private var queuedClipboardDownloadIDs: [String] = []
    private var clipboardPasteTapDates: [Date] = []

    init() {
        Self.clearLegacyOpenAIKeyIfNeeded()
        appLanguage = AppLanguage(rawValue: UserDefaults.standard.string(forKey: Self.appLanguageDefaultsKey) ?? "") ?? .english
        downloadAutoSavesToPhotos = UserDefaults.standard.object(forKey: Self.downloadAutoSaveDefaultsKey) as? Bool ?? true
        isAIAutoModeEnabled = UserDefaults.standard.object(forKey: Self.aiAutoModeDefaultsKey) as? Bool ?? false
        openAIModelOptions = AIModelCatalog.defaultModels(for: .openAI)
        googleAIModelOptions = AIModelCatalog.defaultModels(for: .googleGemini)
        selectedOpenAIModelID = Self.initialModelID(
            savedValue: UserDefaults.standard.string(forKey: Self.selectedOpenAIModelDefaultsKey),
            provider: .openAI
        )
        selectedGoogleModelID = Self.initialModelID(
            savedValue: UserDefaults.standard.string(forKey: Self.selectedGoogleModelDefaultsKey),
            provider: .googleGemini
        )
        let googleConfigured = GoogleAIAPIKeyStore.hasStoredKey()
        let openAIConfigured = OpenAIAPIKeyStore.hasStoredKey()
        hasConfiguredGoogleAIKey = googleConfigured
        hasConfiguredOpenAIKey = openAIConfigured
        selectedAIProvider = Self.initialAIProvider(
            savedValue: UserDefaults.standard.string(forKey: Self.selectedAIProviderDefaultsKey),
            googleConfigured: googleConfigured,
            openAIConfigured: openAIConfigured
        )
        completedDownloadIDs = loadCompletedDownloadIDs()
        loadPersistentHistories()
        startFreshSession()
        bootstrapAIChatSessions()

        if googleConfigured {
            Task {
                await refreshModelsIfPossible(for: .googleGemini)
            }
        }

        if openAIConfigured {
            Task {
                await refreshModelsIfPossible(for: .openAI)
            }
        }
    }

    private static func clearLegacyOpenAIKeyIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.didClearLegacyOpenAIKeyDefaultsKey) else { return }
        _ = OpenAIAPIKeyStore.delete()
        UserDefaults.standard.set(true, forKey: Self.didClearLegacyOpenAIKeyDefaultsKey)
    }

    private static func initialAIProvider(
        savedValue: String?,
        googleConfigured: Bool,
        openAIConfigured: Bool
    ) -> AIProvider {
        if let savedValue, let provider = AIProvider(rawValue: savedValue) {
            return provider
        }

        if googleConfigured {
            return .googleGemini
        }

        if openAIConfigured {
            return .openAI
        }

        return .googleGemini
    }

    private static func initialModelID(savedValue: String?, provider: AIProvider) -> String {
        let fallback = AIModelCatalog.defaultModelID(for: provider)
        guard let savedValue, !savedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return fallback
        }
        return savedValue
    }

    var isBusy: Bool {
        isDownloading || isMerging || isConverting || isCapturingPhoto || isGeneratingTitles || isGeneratingPrompt
    }

    var hasShareableFile: Bool {
        lastSavedFileURL != nil
    }

    var hasEditorVideo: Bool {
        editorVideoURL != nil
    }

    var selectedClip: EditorClip? {
        guard let selectedClipID else { return editorClips.first }
        return editorClips.first(where: { $0.id == selectedClipID }) ?? editorClips.first
    }

    var selectedClipSettings: ReelsEditorSettings {
        selectedClip?.settings ?? ReelsEditorSettings()
    }

    var canConvertLatestVideo: Bool {
        editorVideoURL != nil && !isBusy
    }

    var hasGeneratedTitlesHistory: Bool {
        !generatedTitlesHistory.isEmpty || !trashedGeneratedTitlesHistory.isEmpty
    }

    var hasGeneratedPromptHistory: Bool {
        !generatedPromptsHistory.isEmpty || !trashedGeneratedPromptsHistory.isEmpty
    }

    var currentAIChatSessionLabel: String {
        currentAIChatSession?.labelText ?? text("New Chat", "Chat ថ្មី")
    }

    var currentAIChatSession: AIChatSession? {
        guard let currentAIChatSessionID else { return nil }
        return aiChatSessions.first(where: { $0.id == currentAIChatSessionID })
    }

    var hasPromptInputVideo: Bool {
        promptInputVideoURL != nil
    }

    var selectedAIProviderName: String {
        providerDisplayName(selectedAIProvider)
    }

    var selectedAIProviderModelName: String {
        selectedModelName(for: selectedAIProvider)
    }

    var selectedAIProviderSubtitle: String {
        switch selectedAIProvider {
        case .googleGemini:
            return hasConfiguredGoogleAIKey
                ? text("Active AI: Google Gemini • \(selectedGoogleModelID) is ready.", "AI កំពុងប្រើ៖ Google Gemini • \(selectedGoogleModelID) រួចរាល់ហើយ។")
                : text("Active AI: Google Gemini • \(selectedGoogleModelID). Add a Google key to use it.", "AI កំពុងប្រើ៖ Google Gemini • \(selectedGoogleModelID)។ សូមដាក់ Google key សិន។")
        case .openAI:
            return hasConfiguredOpenAIKey
                ? text("Active AI: OpenAI • \(selectedOpenAIModelID) is ready.", "AI កំពុងប្រើ៖ OpenAI • \(selectedOpenAIModelID) រួចរាល់ហើយ។")
                : text("Active AI: OpenAI • \(selectedOpenAIModelID). Add an OpenAI key to use it.", "AI កំពុងប្រើ៖ OpenAI • \(selectedOpenAIModelID)។ សូមដាក់ OpenAI key សិន។")
        }
    }

    var selectedAIProviderIsConfigured: Bool {
        hasConfiguredKey(for: selectedAIProvider)
    }

    var totalClipDuration: Double {
        editorClips.reduce(0) { $0 + max($1.duration, 0) }
    }

    var adjustedTotalClipDuration: Double {
        let safeSpeed = max(selectedSpeed.rawValue, 0.01)
        return totalClipDuration / safeSpeed
    }

    var downloadPercentText: String {
        "\(Int((downloadProgress * 100).rounded()))%"
    }

    var conversionPercentText: String {
        "\(Int((conversionProgress * 100).rounded()))%"
    }

    var promptPercentText: String {
        "\(Int((promptGenerationProgress * 100).rounded()))%"
    }

    var hasDownloadQueueEntries: Bool {
        !downloadQueue.isEmpty
    }

    var downloadQueueCount: Int {
        downloadQueue.count
    }

    var activeDownloadQueueItem: DownloadQueueItem? {
        downloadQueue.first(where: { $0.state == .downloading })
    }

    var pendingDownloadQueueCount: Int {
        downloadQueue.filter { $0.state == .queued || $0.state == .failed }.count
    }

    var completedDownloadQueueCount: Int {
        downloadQueue.filter { $0.state == .completed }.count
    }

    var downloadStatusBadges: [DownloadStatusBadge] {
        var badges: [DownloadStatusBadge] = []

        if blockedCompletedDownloadCount > 0 {
            badges.append(
                DownloadStatusBadge(
                    id: "blocked-completed",
                    label: text("Blocked \(blockedCompletedDownloadCount)", "បានបិទ \(blockedCompletedDownloadCount)"),
                    tone: .warning
                )
            )
        }

        if unlockedCompletedDownloadCount > 0 {
            badges.append(
                DownloadStatusBadge(
                    id: "unlocked-completed",
                    label: text("Unlocked \(unlockedCompletedDownloadCount)", "បានបើក \(unlockedCompletedDownloadCount)"),
                    tone: .accent
                )
            )
        }

        if queuedNextDownloadCount > 0 {
            badges.append(
                DownloadStatusBadge(
                    id: "queued-next",
                    label: text("Queued Next \(queuedNextDownloadCount)", "បន្ទាប់ \(queuedNextDownloadCount)"),
                    tone: .accent
                )
            )
        }

        if lastDownloadSuccessCount > 0 {
            badges.append(
                DownloadStatusBadge(
                    id: "download-success",
                    label: text("Done \(lastDownloadSuccessCount)", "រួច \(lastDownloadSuccessCount)"),
                    tone: .success
                )
            )
        }

        if lastDownloadFailureCount > 0 {
            badges.append(
                DownloadStatusBadge(
                    id: "download-failed",
                    label: text("Failed \(lastDownloadFailureCount)", "បរាជ័យ \(lastDownloadFailureCount)"),
                    tone: .danger
                )
            )
        }

        return badges
    }

    var shouldShowConcealedDownloadInputSummary: Bool {
        shouldConcealPastedDownloadInput &&
        !rawInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        concealedDownloadInputCount > 0
    }

    var concealedDownloadInputSummary: String {
        let count = concealedDownloadInputCount
        guard count > 0 else {
            return text("Paste Sora link", "បិទភ្ជាប់ Sora link")
        }

        let failedCount = downloadQueue.filter { $0.state == .failed }.count
        if failedCount > 0 && failedCount == count {
            return count == 1
                ? text("1 URL left for retry", "មាន 1 URL សម្រាប់សាកម្តងទៀត")
                : text("\(count) URLs left for retry", "មាន \(count) URL សម្រាប់សាកម្តងទៀត")
        }

        return count == 1
            ? text("1 URL in box", "មាន 1 URL ក្នុងប្រអប់")
            : text("\(count) URLs in box", "មាន \(count) URL ក្នុងប្រអប់")
    }

    private var concealedDownloadInputCount: Int {
        let ids = extractDownloadInputEntries(from: rawInput)
            .map { $0.videoID.lowercased() }
        return Set(ids).count
    }

    var activeOpenAIModelOptions: [AIModelOption] {
        openAIModelOptions
    }

    var activeGoogleModelOptions: [AIModelOption] {
        googleAIModelOptions
    }

    var downloadSaveModeTitle: String {
        downloadAutoSavesToPhotos
            ? text("Download: Photo+Timeline", "ទាញយក៖ រូបថត+Timeline")
            : text("Download: Timeline Only", "ទាញយក៖ Timeline ប៉ុណ្ណោះ")
    }

    var downloadSaveModeSubtitle: String {
        downloadAutoSavesToPhotos
            ? text(
                "Downloads go to Photos and the clip timeline. Export popup save is separate.",
                "វីដេអូចូលទៅ Photos និង clip timeline។ Popup save ពេល export នៅដាច់ដោយឡែក។"
            )
            : text(
                "Downloads go only to the clip timeline. Export popup save is separate.",
                "វីដេអូចូលតែ clip timeline ប៉ុណ្ណោះ។ Popup save ពេល export នៅដាច់ដោយឡែក។"
            )
    }

    var aiAutoModeTitle: String {
        text("AI Auto Mode", "AI ដំណើរការស្វ័យប្រវត្តិ")
    }

    var aiAutoModeStatusText: String {
        isAIAutoModeEnabled ? text("ON", "ON") : text("OFF", "OFF")
    }

    var aiAutoModeSubtitle: String {
        isAIAutoModeEnabled
            ? text(
                "Paste a link or add clips. soranin will auto run download or convert, then create titles, copy, and show AI done. It keeps the current download mode.",
                "Paste link ឬ Add Clips ចូល។ soranin នឹងដំណើរការស្វ័យប្រវត្តិ download ឬ convert ហើយបន្ត create titles, copy និងបង្ហាញ AI done។ វានឹងគោរពរបៀបទាញយកបច្ចុប្បន្នដដែល។"
            )
            : text(
                "Turn it on to auto run link download or clips convert -> titles -> copy.",
                "បើកវា ដើម្បីអោយដំណើរការស្វ័យប្រវត្តិពី link download ឬ clips convert -> titles -> copy។"
            )
    }

    func setLanguage(_ language: AppLanguage) {
        guard appLanguage != language else { return }
        appLanguage = language
        UserDefaults.standard.set(language.rawValue, forKey: Self.appLanguageDefaultsKey)
        statusMessage = text("Language changed to English.", "បានប្ដូរភាសាទៅខ្មែរ។")
    }

    func toggleAIAutoMode() {
        let shouldEnable = !isAIAutoModeEnabled
        setAIAutoModeEnabled(shouldEnable)

        guard shouldEnable else { return }
        triggerAIAutoRunFromCurrentContextIfNeeded()
    }

    func dismissAIAutoDonePopup() {
        isShowingAIAutoDonePopup = false
        aiAutoDoneMessage = ""
    }

    func shouldRunAIAutoCreateTitlesWhenExportAppears() -> Bool {
        isAIAutoModeEnabled && isAIAutoRunInProgress && shouldAutoCreateTitlesAfterExport
    }

    func markAIAutoCreateTitlesStarted() {
        shouldAutoCreateTitlesAfterExport = false
    }

    func shouldRunAIAutoCopyTitlesWhenPopupAppears() -> Bool {
        isAIAutoModeEnabled && isAIAutoRunInProgress && shouldAutoCopyTitlesAfterGeneration
    }

    func markAIAutoCopyTitlesStarted() {
        shouldAutoCopyTitlesAfterGeneration = false
    }

    func setSelectedAIProvider(_ provider: AIProvider, promptForKeyIfMissing: Bool = true) {
        persistSelectedAIProvider(provider)

        if hasConfiguredKey(for: provider) {
            Task {
                await refreshModelsIfPossible(for: provider)
            }
            statusMessage = text(
                "Active AI switched to \(providerDisplayName(provider)).",
                "បានប្ដូរ AI កំពុងប្រើទៅ \(providerDisplayName(provider))។"
            )
            return
        }

        statusMessage = text(
            "\(providerDisplayName(provider)) is selected. Add its API key to use it.",
            "បានជ្រើស \(providerDisplayName(provider)) ហើយ។ សូមដាក់ API key របស់វាដើម្បីប្រើ។"
        )

        guard promptForKeyIfMissing else { return }

        switch provider {
        case .googleGemini:
            presentGoogleAIKeyPrompt(runCreateTitlesAfterSave: false)
        case .openAI:
            presentOpenAIKeyPrompt(runCreateTitlesAfterSave: false)
        }
    }

    func currentOpenAIAPIKey() -> String {
        OpenAIAPIKeyStore.load() ?? ""
    }

    func currentGoogleAIAPIKey() -> String {
        GoogleAIAPIKeyStore.load() ?? ""
    }

    func providerDisplayName(_ provider: AIProvider) -> String {
        switch provider {
        case .googleGemini:
            return "Google Gemini"
        case .openAI:
            return "OpenAI"
        }
    }

    func modelOptions(for provider: AIProvider) -> [AIModelOption] {
        switch provider {
        case .googleGemini:
            return googleAIModelOptions
        case .openAI:
            return openAIModelOptions
        }
    }

    func selectedModelID(for provider: AIProvider) -> String {
        switch provider {
        case .googleGemini:
            return selectedGoogleModelID
        case .openAI:
            return selectedOpenAIModelID
        }
    }

    func selectedModelName(for provider: AIProvider) -> String {
        modelOptions(for: provider)
            .first(where: { $0.id == selectedModelID(for: provider) })?
            .title ?? selectedModelID(for: provider)
    }

    func setSelectedModel(_ modelID: String, for provider: AIProvider) {
        guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        switch provider {
        case .googleGemini:
            selectedGoogleModelID = modelID
            UserDefaults.standard.set(modelID, forKey: Self.selectedGoogleModelDefaultsKey)
        case .openAI:
            selectedOpenAIModelID = modelID
            UserDefaults.standard.set(modelID, forKey: Self.selectedOpenAIModelDefaultsKey)
        }

        statusMessage = text(
            "\(providerDisplayName(provider)) model is now \(modelID).",
            "model របស់ \(providerDisplayName(provider)) ឥឡូវជា \(modelID)។"
        )
    }

    private func setIsRefreshingModels(_ isRefreshing: Bool, for provider: AIProvider) {
        switch provider {
        case .googleGemini:
            isRefreshingGoogleModels = isRefreshing
        case .openAI:
            isRefreshingOpenAIModels = isRefreshing
        }
    }

    private func applyFetchedModels(_ models: [AIModelOption], for provider: AIProvider) {
        let resolvedModels = models.isEmpty ? AIModelCatalog.defaultModels(for: provider) : models

        switch provider {
        case .googleGemini:
            googleAIModelOptions = resolvedModels
            if !resolvedModels.contains(where: { $0.id == selectedGoogleModelID }), let first = resolvedModels.first {
                selectedGoogleModelID = first.id
                UserDefaults.standard.set(first.id, forKey: Self.selectedGoogleModelDefaultsKey)
            }
        case .openAI:
            openAIModelOptions = resolvedModels
            if !resolvedModels.contains(where: { $0.id == selectedOpenAIModelID }), let first = resolvedModels.first {
                selectedOpenAIModelID = first.id
                UserDefaults.standard.set(first.id, forKey: Self.selectedOpenAIModelDefaultsKey)
            }
        }
    }

    func refreshModelsIfPossible(for provider: AIProvider) async {
        guard let apiKey = configuredAPIKey(for: provider), !apiKey.isEmpty else {
            applyFetchedModels(AIModelCatalog.defaultModels(for: provider), for: provider)
            return
        }

        setIsRefreshingModels(true, for: provider)
        defer { setIsRefreshingModels(false, for: provider) }

        let fetchedModels: [AIModelOption]?
        switch provider {
        case .googleGemini:
            fetchedModels = await AIModelCatalog.fetchGoogleModels(apiKey: apiKey)
        case .openAI:
            fetchedModels = await AIModelCatalog.fetchOpenAIModels(apiKey: apiKey)
        }

        let mergedModels = AIModelCatalog.mergedModels(
            for: provider,
            primary: fetchedModels ?? [],
            fallback: AIModelCatalog.defaultModels(for: provider),
            selectedID: selectedModelID(for: provider)
        )

        applyFetchedModels(mergedModels, for: provider)
    }

    func presentGoogleAIKeyPrompt(
        runCreateTitlesAfterSave: Bool,
        runCreateEditorTitlesAfterSave: Bool = false,
        runCreatePromptAfterSave: Bool = false,
        runCreateThumbnailAfterSave: Bool = false
    ) {
        shouldCreateTitlesAfterSavingGoogleKey = runCreateTitlesAfterSave
        shouldCreateEditorTitlesAfterSavingGoogleKey = runCreateEditorTitlesAfterSave
        shouldCreatePromptAfterSavingGoogleKey = runCreatePromptAfterSave
        shouldCreateThumbnailAfterSavingGoogleKey = runCreateThumbnailAfterSave
        googleAIKeyCheckMessage = ""
        isShowingGoogleAIKeyPrompt = true
    }

    func dismissGoogleAIKeyPrompt() {
        shouldCreateTitlesAfterSavingGoogleKey = false
        shouldCreateEditorTitlesAfterSavingGoogleKey = false
        shouldCreatePromptAfterSavingGoogleKey = false
        shouldCreateThumbnailAfterSavingGoogleKey = false
        googleAIKeyCheckMessage = ""
        isShowingGoogleAIKeyPrompt = false
    }

    func saveGoogleAIAPIKey(_ rawKey: String) {
        let trimmedKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            statusMessage = text("Paste your Google AI Studio API key first.", "សូមបិទភ្ជាប់ Google AI Studio API key ជាមុនសិន។")
            return
        }

        guard GoogleAIAPIKeyStore.save(trimmedKey) else {
            statusMessage = text("soranin could not save the Google AI Studio API key.", "soranin មិនអាចរក្សាទុក Google AI Studio API key បានទេ។")
            return
        }

        hasConfiguredGoogleAIKey = true
        persistSelectedAIProvider(.googleGemini)
        Task {
            await refreshModelsIfPossible(for: .googleGemini)
        }
        isShowingGoogleAIKeyPrompt = false
        statusMessage = text(
            "Google AI Studio API key saved. Active AI is now Google Gemini.",
            "បានរក្សាទុក Google AI Studio API key ហើយ។ AI កំពុងប្រើឥឡូវជា Google Gemini។"
        )

        if shouldCreatePromptAfterSavingGoogleKey {
            shouldCreatePromptAfterSavingGoogleKey = false
            shouldCreateTitlesAfterSavingGoogleKey = false
            shouldCreateEditorTitlesAfterSavingGoogleKey = false
            shouldCreateThumbnailAfterSavingGoogleKey = false
            Task {
                await resumePendingPromptCreation()
            }
        } else if shouldCreateThumbnailAfterSavingGoogleKey {
            shouldCreateThumbnailAfterSavingGoogleKey = false
            shouldCreateTitlesAfterSavingGoogleKey = false
            shouldCreateEditorTitlesAfterSavingGoogleKey = false
            Task {
                await createThumbnailForLatestExport()
            }
        } else if shouldCreateEditorTitlesAfterSavingGoogleKey {
            shouldCreateEditorTitlesAfterSavingGoogleKey = false
            shouldCreateTitlesAfterSavingGoogleKey = false
            shouldCreateThumbnailAfterSavingGoogleKey = false
            Task {
                await createTitlesForCurrentEditorVideo()
            }
        } else if shouldCreateTitlesAfterSavingGoogleKey {
            shouldCreateTitlesAfterSavingGoogleKey = false
            shouldCreateEditorTitlesAfterSavingGoogleKey = false
            shouldCreateThumbnailAfterSavingGoogleKey = false
            Task {
                await createTitlesForLatestExport()
            }
        }
    }

    func removeGoogleAIAPIKey() {
        guard GoogleAIAPIKeyStore.delete() else {
            statusMessage = text("soranin could not remove the Google AI Studio API key.", "soranin មិនអាចលុប Google AI Studio API key បានទេ។")
            return
        }

        hasConfiguredGoogleAIKey = false
        if selectedAIProvider == .googleGemini {
            switchToFallbackProviderIfNeeded()
        }
        shouldCreateTitlesAfterSavingGoogleKey = false
        shouldCreateEditorTitlesAfterSavingGoogleKey = false
        shouldCreatePromptAfterSavingGoogleKey = false
        shouldCreateThumbnailAfterSavingGoogleKey = false
        googleAIKeyCheckMessage = ""
        isShowingGoogleAIKeyPrompt = false
        statusMessage = text(
            "Google AI Studio API key removed.",
            "បានលុប Google AI Studio API key ហើយ។"
        )
    }

    func pasteAndCheckGoogleAIKey(_ candidateKey: String) async -> Bool {
        let draft = candidateKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let pasted = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawKey = draft.isEmpty ? pasted : draft

        guard !rawKey.isEmpty else {
            googleAIKeyCheckMessage = text(
                "Copy a Google AI Studio API key first.",
                "សូម copy Google AI Studio API key ជាមុនសិន។"
            )
            statusMessage = text(
                "Copy a Google AI Studio API key first, then tap Paste & Check.",
                "សូម copy Google AI Studio API key ជាមុនសិន រួចចុច Paste & Check។"
            )
            return false
        }

        isCheckingGoogleAIKey = true
        defer { isCheckingGoogleAIKey = false }
        googleAIKeyCheckMessage = text(
            "Checking with Google Gemini...",
            "កំពុងពិនិត្យជាមួយ Google Gemini..."
        )

        statusMessage = text(
            "Checking your Google AI Studio API key...",
            "កំពុងពិនិត្យ Google AI Studio API key របស់អ្នក..."
        )

        do {
            try await GoogleAIAPIKeyValidator.validate(rawKey, modelID: selectedGoogleModelID)
        } catch {
            googleAIKeyCheckMessage = text(
                "This Google key can't run: \(error.localizedDescription)",
                "Google key នេះមិនអាចប្រើបានទេ៖ \(error.localizedDescription)"
            )
            statusMessage = text(
                "Google AI Studio key can't run: \(error.localizedDescription)",
                "Google AI Studio key មិនអាចប្រើបានទេ៖ \(error.localizedDescription)"
            )
            return false
        }

        guard GoogleAIAPIKeyStore.save(rawKey) else {
            googleAIKeyCheckMessage = text(
                "Google key passed the check, but soranin could not save it.",
                "Google key ឆ្លងការពិនិត្យហើយ ប៉ុន្តែ soranin មិនអាចរក្សាទុកវាបានទេ។"
            )
            statusMessage = text(
                "soranin could not save the Google AI Studio API key.",
                "soranin មិនអាចរក្សាទុក Google AI Studio API key បានទេ។"
            )
            return false
        }

        hasConfiguredGoogleAIKey = true
        persistSelectedAIProvider(.googleGemini)
        await refreshModelsIfPossible(for: .googleGemini)
        let shouldRunActionAfterSave =
            shouldCreatePromptAfterSavingGoogleKey ||
            shouldCreateEditorTitlesAfterSavingGoogleKey ||
            shouldCreateTitlesAfterSavingGoogleKey ||
            shouldCreateThumbnailAfterSavingGoogleKey
        googleAIKeyCheckMessage = text(
            "Google AI Studio key added. Gemini is ready.",
            "បានដាក់ Google AI Studio key ហើយ។ Gemini អាចប្រើបានហើយ។"
        )
        statusMessage = text(
            "Google AI Studio API key is connected. Active AI: Google Gemini.",
            "Google AI Studio API key បានភ្ជាប់រួចហើយ។ AI កំពុងប្រើ៖ Google Gemini។"
        )

        if shouldRunActionAfterSave {
            isShowingGoogleAIKeyPrompt = false
        }

        if shouldCreatePromptAfterSavingGoogleKey {
            shouldCreatePromptAfterSavingGoogleKey = false
            shouldCreateTitlesAfterSavingGoogleKey = false
            shouldCreateEditorTitlesAfterSavingGoogleKey = false
            shouldCreateThumbnailAfterSavingGoogleKey = false
            await resumePendingPromptCreation()
        } else if shouldCreateThumbnailAfterSavingGoogleKey {
            shouldCreateThumbnailAfterSavingGoogleKey = false
            shouldCreateTitlesAfterSavingGoogleKey = false
            shouldCreateEditorTitlesAfterSavingGoogleKey = false
            await createThumbnailForLatestExport()
        } else if shouldCreateEditorTitlesAfterSavingGoogleKey {
            shouldCreateEditorTitlesAfterSavingGoogleKey = false
            shouldCreateTitlesAfterSavingGoogleKey = false
            shouldCreateThumbnailAfterSavingGoogleKey = false
            await createTitlesForCurrentEditorVideo()
        } else if shouldCreateTitlesAfterSavingGoogleKey {
            shouldCreateTitlesAfterSavingGoogleKey = false
            shouldCreateEditorTitlesAfterSavingGoogleKey = false
            shouldCreateThumbnailAfterSavingGoogleKey = false
            await createTitlesForLatestExport()
        }

        return true
    }

    func presentOpenAIKeyPrompt(runCreateTitlesAfterSave: Bool, runCreateEditorTitlesAfterSave: Bool = false, runCreatePromptAfterSave: Bool = false) {
        shouldCreateTitlesAfterSavingKey = runCreateTitlesAfterSave
        shouldCreateEditorTitlesAfterSavingKey = runCreateEditorTitlesAfterSave
        shouldCreatePromptAfterSavingKey = runCreatePromptAfterSave
        openAIKeyCheckMessage = ""
        isShowingOpenAIKeyPrompt = true
    }

    func dismissOpenAIKeyPrompt() {
        shouldCreateTitlesAfterSavingKey = false
        shouldCreateEditorTitlesAfterSavingKey = false
        shouldCreatePromptAfterSavingKey = false
        openAIKeyCheckMessage = ""
        isShowingOpenAIKeyPrompt = false
    }

    func saveOpenAIAPIKey(_ rawKey: String) {
        let trimmedKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            statusMessage = text("Paste your OpenAI API key first.", "សូមបិទភ្ជាប់ OpenAI API key ជាមុនសិន។")
            return
        }

        guard OpenAIAPIKeyStore.save(trimmedKey) else {
            statusMessage = text("soranin could not save the OpenAI API key.", "soranin មិនអាចរក្សាទុក OpenAI API key បានទេ។")
            return
        }

        hasConfiguredOpenAIKey = true
        persistSelectedAIProvider(.openAI)
        Task {
            await refreshModelsIfPossible(for: .openAI)
        }
        isShowingOpenAIKeyPrompt = false
        statusMessage = text(
            "OpenAI API key saved. Active AI is now OpenAI.",
            "បានរក្សាទុក OpenAI API key ហើយ។ AI កំពុងប្រើឥឡូវជា OpenAI។"
        )

        if shouldCreatePromptAfterSavingKey {
            shouldCreatePromptAfterSavingKey = false
            shouldCreateTitlesAfterSavingKey = false
            shouldCreateEditorTitlesAfterSavingKey = false
            Task {
                await resumePendingPromptCreation()
            }
        } else if shouldCreateEditorTitlesAfterSavingKey {
            shouldCreateEditorTitlesAfterSavingKey = false
            shouldCreateTitlesAfterSavingKey = false
            Task {
                await createTitlesForCurrentEditorVideo()
            }
        } else if shouldCreateTitlesAfterSavingKey {
            shouldCreateTitlesAfterSavingKey = false
            shouldCreateEditorTitlesAfterSavingKey = false
            Task {
                await createTitlesForLatestExport()
            }
        }
    }

    func removeOpenAIAPIKey() {
        guard OpenAIAPIKeyStore.delete() else {
            statusMessage = text("soranin could not remove the OpenAI API key.", "soranin មិនអាចលុប OpenAI API key បានទេ។")
            return
        }

        hasConfiguredOpenAIKey = false
        if selectedAIProvider == .openAI {
            switchToFallbackProviderIfNeeded()
        }
        shouldCreateTitlesAfterSavingKey = false
        shouldCreateEditorTitlesAfterSavingKey = false
        shouldCreatePromptAfterSavingKey = false
        openAIKeyCheckMessage = ""
        isShowingOpenAIKeyPrompt = false
        statusMessage = text(
            "OpenAI API key removed.",
            "បានលុប OpenAI API key ហើយ។"
        )
    }

    func pasteAndCheckOpenAIAPIKey(_ candidateKey: String) async -> Bool {
        let draft = candidateKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let pasted = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawKey = draft.isEmpty ? pasted : draft

        guard !rawKey.isEmpty else {
            openAIKeyCheckMessage = text(
                "Copy an OpenAI API key first.",
                "សូម copy OpenAI API key ជាមុនសិន។"
            )
            statusMessage = text(
                "Copy an OpenAI API key first, then tap Paste & Check.",
                "សូម copy OpenAI API key ជាមុនសិន រួចចុច Paste & Check។"
            )
            return false
        }

        isCheckingOpenAIKey = true
        defer { isCheckingOpenAIKey = false }
        openAIKeyCheckMessage = text(
            "Checking with OpenAI...",
            "កំពុងពិនិត្យជាមួយ OpenAI..."
        )

        statusMessage = text(
            "Checking your OpenAI API key...",
            "កំពុងពិនិត្យ OpenAI API key របស់អ្នក..."
        )

        do {
            try await OpenAIAPIKeyValidator.validate(rawKey, modelID: selectedOpenAIModelID)
        } catch {
            openAIKeyCheckMessage = text(
                "This OpenAI key can't run: \(error.localizedDescription)",
                "OpenAI key នេះមិនអាចប្រើបានទេ៖ \(error.localizedDescription)"
            )
            statusMessage = text(
                "OpenAI key can't run: \(error.localizedDescription)",
                "OpenAI key មិនអាចប្រើបានទេ៖ \(error.localizedDescription)"
            )
            return false
        }

        guard OpenAIAPIKeyStore.save(rawKey) else {
            openAIKeyCheckMessage = text(
                "OpenAI key passed the check, but soranin could not save it.",
                "OpenAI key ឆ្លងការពិនិត្យហើយ ប៉ុន្តែ soranin មិនអាចរក្សាទុកវាបានទេ។"
            )
            statusMessage = text(
                "soranin could not save the OpenAI API key.",
                "soranin មិនអាចរក្សាទុក OpenAI API key បានទេ។"
            )
            return false
        }

        hasConfiguredOpenAIKey = true
        persistSelectedAIProvider(.openAI)
        await refreshModelsIfPossible(for: .openAI)
        let shouldRunActionAfterSave =
            shouldCreatePromptAfterSavingKey ||
            shouldCreateEditorTitlesAfterSavingKey ||
            shouldCreateTitlesAfterSavingKey
        openAIKeyCheckMessage = text(
            "OpenAI key added. AI is ready.",
            "បានដាក់ OpenAI key ហើយ។ AI អាចប្រើបានហើយ។"
        )
        statusMessage = text(
            "OpenAI API key is connected. Active AI: OpenAI.",
            "OpenAI API key បានភ្ជាប់រួចហើយ។ AI កំពុងប្រើ៖ OpenAI។"
        )

        if shouldRunActionAfterSave {
            isShowingOpenAIKeyPrompt = false
        }

        if shouldCreatePromptAfterSavingKey {
            shouldCreatePromptAfterSavingKey = false
            shouldCreateTitlesAfterSavingKey = false
            shouldCreateEditorTitlesAfterSavingKey = false
            await resumePendingPromptCreation()
        } else if shouldCreateEditorTitlesAfterSavingKey {
            shouldCreateEditorTitlesAfterSavingKey = false
            shouldCreateTitlesAfterSavingKey = false
            await createTitlesForCurrentEditorVideo()
        } else if shouldCreateTitlesAfterSavingKey {
            shouldCreateTitlesAfterSavingKey = false
            shouldCreateEditorTitlesAfterSavingKey = false
            await createTitlesForLatestExport()
        }

        return true
    }

    func updateRawInput(_ newValue: String) {
        rawInput = normalizedInput(from: newValue)
        shouldConcealPastedDownloadInput = false
        scheduleAIAutoRunFromInputIfNeeded()
    }

    func triggerAIAutoRunFromCurrentInputIfNeeded() {
        guard isAIAutoModeEnabled, !isBusy else { return }
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let entries = extractDownloadInputEntries(from: trimmed)
        guard !entries.isEmpty else { return }

        statusMessage = text(
            "AI Auto Mode found a link and is starting download now.",
            "AI Auto Mode បានរកឃើញ link ហើយកំពុងចាប់ផ្តើម download ឥឡូវនេះ។"
        )

        Task {
            await downloadVideo()
        }
    }

    func triggerAIAutoRunFromCurrentContextIfNeeded() {
        guard isAIAutoModeEnabled, !isBusy else { return }

        if !editorClips.isEmpty {
            prepareAIAutoRunForClipConvert()
            statusMessage = text(
                "AI Auto Mode found clips and is starting Reels convert now.",
                "AI Auto Mode បានរកឃើញ clips ហើយកំពុងចាប់ផ្តើម convert Reels ឥឡូវនេះ។"
            )

            Task {
                await convertLatestVideoForReels(editorSettings: selectedClipSettings)
            }
            return
        }

        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let entries = extractDownloadInputEntries(from: trimmed)
        guard !entries.isEmpty else { return }

        scheduleAIAutoRunFromInputIfNeeded()
    }

    func toggleDownloadSaveMode() {
        if isAIAutoModeEnabled && !downloadAutoSavesToPhotos {
            statusMessage = text(
                "AI Auto Mode keeps downloads on Timeline Only. Turn AI Auto Mode off first if you want Photos + Timeline.",
                "AI Auto Mode រក្សា download ឲ្យនៅ Timeline Only ដដែល។ សូមបិទ AI Auto Mode ជាមុនសិន បើអ្នកចង់ប្រើ Photos + Timeline។"
            )
            return
        }

        downloadAutoSavesToPhotos.toggle()
        UserDefaults.standard.set(downloadAutoSavesToPhotos, forKey: Self.downloadAutoSaveDefaultsKey)
        statusMessage = downloadAutoSavesToPhotos
            ? text(
                "Download mode: videos go to Photos and the clip timeline. Export popup save stays separate.",
                "របៀបទាញយក៖ វីដេអូចូលទៅ Photos និង clip timeline។ Popup save ពេល export នៅដាច់ដោយឡែក។"
            )
            : text(
                "Download mode: videos go only to the clip timeline. Export popup save stays separate.",
                "របៀបទាញយក៖ វីដេអូចូលតែ clip timeline ប៉ុណ្ណោះ។ Popup save ពេល export នៅដាច់ដោយឡែក។"
            )
    }

    func captureIDFromClipboard() {
        guard !(isBusy && !isDownloading) else {
            statusMessage = text("Wait for the current task to finish first.", "សូមរង់ចាំឲ្យ task បច្ចុប្បន្នចប់សិន។")
            return
        }

        let clipboardText = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !clipboardText.isEmpty else {
            statusMessage = self.text("Clipboard is empty.", "Clipboard ទទេ។")
            return
        }

        let clipboardEntries = extractDownloadInputEntries(from: clipboardText)
        guard !clipboardEntries.isEmpty else {
            statusMessage = self.text("No valid Sora or Facebook link found in the clipboard.", "រកមិនឃើញ Sora ឬ Facebook link ត្រឹមត្រូវក្នុង clipboard ទេ។")
            return
        }

        let allowCompletedUnlock = shouldUnlockCompletedDownloadsFromClipboard()
        let enqueueResult = enqueueDownloadInputEntries(clipboardEntries, allowingCompletedIDs: allowCompletedUnlock)
        if !enqueueResult.reactivatedCompleted.isEmpty {
            for videoID in enqueueResult.reactivatedCompleted {
                completedDownloadIDs.remove(videoID.lowercased())
            }
            persistCompletedDownloadIDs()
        }
        updateDownloadEnqueueBadges(from: enqueueResult)
        rawInput = activeDownloadSourceInputText()
        shouldConcealPastedDownloadInput = !rawInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        let baseMessage = messageForEnqueueResult(
            enqueueResult,
            successSingular: self.text("Added 1 download from the clipboard.", "បានបន្ថែម 1 download ពី clipboard។"),
            successPlural: { count in
                self.text("Added \(count) downloads from the clipboard.", "បានបន្ថែម \(count) download ពី clipboard។")
            }
        )
        if isDownloading, !enqueueResult.added.isEmpty {
            enqueueClipboardDownloadsForAutoStart(enqueueResult.added)
            statusMessage = baseMessage + "\n" + text(
                "New pasted URLs will auto download after the current download.",
                "URL ថ្មីដែលបាន paste នឹង auto download បន្ទាប់ពី download បច្ចុប្បន្នចប់។"
            )
            return
        }

        statusMessage = baseMessage

        if !isBusy && !enqueueResult.added.isEmpty {
            Task {
                await downloadVideo()
            }
        } else if isAIAutoModeEnabled {
            scheduleAIAutoRunFromInputIfNeeded()
        }
    }

    func copyMacControlCommandFromInput(preferredServerURL: String? = nil) {
        let entries = extractDownloadInputEntries(from: rawInput)
        let videoIDs = deduplicatedSoraVideoIDs(from: entries)

        guard !videoIDs.isEmpty else {
            statusMessage = text(
                "Add at least one Sora URL or ID first, then tap Mac.",
                "សូមដាក់ Sora URL ឬ ID យ៉ាងហោចណាស់ 1 ជាមុនសិន ហើយចុច Mac។"
            )
            return
        }

        statusMessage = text(
            "Sending URLs to Mac controller...",
            "កំពុងផ្ញើ URL ទៅ Mac controller..."
        )

        Task {
            let remoteResult = await sendVideoIDsToMacController(videoIDs, preferredServerURL: preferredServerURL)
            if remoteResult.ok {
                statusMessage = text(
                    remoteResult.message ?? "Sent to Mac controller. Batch started.",
                    remoteResult.message ?? "បានផ្ញើទៅ Mac controller ហើយ។ Batch ចាប់ផ្តើមរួច។"
                )
                return
            }

            let command = macControlCommand(for: videoIDs)
            UIPasteboard.general.string = command
            let fallbackMessage = remoteResult.message ?? text(
                "Could not reach Mac controller server.",
                "មិនអាចភ្ជាប់ទៅ Mac controller server បានទេ។"
            )
            statusMessage = fallbackMessage + "\n" + text(
                "Mac command copied. Paste it in Mac Terminal to run manually.",
                "បាន copy កូដសម្រាប់ Mac ហើយ។ បិទភ្ជាប់ទៅ Terminal នៅ Mac ដើម្បីដំណើរការដោយដៃ។"
            )
        }
    }

    func downloadVideo() async {
        guard !isBusy else {
            statusMessage = text("Wait for the current task to finish first.", "សូមរង់ចាំឲ្យ task បច្ចុប្បន្នចប់សិន។")
            return
        }

        let inputVideoEntries = extractDownloadInputEntries(from: rawInput)
        var latestEnqueueResult = DownloadEnqueueResult()
        if !inputVideoEntries.isEmpty {
            latestEnqueueResult = enqueueDownloadInputEntries(inputVideoEntries)
            updateDownloadEnqueueBadges(from: latestEnqueueResult)
        }

        let pendingItems = downloadQueue
            .filter { $0.state == .queued || $0.state == .failed }
        let pendingVideoIDs = pendingItems.map(\.videoID)

        guard !pendingVideoIDs.isEmpty else {
            resetAIAutoRunState()
            if latestEnqueueResult.hasChanges {
                statusMessage = messageForEnqueueResult(
                    latestEnqueueResult,
                    successSingular: text("1 video is already in the list.", "វីដេអូ 1 មានក្នុងបញ្ជីរួចហើយ។"),
                    successPlural: { count in
                        text("\(count) videos are already in the list.", "វីដេអូ \(count) មានក្នុងបញ្ជីរួចហើយ។")
                    }
                )
            } else if downloadQueue.isEmpty {
                statusMessage = text("Enter one or more valid Sora IDs, Sora URLs, or Facebook URLs first.", "សូមបញ្ចូល Sora ID, Sora URL ឬ Facebook URL មួយ ឬច្រើនដែលត្រឹមត្រូវជាមុនសិន។")
            } else {
                statusMessage = text("All queued downloads are already finished.", "Download ទាំងអស់ក្នុងបញ្ជីបានចប់រួចហើយ។")
            }
            return
        }

        resetDownloadRunSummary()
        await performDownloadPass(
            videoIDs: pendingVideoIDs,
            enqueueResult: latestEnqueueResult,
            allowsAutoConvertAfterCompletion: true
        )
    }

    private func performDownloadPass(
        videoIDs: [String],
        enqueueResult latestEnqueueResult: DownloadEnqueueResult,
        allowsAutoConvertAfterCompletion: Bool
    ) async {
        guard !videoIDs.isEmpty else { return }

        if isAIAutoModeEnabled {
            prepareAIAutoRunForDownload()
        } else {
            resetAIAutoRunState()
        }

        isDownloading = true
        downloadProgress = 0

        var completedVideoIDs: [String] = []
        var failedVideoIDs: [String] = []

        await withTaskGroup(of: (String, Bool).self) { group in
            for videoID in videoIDs {
                group.addTask { [weak self] in
                    guard let self else {
                        return (videoID, false)
                    }

                    do {
                        try await self.downloadQueuedVideo(videoID: videoID)
                        return (videoID, true)
                    } catch {
                        return (videoID, false)
                    }
                }
            }

            for await (videoID, didSucceed) in group {
                if didSucceed {
                    completedVideoIDs.append(videoID)
                } else {
                    failedVideoIDs.append(videoID)
                }
            }
        }

        isDownloading = false
        downloadProgress = 0
        lastDownloadSuccessCount += completedVideoIDs.count
        lastDownloadFailureCount += failedVideoIDs.count
        downloadQueue.removeAll { item in
            completedVideoIDs.contains { $0.caseInsensitiveCompare(item.videoID) == .orderedSame }
        }
        rawInput = failedDownloadSourceInputText()
        shouldConcealPastedDownloadInput = !rawInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        statusMessage = finalDownloadSummary(
            completedVideoIDs: completedVideoIDs,
            failedVideoIDs: failedVideoIDs,
            enqueueResult: latestEnqueueResult
        )

        let queuedIDs = consumeQueuedClipboardDownloadIDs()
        if !queuedIDs.isEmpty {
            statusMessage += "\n" + text(
                "New pasted URLs are starting download now.",
                "URL ថ្មីដែលបាន paste កំពុងចាប់ផ្តើម download ឥឡូវនេះ។"
            )
            await performDownloadPass(
                videoIDs: queuedIDs,
                enqueueResult: DownloadEnqueueResult(),
                allowsAutoConvertAfterCompletion: false
            )
            return
        }

        let shouldAutoConvertNow =
            allowsAutoConvertAfterCompletion &&
            isAIAutoRunInProgress &&
            shouldAutoConvertAfterDownload &&
            !completedVideoIDs.isEmpty &&
            !editorClips.isEmpty

        if shouldAutoConvertNow {
            shouldAutoConvertAfterDownload = false
            statusMessage += "\n" + text(
                "AI Auto Mode is starting Reels convert now.",
                "AI Auto Mode កំពុងចាប់ផ្តើម convert Reels ឥឡូវនេះ។"
            )
            await convertLatestVideoForReels(editorSettings: selectedClipSettings)
        } else if isAIAutoRunInProgress {
            resetAIAutoRunState()
        }
    }

    func mergeVideosForEditing(from sourceURLs: [URL]) async {
        let pickedURLs = sourceURLs.filter { !$0.path.isEmpty }
        guard !pickedURLs.isEmpty else {
            statusMessage = "Choose one or more videos to merge first."
            return
        }

        guard !isBusy else {
            statusMessage = "Wait for the current task to finish first."
            return
        }

        isMerging = true
        defer {
            if isMerging {
                isMerging = false
            }
        }
        statusMessage = "Adding more clips..."

        do {
            let importedClips = try importVideosAsClips(from: pickedURLs)
            let updatedClips = currentEditorClips() + importedClips
            guard updatedClips.count > 1 else {
                throw ReelsVideoExportError.noSourceVideos
            }
            setEditorClips(updatedClips, selectedClipID: importedClips.first?.id ?? selectedClipID ?? updatedClips.first?.id)
            statusMessage = """
            Added \(importedClips.count) clips.
            New clips were added to the timeline and selected automatically.
            """

            if isAIAutoModeEnabled {
                let settingsForAutoConvert = selectedClipSettings
                prepareAIAutoRunForClipConvert()
                statusMessage += "\n" + text(
                    "AI Auto Mode is starting Reels convert from the clip timeline now.",
                    "AI Auto Mode កំពុងចាប់ផ្តើម convert Reels ពី clip timeline ឥឡូវនេះ។"
                )
                isMerging = false
                await convertLatestVideoForReels(editorSettings: settingsForAutoConvert)
            }
        } catch {
            statusMessage = "Merge failed: \(error.localizedDescription)"
        }
    }

    func inputVideosForEditing(from sourceURLs: [URL]) async {
        let pickedURLs = sourceURLs.filter { !$0.path.isEmpty }
        guard !pickedURLs.isEmpty else {
            statusMessage = "Choose one or more videos from Photos first."
            return
        }

        guard !isBusy else {
            statusMessage = "Wait for the current task to finish first."
            return
        }

        isMerging = true
        defer {
            if isMerging {
                isMerging = false
            }
        }
        statusMessage = "Preparing \(pickedURLs.count) input videos from Photos..."

        do {
            let importedClips = try importVideosAsClips(from: pickedURLs)
            setEditorClips(importedClips, selectedClipID: importedClips.first?.id)
            statusMessage = importedClips.count > 1
                ? """
                Input ready: \(importedClips.count) videos.
                Drag the clip line and stop on the center marker to pick one for editing.
                """
                : """
                Input video ready: \(importedClips.first?.title ?? "Video")
                You can now play, cut photo, or convert this video.
                """

            if isAIAutoModeEnabled {
                let settingsForAutoConvert = selectedClipSettings
                prepareAIAutoRunForClipConvert()
                statusMessage += "\n" + text(
                    "AI Auto Mode is starting Reels convert from the selected clips now.",
                    "AI Auto Mode កំពុងចាប់ផ្តើម convert Reels ពី clips ដែលបានជ្រើស ឥឡូវនេះ។"
                )
                isMerging = false
                await convertLatestVideoForReels(editorSettings: settingsForAutoConvert)
            }
        } catch {
            statusMessage = "Input video failed: \(error.localizedDescription)"
        }
    }

    func inputVideoForPrompt(from sourceURLs: [URL]) async {
        let pickedURLs = sourceURLs.filter { !$0.path.isEmpty }
        guard let sourceURL = pickedURLs.first else {
            statusMessage = text("Choose one video for Create Prompt first.", "សូមជ្រើសវីដេអូមួយសម្រាប់ Create Prompt ជាមុនសិន។")
            return
        }

        guard !isBusy else {
            statusMessage = text("Wait for the current task to finish first.", "សូមរង់ចាំឲ្យ task បច្ចុប្បន្នចប់សិន។")
            return
        }

        let startedAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if startedAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            removePromptInputFramePreview()
            let destinationURL = try makePromptImportedVideoDestinationURL(for: sourceURL)

            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }

            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            promptInputVideoURL = destinationURL
            promptInputVideoTitle = displayName(for: destinationURL)
            generatedPromptText = ""
            promptGenerationProgress = 0
            statusMessage = text(
                "Prompt video ready: \(displayName(for: destinationURL))",
                "វីដេអូសម្រាប់ Prompt បានរួចហើយ៖ \(displayName(for: destinationURL))"
            )
        } catch {
            statusMessage = text(
                "Prompt video failed: \(error.localizedDescription)",
                "វីដេអូសម្រាប់ Prompt បរាជ័យ៖ \(error.localizedDescription)"
            )
        }
    }

    func capturePromptInputFramePreview(at seconds: Double) async {
        guard !isBusy else {
            statusMessage = text("Wait for the current task to finish first.", "សូមរង់ចាំឲ្យ task បច្ចុប្បន្នចប់សិន។")
            return
        }

        guard let sourceURL = promptInputVideoURL else {
            statusMessage = text(
                "Add one prompt video first, then pick a frame from it.",
                "សូមដាក់វីដេអូក្នុងប្រអប់ Prompt ជាមុនសិន បន្ទាប់មករើស frame ពីវា។"
            )
            return
        }

        isCapturingPhoto = true
        let clampedSeconds = max(seconds, 0)
        statusMessage = text(
            "Picking a prompt frame at \(Self.playbackTimestamp(clampedSeconds))...",
            "កំពុងរើស frame សម្រាប់ Prompt នៅ \(Self.playbackTimestamp(clampedSeconds))..."
        )

        do {
            let imageData = try await ReelsVideoExporter.capturePhotoData(sourceURL: sourceURL, at: clampedSeconds)
            let fileName = try makePromptInputFramePreviewFileName(for: sourceURL, seconds: clampedSeconds)
            let fileURL = try historyThumbnailsDirectoryURL().appendingPathComponent(fileName)

            removePromptInputFramePreview()
            try imageData.write(to: fileURL, options: .atomic)

            promptInputFramePreviewFileName = fileName
            promptInputFramePreviewURL = fileURL
            statusMessage = text(
                "Prompt frame ready. Titles History and Prompt History will use this screenshot.",
                "បានរើស frame សម្រាប់ Prompt រួចហើយ។ Titles History និង Prompt History នឹងប្រើរូបនេះ។"
            )
        } catch {
            statusMessage = text(
                "Prompt frame failed: \(error.localizedDescription)",
                "ការរើស frame សម្រាប់ Prompt បរាជ័យ៖ \(error.localizedDescription)"
            )
        }

        isCapturingPhoto = false
    }

    func convertLatestVideoForReels(editorSettings: ReelsEditorSettings) async {
        guard !isBusy else {
            statusMessage = "Wait for the current task to finish first."
            return
        }

        beginBackgroundWork(named: "soranin.export")
        defer {
            isConverting = false
            endBackgroundWork()
        }

        if editorClips.count > 1 {
            let exportClips = editorClips.map { clip in
                ReelsExportClip(sourceURL: clip.fileURL, title: clip.title, settings: clip.settings)
            }

            isConverting = true
            conversionProgress = 0
            exportPreviewAlreadySavedToPhotos = false
            isShowingExportPreview = false
            statusMessage = "Converting \(editorClips.count) clips to Facebook Reels 9:16 Full HD at \(selectedSpeed.label)..."

            do {
                let outputURL = try await ReelsVideoExporter.exportSequence(
                    clips: exportClips,
                    destinationDirectory: try downloadsDirectoryURL(),
                    speed: selectedSpeed,
                    progressHandler: { [weak self] progress in
                        Task { @MainActor in
                            guard let self else { return }
                            self.conversionProgress = min(max(progress, 0), 1)
                            self.statusMessage = "Exporting Reels... \(self.conversionPercentText)"
                        }
                    }
                )

                await handleCompletedExport(at: outputURL)
            } catch {
                resetAIAutoRunState()
                conversionProgress = 0
                statusMessage = "Reels conversion failed: \(error.localizedDescription)"
            }

            return
        }

        guard let sourceURL = editorVideoURL else {
            resetAIAutoRunState()
            statusMessage = "Download one video first, then convert it for Reels."
            return
        }

        isConverting = true
        conversionProgress = 0
        exportPreviewAlreadySavedToPhotos = false
        isShowingExportPreview = false
        statusMessage = "Converting to Facebook Reels 9:16 Full HD at \(selectedSpeed.label)..."

        do {
            let outputURL = try await ReelsVideoExporter.export(
                sourceURL: sourceURL,
                destinationDirectory: try downloadsDirectoryURL(),
                speed: selectedSpeed,
                editorSettings: editorSettings,
                progressHandler: { [weak self] progress in
                    Task { @MainActor in
                        guard let self else { return }
                        self.conversionProgress = min(max(progress, 0), 1)
                        self.statusMessage = "Exporting Reels... \(self.conversionPercentText)"
                    }
                }
            )

            await handleCompletedExport(at: outputURL)
        } catch {
            resetAIAutoRunState()
            conversionProgress = 0
            statusMessage = "Reels conversion failed: \(error.localizedDescription)"
        }
    }

    func dismissExportPreview() {
        exportPreviewAlreadySavedToPhotos = false
        exportPreviewPhotoSaveMessage = ""
        isShowingExportPreview = false
    }

    func dismissGeneratedTitles() {
        generatedTitlesText = ""
        isShowingGeneratedTitles = false
        generatedTitlesSourceURL = nil
        generatedTitlesSourceName = ""
        if isAIAutoRunInProgress {
            resetAIAutoRunState()
        }
    }

    func dismissGeneratedThumbnail() {
        isShowingGeneratedThumbnail = false
        generatedThumbnailImageURL = nil
        generatedThumbnailHeadline = ""
        generatedThumbnailReason = ""
        generatedThumbnailPhotoSaveMessage = ""
        generatedThumbnailSavedToPhotos = false
        generatedThumbnailSourceURL = nil
        generatedThumbnailSuggestion = nil
        generatedThumbnailVariationIndex = 0
    }

    private func clearReelsEditorAfterTitleCopy() {
        editorClips = []
        selectedClipID = nil
        editorClipCount = 0
        editorVideoURL = nil
        exportPreviewURL = nil
        exportPreviewAlreadySavedToPhotos = false
        exportPreviewPhotoSaveMessage = ""
        isShowingExportPreview = false
        conversionProgress = 0
    }

    func showTitlesHistory() {
        guard hasGeneratedTitlesHistory else {
            statusMessage = text(
                "No AI titles have been created yet.",
                "មិនទាន់មាន AI titles ដែលបានបង្កើតនៅឡើយ។"
            )
            return
        }

        focusedDismiss()
        isShowingTitlesHistory = true
    }

    func dismissTitlesHistory() {
        isShowingTitlesHistory = false
    }

    func showPromptHistory() {
        guard hasGeneratedPromptHistory else {
            statusMessage = text(
                "No AI prompts have been created yet.",
                "មិនទាន់មាន AI prompts ដែលបានបង្កើតនៅឡើយ។"
            )
            return
        }

        focusedDismiss()
        isShowingPromptHistory = true
    }

    func dismissPromptHistory() {
        isShowingPromptHistory = false
    }

    func dismissGeneratedPrompt() {
        generatedPromptText = ""
        isShowingGeneratedPrompt = false
    }

    func dismissPhotoPreview() {
        isShowingPhotoPreview = false
        photoPreviewURL = nil
    }

    func handleAppMovedToBackground() {
        if isBusy {
            pendingCloseCleanup = true
            statusMessage = text("soranin will clear local media after the current task finishes.", "soranin នឹងសម្អាត media local បន្ទាប់ពី task បច្ចុប្បន្នចប់។")
            return
        }

        clearAllLocalMedia()
    }

    func performPendingCloseCleanupIfNeeded() {
        guard pendingCloseCleanup, !isBusy else { return }
        clearAllLocalMedia()
    }

    func saveLatestVideoToPhotosAgain() async {
        guard let fileURL = lastSavedFileURL else {
            statusMessage = text("No exported video is ready yet.", "មិនទាន់មានវីដេអូ export រួចរាល់នៅឡើយ។")
            return
        }

        let saveMessage = await saveVideoToPhotos(from: fileURL)
        if didSaveToPhotos(saveMessage) {
            exportPreviewAlreadySavedToPhotos = true
            statusMessage = """
            Export saved to Photos: \(displayName(for: fileURL))
            Local files and the clip timeline stay in soranin.
            """
            return
        }
        statusMessage = "Export save: \(saveMessage)"
    }

    func saveGeneratedThumbnailToPhotos() async {
        guard let fileURL = generatedThumbnailImageURL else {
            statusMessage = text(
                "No thumbnail image is ready yet.",
                "មិនទាន់មានរូប thumbnail រួចរាល់នៅឡើយ។"
            )
            return
        }

        let saveMessage = await saveImageToPhotos(from: fileURL)
        generatedThumbnailPhotoSaveMessage = saveMessage
        generatedThumbnailSavedToPhotos = didSaveToPhotos(saveMessage)
        statusMessage = """
        Thumbnail ready: \(displayName(for: fileURL))
        \(saveMessage)
        """
    }

    func createTitlesForLatestExport() async {
        guard let fileURL = exportPreviewURL ?? lastSavedFileURL else {
            statusMessage = text("No exported video is ready for titles yet.", "មិនទាន់មានវីដេអូ export សម្រាប់បង្កើតចំណងជើងនៅឡើយ។")
            return
        }

        guard !isDownloading && !isMerging && !isConverting && !isCapturingPhoto else {
            statusMessage = text("Wait for the current task to finish first.", "សូមរង់ចាំឲ្យ task បច្ចុប្បន្នចប់សិន។")
            return
        }

        generatedTitlesSourceURL = fileURL
        generatedTitlesSourceName = displayName(for: fileURL)
        await generateTitles(
            for: fileURL,
            isPromptVideo: false,
            presentKeyPromptIfNeeded: { [weak self] provider in
                self?.presentKeyPrompt(for: provider, runCreateTitlesAfterSave: true)
            },
            onSuccess: { [weak self] in
                self?.isShowingExportPreview = false
                self?.isShowingGeneratedTitles = true
            }
        )
        if isAIAutoRunInProgress && !isShowingGeneratedTitles {
            resetAIAutoRunState()
        }
    }

    func createThumbnailForLatestExport() async {
        guard let fileURL = exportPreviewURL ?? lastSavedFileURL else {
            statusMessage = text(
                "No exported video is ready for a thumbnail yet.",
                "មិនទាន់មានវីដេអូ export សម្រាប់បង្កើត thumbnail នៅឡើយ។"
            )
            return
        }

        await generateThumbnail(for: fileURL, regenerate: false)
    }

    func createThumbnailForCurrentEditorVideo() async {
        guard !isDownloading && !isMerging && !isConverting && !isCapturingPhoto && !isGeneratingTitles && !isGeneratingPrompt && !isGeneratingThumbnail else {
            statusMessage = text("Wait for the current task to finish first.", "សូមរង់ចាំឲ្យ task បច្ចុប្បន្នចប់សិន។")
            return
        }

        guard let fileURL = editorVideoURL ?? selectedClip?.fileURL else {
            statusMessage = text(
                "No Reels clip is ready for an AI photo yet.",
                "មិនទាន់មាន Reels clip សម្រាប់ AI photo នៅឡើយ។"
            )
            return
        }

        await generateThumbnail(for: fileURL, regenerate: false)
    }

    func createThumbnailForAIChatDraftVideo() async {
        guard !isDownloading && !isMerging && !isConverting && !isCapturingPhoto && !isGeneratingTitles && !isGeneratingPrompt && !isGeneratingThumbnail else {
            statusMessage = text("Wait for the current task to finish first.", "សូមរង់ចាំឲ្យ task បច្ចុប្បន្នចប់សិន។")
            return
        }

        guard let videoAttachment = aiChatDraftAttachments.first(where: { $0.kind == .video }) else {
            statusMessage = text(
                "Add one video first, then tap Create Thumbnail.",
                "សូមបន្ថែម video មួយសិន បន្ទាប់មកចុច Create Thumbnail។"
            )
            return
        }

        await generateThumbnail(for: videoAttachment.url, regenerate: false)
    }

    func createThumbnailAgain() async {
        guard let fileURL = generatedThumbnailSourceURL ?? exportPreviewURL ?? lastSavedFileURL else {
            statusMessage = text(
                "No exported video is ready for another thumbnail yet.",
                "មិនទាន់មានវីដេអូ export សម្រាប់បង្កើត thumbnail ម្ដងទៀតនៅឡើយ។"
            )
            return
        }

        await generateThumbnail(for: fileURL, regenerate: true)
    }

    func createTitlesForCurrentEditorVideo() async {
        guard let fileURL = promptInputVideoURL else {
            statusMessage = text(
                "No prompt video is ready for titles yet.",
                "មិនទាន់មានវីដេអូក្នុងប្រអប់ Prompt សម្រាប់ titles នៅឡើយ។"
            )
            return
        }

        guard !isDownloading && !isMerging && !isConverting && !isCapturingPhoto && !isGeneratingPrompt else {
            statusMessage = text("Wait for the current task to finish first.", "សូមរង់ចាំឲ្យ task បច្ចុប្បន្នចប់សិន។")
            return
        }

        generatedTitlesSourceURL = fileURL
        generatedTitlesSourceName = promptInputVideoTitle.isEmpty
            ? displayName(for: fileURL)
            : promptInputVideoTitle
        await generateTitles(
            for: fileURL,
            isPromptVideo: true,
            presentKeyPromptIfNeeded: { [weak self] provider in
                self?.presentKeyPrompt(
                    for: provider,
                    runCreateTitlesAfterSave: false,
                    runCreateEditorTitlesAfterSave: true
                )
            },
            onSuccess: { [weak self] in
                self?.isShowingGeneratedTitles = true
            }
        )
    }

    func createPromptForCurrentEditorVideo() async {
        guard !isDownloading && !isMerging && !isConverting && !isCapturingPhoto && !isGeneratingTitles else {
            statusMessage = text("Wait for the current task to finish first.", "សូមរង់ចាំឲ្យ task បច្ចុប្បន្នចប់សិន។")
            return
        }

        let source: (url: URL, name: String, clipCount: Int)
        do {
            source = try await makePromptSource()
        } catch {
            statusMessage = text(
                "No prompt video is ready for an AI prompt yet.",
                "មិនទាន់មានវីដេអូក្នុងប្រអប់ Prompt សម្រាប់ AI prompt នៅឡើយ។"
            )
            return
        }

        await createPrompt(for: source)
    }

    func createPromptForLatestExport() async {
        guard !isDownloading && !isMerging && !isConverting && !isCapturingPhoto && !isGeneratingTitles else {
            statusMessage = text("Wait for the current task to finish first.", "សូមរង់ចាំឲ្យ task បច្ចុប្បន្នចប់សិន។")
            return
        }

        guard let fileURL = exportPreviewURL ?? lastSavedFileURL else {
            statusMessage = text(
                "No exported video is ready for an AI prompt yet.",
                "មិនទាន់មានវីដេអូ export សម្រាប់ AI prompt នៅឡើយ។"
            )
            return
        }

        let source = (
            url: fileURL,
            name: displayName(for: fileURL),
            clipCount: 1
        )
        await createPrompt(for: source)
    }

    func copyGeneratedTitlesToClipboard() async {
        guard !generatedTitlesText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusMessage = text("No titles are ready to copy yet.", "មិនទាន់មានចំណងជើងសម្រាប់ចម្លងនៅឡើយ។")
            return
        }

        let shouldClearReelsVideoAfterCopy =
            generatedTitlesSourceURL != nil &&
            generatedTitlesSourceURL != promptInputVideoURL

        UIPasteboard.general.string = generatedTitlesText
        await recordGeneratedTitlesToHistory(generatedTitlesText)
        dismissGeneratedTitles()
        if shouldClearReelsVideoAfterCopy {
            clearReelsEditorAfterTitleCopy()
        }
        if isAIAutoRunInProgress {
            completeAIAutoRun()
        }
        statusMessage = text(
            shouldClearReelsVideoAfterCopy
                ? "Titles copied to the clipboard. Reels video was cleared."
                : "Titles copied to the clipboard.",
            shouldClearReelsVideoAfterCopy
                ? "បានចម្លងចំណងជើងទៅ clipboard ហើយ។ វីដេអូក្នុង Reels ត្រូវបានសម្អាតហើយ។"
                : "បានចម្លងចំណងជើងទៅ clipboard ហើយ។"
        )
    }

    func copyAllGeneratedTitlesToClipboard() {
        let combinedTitles = generatedTitlesHistory
            .map(\.text)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")

        guard !combinedTitles.isEmpty else {
            statusMessage = text(
                "No titles are ready to copy yet.",
                "មិនទាន់មានចំណងជើងសម្រាប់ចម្លងនៅឡើយ។"
            )
            return
        }

        UIPasteboard.general.string = combinedTitles
        statusMessage = text(
            "All saved titles copied to the clipboard.",
            "បានចម្លង titles ទាំងអស់ទៅ clipboard ហើយ។"
        )
    }

    func copyGeneratedTitleHistoryEntryToClipboard(_ entry: GeneratedHistoryEntry) {
        UIPasteboard.general.string = entry.text
        statusMessage = text(
            "Title copied to the clipboard.",
            "បានចម្លង title ទៅ clipboard ហើយ។"
        )
    }

    func moveGeneratedTitleHistoryEntryToTrash(_ entry: GeneratedHistoryEntry) {
        generatedTitlesHistory.removeAll { $0.id == entry.id }
        trashedGeneratedTitlesHistory.insert(entry, at: 0)
        persistHistories()
        statusMessage = text(
            "Title moved to trash.",
            "បានផ្លាស់ទី title ទៅធុងសម្រាម។"
        )
    }

    func restoreGeneratedTitleHistoryEntry(_ entry: GeneratedHistoryEntry) {
        trashedGeneratedTitlesHistory.removeAll { $0.id == entry.id }
        generatedTitlesHistory.insert(entry, at: 0)
        persistHistories()
        statusMessage = text(
            "Title restored from trash.",
            "បានស្តារ title ពីធុងសម្រាម។"
        )
    }

    func copyAllGeneratedPromptsToClipboard() {
        let combinedPrompts = generatedPromptsHistory
            .map(\.text)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")

        guard !combinedPrompts.isEmpty else {
            statusMessage = text(
                "No prompts are ready to copy yet.",
                "មិនទាន់មាន prompts សម្រាប់ចម្លងនៅឡើយ។"
            )
            return
        }

        UIPasteboard.general.string = combinedPrompts
        statusMessage = text(
            "All saved prompts copied to the clipboard.",
            "បានចម្លង prompts ទាំងអស់ទៅ clipboard ហើយ។"
        )
    }

    func copyGeneratedPromptHistoryEntryToClipboard(_ entry: GeneratedHistoryEntry) {
        UIPasteboard.general.string = entry.text
        statusMessage = text(
            "Prompt copied to the clipboard.",
            "បានចម្លង prompt ទៅ clipboard ហើយ។"
        )
    }

    func moveGeneratedPromptHistoryEntryToTrash(_ entry: GeneratedHistoryEntry) {
        generatedPromptsHistory.removeAll { $0.id == entry.id }
        trashedGeneratedPromptsHistory.insert(entry, at: 0)
        persistHistories()
        statusMessage = text(
            "Prompt moved to trash.",
            "បានផ្លាស់ទី prompt ទៅធុងសម្រាម។"
        )
    }

    func restoreGeneratedPromptHistoryEntry(_ entry: GeneratedHistoryEntry) {
        trashedGeneratedPromptsHistory.removeAll { $0.id == entry.id }
        generatedPromptsHistory.insert(entry, at: 0)
        persistHistories()
        statusMessage = text(
            "Prompt restored from trash.",
            "បានស្តារ prompt ពីធុងសម្រាម។"
        )
    }

    func copyGeneratedPromptToClipboard() async {
        guard !generatedPromptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusMessage = text("No AI prompt is ready to copy yet.", "មិនទាន់មាន AI prompt សម្រាប់ចម្លងនៅឡើយ។")
            return
        }

        UIPasteboard.general.string = generatedPromptText
        await recordGeneratedPromptToHistory(generatedPromptText)
        statusMessage = text(
            "AI prompt copied to the clipboard.",
            "បានចម្លង AI prompt ទៅ clipboard ហើយ។"
        )
    }

    func importVideoForEditing(from sourceURL: URL) async {
        guard !isBusy else {
            statusMessage = "Wait for the current task to finish first."
            return
        }

        let startedAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if startedAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let destinationURL = try makeImportedVideoDestinationURL(for: sourceURL)

            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }

            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            let clip = makeClip(for: destinationURL)
            setEditorClips([clip], selectedClipID: clip.id)
            statusMessage = """
            Input video ready: \(displayName(for: destinationURL))
            You can now play, cut photo, or convert this video.
            """
        } catch {
            statusMessage = "Input video failed: \(error.localizedDescription)"
        }
    }

    func capturePhotoFromLatestVideo(at seconds: Double) async {
        guard !isBusy else {
            statusMessage = "Wait for the current task to finish first."
            return
        }

        guard let sourceURL = editorVideoURL else {
            statusMessage = "Download one video first, then cut a photo from it."
            return
        }

        isCapturingPhoto = true
        let clampedSeconds = max(seconds, 0)
        statusMessage = "Cutting photo from video at \(Self.playbackTimestamp(clampedSeconds))..."

        do {
            let imageData = try await ReelsVideoExporter.capturePhotoData(sourceURL: sourceURL, at: clampedSeconds)
            let destinationURL = try makeImageDestinationURL(for: sourceURL, seconds: clampedSeconds)
            try imageData.write(to: destinationURL, options: .atomic)
            photoPreviewURL = destinationURL
            isShowingPhotoPreview = true
            lastSavedFileURL = destinationURL
            statusMessage = """
            Photo cut ready: \(displayName(for: destinationURL))
            Frame time: \(Self.playbackTimestamp(clampedSeconds))
            Edit, save, or share it from the popup.
            """
        } catch {
            statusMessage = "Cut photo failed: \(error.localizedDescription)"
        }

        isCapturingPhoto = false
    }

    func moveClipEarlier(_ clip: EditorClip) async {
        guard !isBusy else {
            statusMessage = "Wait for the current task to finish first."
            return
        }

        guard let index = editorClips.firstIndex(of: clip), index > 0 else {
            return
        }

        var updatedClips = editorClips
        updatedClips.swapAt(index, index - 1)
        setEditorClips(updatedClips, selectedClipID: clip.id)
        statusMessage = "Clip moved earlier."
    }

    func moveClipLater(_ clip: EditorClip) async {
        guard !isBusy else {
            statusMessage = "Wait for the current task to finish first."
            return
        }

        guard let index = editorClips.firstIndex(of: clip), index < editorClips.count - 1 else {
            return
        }

        var updatedClips = editorClips
        updatedClips.swapAt(index, index + 1)
        setEditorClips(updatedClips, selectedClipID: clip.id)
        statusMessage = "Clip moved later."
    }

    func removeClip(_ clip: EditorClip) async {
        guard !isBusy else {
            statusMessage = "Wait for the current task to finish first."
            return
        }

        guard let index = editorClips.firstIndex(of: clip) else {
            return
        }

        var updatedClips = editorClips
        updatedClips.remove(at: index)

        if updatedClips.isEmpty {
            editorClips = []
            selectedClipID = nil
            editorClipCount = 0
            editorVideoURL = nil
            statusMessage = "No clips left. Add clips again."
        } else {
            let nextSelectedID = updatedClips[min(index, updatedClips.count - 1)].id
            setEditorClips(updatedClips, selectedClipID: nextSelectedID)
            statusMessage = updatedClips.count > 1
                ? "Clip removed. Timeline updated."
                : "One clip left. You can preview and convert it now."
        }
    }

    func clearAllEditorClips() {
        guard !isBusy else {
            statusMessage = "Wait for the current task to finish first."
            return
        }

        editorClips = []
        selectedClipID = nil
        editorClipCount = 0
        editorVideoURL = nil
        statusMessage = "All clips cleared. Add clips again."
    }

    func selectClip(_ clipID: EditorClip.ID?) {
        guard let clipID else { return }
        guard clipID != selectedClipID else { return }
        setEditorClips(editorClips, selectedClipID: clipID)
    }

    func moveClip(from sourceID: EditorClip.ID, to targetID: EditorClip.ID) {
        guard sourceID != targetID,
              let sourceIndex = editorClips.firstIndex(where: { $0.id == sourceID }),
              let targetIndex = editorClips.firstIndex(where: { $0.id == targetID }) else {
            return
        }

        var updatedClips = editorClips
        let movedClip = updatedClips.remove(at: sourceIndex)
        updatedClips.insert(movedClip, at: targetIndex)
        setEditorClips(updatedClips, selectedClipID: movedClip.id)
        statusMessage = "Clip order updated."
    }

    func updateSelectedClipSettings(_ settings: ReelsEditorSettings) {
        guard let selectedClipID,
              let index = editorClips.firstIndex(where: { $0.id == selectedClipID }) else {
            return
        }

        guard editorClips[index].settings != settings else {
            return
        }

        editorClips[index].settings = settings
    }

    private func enqueueDownloadInputEntries(
        _ entries: [DownloadInputEntry],
        allowingCompletedIDs: Bool = false
    ) -> DownloadEnqueueResult {
        var result = DownloadEnqueueResult()

        for entry in entries {
            let normalizedID = entry.videoID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedID.isEmpty else { continue }

            if containsQueuedOrSavedVideo(
                normalizedID,
                sourceKind: entry.sourceKind,
                allowingCompletedIDs: allowingCompletedIDs
            ) {
                if isCompletedDownloadedVideo(normalizedID) {
                    if allowingCompletedIDs {
                        result.reactivatedCompleted.append(normalizedID)
                    } else {
                        result.blockedCompleted.append(normalizedID)
                    }
                } else {
                    result.duplicates.append(normalizedID)
                }
                continue
            }

            downloadQueue.append(
                DownloadQueueItem(
                    videoID: normalizedID,
                    sourceInput: entry.sourceInput,
                    sourceKind: entry.sourceKind
                )
            )
            result.added.append(normalizedID)
        }

        return result
    }

    private func containsQueuedOrSavedVideo(
        _ videoID: String,
        sourceKind: DownloadSourceKind,
        allowingCompletedIDs: Bool = false
    ) -> Bool {
        if downloadQueue.contains(where: {
            $0.sourceKind == sourceKind && $0.videoID.caseInsensitiveCompare(videoID) == .orderedSame
        }) {
            return true
        }

        if isCompletedDownloadedVideo(videoID) {
            return !allowingCompletedIDs
        }

        guard sourceKind == .sora else { return false }
        guard let directoryURL = try? downloadsDirectoryURL() else { return false }
        let exactURL = directoryURL.appendingPathComponent(SoraVideoLink.fileName(for: videoID))
        if FileManager.default.fileExists(atPath: exactURL.path) {
            return !allowingCompletedIDs
        }
        return false
    }

    private func downloadQueuedVideo(videoID: String) async throws {
        guard let queueItem = downloadQueue.first(where: { $0.videoID.caseInsensitiveCompare(videoID) == .orderedSame }) else {
            throw SoraDownloadError.invalidResponse
        }

        markDownloadQueueItem(videoID: videoID, state: .downloading, progress: 0, errorMessage: nil)
        statusMessage = text("Downloading \(queueItem.displayTitle)...", "កំពុងទាញយក \(queueItem.displayTitle)...")

        do {
            switch queueItem.sourceKind {
            case .sora:
                try await downloadQueuedSoraVideo(queueItem)
            case .facebook:
                try await downloadQueuedFacebookVideo(queueItem)
            }
        } catch {
            downloadProgress = 0
            markDownloadQueueItem(videoID: videoID, state: .failed, progress: 0, errorMessage: error.localizedDescription)
            statusMessage = text("Download failed: \(error.localizedDescription)", "ទាញយកបរាជ័យ៖ \(error.localizedDescription)")
            throw error
        }
    }

    private func downloadQueuedSoraVideo(_ queueItem: DownloadQueueItem) async throws {
        let videoID = queueItem.videoID
        let candidateURLs = SoraVideoLink.downloadURLCandidates(for: videoID)
        let (temporaryURL, _, successfulURL) = try await downloadFromAvailableSources(
            candidateURLs,
            videoID: queueItem.displayTitle
        )

        let destinationURL = try makeDestinationURL(for: videoID)
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        try FileManager.default.copyItem(at: temporaryURL, to: destinationURL)
        if FileManager.default.fileExists(atPath: temporaryURL.path) {
            try? FileManager.default.removeItem(at: temporaryURL)
        }

        let clip = makeClip(for: destinationURL)
        let updatedClips = currentEditorClips() + [clip]
        setEditorClips(updatedClips, selectedClipID: clip.id)
        downloadProgress = 1

        if downloadAutoSavesToPhotos {
            _ = await saveVideoToPhotos(from: destinationURL)
        }

        completedDownloadIDs.insert(videoID.lowercased())
        persistCompletedDownloadIDs()
        markDownloadQueueItem(videoID: videoID, state: .completed, progress: 1, errorMessage: nil)
        let hostLabel = successfulURL.host ?? successfulURL.absoluteString
        statusMessage = text(
            "Downloaded \(queueItem.displayTitle) via \(hostLabel).",
            "បានទាញយក \(queueItem.displayTitle) តាម \(hostLabel) ហើយ។"
        )
    }

    private func downloadQueuedFacebookVideo(_ queueItem: DownloadQueueItem) async throws {
        let resolved = try await resolveFacebookDownloadCandidates(for: queueItem.sourceInput)
        let (temporaryURL, _, successfulURL) = try await downloadFromAvailableSources(
            resolved.urls,
            videoID: queueItem.displayTitle
        )

        let destinationURL = try makeFacebookDestinationURL(
            preferredFileName: resolved.preferredFilename,
            fallbackKey: queueItem.videoID
        )
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        try FileManager.default.copyItem(at: temporaryURL, to: destinationURL)
        if FileManager.default.fileExists(atPath: temporaryURL.path) {
            try? FileManager.default.removeItem(at: temporaryURL)
        }

        _ = await saveVideoToPhotos(from: destinationURL)
        downloadProgress = 1
        completedDownloadIDs.insert(queueItem.videoID.lowercased())
        persistCompletedDownloadIDs()
        markDownloadQueueItem(videoID: queueItem.videoID, state: .completed, progress: 1, errorMessage: nil)
        let hostLabel = successfulURL.host ?? successfulURL.absoluteString
        statusMessage = text(
            "Facebook video saved to Photos via \(hostLabel).",
            "វីដេអូ Facebook ត្រូវបានរក្សាទុកទៅ Photos តាម \(hostLabel) ហើយ។"
        )
    }

    private func downloadFromAvailableSources(_ urls: [URL], videoID: String) async throws -> (URL, URLResponse, URL) {
        var lastError: Error?

        for (index, url) in urls.enumerated() {
            var request = URLRequest(url: url)
            request.timeoutInterval = index == 0 ? 20 : 45

            if index > 0 {
                let hostLabel = url.host ?? url.absoluteString
                statusMessage = text(
                    "Primary download failed. Switching to \(hostLabel) for \(videoID)...",
                    "Download ដើមបរាជ័យ។ កំពុងប្ដូរទៅ \(hostLabel) សម្រាប់ \(videoID)..."
                )
            }

            do {
                let (temporaryURL, response) = try await downloadFile(with: request, videoID: videoID)
                try validate(response: response)
                return (temporaryURL, response, url)
            } catch {
                lastError = error

                if case let SoraDownloadError.httpStatus(statusCode) = error,
                   statusCode == 404 || statusCode == 410 {
                    continue
                }

                if index < urls.count - 1 {
                    continue
                }
            }
        }

        throw lastError ?? SoraDownloadError.invalidResponse
    }

    private func markDownloadQueueItem(
        videoID: String,
        state: DownloadQueueState,
        progress: Double? = nil,
        errorMessage: String? = nil
    ) {
        guard let index = downloadQueue.firstIndex(where: { $0.videoID.caseInsensitiveCompare(videoID) == .orderedSame }) else {
            return
        }

        downloadQueue[index].state = state
        if let progress {
            downloadQueue[index].progress = min(max(progress, 0), 1)
        }
        downloadQueue[index].errorMessage = errorMessage
        refreshAggregateDownloadProgress()
    }

    private func refreshAggregateDownloadProgress() {
        let visibleItems = downloadQueue.filter {
            $0.state == .queued || $0.state == .downloading || $0.state == .completed || $0.state == .failed
        }

        guard !visibleItems.isEmpty else {
            downloadProgress = 0
            return
        }

        let combinedProgress = visibleItems.reduce(0.0) { partialResult, item in
            switch item.state {
            case .completed, .failed:
                return partialResult + 1
            case .queued:
                return partialResult
            case .downloading:
                return partialResult + item.progress
            }
        }

        downloadProgress = min(max(combinedProgress / Double(visibleItems.count), 0), 1)
    }

    private func activeDownloadSourceInputText() -> String {
        let visibleSources = downloadQueue
            .filter { $0.state != .completed }
            .map(\.sourceInput)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        return deduplicatedSourceInputText(from: visibleSources)
    }

    private func failedDownloadSourceInputText() -> String {
        let failedSources = downloadQueue
            .filter { $0.state == .failed }
            .map(\.sourceInput)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        return deduplicatedSourceInputText(from: failedSources)
    }

    private func deduplicatedSourceInputText(from sources: [String]) -> String {
        var seen = Set<String>()
        var ordered: [String] = []

        for source in sources {
            let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { continue }
            ordered.append(trimmed)
        }

        return ordered.joined(separator: "\n")
    }

    private func deduplicatedSoraVideoIDs(from entries: [DownloadInputEntry]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []

        for entry in entries {
            guard entry.sourceKind == .sora else { continue }
            let trimmed = entry.videoID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { continue }
            ordered.append(trimmed)
        }

        return ordered
    }

    private func macControlCommand(for videoIDs: [String]) -> String {
        let dashboardStatusURL = "http://127.0.0.1:8765/status"

        let idArguments = videoIDs
            .map(shellSingleQuoted)
            .joined(separator: " ")

        return """
        SUITE_DIR="${SORANIN_CONTROL_SUITE_DIR:-$HOME/Downloads/SoraninControlSuite}"
        SCRIPTS_DIR="${SORANIN_SCRIPTS_DIR:-$SUITE_DIR/scripts}"
        ROOT_DIR="${SORANIN_PACKAGES_ROOT:-${SORANIN_ROOT_DIR:-$HOME/Downloads/Soranin}}"
        if [ ! -f "$SCRIPTS_DIR/sora_downloader.py" ] && [ -f "$HOME/Downloads/sora_downloader.py" ]; then
          SCRIPTS_DIR="$HOME/Downloads"
        fi
        if [ ! -d "$ROOT_DIR" ]; then
          ROOT_DIR="$HOME/.soranin/Soranin"
        fi
        cd "$HOME"
        if curl -fsS \(shellSingleQuoted(dashboardStatusURL)) >/dev/null; then
          echo "Mac app check: online"
        else
          echo "Mac app check: offline (optional dashboard)."
        fi
        python3 "$SCRIPTS_DIR/sora_downloader.py" "$ROOT_DIR" \(idArguments)
        python3 "$SCRIPTS_DIR/fast_reels_batch.py" "$ROOT_DIR"
        """
    }

    private func persistMacControlServerURL(_ value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            return
        }
        UserDefaults.standard.set(trimmed, forKey: Self.macControlServerURLDefaultsKey)
    }

    private func macControlBaseURLCandidates(preferredServerURL: String? = nil) -> [URL] {
        var rawValues: [String] = []
        if let preferred = preferredServerURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           !preferred.isEmpty {
            rawValues.append(preferred)
        }
        if let saved = UserDefaults.standard.string(forKey: Self.macControlServerURLDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !saved.isEmpty {
            rawValues.append(saved)
        }
        rawValues.append("http://127.0.0.1:8765")
        rawValues.append("http://localhost:8765")

        var urls: [URL] = []
        var seen = Set<String>()
        for raw in rawValues {
            guard let url = URL(string: raw) else { continue }
            let key = url.absoluteString.lowercased()
            guard seen.insert(key).inserted else { continue }
            urls.append(url)
        }
        return urls
    }

    private func sendVideoIDsToMacController(
        _ videoIDs: [String],
        preferredServerURL: String? = nil
    ) async -> (ok: Bool, message: String?) {
        let payload: [String: Any] = [
            "video_ids": videoIDs
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            return (false, text("Could not create request payload.", "មិនអាចបង្កើត payload សម្រាប់ request បានទេ។"))
        }

        var lastErrorMessage: String?

        for baseURL in macControlBaseURLCandidates(preferredServerURL: preferredServerURL) {
            let endpoint = baseURL.appending(path: "remote-run")
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = 45
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    lastErrorMessage = text("Mac server response is invalid.", "Response ពី Mac server មិនត្រឹមត្រូវ។")
                    continue
                }

                let envelope = try? JSONDecoder().decode(MacRemoteRunResponse.self, from: data)
                if (200 ... 299).contains(httpResponse.statusCode) {
                    if envelope?.ok == false {
                        let message = envelope?.message?.trimmingCharacters(in: .whitespacesAndNewlines)
                        lastErrorMessage = message?.isEmpty == false
                            ? message
                            : text("Mac server rejected this request.", "Mac server មិនទទួលយក request នេះទេ។")
                        continue
                    }
                    persistMacControlServerURL(baseURL.absoluteString)
                    let message = envelope?.message?.trimmingCharacters(in: .whitespacesAndNewlines)
                    return (true, message?.isEmpty == false ? message : text("Sent to Mac controller.", "បានផ្ញើទៅ Mac controller ហើយ។"))
                }

                if let message = envelope?.message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
                    lastErrorMessage = message
                } else {
                    lastErrorMessage = text(
                        "Mac server returned HTTP \(httpResponse.statusCode).",
                        "Mac server ត្រឡប់ HTTP \(httpResponse.statusCode)។"
                    )
                }
            } catch {
                lastErrorMessage = text(
                    "Cannot connect to \(baseURL.absoluteString).",
                    "មិនអាចភ្ជាប់ទៅ \(baseURL.absoluteString) បានទេ។"
                )
            }
        }

        return (false, lastErrorMessage)
    }

    func loadMacControlBootstrap(
        preferredServerURL: String,
        chromeName: String = "",
        pageName: String = ""
    ) async -> (ok: Bool, message: String, profiles: [String], summary: String) {
        var lastErrorMessage = text(
            "Could not reach the Mac controller server.",
            "មិនអាចភ្ជាប់ទៅ Mac controller server បានទេ។"
        )

        for baseURL in macControlBaseURLCandidates(preferredServerURL: preferredServerURL) {
            var components = URLComponents(url: baseURL.appending(path: "facebook-post-bootstrap"), resolvingAgainstBaseURL: false)
            var items: [URLQueryItem] = []
            if !chromeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                items.append(URLQueryItem(name: "chrome_name", value: chromeName))
            }
            if !pageName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                items.append(URLQueryItem(name: "page_name", value: pageName))
            }
            if !items.isEmpty {
                components?.queryItems = items
            }
            guard let endpoint = components?.url else {
                continue
            }

            var request = URLRequest(url: endpoint)
            request.httpMethod = "GET"
            request.timeoutInterval = 20

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    lastErrorMessage = text("Mac server response is invalid.", "Response ពី Mac server មិនត្រឹមត្រូវ។")
                    continue
                }

                let envelope = try? JSONDecoder().decode(MacControlBootstrapResponse.self, from: data)
                if (200 ... 299).contains(httpResponse.statusCode), envelope?.ok != false {
                    persistMacControlServerURL(baseURL.absoluteString)
                    let profiles = envelope?.profiles ?? []
                    let summary = envelope?.memorySummary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let message = envelope?.message?.trimmingCharacters(in: .whitespacesAndNewlines)
                    return (
                        true,
                        message?.isEmpty == false
                            ? message!
                            : text("Mac control is ready.", "Mac control រួចរាល់ហើយ។"),
                        profiles,
                        summary
                    )
                }

                if let message = envelope?.message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
                    lastErrorMessage = message
                } else {
                    lastErrorMessage = text(
                        "Mac server returned HTTP \(httpResponse.statusCode).",
                        "Mac server ត្រឡប់ HTTP \(httpResponse.statusCode)។"
                    )
                }
            } catch {
                lastErrorMessage = text(
                    "Cannot connect to \(baseURL.absoluteString).",
                    "មិនអាចភ្ជាប់ទៅ \(baseURL.absoluteString) បានទេ។"
                )
            }
        }

        return (false, lastErrorMessage, [], "")
    }

    func preflightMacFacebookPost(
        preferredServerURL: String,
        chromeName: String,
        pageName: String,
        foldersText: String,
        intervalMinutes: Int,
        closeAfterEach: Bool,
        closeAfterFinish: Bool,
        postNowAdvanceSlot: Bool
    ) async -> (ok: Bool, message: String, summary: String) {
        let folders = foldersText
            .components(separatedBy: CharacterSet(charactersIn: ", \n\t"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !chromeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (false, text("Add Chrome Name first.", "សូមដាក់ Chrome Name ជាមុនសិន។"), "")
        }
        guard !pageName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (false, text("Add Page first.", "សូមដាក់ Page ជាមុនសិន។"), "")
        }
        guard !folders.isEmpty else {
            return (false, text("Add at least one folder first.", "សូមដាក់ folder យ៉ាងហោចណាស់ 1 ជាមុនសិន។"), "")
        }

        let payload: [String: Any] = [
            "chrome_name": chromeName,
            "page_name": pageName,
            "folders": folders,
            "interval_minutes": max(intervalMinutes, 1),
            "close_after_each": closeAfterEach,
            "close_after_finish": closeAfterFinish,
            "post_now_advance_slot": postNowAdvanceSlot,
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            return (false, text("Could not create request payload.", "មិនអាចបង្កើត payload សម្រាប់ request បានទេ។"), "")
        }

        var lastErrorMessage = text(
            "Could not reach the Mac controller server.",
            "មិនអាចភ្ជាប់ទៅ Mac controller server បានទេ។"
        )

        for baseURL in macControlBaseURLCandidates(preferredServerURL: preferredServerURL) {
            let endpoint = baseURL.appending(path: "facebook-post-preflight")
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = 90
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    lastErrorMessage = text("Mac server response is invalid.", "Response ពី Mac server មិនត្រឹមត្រូវ។")
                    continue
                }

                let envelope = try? JSONDecoder().decode(MacFacebookPostResponse.self, from: data)
                if (200 ... 299).contains(httpResponse.statusCode), envelope?.ok != false {
                    persistMacControlServerURL(baseURL.absoluteString)
                    let summary = envelope?.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let message = envelope?.message?.trimmingCharacters(in: .whitespacesAndNewlines)
                    return (
                        true,
                        message?.isEmpty == false
                            ? message!
                            : text("Preflight finished.", "Preflight បានចប់ហើយ។"),
                        summary
                    )
                }

                if let message = envelope?.message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
                    lastErrorMessage = message
                } else {
                    lastErrorMessage = text(
                        "Mac server returned HTTP \(httpResponse.statusCode).",
                        "Mac server ត្រឡប់ HTTP \(httpResponse.statusCode)។"
                    )
                }
            } catch {
                lastErrorMessage = text(
                    "Cannot connect to \(baseURL.absoluteString).",
                    "មិនអាចភ្ជាប់ទៅ \(baseURL.absoluteString) បានទេ។"
                )
            }
        }

        return (false, lastErrorMessage, "")
    }

    func runMacFacebookPost(
        preferredServerURL: String,
        chromeName: String,
        pageName: String,
        foldersText: String,
        intervalMinutes: Int,
        closeAfterEach: Bool,
        closeAfterFinish: Bool,
        postNowAdvanceSlot: Bool
    ) async -> (ok: Bool, message: String) {
        let folders = foldersText
            .components(separatedBy: CharacterSet(charactersIn: ", \n\t"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !chromeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (false, text("Add Chrome Name first.", "សូមដាក់ Chrome Name ជាមុនសិន។"))
        }
        guard !pageName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (false, text("Add Page first.", "សូមដាក់ Page ជាមុនសិន។"))
        }
        guard !folders.isEmpty else {
            return (false, text("Add at least one folder first.", "សូមដាក់ folder យ៉ាងហោចណាស់ 1 ជាមុនសិន។"))
        }

        let payload: [String: Any] = [
            "chrome_name": chromeName,
            "page_name": pageName,
            "folders": folders,
            "interval_minutes": max(intervalMinutes, 1),
            "close_after_each": closeAfterEach,
            "close_after_finish": closeAfterFinish,
            "post_now_advance_slot": postNowAdvanceSlot,
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            return (false, text("Could not create request payload.", "មិនអាចបង្កើត payload សម្រាប់ request បានទេ។"))
        }

        var lastErrorMessage = text(
            "Could not reach the Mac controller server.",
            "មិនអាចភ្ជាប់ទៅ Mac controller server បានទេ។"
        )

        for baseURL in macControlBaseURLCandidates(preferredServerURL: preferredServerURL) {
            let endpoint = baseURL.appending(path: "facebook-post-run")
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = 45
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    lastErrorMessage = text("Mac server response is invalid.", "Response ពី Mac server មិនត្រឹមត្រូវ។")
                    continue
                }

                let envelope = try? JSONDecoder().decode(MacFacebookPostResponse.self, from: data)
                if (200 ... 299).contains(httpResponse.statusCode), envelope?.ok != false {
                    persistMacControlServerURL(baseURL.absoluteString)
                    let message = envelope?.message?.trimmingCharacters(in: .whitespacesAndNewlines)
                    return (
                        true,
                        message?.isEmpty == false
                            ? message!
                            : text("Facebook post job started on Mac.", "បានចាប់ផ្តើម Facebook post job លើ Mac ហើយ។")
                    )
                }

                if let message = envelope?.message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
                    lastErrorMessage = message
                } else {
                    lastErrorMessage = text(
                        "Mac server returned HTTP \(httpResponse.statusCode).",
                        "Mac server ត្រឡប់ HTTP \(httpResponse.statusCode)។"
                    )
                }
            } catch {
                lastErrorMessage = text(
                    "Cannot connect to \(baseURL.absoluteString).",
                    "មិនអាចភ្ជាប់ទៅ \(baseURL.absoluteString) បានទេ។"
                )
            }
        }

        return (false, lastErrorMessage)
    }

    func quitMacChrome(preferredServerURL: String) async -> (ok: Bool, message: String) {
        var lastErrorMessage = text(
            "Could not reach the Mac controller server.",
            "មិនអាចភ្ជាប់ទៅ Mac controller server បានទេ។"
        )

        for baseURL in macControlBaseURLCandidates(preferredServerURL: preferredServerURL) {
            let endpoint = baseURL.appending(path: "quit-chrome")
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = 20

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    lastErrorMessage = text("Mac server response is invalid.", "Response ពី Mac server មិនត្រឹមត្រូវ។")
                    continue
                }

                let envelope = try? JSONDecoder().decode(MacFacebookPostResponse.self, from: data)
                if (200 ... 299).contains(httpResponse.statusCode), envelope?.ok != false {
                    persistMacControlServerURL(baseURL.absoluteString)
                    let message = envelope?.message?.trimmingCharacters(in: .whitespacesAndNewlines)
                    return (
                        true,
                        message?.isEmpty == false
                            ? message!
                            : text("Google Chrome quit on Mac.", "បានបិទ Google Chrome លើ Mac ហើយ។")
                    )
                }

                if let message = envelope?.message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
                    lastErrorMessage = message
                } else {
                    lastErrorMessage = text(
                        "Mac server returned HTTP \(httpResponse.statusCode).",
                        "Mac server ត្រឡប់ HTTP \(httpResponse.statusCode)។"
                    )
                }
            } catch {
                lastErrorMessage = text(
                    "Cannot connect to \(baseURL.absoluteString).",
                    "មិនអាចភ្ជាប់ទៅ \(baseURL.absoluteString) បានទេ។"
                )
            }
        }

        return (false, lastErrorMessage)
    }

    private func resolveFacebookDownloadCandidates(for rawValue: String) async throws -> (urls: [URL], preferredFilename: String?) {
        let payload: [String: Any] = [
            "url": rawValue,
            "quality": "auto"
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            throw SoraDownloadError.invalidResponse
        }

        var lastError: String?
        let publicCandidates = [
            "https://soradown.online",
            "https://soravdl.com",
            "https://sora-license-server-op4k.onrender.com"
        ]
        var baseURLs: [URL] = []
        var seen = Set<String>()
        for raw in publicCandidates {
            guard let url = URL(string: raw) else { continue }
            let key = url.absoluteString.lowercased()
            guard seen.insert(key).inserted else { continue }
            baseURLs.append(url)
        }
        for url in macControlBaseURLCandidates() {
            let key = url.absoluteString.lowercased()
            guard seen.insert(key).inserted else { continue }
            baseURLs.append(url)
        }

        for baseURL in baseURLs {
            let endpoint = baseURL.appending(path: "facebook-resolve")
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = 45
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    lastError = text("Facebook resolver response is invalid.", "Response ពី Facebook resolver មិនត្រឹមត្រូវ។")
                    continue
                }

                let envelope = try JSONDecoder().decode(FacebookResolveResponse.self, from: data)
                if !(200 ... 299).contains(httpResponse.statusCode) || envelope.ok == false {
                    lastError = envelope.message?.trimmingCharacters(in: .whitespacesAndNewlines)
                    if lastError?.isEmpty != false {
                        lastError = text(
                            "Facebook resolver returned HTTP \(httpResponse.statusCode).",
                            "Facebook resolver ត្រឡប់ HTTP \(httpResponse.statusCode)។"
                        )
                    }
                    continue
                }

                let urls = (envelope.candidates ?? []).compactMap { candidate -> URL? in
                    guard let rawURL = candidate.url?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !rawURL.isEmpty else {
                        return nil
                    }
                    return URL(string: rawURL)
                }

                guard !urls.isEmpty else {
                    lastError = text("Facebook resolver returned no direct video URL.", "Facebook resolver មិនបានផ្ដល់ video URL ដោយផ្ទាល់ទេ។")
                    continue
                }

                return (
                    urls,
                    envelope.preferredFilename?.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            } catch {
                lastError = text(
                    "Cannot connect to \(baseURL.absoluteString).",
                    "មិនអាចភ្ជាប់ទៅ \(baseURL.absoluteString) បានទេ។"
                )
            }
        }

        throw NSError(
            domain: "soranin.facebook.resolve",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: lastError ?? text(
                    "Could not reach the Facebook resolver server.",
                    "មិនអាចភ្ជាប់ទៅ Facebook resolver server បានទេ។"
                )
            ]
        )
    }

    private func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func extractDownloadInputEntries(from text: String) -> [DownloadInputEntry] {
        var orderedEntries: [(Int, DownloadInputEntry)] = []

        orderedEntries += SoraVideoLink.extractVideoSources(from: text).map { source in
            (
                source.location,
                DownloadInputEntry(
                    videoID: source.videoID,
                    sourceInput: preservedSourceInput(
                        sourceText: source.sourceText,
                        location: source.location,
                        in: text
                    ),
                    sourceKind: .sora
                )
            )
        }

        orderedEntries += FacebookVideoLink.extractVideoSources(from: text).map { source in
            (
                source.location,
                DownloadInputEntry(
                    videoID: source.videoID,
                    sourceInput: preservedSourceInput(
                        sourceText: source.sourceText,
                        location: source.location,
                        in: text
                    ),
                    sourceKind: .facebook
                )
            )
        }

        guard !orderedEntries.isEmpty else { return [] }

        let sortedEntries = orderedEntries.sorted { lhs, rhs in
            if lhs.0 == rhs.0 {
                return lhs.1.videoID < rhs.1.videoID
            }
            return lhs.0 < rhs.0
        }

        var seenKeys = Set<String>()
        var uniqueEntries: [DownloadInputEntry] = []
        for (_, entry) in sortedEntries {
            let key = "\(entry.sourceKind.rawValue):\(entry.videoID.lowercased())"
            guard seenKeys.insert(key).inserted else { continue }
            uniqueEntries.append(entry)
        }

        return uniqueEntries
    }

    private func preservedSourceInput(sourceText: String, location: Int, in text: String) -> String {
        let nsText = text as NSString
        guard location >= 0, location < nsText.length else {
            return sourceText
        }

        let lineRange = nsText.lineRange(for: NSRange(location: location, length: 0))
        let lineText = nsText.substring(with: lineRange)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return lineText.isEmpty ? sourceText : lineText
    }

    private func messageForEnqueueResult(
        _ result: DownloadEnqueueResult,
        successSingular: String,
        successPlural: (Int) -> String
    ) -> String {
        if !result.reactivatedCompleted.isEmpty && result.added.count == result.reactivatedCompleted.count && result.duplicates.isEmpty {
            return result.reactivatedCompleted.count == 1
                ? text("Unlocked 1 completed URL for download again.", "បានបើក 1 URL ដែលធ្លាប់ទាញយករួច សម្រាប់ទាញយកម្តងទៀត។")
                : text("Unlocked \(result.reactivatedCompleted.count) completed URLs for download again.", "បានបើក URL ដែលធ្លាប់ទាញយករួច \(result.reactivatedCompleted.count) សម្រាប់ទាញយកម្តងទៀត។")
        }

        if !result.blockedCompleted.isEmpty && result.added.isEmpty && result.duplicates.isEmpty {
            return text(
                "This URL was already downloaded. Tap Paste 3 times within 15 seconds to unlock it.",
                "URL នេះបានទាញយករួចហើយ។ ចុច Paste 3 ដងក្នុង 15 វិនាទី ដើម្បីបើកវាឡើងវិញ។"
            )
        }

        if !result.added.isEmpty && result.duplicates.isEmpty {
            let successMessage = result.added.count == 1 ? successSingular : successPlural(result.added.count)
            if !result.blockedCompleted.isEmpty {
                return successMessage + "\n" + text(
                    "\(result.blockedCompleted.count) completed URLs stayed blocked.",
                    "URL ដែលបានទាញយករួច \(result.blockedCompleted.count) ត្រូវបានទុកបិទដដែល។"
                )
            }
            return successMessage
        }

        if result.added.isEmpty && !result.duplicates.isEmpty {
            let duplicateSummary = result.duplicates.count == 1
                ? text("This URL is already in the list.", "URL នេះមានក្នុងបញ្ជីរួចហើយ។")
                : text("\(result.duplicates.count) URLs are already in the list.", "URL ចំនួន \(result.duplicates.count) មានក្នុងបញ្ជីរួចហើយ។")
            return duplicateSummary
        }

        if !result.added.isEmpty && !result.duplicates.isEmpty {
            let base = text(
                "Added \(result.added.count). Skipped \(result.duplicates.count) duplicate URLs.",
                "បានបន្ថែម \(result.added.count)។ រំលង URL ស្ទួន \(result.duplicates.count)។"
            )
            if !result.blockedCompleted.isEmpty {
                return base + "\n" + text(
                    "\(result.blockedCompleted.count) completed URLs stayed blocked.",
                    "URL ដែលបានទាញយករួច \(result.blockedCompleted.count) ត្រូវបានទុកបិទដដែល។"
                )
            }
            return base
        }

        return text("No valid Sora or Facebook links were added.", "មិនមាន Sora ឬ Facebook link ត្រឹមត្រូវណាត្រូវបានបន្ថែមទេ។")
    }

    private func finalDownloadSummary(
        completedVideoIDs: [String],
        failedVideoIDs: [String],
        enqueueResult: DownloadEnqueueResult
    ) -> String {
        let duplicateCount = enqueueResult.duplicates.count

        if failedVideoIDs.isEmpty {
            let completionLine: String
            if completedVideoIDs.count == 1 {
                completionLine = text("1 video finished downloading.", "វីដេអូ 1 បានទាញយករួច។")
            } else {
                completionLine = text("\(completedVideoIDs.count) videos finished downloading.", "វីដេអូ \(completedVideoIDs.count) បានទាញយករួច។")
            }

            let facebookCount = completedVideoIDs.filter { $0.lowercased().hasPrefix("facebook_") }.count
            let soraCount = completedVideoIDs.count - facebookCount
            var saveLines: [String] = []
            if soraCount > 0 {
                saveLines.append(
                    downloadAutoSavesToPhotos
                        ? text("Sora videos were added to Photos and the clip timeline.", "វីដេអូ Sora ត្រូវបានបន្ថែមទៅ Photos និង clip timeline។")
                        : text("Sora videos were added to the clip timeline only.", "វីដេអូ Sora ត្រូវបានបន្ថែមតែទៅ clip timeline ប៉ុណ្ណោះ។")
                )
            }
            if facebookCount > 0 {
                saveLines.append(
                    text("Facebook videos were saved to Photos only.", "វីដេអូ Facebook ត្រូវបានរក្សាទុកទៅ Photos តែប៉ុណ្ណោះ។")
                )
            }
            let saveLine = saveLines.joined(separator: "\n")

            if duplicateCount > 0 {
                return """
                \(completionLine)
                \(saveLine)
                \(text("Skipped \(duplicateCount) duplicate URLs.", "បានរំលង URL ស្ទួន \(duplicateCount)។"))
                """
            }

            return """
            \(completionLine)
            \(saveLine)
            """
        }

        return """
        \(text("Downloaded \(completedVideoIDs.count) videos.", "បានទាញយកវីដេអូ \(completedVideoIDs.count)។"))
        \(text("Failed \(failedVideoIDs.count) videos.", "បរាជ័យវីដេអូ \(failedVideoIDs.count)។"))
        \(text("Failed URLs stay in the box for retry.", "URL ដែលបរាជ័យនៅសល់ក្នុងប្រអប់សម្រាប់ចុចម្តងទៀត។"))
        \(duplicateCount > 0 ? text("Skipped \(duplicateCount) duplicate URLs.", "បានរំលង URL ស្ទួន \(duplicateCount)។") : "")
        """
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isCompletedDownloadedVideo(_ videoID: String) -> Bool {
        if completedDownloadIDs.contains(videoID.lowercased()) {
            return true
        }

        if videoID.lowercased().hasPrefix("facebook_") {
            return false
        }

        guard let directoryURL = try? downloadsDirectoryURL() else { return false }
        let exactURL = directoryURL.appendingPathComponent(SoraVideoLink.fileName(for: videoID))
        return FileManager.default.fileExists(atPath: exactURL.path)
    }

    private func loadCompletedDownloadIDs() -> Set<String> {
        var ids = Set(
            (UserDefaults.standard.array(forKey: Self.completedDownloadIDsDefaultsKey) as? [String] ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )

        if let directoryURL = try? downloadsDirectoryURL(),
           let fileURLs = try? FileManager.default.contentsOfDirectory(
               at: directoryURL,
               includingPropertiesForKeys: nil,
               options: [.skipsHiddenFiles]
           ) {
            for fileURL in fileURLs where Self.supportedVideoExtensions.contains(fileURL.pathExtension.lowercased()) {
                let videoID = fileURL.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
                if !videoID.isEmpty {
                    ids.insert(videoID.lowercased())
                }
            }
        }

        return ids
    }

    private func persistCompletedDownloadIDs() {
        UserDefaults.standard.set(Array(completedDownloadIDs).sorted(), forKey: Self.completedDownloadIDsDefaultsKey)
    }

    private func shouldUnlockCompletedDownloadsFromClipboard() -> Bool {
        let now = Date()
        let cutoff = now.addingTimeInterval(-15)
        clipboardPasteTapDates = clipboardPasteTapDates.filter { $0 >= cutoff }
        clipboardPasteTapDates.append(now)
        if clipboardPasteTapDates.count >= 3 {
            clipboardPasteTapDates.removeAll()
            return true
        }
        return false
    }

    private func enqueueClipboardDownloadsForAutoStart(_ videoIDs: [String]) {
        guard !videoIDs.isEmpty else { return }
        var seen = Set(queuedClipboardDownloadIDs.map { $0.lowercased() })
        for videoID in videoIDs {
            let key = videoID.lowercased()
            guard !seen.contains(key) else { continue }
            queuedClipboardDownloadIDs.append(videoID)
            seen.insert(key)
        }
        queuedNextDownloadCount = queuedClipboardDownloadIDs.count
    }

    private func consumeQueuedClipboardDownloadIDs() -> [String] {
        guard !queuedClipboardDownloadIDs.isEmpty else { return [] }
        let availableQueuedIDs = Set(
            downloadQueue
                .filter { $0.state == .queued }
                .map { $0.videoID.lowercased() }
        )
        let next = queuedClipboardDownloadIDs.filter { availableQueuedIDs.contains($0.lowercased()) }
        queuedClipboardDownloadIDs.removeAll()
        queuedNextDownloadCount = 0
        return next
    }

    private func downloadFile(with request: URLRequest, videoID: String) async throws -> (URL, URLResponse) {
        let delegate = DownloadProgressDelegate { [weak self] progress in
            Task { @MainActor in
                guard let self else { return }
                self.downloadProgress = progress
                self.markDownloadQueueItem(videoID: videoID, state: .downloading, progress: progress, errorMessage: nil)
                self.statusMessage = self.text(
                    "Downloading \(videoID)... \(self.downloadPercentText)",
                    "កំពុងទាញយក \(videoID)... \(self.downloadPercentText)"
                )
            }
        }

        return try await delegate.download(with: request)
    }

    private func currentEditorClips() -> [EditorClip] { editorClips }

    private func importVideosAsClips(from sourceURLs: [URL]) throws -> [EditorClip] {
        try sourceURLs.filter { !$0.path.isEmpty }.map { sourceURL in
            let startedAccess = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if startedAccess {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            let destinationURL = try makeImportedVideoDestinationURL(for: sourceURL)

            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }

            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            return makeClip(for: destinationURL)
        }
    }

    private func setEditorClips(_ clips: [EditorClip], selectedClipID: EditorClip.ID?) {
        editorClips = clips
        editorClipCount = clips.count
        let activeClipID = selectedClipID ?? clips.first?.id
        self.selectedClipID = activeClipID
        editorVideoURL = clips.first(where: { $0.id == activeClipID })?.fileURL ?? clips.first?.fileURL
        if let editorVideoURL {
            lastSavedFileURL = editorVideoURL
        }
    }

    private func makeClip(for fileURL: URL) -> EditorClip {
        let asset = AVURLAsset(url: fileURL)
        let seconds = CMTimeGetSeconds(asset.duration)
        let safeDuration = seconds.isFinite ? max(seconds, 0) : 0
        return EditorClip(
            fileURL: fileURL,
            title: displayName(for: fileURL),
            duration: safeDuration
        )
    }

    func saveEditedPhotoToPhotos(from fileURL: URL) async {
        lastSavedFileURL = fileURL
        let saveMessage = await saveImageToPhotos(from: fileURL)
        statusMessage = """
        Photo ready: \(displayName(for: fileURL))
        \(saveMessage)
        """
    }

    private func handleCompletedExport(at outputURL: URL) async {
        conversionProgress = 1
        lastSavedFileURL = outputURL
        exportPreviewURL = outputURL
        let saveMessage = await saveVideoToPhotos(from: outputURL)
        exportPreviewPhotoSaveMessage = saveMessage
        exportPreviewAlreadySavedToPhotos = didSaveToPhotos(saveMessage)
        isShowingExportPreview = true

        statusMessage = """
        Convert done: \(displayName(for: outputURL))
        Facebook Reels 1080 x 1920 at \(selectedSpeed.label)
        \(saveMessage)
        Use the popup to create titles or share.
        """
    }

    private func didSaveToPhotos(_ message: String) -> Bool {
        let lowercased = message.lowercased()
        return lowercased.contains("saved to photos")
            && !lowercased.contains("files only")
            && !lowercased.contains("failed")
    }

    private func cleanupLocalExportFileIfNeeded(at fileURL: URL) {
        guard !editorClips.contains(where: { $0.fileURL == fileURL }) else { return }

        if FileManager.default.fileExists(atPath: fileURL.path) {
            try? FileManager.default.removeItem(at: fileURL)
        }

        if lastSavedFileURL == fileURL {
            lastSavedFileURL = nil
        }

        if exportPreviewURL == fileURL {
            exportPreviewURL = nil
        }

        exportPreviewAlreadySavedToPhotos = false
        exportPreviewPhotoSaveMessage = ""
        isShowingExportPreview = false
    }

    private func clearAllLocalMedia(statusMessage customStatusMessage: String = "All local video/media files were cleared when soranin closed.") {
        pendingCloseCleanup = false
        resetAIAutoRunState()
        dismissAIAutoDonePopup()
        queuedClipboardDownloadIDs.removeAll()
        clipboardPasteTapDates.removeAll()
        blockedCompletedDownloadCount = 0
        unlockedCompletedDownloadCount = 0
        queuedNextDownloadCount = 0
        lastDownloadSuccessCount = 0
        lastDownloadFailureCount = 0

        if let directoryURL = try? downloadsDirectoryURL(),
           let fileURLs = try? FileManager.default.contentsOfDirectory(
               at: directoryURL,
               includingPropertiesForKeys: nil,
               options: [.skipsHiddenFiles]
           ) {
            for fileURL in fileURLs {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }

        editorClips = []
        downloadQueue = []
        selectedClipID = nil
        editorClipCount = 0
        editorVideoURL = nil
        lastSavedFileURL = nil
        rawInput = ""
        downloadProgress = 0
        conversionProgress = 0
        selectedSpeed = .slow90
        exportPreviewURL = nil
        exportPreviewAlreadySavedToPhotos = false
        exportPreviewPhotoSaveMessage = ""
        generatedTitlesText = ""
        isShowingGeneratedTitles = false
        isGeneratingThumbnail = false
        thumbnailGenerationProgress = 0
        shouldConcealPastedDownloadInput = false
        generatedThumbnailImageURL = nil
        generatedThumbnailHeadline = ""
        generatedThumbnailReason = ""
        generatedThumbnailPhotoSaveMessage = ""
        generatedThumbnailSavedToPhotos = false
        isShowingGeneratedThumbnail = false
        isShowingTitlesHistory = false
        isGeneratingTitles = false
        generatedPromptText = ""
        isShowingGeneratedPrompt = false
        isShowingPromptHistory = false
        isGeneratingPrompt = false
        promptGenerationProgress = 0
        promptProgressTask?.cancel()
        promptProgressTask = nil
        thumbnailProgressTask?.cancel()
        thumbnailProgressTask = nil
        pendingPromptSourceURL = nil
        pendingPromptSourceName = ""
        pendingPromptSourceClipCount = 0
        promptInputVideoURL = nil
        promptInputVideoTitle = ""
        promptInputFramePreviewURL = nil
        generatedPromptSourceURL = nil
        generatedPromptSourceName = ""
        generatedPromptSourceClipCount = 0
        generatedTitlesSourceURL = nil
        generatedTitlesSourceName = ""
        generatedThumbnailSourceURL = nil
        generatedThumbnailSuggestion = nil
        generatedThumbnailVariationIndex = 0
        removePromptInputFramePreview()
        isShowingGoogleAIKeyPrompt = false
        googleAIKeyCheckMessage = ""
        isShowingOpenAIKeyPrompt = false
        openAIKeyCheckMessage = ""
        shouldCreateTitlesAfterSavingGoogleKey = false
        shouldCreateEditorTitlesAfterSavingGoogleKey = false
        shouldCreatePromptAfterSavingGoogleKey = false
        shouldCreateThumbnailAfterSavingGoogleKey = false
        shouldCreateTitlesAfterSavingKey = false
        shouldCreateEditorTitlesAfterSavingKey = false
        shouldCreatePromptAfterSavingKey = false
        isShowingExportPreview = false
        photoPreviewURL = nil
        isShowingPhotoPreview = false

        statusMessage = customStatusMessage
    }

    private func updateDownloadEnqueueBadges(from result: DownloadEnqueueResult) {
        blockedCompletedDownloadCount = result.blockedCompleted.count
        unlockedCompletedDownloadCount = result.reactivatedCompleted.count
    }

    private func resetDownloadRunSummary() {
        lastDownloadSuccessCount = 0
        lastDownloadFailureCount = 0
    }

    private func recordGeneratedTitlesToHistory(_ rawTitles: String) async {
        let trimmedTitles = rawTitles.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitles.isEmpty else { return }

        let sourceURL = generatedTitlesSourceURL ?? promptInputVideoURL ?? exportPreviewURL ?? lastSavedFileURL ?? editorVideoURL ?? selectedClip?.fileURL
        let thumbnailOverrideURL = sourceURL == promptInputVideoURL ? promptInputFramePreviewURL : nil
        let sourceName = !generatedTitlesSourceName.isEmpty
            ? generatedTitlesSourceName
            : sourceURL.map(displayName(for:)) ?? text("Exported video", "វីដេអូ export")
        let entry = await makeGeneratedHistoryEntry(
            text: trimmedTitles,
            sourceURL: sourceURL,
            sourceName: sourceName,
            thumbnailOverrideURL: thumbnailOverrideURL
        )

        if generatedTitlesHistory.first?.text == entry.text, generatedTitlesHistory.first?.sourceName == entry.sourceName {
            return
        }

        generatedTitlesHistory.insert(entry, at: 0)
        persistHistories()
    }

    private func recordGeneratedPromptToHistory(_ rawPrompt: String) async {
        let trimmedPrompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return }

        let sourceURL = generatedPromptSourceURL ?? promptInputVideoURL
        let thumbnailOverrideURL = sourceURL == promptInputVideoURL ? promptInputFramePreviewURL : nil
        let sourceName = !generatedPromptSourceName.isEmpty
            ? generatedPromptSourceName
            : sourceURL.map(displayName(for:)) ?? text("Prompt video", "វីដេអូសម្រាប់ Prompt")
        let entry = await makeGeneratedHistoryEntry(
            text: trimmedPrompt,
            sourceURL: sourceURL,
            sourceName: sourceName,
            thumbnailOverrideURL: thumbnailOverrideURL
        )

        if generatedPromptsHistory.first?.text == entry.text, generatedPromptsHistory.first?.sourceName == entry.sourceName {
            return
        }

        generatedPromptsHistory.insert(entry, at: 0)
        persistHistories()
    }

    private func startPromptProgressAnimation() {
        promptProgressTask?.cancel()
        promptGenerationProgress = 0.04
        promptProgressTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(140))
                if Task.isCancelled { break }
                let nextValue = min(self.promptGenerationProgress + 0.04, 0.92)
                self.promptGenerationProgress = nextValue
            }
        }
    }

    private func finishPromptProgressAnimation(success: Bool) async {
        promptProgressTask?.cancel()
        promptProgressTask = nil
        promptGenerationProgress = success ? 1 : 0
    }

    private func startThumbnailProgressAnimation() {
        thumbnailProgressTask?.cancel()
        thumbnailGenerationProgress = 0.06
        thumbnailProgressTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(160))
                if Task.isCancelled { break }
                let nextValue = min(self.thumbnailGenerationProgress + 0.035, 0.94)
                self.thumbnailGenerationProgress = nextValue
            }
        }
    }

    private func finishThumbnailProgressAnimation(success: Bool) async {
        thumbnailProgressTask?.cancel()
        thumbnailProgressTask = nil
        thumbnailGenerationProgress = success ? 1 : 0
    }

    private func createPrompt(for source: (url: URL, name: String, clipCount: Int)) async {
        pendingPromptSourceURL = source.url
        pendingPromptSourceName = source.name
        pendingPromptSourceClipCount = source.clipCount
        generatedPromptSourceURL = source.url
        generatedPromptSourceName = source.name
        generatedPromptSourceClipCount = source.clipCount
        generatedPromptText = ""
        isShowingGeneratedPrompt = false
        startPromptProgressAnimation()
        await generatePrompt(
            for: source,
            presentKeyPromptIfNeeded: { [weak self] provider in
                self?.presentKeyPrompt(
                    for: provider,
                    runCreateTitlesAfterSave: false,
                    runCreatePromptAfterSave: true
                )
            }
        )
    }

    private func resumePendingPromptCreation() async {
        guard let pendingPromptSourceURL else {
            await createPromptForCurrentEditorVideo()
            return
        }

        let source = (
            url: pendingPromptSourceURL,
            name: pendingPromptSourceName.isEmpty ? displayName(for: pendingPromptSourceURL) : pendingPromptSourceName,
            clipCount: max(pendingPromptSourceClipCount, 1)
        )
        await createPrompt(for: source)
    }

    private func makePromptSource() async throws -> (url: URL, name: String, clipCount: Int) {
        if let promptInputVideoURL {
            return (
                url: promptInputVideoURL,
                name: promptInputVideoTitle.isEmpty ? displayName(for: promptInputVideoURL) : promptInputVideoTitle,
                clipCount: 1
            )
        }

        throw NSError(domain: "soranin.prompt", code: 404)
    }

    private func makeGeneratedHistoryEntry(
        text: String,
        sourceURL: URL?,
        sourceName: String,
        thumbnailOverrideURL: URL? = nil
    ) async -> GeneratedHistoryEntry {
        let thumbnailFileName: String?

        if let thumbnailOverrideURL {
            thumbnailFileName = await copyHistoryThumbnailFileName(from: thumbnailOverrideURL)
        } else {
            thumbnailFileName = await makeHistoryThumbnailFileName(for: sourceURL)
        }

        return GeneratedHistoryEntry(
            text: text,
            sourceName: sourceName,
            thumbnailFileName: thumbnailFileName
        )
    }

    func historyThumbnailURL(for entry: GeneratedHistoryEntry) -> URL? {
        guard let thumbnailFileName = entry.thumbnailFileName else { return nil }
        return try? historyThumbnailsDirectoryURL().appendingPathComponent(thumbnailFileName)
    }

    private func loadPersistentHistories() {
        guard let historyFileURL = try? historiesFileURL(),
              let data = try? Data(contentsOf: historyFileURL),
              let snapshot = try? JSONDecoder().decode(PersistentHistorySnapshot.self, from: data) else {
            generatedTitlesHistory = []
            trashedGeneratedTitlesHistory = []
            generatedPromptsHistory = []
            trashedGeneratedPromptsHistory = []
            return
        }

        generatedTitlesHistory = snapshot.titles
        trashedGeneratedTitlesHistory = snapshot.trashedTitles
        generatedPromptsHistory = snapshot.prompts
        trashedGeneratedPromptsHistory = snapshot.trashedPrompts
    }

    private func persistHistories() {
        let snapshot = PersistentHistorySnapshot(
            titles: generatedTitlesHistory,
            trashedTitles: trashedGeneratedTitlesHistory,
            prompts: generatedPromptsHistory,
            trashedPrompts: trashedGeneratedPromptsHistory
        )

        guard let historyFileURL = try? historiesFileURL(),
              let data = try? JSONEncoder().encode(snapshot) else {
            return
        }

        try? data.write(to: historyFileURL, options: [.atomic])
    }

    private func historiesDirectoryURL() throws -> URL {
        let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directoryURL = appSupportURL.appendingPathComponent(Self.historiesFolderName, isDirectory: true)

        if !FileManager.default.fileExists(atPath: directoryURL.path) {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }

        return directoryURL
    }

    private func historiesFileURL() throws -> URL {
        try historiesDirectoryURL().appendingPathComponent(Self.historiesFileName)
    }

    private func historyThumbnailsDirectoryURL() throws -> URL {
        let directoryURL = try historiesDirectoryURL().appendingPathComponent(Self.historyThumbnailsFolderName, isDirectory: true)

        if !FileManager.default.fileExists(atPath: directoryURL.path) {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }

        return directoryURL
    }

    private func makeHistoryThumbnailFileName(for sourceURL: URL?) async -> String? {
        guard let sourceURL else { return nil }

        let asset = AVURLAsset(url: sourceURL)
        let durationSeconds = CMTimeGetSeconds(asset.duration)
        let preferredSeconds = durationSeconds.isFinite ? min(max(durationSeconds * 0.12, 0), 1.5) : 0
        let captureTime = CMTime(seconds: preferredSeconds, preferredTimescale: 600)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 360, height: 360)

        do {
            let cgImage = try generator.copyCGImage(at: captureTime, actualTime: nil)
            let image = UIImage(cgImage: cgImage)
            guard let data = image.jpegData(compressionQuality: 0.84) else {
                return nil
            }

            let fileName = "\(UUID().uuidString).jpg"
            let fileURL = try historyThumbnailsDirectoryURL().appendingPathComponent(fileName)
            try data.write(to: fileURL, options: [.atomic])
            return fileName
        } catch {
            return nil
        }
    }

    private func copyHistoryThumbnailFileName(from sourceURL: URL) async -> String? {
        guard let image = UIImage(contentsOfFile: sourceURL.path),
              let data = image.jpegData(compressionQuality: 0.9) else {
            return nil
        }

        do {
            let fileName = "\(UUID().uuidString).jpg"
            let fileURL = try historyThumbnailsDirectoryURL().appendingPathComponent(fileName)
            try data.write(to: fileURL, options: [.atomic])
            return fileName
        } catch {
            return nil
        }
    }

    private func makePromptInputFramePreviewFileName(for sourceURL: URL, seconds: Double) throws -> String {
        let stem = Self.sanitizedFileStem(
            sourceURL.deletingPathExtension().lastPathComponent,
            fallback: "prompt-preview"
        )
        let secondToken = Self.imageTimeToken(seconds)
        return "\(stem)-prompt-preview-\(secondToken)-\(UUID().uuidString).jpg"
    }

    private func removePromptInputFramePreview() {
        guard let fileName = promptInputFramePreviewFileName else {
            promptInputFramePreviewURL = nil
            return
        }

        if let fileURL = try? historyThumbnailsDirectoryURL().appendingPathComponent(fileName),
           FileManager.default.fileExists(atPath: fileURL.path) {
            try? FileManager.default.removeItem(at: fileURL)
        }

        promptInputFramePreviewFileName = nil
        promptInputFramePreviewURL = nil
    }

    private func focusedDismiss() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func startFreshSession() {
        clearAllLocalMedia(statusMessage: text("Waiting for a Sora ID.", "រង់ចាំ Sora ID។"))
    }

    private func setAIAutoModeEnabled(_ enabled: Bool) {
        isAIAutoModeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.aiAutoModeDefaultsKey)
        if enabled && downloadAutoSavesToPhotos {
            downloadAutoSavesToPhotos = false
            UserDefaults.standard.set(false, forKey: Self.downloadAutoSaveDefaultsKey)
        }
        if !enabled {
            aiAutoInputTask?.cancel()
            aiAutoInputTask = nil
            resetAIAutoRunState()
            dismissAIAutoDonePopup()
        }
        statusMessage = enabled
            ? text(
                downloadAutoSavesToPhotos
                    ? "AI Auto Mode is ON. Start Download will auto run the full AI flow and keep Download: Photo+Timeline."
                    : "AI Auto Mode is ON. Start Download will auto run the full AI flow and keep Download: Timeline Only.",
                downloadAutoSavesToPhotos
                    ? "AI Auto Mode បានបើកហើយ។ ពេលចុច Start Download វានឹងរត់ flow AI ទាំងមូលដោយស្វ័យប្រវត្តិ ហើយរក្សា Download: Photo+Timeline ដដែល។"
                    : "AI Auto Mode បានបើកហើយ។ ពេលចុច Start Download វានឹងរត់ flow AI ទាំងមូលដោយស្វ័យប្រវត្តិ ហើយរក្សា Download: Timeline Only ដដែល។"
            )
            : text(
                "AI Auto Mode is OFF. soranin will wait for your manual taps.",
                "AI Auto Mode បានបិទហើយ។ soranin នឹងរង់ចាំការចុចដោយដៃរបស់អ្នក។"
            )
    }

    private func prepareAIAutoRunForDownload() {
        isAIAutoRunInProgress = true
        shouldAutoConvertAfterDownload = true
        shouldAutoCreateTitlesAfterExport = true
        shouldAutoCopyTitlesAfterGeneration = true
        isShowingAIAutoDonePopup = false
        aiAutoDoneMessage = ""
    }

    private func prepareAIAutoRunForClipConvert() {
        isAIAutoRunInProgress = true
        shouldAutoConvertAfterDownload = false
        shouldAutoCreateTitlesAfterExport = true
        shouldAutoCopyTitlesAfterGeneration = true
        isShowingAIAutoDonePopup = false
        aiAutoDoneMessage = ""
    }

    private func resetAIAutoRunState() {
        isAIAutoRunInProgress = false
        shouldAutoConvertAfterDownload = false
        shouldAutoCreateTitlesAfterExport = false
        shouldAutoCopyTitlesAfterGeneration = false
    }

    private func scheduleAIAutoRunFromInputIfNeeded() {
        aiAutoInputTask?.cancel()
        aiAutoInputTask = nil

        guard isAIAutoModeEnabled, !isBusy else { return }
        let snapshot = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !snapshot.isEmpty else { return }
        let entries = extractDownloadInputEntries(from: snapshot)
        guard !entries.isEmpty else { return }

        aiAutoInputTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            await self?.runScheduledAIAutoInput(snapshot: snapshot)
        }
    }

    private func runScheduledAIAutoInput(snapshot: String) async {
        guard isAIAutoModeEnabled, !isBusy else { return }
        let current = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard current == snapshot else { return }
        let entries = extractDownloadInputEntries(from: current)
        guard !entries.isEmpty else { return }

        statusMessage = text(
            "AI Auto Mode found a link in the box and is starting download now.",
            "AI Auto Mode បានរកឃើញ link ក្នុងប្រអប់ ហើយកំពុងចាប់ផ្តើម download ឥឡូវនេះ។"
        )

        await downloadVideo()
    }

    private func completeAIAutoRun() {
        aiAutoDoneMessage = text(
            "AI finished the flow: download, Reels convert, titles, and auto copy are done. You can close this popup and start again.",
            "AI បានធ្វើ flow រួចហើយ៖ ទាញយក, convert Reels, បង្កើត titles និង copy ស្វ័យប្រវត្តិបានចប់។ អ្នកអាចបិទ popup នេះ ហើយចាប់ផ្តើមម្ដងទៀតបាន។"
        )
        isShowingAIAutoDonePopup = true
        resetAIAutoRunState()
    }

    private func text(_ english: String, _ khmer: String) -> String {
        appLanguage == .khmer ? khmer : english
    }

    private func persistSelectedAIProvider(_ provider: AIProvider) {
        selectedAIProvider = provider
        UserDefaults.standard.set(provider.rawValue, forKey: Self.selectedAIProviderDefaultsKey)
    }

    private func hasConfiguredKey(for provider: AIProvider) -> Bool {
        switch provider {
        case .googleGemini:
            return hasConfiguredGoogleAIKey
        case .openAI:
            return hasConfiguredOpenAIKey
        }
    }

    private func configuredAPIKey(for provider: AIProvider) -> String? {
        switch provider {
        case .googleGemini:
            return GoogleAIAPIKeyStore.load()?.trimmingCharacters(in: .whitespacesAndNewlines)
        case .openAI:
            return OpenAIAPIKeyStore.load()?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func fallbackProvider(for provider: AIProvider) -> AIProvider? {
        switch provider {
        case .googleGemini:
            return hasConfiguredOpenAIKey ? .openAI : nil
        case .openAI:
            return hasConfiguredGoogleAIKey ? .googleGemini : nil
        }
    }

    private func providerSequence(preferred provider: AIProvider) -> [AIProvider] {
        var providers: [AIProvider] = []

        if hasConfiguredKey(for: provider) {
            providers.append(provider)
        }

        if let fallback = fallbackProvider(for: provider), !providers.contains(fallback) {
            providers.append(fallback)
        }

        return providers
    }

    private func presentKeyPrompt(
        for provider: AIProvider,
        runCreateTitlesAfterSave: Bool,
        runCreateEditorTitlesAfterSave: Bool = false,
        runCreatePromptAfterSave: Bool = false
    ) {
        switch provider {
        case .googleGemini:
            presentGoogleAIKeyPrompt(
                runCreateTitlesAfterSave: runCreateTitlesAfterSave,
                runCreateEditorTitlesAfterSave: runCreateEditorTitlesAfterSave,
                runCreatePromptAfterSave: runCreatePromptAfterSave
            )
        case .openAI:
            presentOpenAIKeyPrompt(
                runCreateTitlesAfterSave: runCreateTitlesAfterSave,
                runCreateEditorTitlesAfterSave: runCreateEditorTitlesAfterSave,
                runCreatePromptAfterSave: runCreatePromptAfterSave
            )
        }
    }

    private func missingKeyStatus(for provider: AIProvider, isPromptVideo: Bool) -> String {
        switch (provider, isPromptVideo) {
        case (.googleGemini, true):
            return text(
                "Add your Google AI Studio API key once so soranin can create titles from this prompt video.",
                "សូមបញ្ចូល Google AI Studio API key ម្តងសិន ដើម្បីឲ្យ soranin បង្កើត titles ពីវីដេអូក្នុងប្រអប់ Prompt នេះ។"
            )
        case (.googleGemini, false):
            return text(
                "Add your Google AI Studio API key once so soranin can create accurate AI titles.",
                "សូមបញ្ចូល Google AI Studio API key ម្តងសិន ដើម្បីឲ្យ soranin បង្កើត AI titles ត្រូវជាងមុន។"
            )
        case (.openAI, true):
            return text(
                "Add your OpenAI API key once so soranin can create titles from this prompt video.",
                "សូមបញ្ចូល OpenAI API key ម្តងសិន ដើម្បីឲ្យ soranin បង្កើត titles ពីវីដេអូក្នុងប្រអប់ Prompt នេះ។"
            )
        case (.openAI, false):
            return text(
                "Add your OpenAI API key once so soranin can create accurate AI titles.",
                "សូមបញ្ចូល OpenAI API key ម្តងសិន ដើម្បីឲ្យ soranin បង្កើត AI titles ត្រូវជាងមុន។"
            )
        }
    }

    private func titleAnalysisStatus(for provider: AIProvider, isPromptVideo: Bool) -> String {
        switch (provider, isPromptVideo) {
        case (.googleGemini, true):
            return text(
                "Analyzing the prompt video with Google AI Studio and creating new English titles...",
                "កំពុងវិភាគវីដេអូក្នុងប្រអប់ Prompt ដោយ Google AI Studio ហើយបង្កើតចំណងជើង English ថ្មី..."
            )
        case (.googleGemini, false):
            return text(
                "Analyzing the full exported video with Google AI Studio and creating new English titles...",
                "កំពុងវិភាគវីដេអូ export ពេញដោយ Google AI Studio ហើយបង្កើតចំណងជើង English ថ្មី..."
            )
        case (.openAI, true):
            return text(
                "Analyzing the prompt video with OpenAI and creating new English titles...",
                "កំពុងវិភាគវីដេអូក្នុងប្រអប់ Prompt ដោយ OpenAI ហើយបង្កើតចំណងជើង English ថ្មី..."
            )
        case (.openAI, false):
            return text(
                "Analyzing the full exported video with OpenAI and creating new English titles...",
                "កំពុងវិភាគវីដេអូ export ពេញដោយ OpenAI ហើយបង្កើតចំណងជើង English ថ្មី..."
            )
        }
    }

    private func titleSuccessStatus(for provider: AIProvider, isPromptVideo: Bool) -> String {
        switch (provider, isPromptVideo) {
        case (.googleGemini, true):
            return text(
                "Google AI titles for this prompt video are ready. Tap Copy to save them to the clipboard.",
                "Google AI titles សម្រាប់វីដេអូក្នុងប្រអប់ Prompt រួចរាល់ហើយ។ ចុច Copy ដើម្បីចម្លងទៅ clipboard។"
            )
        case (.googleGemini, false):
            return text(
                "Google AI titles are ready. Tap Copy to save them to the clipboard.",
                "Google AI titles បានរួចរាល់ហើយ។ ចុច Copy ដើម្បីចម្លងទៅ clipboard។"
            )
        case (.openAI, true):
            return text(
                "OpenAI titles for this prompt video are ready. Tap Copy to save them to the clipboard.",
                "OpenAI titles សម្រាប់វីដេអូក្នុងប្រអប់ Prompt រួចរាល់ហើយ។ ចុច Copy ដើម្បីចម្លងទៅ clipboard។"
            )
        case (.openAI, false):
            return text(
                "OpenAI titles are ready. Tap Copy to save them to the clipboard.",
                "OpenAI titles បានរួចរាល់ហើយ។ ចុច Copy ដើម្បីចម្លងទៅ clipboard។"
            )
        }
    }

    private func titleFailureStatus(for provider: AIProvider, isPromptVideo: Bool, error: Error) -> String {
        switch (provider, isPromptVideo) {
        case (.googleGemini, true):
            return text(
                "Google AI title creation failed for this prompt video: \(error.localizedDescription)",
                "ការបង្កើត Google AI title សម្រាប់វីដេអូក្នុងប្រអប់ Prompt នេះបរាជ័យ៖ \(error.localizedDescription)"
            )
        case (.googleGemini, false):
            return text(
                "Google AI title creation failed: \(error.localizedDescription)",
                "ការបង្កើត Google AI title បរាជ័យ៖ \(error.localizedDescription)"
            )
        case (.openAI, true):
            return text(
                "OpenAI title creation failed for this prompt video: \(error.localizedDescription)",
                "ការបង្កើត OpenAI title សម្រាប់វីដេអូក្នុងប្រអប់ Prompt នេះបរាជ័យ៖ \(error.localizedDescription)"
            )
        case (.openAI, false):
            return text(
                "OpenAI title creation failed: \(error.localizedDescription)",
                "ការបង្កើត OpenAI title បរាជ័យ៖ \(error.localizedDescription)"
            )
        }
    }

    private func titleFallbackStatus(from failedProvider: AIProvider, to nextProvider: AIProvider) -> String {
        text(
            "\(providerDisplayName(failedProvider)) failed. Trying \(providerDisplayName(nextProvider)) now...",
            "\(providerDisplayName(failedProvider)) បរាជ័យ។ កំពុងសាក \(providerDisplayName(nextProvider)) ឥឡូវនេះ..."
        )
    }

    private func selectedProviderFallbackStatus(using provider: AIProvider) -> String {
        text(
            "\(providerDisplayName(selectedAIProvider)) is not ready, so soranin is using \(providerDisplayName(provider)) instead.",
            "\(providerDisplayName(selectedAIProvider)) មិនទាន់រួចរាល់ទេ ដូច្នេះ soranin កំពុងប្រើ \(providerDisplayName(provider)) ជំនួស។"
        )
    }

    private func missingPromptKeyStatus(for provider: AIProvider) -> String {
        switch provider {
        case .googleGemini:
            return text(
                "Add your Google AI Studio API key once so soranin can create Sora prompts from the prompt video.",
                "សូមបញ្ចូល Google AI Studio API key ម្តងសិន ដើម្បីឲ្យ soranin បង្កើត Sora prompts ពីវីដេអូក្នុងប្រអប់ Prompt។"
            )
        case .openAI:
            return text(
                "Add your OpenAI API key once so soranin can create Sora prompts from the prompt video.",
                "សូមបញ្ចូល OpenAI API key ម្តងសិន ដើម្បីឲ្យ soranin បង្កើត Sora prompts ពីវីដេអូក្នុងប្រអប់ Prompt។"
            )
        }
    }

    private func promptAnalysisStatus(for provider: AIProvider, clipCount: Int) -> String {
        switch provider {
        case .googleGemini:
            return text(
                clipCount > 1
                    ? "Analyzing \(clipCount) prompt videos with Google AI Studio and writing one Sora prompt..."
                    : "Analyzing the prompt video with Google AI Studio and writing a Sora prompt...",
                clipCount > 1
                    ? "កំពុងវិភាគវីដេអូ prompt \(clipCount) ដោយ Google AI Studio ហើយសរសេរ Sora prompt តែមួយ..."
                    : "កំពុងវិភាគវីដេអូក្នុងប្រអប់ Prompt ដោយ Google AI Studio ហើយសរសេរ Sora prompt..."
            )
        case .openAI:
            return text(
                clipCount > 1
                    ? "Analyzing \(clipCount) prompt videos with OpenAI and writing one Sora prompt..."
                    : "Analyzing the prompt video with OpenAI and writing a Sora prompt...",
                clipCount > 1
                    ? "កំពុងវិភាគវីដេអូ prompt \(clipCount) ដោយ OpenAI ហើយសរសេរ Sora prompt តែមួយ..."
                    : "កំពុងវិភាគវីដេអូក្នុងប្រអប់ Prompt ដោយ OpenAI ហើយសរសេរ Sora prompt..."
            )
        }
    }

    private func promptSuccessStatus(for provider: AIProvider) -> String {
        switch provider {
        case .googleGemini:
            return text(
                "Google AI prompt is ready below. Tap Copy Prompt to save it to the clipboard.",
                "Google AI prompt បានរួចរាល់នៅខាងក្រោមហើយ។ ចុច Copy Prompt ដើម្បីចម្លងទៅ clipboard។"
            )
        case .openAI:
            return text(
                "OpenAI prompt is ready below. Tap Copy Prompt to save it to the clipboard.",
                "OpenAI prompt បានរួចរាល់នៅខាងក្រោមហើយ។ ចុច Copy Prompt ដើម្បីចម្លងទៅ clipboard។"
            )
        }
    }

    private func promptFailureStatus(for provider: AIProvider, error: Error) -> String {
        switch provider {
        case .googleGemini:
            return text(
                "Google AI prompt failed: \(error.localizedDescription)",
                "Google AI prompt បរាជ័យ៖ \(error.localizedDescription)"
            )
        case .openAI:
            return text(
                "OpenAI prompt failed: \(error.localizedDescription)",
                "OpenAI prompt បរាជ័យ៖ \(error.localizedDescription)"
            )
        }
    }

    private func generatePrompt(
        for source: (url: URL, name: String, clipCount: Int),
        presentKeyPromptIfNeeded: @escaping (AIProvider) -> Void
    ) async {
        let providersToTry = providerSequence(preferred: selectedAIProvider)

        guard !providersToTry.isEmpty else {
            await finishPromptProgressAnimation(success: false)
            presentKeyPromptIfNeeded(selectedAIProvider)
            statusMessage = missingPromptKeyStatus(for: selectedAIProvider)
            return
        }

        if providersToTry.first != selectedAIProvider, let fallback = providersToTry.first {
            statusMessage = selectedProviderFallbackStatus(using: fallback)
        }

        isGeneratingPrompt = true
        defer { isGeneratingPrompt = false }

        var lastError: Error?

        for (index, provider) in providersToTry.enumerated() {
            guard let apiKey = configuredAPIKey(for: provider), !apiKey.isEmpty else {
                continue
            }

            statusMessage = promptAnalysisStatus(for: provider, clipCount: source.clipCount)

            do {
                let generatedPrompt: String
                switch provider {
                case .googleGemini:
                    generatedPrompt = try await GoogleAIVideoPromptGenerator.generatePrompt(
                        for: source.url,
                        apiKey: apiKey,
                        modelName: selectedModelID(for: .googleGemini),
                        appLanguage: appLanguage
                    )
                case .openAI:
                    generatedPrompt = try await OpenAIVideoPromptGenerator.generatePrompt(
                        for: source.url,
                        apiKey: apiKey,
                        modelID: selectedModelID(for: .openAI),
                        appLanguage: appLanguage
                    )
                }

                await finishPromptProgressAnimation(success: true)
                generatedPromptText = generatedPrompt
                isShowingGeneratedPrompt = true
                statusMessage = promptSuccessStatus(for: provider)
                return
            } catch {
                lastError = error
                if index < providersToTry.count - 1 {
                    statusMessage = titleFallbackStatus(from: provider, to: providersToTry[index + 1])
                    continue
                }
            }
        }

        await finishPromptProgressAnimation(success: false)
        if let lastError {
            statusMessage = promptFailureStatus(for: providersToTry.last ?? selectedAIProvider, error: lastError)
        }
    }

    private func generateTitles(
        for fileURL: URL,
        isPromptVideo: Bool,
        presentKeyPromptIfNeeded: @escaping (AIProvider) -> Void,
        onSuccess: @escaping () -> Void = {}
    ) async {
        let providersToTry = providerSequence(preferred: selectedAIProvider)

        guard !providersToTry.isEmpty else {
            presentKeyPromptIfNeeded(selectedAIProvider)
            statusMessage = missingKeyStatus(for: selectedAIProvider, isPromptVideo: isPromptVideo)
            return
        }

        if providersToTry.first != selectedAIProvider, let fallback = providersToTry.first {
            statusMessage = selectedProviderFallbackStatus(using: fallback)
        }

        isGeneratingTitles = true
        defer { isGeneratingTitles = false }

        var lastError: Error?

        for (index, provider) in providersToTry.enumerated() {
            guard let apiKey = configuredAPIKey(for: provider), !apiKey.isEmpty else {
                continue
            }

            statusMessage = titleAnalysisStatus(for: provider, isPromptVideo: isPromptVideo)

            do {
                let generatedTitles: String
                switch provider {
                case .googleGemini:
                    generatedTitles = try await GoogleAIVideoTitleGenerator.generateTitles(
                        for: fileURL,
                        apiKey: apiKey,
                        modelName: selectedModelID(for: .googleGemini),
                        appLanguage: appLanguage
                    )
                case .openAI:
                    generatedTitles = try await OpenAIVideoTitleGenerator.generateTitles(
                        for: fileURL,
                        apiKey: apiKey,
                        modelID: selectedModelID(for: .openAI),
                        appLanguage: appLanguage
                    )
                }

                generatedTitlesText = generatedTitles
                onSuccess()
                statusMessage = titleSuccessStatus(for: provider, isPromptVideo: isPromptVideo)
                return
            } catch {
                lastError = error
                if index < providersToTry.count - 1 {
                    statusMessage = titleFallbackStatus(from: provider, to: providersToTry[index + 1])
                    continue
                }
            }
        }

        if let lastError {
            statusMessage = titleFailureStatus(for: providersToTry.last ?? selectedAIProvider, isPromptVideo: isPromptVideo, error: lastError)
        }
    }

    private func generateThumbnail(for fileURL: URL, regenerate: Bool) async {
        guard let apiKey = configuredAPIKey(for: .googleGemini), !apiKey.isEmpty else {
            presentGoogleAIKeyPrompt(
                runCreateTitlesAfterSave: false,
                runCreateThumbnailAfterSave: true
            )
            statusMessage = text(
                "Add your Google AI Studio API key once so soranin can create a smart thumbnail from the full video.",
                "សូមបញ្ចូល Google AI Studio API key ម្តងសិន ដើម្បីឲ្យ soranin បង្កើត thumbnail ឆ្លាតវៃពីវីដេអូទាំងមូល។"
            )
            return
        }

        isGeneratingThumbnail = true
        generatedThumbnailSourceURL = fileURL
        generatedThumbnailPhotoSaveMessage = ""
        generatedThumbnailSavedToPhotos = false
        isShowingGeneratedThumbnail = false

        if !regenerate {
            generatedThumbnailVariationIndex = 0
        } else {
            generatedThumbnailVariationIndex += 1
        }

        statusMessage = text(
            "Analyzing the full video with Google AI Studio and choosing the strongest thumbnail moment...",
            "កំពុងវិភាគវីដេអូទាំងមូលដោយ Google AI Studio ហើយជ្រើសពេលដែលសមបំផុតសម្រាប់ thumbnail..."
        )

        startThumbnailProgressAnimation()

        defer { isGeneratingThumbnail = false }

        do {
            let suggestion = try await GoogleAIVideoThumbnailGenerator.suggestThumbnail(
                for: fileURL,
                apiKey: apiKey,
                modelName: selectedModelID(for: .googleGemini),
                appLanguage: appLanguage,
                previousSuggestion: regenerate ? generatedThumbnailSuggestion : nil,
                variationIndex: generatedThumbnailVariationIndex
            )

            let imageData = try await ReelsVideoExporter.capturePhotoData(
                sourceURL: fileURL,
                at: suggestion.timestampSeconds
            )
            let imageURL = try makeImageDestinationURL(for: fileURL, seconds: suggestion.timestampSeconds)
            try imageData.write(to: imageURL, options: .atomic)

            generatedThumbnailSuggestion = suggestion
            generatedThumbnailImageURL = imageURL
            generatedThumbnailHeadline = suggestion.headline
            generatedThumbnailReason = suggestion.reason
            await finishThumbnailProgressAnimation(success: true)
            isShowingGeneratedThumbnail = true

            statusMessage = """
            \(text("Thumbnail ready", "Thumbnail រួចរាល់")): \(displayName(for: imageURL))
            \(text("Google Gemini chose a high-interest frame from the full video.", "Google Gemini បានជ្រើស frame ដែលទាក់ទាញពីវីដេអូទាំងមូល។"))
            """
        } catch {
            await finishThumbnailProgressAnimation(success: false)
            statusMessage = text(
                "Thumbnail failed: \(error.localizedDescription)",
                "បង្កើត thumbnail បរាជ័យ៖ \(error.localizedDescription)"
            )
        }
    }

    private func switchToFallbackProviderIfNeeded() {
        if hasConfiguredGoogleAIKey {
            persistSelectedAIProvider(.googleGemini)
            statusMessage = text(
                "Active AI switched to Google Gemini.",
                "បានប្ដូរ AI កំពុងប្រើទៅ Google Gemini។"
            )
        } else if hasConfiguredOpenAIKey {
            persistSelectedAIProvider(.openAI)
            statusMessage = text(
                "Active AI switched to OpenAI.",
                "បានប្ដូរ AI កំពុងប្រើទៅ OpenAI។"
            )
        }
    }

    private func beginBackgroundWork(named name: String) {
        endBackgroundWork()
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            Task { @MainActor in
                self?.statusMessage = "iOS stopped the background export. Keep soranin open for very long exports."
                self?.endBackgroundWork()
            }
        }
    }

    private func endBackgroundWork() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    private func validate(response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SoraDownloadError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw SoraDownloadError.httpStatus(httpResponse.statusCode)
        }
    }

    private func makeDestinationURL(for videoID: String) throws -> URL {
        let directoryURL = try downloadsDirectoryURL()

        let baseFileName = SoraVideoLink.fileName(for: videoID)
        let baseURL = directoryURL.appendingPathComponent(baseFileName)

        if !FileManager.default.fileExists(atPath: baseURL.path) {
            return baseURL
        }

        let stem = baseURL.deletingPathExtension().lastPathComponent
        let ext = baseURL.pathExtension
        let timestamp = Self.timestampFormatter.string(from: .now)
        return directoryURL.appendingPathComponent("\(stem)-\(timestamp).\(ext)")
    }

    private func makeFacebookDestinationURL(preferredFileName: String?, fallbackKey: String) throws -> URL {
        let directoryURL = try downloadsDirectoryURL()
        let rawName = preferredFileName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidateName = rawName?.isEmpty == false ? rawName! : "\(fallbackKey).mp4"
        let originalExtension = URL(fileURLWithPath: candidateName).pathExtension
        let safeExtension = originalExtension.isEmpty ? "mp4" : originalExtension
        let stem = Self.sanitizedFileStem(
            URL(fileURLWithPath: candidateName).deletingPathExtension().lastPathComponent,
            fallback: fallbackKey
        )
        let baseURL = directoryURL.appendingPathComponent("\(stem).\(safeExtension)")

        if !FileManager.default.fileExists(atPath: baseURL.path) {
            return baseURL
        }

        let timestamp = Self.timestampFormatter.string(from: .now)
        return directoryURL.appendingPathComponent("\(stem)-\(timestamp).\(safeExtension)")
    }

    private func makeImageDestinationURL(for sourceURL: URL, seconds: Double) throws -> URL {
        let directoryURL = try downloadsDirectoryURL()
        let stem = Self.sanitizedFileStem(
            sourceURL.deletingPathExtension().lastPathComponent,
            fallback: "input-video"
        )
        let secondToken = Self.imageTimeToken(seconds)
        let baseURL = directoryURL.appendingPathComponent("\(stem)-frame-\(secondToken).jpg")

        if !FileManager.default.fileExists(atPath: baseURL.path) {
            return baseURL
        }

        let timestamp = Self.timestampFormatter.string(from: .now)
        return directoryURL.appendingPathComponent("\(stem)-frame-\(secondToken)-\(timestamp).jpg")
    }

    private func makeImportedVideoDestinationURL(for sourceURL: URL) throws -> URL {
        let directoryURL = try downloadsDirectoryURL()
        let sourceExtension = sourceURL.pathExtension.isEmpty ? "mp4" : sourceURL.pathExtension
        let stem = Self.sanitizedFileStem(
            sourceURL.deletingPathExtension().lastPathComponent,
            fallback: "input-video"
        )

        let baseURL = directoryURL.appendingPathComponent("\(stem)-input.\(sourceExtension)")
        if !FileManager.default.fileExists(atPath: baseURL.path) {
            return baseURL
        }

        let timestamp = Self.timestampFormatter.string(from: .now)
        return directoryURL.appendingPathComponent("\(stem)-input-\(timestamp).\(sourceExtension)")
    }

    private func makePromptImportedVideoDestinationURL(for sourceURL: URL) throws -> URL {
        let directoryURL = try downloadsDirectoryURL()
        let sourceExtension = sourceURL.pathExtension.isEmpty ? "mp4" : sourceURL.pathExtension
        let stem = Self.sanitizedFileStem(
            sourceURL.deletingPathExtension().lastPathComponent,
            fallback: "prompt-video"
        )

        let baseURL = directoryURL.appendingPathComponent("\(stem)-prompt.\(sourceExtension)")
        if !FileManager.default.fileExists(atPath: baseURL.path) {
            return baseURL
        }

        let timestamp = Self.timestampFormatter.string(from: .now)
        return directoryURL.appendingPathComponent("\(stem)-prompt-\(timestamp).\(sourceExtension)")
    }

    private func importedAIChatAttachment(from sourceURL: URL) -> AIChatAttachment? {
        let standardized = sourceURL.standardizedFileURL
        guard let kind = aiChatAttachmentKind(for: standardized) else {
            return nil
        }

        do {
            let destinationURL = try makeAIChatAttachmentDestinationURL(for: standardized)

            if standardized != destinationURL {
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.copyItem(at: standardized, to: destinationURL)
            }

            return AIChatAttachment(
                kind: kind,
                path: destinationURL.path,
                mimeType: mimeType(for: destinationURL, fallback: kind == .image ? "image/jpeg" : "video/mp4"),
                displayName: standardized.lastPathComponent
            )
        } catch {
            return nil
        }
    }

    private func aiChatAttachmentKind(for url: URL) -> AIChatAttachmentKind? {
        let ext = url.pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "webp", "heic", "gif", "bmp"].contains(ext) {
            return .image
        }
        if ["mp4", "mov", "m4v", "avi", "mkv", "webm"].contains(ext) {
            return .video
        }

        if let resourceValues = try? url.resourceValues(forKeys: [.contentTypeKey]),
           let contentType = resourceValues.contentType {
            if contentType.conforms(to: .image) {
                return .image
            }
            if contentType.conforms(to: .movie) || contentType.conforms(to: .audiovisualContent) {
                return .video
            }
        }

        return nil
    }

    private func aiChatAttachmentsDirectoryURL() throws -> URL {
        let directoryURL = try downloadsDirectoryURL().appendingPathComponent("AIChatMedia", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directoryURL.path) {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
        return directoryURL
    }

    private func makeAIChatAttachmentDestinationURL(for sourceURL: URL) throws -> URL {
        let directoryURL = try aiChatAttachmentsDirectoryURL()
        let sourceExtension = sourceURL.pathExtension.isEmpty ? "dat" : sourceURL.pathExtension
        let kind = aiChatAttachmentKind(for: sourceURL)
        let fallbackStem = kind == .video ? "chat-video" : "chat-image"
        let stem = Self.sanitizedFileStem(
            sourceURL.deletingPathExtension().lastPathComponent,
            fallback: fallbackStem
        )

        let timestamp = Self.timestampFormatter.string(from: .now)
        return directoryURL.appendingPathComponent("\(stem)-\(timestamp).\(sourceExtension)")
    }

    private func mimeType(for url: URL, fallback: String) -> String {
        if let resourceValues = try? url.resourceValues(forKeys: [.contentTypeKey]),
           let contentType = resourceValues.contentType,
           let mimeType = contentType.preferredMIMEType {
            return mimeType
        }

        if let type = UTType(filenameExtension: url.pathExtension),
           let mimeType = type.preferredMIMEType {
            return mimeType
        }

        return fallback
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        return formatter
    }()

    private static func imageTimeToken(_ seconds: Double) -> String {
        String(format: "%.2f", seconds).replacingOccurrences(of: ".", with: "-")
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

    private func displayName(for fileURL: URL) -> String {
        let decoded = fileURL.lastPathComponent.removingPercentEncoding ?? fileURL.lastPathComponent
        return decoded.replacingOccurrences(of: "-", with: " ")
    }

    private static func sanitizedFileStem(_ rawValue: String, fallback: String) -> String {
        let decoded = (rawValue.removingPercentEncoding ?? rawValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let spaced = decoded.replacingOccurrences(of: " ", with: "-")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let filtered = String(
            spaced.unicodeScalars.map { scalar in
                allowed.contains(scalar) ? Character(scalar) : "-"
            }
        )
        let collapsed = filtered.replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return trimmed.isEmpty ? fallback : trimmed.lowercased()
    }

    private static let supportedVideoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    private func downloadsDirectoryURL() throws -> URL {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let directoryURL = documentsURL.appendingPathComponent("SoraDownloads", isDirectory: true)

        if !FileManager.default.fileExists(atPath: directoryURL.path) {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }

        return directoryURL
    }

    private func loadMostRecentSavedVideo() -> URL? {
        guard let directoryURL = try? downloadsDirectoryURL() else {
            return nil
        }

        let resourceKeys: Set<URLResourceKey> = [.contentModificationDateKey, .creationDateKey, .isRegularFileKey]
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let regularFiles = fileURLs.filter { url in
            let values = try? url.resourceValues(forKeys: resourceKeys)
            let isRegularFile = values?.isRegularFile ?? false
            return isRegularFile && Self.supportedVideoExtensions.contains(url.pathExtension.lowercased())
        }

        return regularFiles.max { lhs, rhs in
            let lhsValues = try? lhs.resourceValues(forKeys: resourceKeys)
            let rhsValues = try? rhs.resourceValues(forKeys: resourceKeys)

            let lhsDate = lhsValues?.contentModificationDate ?? lhsValues?.creationDate ?? .distantPast
            let rhsDate = rhsValues?.contentModificationDate ?? rhsValues?.creationDate ?? .distantPast
            return lhsDate < rhsDate
        }
    }

    private func saveVideoToPhotos(from fileURL: URL) async -> String {
        do {
            guard Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryAddUsageDescription") != nil else {
                return "Saved to Files only. Photos permission text is missing."
            }

            let authorizationStatus = await requestPhotoLibraryAccessIfNeeded()
            guard authorizationStatus == .authorized || authorizationStatus == .limited else {
                return "Saved to Files only. Photos access was not allowed."
            }

            try await performPhotoLibraryChanges {
                let creationRequest = PHAssetCreationRequest.forAsset()
                creationRequest.addResource(with: .video, fileURL: fileURL, options: nil)
            }
            return "Saved to Photos automatically."
        } catch {
            return "Saved to Files, but Photos save failed: \(error.localizedDescription)"
        }
    }

    private func saveImageToPhotos(from fileURL: URL) async -> String {
        do {
            guard Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryAddUsageDescription") != nil else {
                return "Saved to Files only. Photos permission text is missing."
            }

            let authorizationStatus = await requestPhotoLibraryAccessIfNeeded()
            guard authorizationStatus == .authorized || authorizationStatus == .limited else {
                return "Saved to Files only. Photos access was not allowed."
            }

            try await performPhotoLibraryChanges {
                let creationRequest = PHAssetCreationRequest.forAsset()
                creationRequest.addResource(with: .photo, fileURL: fileURL, options: nil)
            }
            return "Saved to Photos automatically."
        } catch {
            return "Saved to Files, but Photos save failed: \(error.localizedDescription)"
        }
    }

    private func requestPhotoLibraryAccessIfNeeded() async -> PHAuthorizationStatus {
        let currentStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch currentStatus {
        case .notDetermined:
            return await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        default:
            return currentStatus
        }
    }

    private func performPhotoLibraryChanges(_ changes: @escaping () -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges(changes) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: SoraDownloadError.photoSaveFailed)
                }
            }
        }
    }

    private func normalizedInput(from text: String, forceVideoID: Bool = false) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if FacebookVideoLink.containsSupportedURL(trimmed) {
            return trimmed
        }

        let shouldNormalize = forceVideoID || SoraVideoLink.shouldNormalizeToVideoID(trimmed)
        guard shouldNormalize else {
            return trimmed
        }

        let videoIDs = SoraVideoLink.extractVideoIDs(from: trimmed)
        guard let firstVideoID = videoIDs.first else {
            return trimmed
        }

        if forceVideoID || videoIDs.count == 1 {
            return firstVideoID
        }

        return trimmed
    }
}

extension SoraDownloadViewModel {
    func addAIChatAttachments(_ urls: [URL]) {
        let imported = urls.compactMap(importedAIChatAttachment(from:))
        guard !imported.isEmpty else {
            aiChatStatus = text(
                "No valid image or video was added.",
                "មិនមាន image ឬ video ត្រឹមត្រូវត្រូវបានបន្ថែមទេ។"
            )
            return
        }

        var merged = aiChatDraftAttachments
        for attachment in imported where !merged.contains(where: { $0.path == attachment.path }) {
            merged.append(attachment)
        }

        if merged.count > 8 {
            merged = Array(merged.prefix(8))
        }

        aiChatDraftAttachments = merged
        aiChatStatus = text(
            "\(merged.count) media attached.",
            "បានភ្ជាប់ media \(merged.count)។"
        )
    }

    func removeAIChatAttachment(_ attachment: AIChatAttachment) {
        aiChatDraftAttachments.removeAll { $0.id == attachment.id }
        aiChatStatus = aiChatDraftAttachments.isEmpty
            ? text("Media cleared.", "បានសម្អាត media ហើយ។")
            : text(
                "\(aiChatDraftAttachments.count) media attached.",
                "បានភ្ជាប់ media \(aiChatDraftAttachments.count)។"
            )
    }

    func clearAIChatAttachments() {
        aiChatDraftAttachments.removeAll()
        aiChatStatus = text("Media cleared.", "បានសម្អាត media ហើយ។")
    }

    func submitAIChatMessage(_ messageText: String) {
        let trimmed = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        let pendingAttachments = aiChatDraftAttachments
        let normalizedMessage = trimmed.isEmpty && !pendingAttachments.isEmpty
            ? "Analyze the attached media carefully."
            : trimmed

        guard (!normalizedMessage.isEmpty || !pendingAttachments.isEmpty), aiChatSendTask == nil else { return }

        aiChatSendTask = Task { [weak self] in
            guard let self else { return }
            await self.sendAIChatMessage(normalizedMessage, attachments: pendingAttachments)
            await MainActor.run {
                self.aiChatSendTask = nil
            }
        }
    }

    func showAIChat() {
        if aiChatSessions.isEmpty {
            bootstrapAIChatSessions()
        }
        aiChatDraftAttachments = []
        isShowingAIChat = true
        if aiChatStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            aiChatStatus = text("AI chat is ready.", "AI chat រួចរាល់ហើយ។")
        }
    }

    func dismissAIChat() {
        isShowingAIChat = false
    }

    func startNewAIChatSession() {
        let now = Date()
        let session = AIChatSession(
            id: UUID(),
            createdAt: now,
            updatedAt: now,
            title: "New Chat",
            messages: []
        )
        aiChatSessions.insert(session, at: 0)
        currentAIChatSessionID = session.id
        aiChatMessages = []
        aiChatDraftAttachments = []
        aiChatStatus = text("New chat created.", "បានបង្កើត chat ថ្មី។")
        persistAIChatStore()
    }

    func loadAIChatSession(_ session: AIChatSession) {
        currentAIChatSessionID = session.id
        aiChatMessages = session.messages
        aiChatDraftAttachments = []
        aiChatStatus = text(
            "Loaded \(session.previewText).",
            "បានបើក \(session.previewText)។"
        )
        persistCurrentAIChatSession(markUpdated: false)
    }

    func deleteCurrentAIChatSession() {
        guard let currentAIChatSessionID else { return }
        aiChatSessions.removeAll { $0.id == currentAIChatSessionID }

        if let firstSession = aiChatSessions.first {
            loadAIChatSession(firstSession)
        } else {
            startNewAIChatSession()
        }

        aiChatStatus = text("Chat deleted.", "បានលុប chat ហើយ។")
        persistAIChatStore()
    }

    func copyAIChatMessageToClipboard(_ message: AIChatMessage) {
        UIPasteboard.general.string = message.content
        aiChatStatus = text("Message copied.", "បានចម្លងសារ។")
    }

    func copyAIChatPromptToClipboard(_ message: AIChatMessage) {
        guard let prompt = AIChatPromptExtractor.extractGenerationPrompt(from: message.content) else { return }
        UIPasteboard.general.string = prompt
        aiChatStatus = text("Prompt copied.", "បានចម្លង prompt។")
    }

    func copyAIChatPromptToClipboard(_ prompt: String) {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return }
        UIPasteboard.general.string = trimmedPrompt
        aiChatStatus = text("Prompt copied.", "បានចម្លង prompt។")
    }

    func copyAIChatConversationToClipboard() {
        let transcript = aiChatMessages
            .map { message -> String in
                let trimmedContent = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                let speaker = message.role == "user" ? text("You", "អ្នក") : "AI"
                let attachmentSummary = message.attachments.isEmpty
                    ? ""
                    : "\n[Media: \(message.attachments.map(\.resolvedDisplayName).joined(separator: ", "))]"
                let body = trimmedContent.isEmpty ? attachmentSummary.trimmingCharacters(in: .whitespacesAndNewlines) : trimmedContent + attachmentSummary
                guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
                return "\(speaker):\n\(body)"
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        guard !transcript.isEmpty else { return }

        UIPasteboard.general.string = transcript
        aiChatStatus = text("Chat copied.", "បានចម្លង chat ទាំងមូល។")
    }

    func sendAIChatMessage(_ messageText: String, attachments: [AIChatAttachment] = []) async {
        let trimmed = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }

        if currentAIChatSessionID == nil {
            startNewAIChatSession()
        }

        let userMessage = AIChatMessage(
            role: "user",
            content: trimmed,
            attachments: attachments
        )
        appendAIChatMessage(userMessage)
        aiChatDraftAttachments = []
        isSendingAIChat = true
        defer { isSendingAIChat = false }

        let providersToTry = providerSequence(preferred: selectedAIProvider)

        guard !providersToTry.isEmpty else {
            presentKeyPrompt(for: selectedAIProvider, runCreateTitlesAfterSave: false)
            aiChatStatus = text(
                "Add an AI API key first so soranin can chat.",
                "សូមដាក់ AI API key សិន ដើម្បីឲ្យ soranin អាច chat បាន។"
            )
            return
        }

        if providersToTry.first != selectedAIProvider, let fallback = providersToTry.first {
            aiChatStatus = selectedProviderFallbackStatus(using: fallback)
        }

        let conversation = Array(aiChatMessages.suffix(18))
        let systemPrompt = aiChatSystemPrompt()
        var lastError: Error?

        for (index, provider) in providersToTry.enumerated() {
            guard let apiKey = configuredAPIKey(for: provider), !apiKey.isEmpty else {
                continue
            }

            aiChatStatus = text(
                "Sending your message to \(providerDisplayName(provider))...",
                "កំពុងផ្ញើសាររបស់អ្នកទៅ \(providerDisplayName(provider))..."
            )

            do {
                let reply: String
                switch provider {
                case .googleGemini:
                    reply = try await GoogleAIChatService.sendConversation(
                        messages: conversation,
                        systemPrompt: systemPrompt,
                        apiKey: apiKey,
                        modelName: selectedModelID(for: .googleGemini)
                    )
                case .openAI:
                    reply = try await OpenAIChatService.sendConversation(
                        messages: conversation,
                        systemPrompt: systemPrompt,
                        apiKey: apiKey,
                        modelID: selectedModelID(for: .openAI)
                    )
                }

                let completedReply = try await completedPromptReplyIfNeeded(
                    initialReply: reply,
                    latestRequest: trimmed,
                    conversation: conversation,
                    systemPrompt: systemPrompt,
                    provider: provider,
                    apiKey: apiKey
                )

                appendAIChatMessage(
                    AIChatMessage(
                        role: "assistant",
                        content: completedReply.trimmingCharacters(in: .whitespacesAndNewlines),
                        attachments: []
                    )
                )
                aiChatStatus = text(
                    "\(providerDisplayName(provider)) replied.",
                    "\(providerDisplayName(provider)) បានឆ្លើយតបហើយ។"
                )
                return
            } catch {
                lastError = error
                if index < providersToTry.count - 1 {
                    aiChatStatus = titleFallbackStatus(from: provider, to: providersToTry[index + 1])
                    continue
                }
            }
        }

        if let lastError {
            aiChatStatus = text(
                "AI chat failed: \(lastError.localizedDescription)",
                "AI chat បរាជ័យ៖ \(lastError.localizedDescription)"
            )
        }
    }

    private func aiChatSystemPrompt() -> String {
        switch appLanguage {
        case .english:
            return """
            You are soranin AI chat inside an iPhone app for Sora video downloads, Reels conversion, titles, and prompts.
            Reply clearly and helpfully.
            Match the user's language when possible. If the user writes Khmer, reply in Khmer. Otherwise reply in English.
            Keep responses concise but useful.
            The user may attach images or videos. If a video is attached, analyze the full video when possible or use the provided ordered frames carefully.
            If the user asks for a prompt, label each English prompt clearly as Prompt 1:, Prompt 2:, and so on, then add a short Khmer note if useful.
            If the user asks for steps, give practical step-by-step help.
            If the user asks for a specific number of prompts, titles, ideas, or options, return exactly that number.
            Never say you made 5 items and then only show 3.
            If the answer is getting long, shorten each item instead of dropping items.
            """
        case .khmer:
            return """
            You are soranin AI chat inside an iPhone app for Sora video downloads, Reels conversion, titles, and prompts.
            សូមឆ្លើយតបឲ្យច្បាស់ ងាយយល់ និងមានប្រយោជន៍។
            បើអ្នកប្រើសរសេរជាភាសាខ្មែរ សូមឆ្លើយជាភាសាខ្មែរ។ បើជាអង់គ្លេស សូមឆ្លើយជាអង់គ្លេស។
            រក្សាចម្លើយឲ្យខ្លី តែមានព័ត៌មានគ្រប់គ្រាន់។
            អ្នកប្រើអាចភ្ជាប់រូបភាព ឬ វីដេអូមកជាមួយសារ។ បើមានវីដេអូ សូមវិភាគវីដេអូទាំងមូលឲ្យបានល្អបំផុត ឬប្រើ frames ដែលបានផ្ដល់តាមលំដាប់ពេលវេលា។
            បើអ្នកប្រើសុំ prompt សូមដាក់ស្លាកជាភាសាអង់គ្លេសឲ្យច្បាស់ ដូចជា Prompt 1:, Prompt 2: ហើយអាចបន្ថែមសេចក្តីពន្យល់ខ្លីជាភាសាខ្មែរខាងក្រោមបាន។
            បើអ្នកប្រើស្នើចំនួនជាក់លាក់ ដូចជា 5 prompts, 10 titles ឬ 4 ideas សូមឆ្លើយឲ្យគ្រប់ចំនួននោះពិតៗ។
            កុំប្រាប់ថាបានបង្កើត 5 ប៉ុន្តែបង្ហាញតែ 3។
            បើចម្លើយវែងពេក សូមបង្រួម item នីមួយៗ ប៉ុន្តែកុំបោះចោល item។
            """
        }
    }

    private func completedPromptReplyIfNeeded(
        initialReply: String,
        latestRequest: String,
        conversation: [AIChatMessage],
        systemPrompt: String,
        provider: AIProvider,
        apiKey: String
    ) async throws -> String {
        let requestedCount = AIChatPromptExtractor.requestedPromptCount(from: latestRequest)
        guard requestedCount > 1, AIChatPromptExtractor.wantsPromptOnly(latestRequest) else {
            return initialReply
        }

        var combinedReply = initialReply.trimmingCharacters(in: .whitespacesAndNewlines)
        var promptBlocks = AIChatPromptExtractor.extractPromptBlocks(from: combinedReply)
        guard !promptBlocks.isEmpty, promptBlocks.count < requestedCount else {
            return combinedReply
        }

        for _ in 0 ..< 2 {
            let remainingCount = requestedCount - promptBlocks.count
            guard remainingCount > 0 else { break }

            let completedList = promptBlocks.enumerated().map { index, prompt in
                "\(index + 1). \(prompt)"
            }.joined(separator: "\n")

            let continuationInstruction = """
            The user asked for \(requestedCount) prompts.
            You have already returned \(promptBlocks.count) complete prompts below:
            \(completedList)

            Continue with exactly \(remainingCount) more complete prompts only.
            Keep the same format as before.
            Start from item \(promptBlocks.count + 1).
            Do not repeat earlier prompts.
            Finish every remaining item completely.
            """

            var followUpConversation = conversation
            followUpConversation.append(AIChatMessage(role: "assistant", content: combinedReply))

            let continuationReply: String
            do {
                switch provider {
                case .googleGemini:
                    continuationReply = try await GoogleAIChatService.sendConversation(
                        messages: followUpConversation + [AIChatMessage(role: "user", content: continuationInstruction)],
                        systemPrompt: systemPrompt,
                        apiKey: apiKey,
                        modelName: selectedModelID(for: .googleGemini)
                    )
                case .openAI:
                    continuationReply = try await OpenAIChatService.sendConversation(
                        messages: followUpConversation + [AIChatMessage(role: "user", content: continuationInstruction)],
                        systemPrompt: systemPrompt,
                        apiKey: apiKey,
                        modelID: selectedModelID(for: .openAI)
                    )
                }
            } catch {
                break
            }

            let trimmedContinuation = continuationReply.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedContinuation.isEmpty else { break }

            combinedReply += "\n\n" + trimmedContinuation
            let updatedPromptBlocks = AIChatPromptExtractor.extractPromptBlocks(from: combinedReply)
            guard updatedPromptBlocks.count > promptBlocks.count else { break }
            promptBlocks = updatedPromptBlocks
        }

        return combinedReply
    }

    private func appendAIChatMessage(_ message: AIChatMessage) {
        aiChatMessages.append(message)
        trimAIChatMessages()
        persistCurrentAIChatSession()
    }

    private func trimAIChatMessages() {
        guard aiChatMessages.count > 30 else { return }
        aiChatMessages = Array(aiChatMessages.suffix(30))
    }

    private func bootstrapAIChatSessions() {
        let store = loadAIChatStore()
        aiChatSessions = store.sessions
            .map { session in
                var normalized = session
                if let derivedTitle = AIChatSession.derivedTitle(from: normalized.messages),
                   normalized.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || normalized.title == "New Chat" {
                    normalized.title = derivedTitle
                }
                return normalized
            }
            .sorted { $0.updatedAt > $1.updatedAt }

        if let currentID = store.currentSessionID,
           let current = aiChatSessions.first(where: { $0.id == currentID }) {
            currentAIChatSessionID = current.id
            aiChatMessages = current.messages
            aiChatStatus = text("AI chat is ready.", "AI chat រួចរាល់ហើយ។")
            return
        }

        if let latest = aiChatSessions.first {
            currentAIChatSessionID = latest.id
            aiChatMessages = latest.messages
            aiChatStatus = text("AI chat is ready.", "AI chat រួចរាល់ហើយ។")
            persistAIChatStore()
            return
        }

        startNewAIChatSession()
    }

    private func loadAIChatStore() -> AIChatStore {
        guard let storeURL = try? aiChatStoreURL(),
              let data = try? Data(contentsOf: storeURL),
              let store = try? JSONDecoder().decode(AIChatStore.self, from: data) else {
            return AIChatStore(currentSessionID: nil, sessions: [])
        }

        return store
    }

    private func persistCurrentAIChatSession(markUpdated: Bool = true) {
        let now = Date()

        if let currentAIChatSessionID,
           let index = aiChatSessions.firstIndex(where: { $0.id == currentAIChatSessionID }) {
            aiChatSessions[index].messages = aiChatMessages
            if let derivedTitle = AIChatSession.derivedTitle(from: aiChatMessages),
               aiChatSessions[index].title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || aiChatSessions[index].title == "New Chat" {
                aiChatSessions[index].title = derivedTitle
            }
            if markUpdated {
                aiChatSessions[index].updatedAt = now
            }
        } else {
            let session = AIChatSession(
                id: currentAIChatSessionID ?? UUID(),
                createdAt: now,
                updatedAt: now,
                title: AIChatSession.derivedTitle(from: aiChatMessages) ?? "New Chat",
                messages: aiChatMessages
            )
            currentAIChatSessionID = session.id
            aiChatSessions.insert(session, at: 0)
        }

        aiChatSessions.sort { $0.updatedAt > $1.updatedAt }
        persistAIChatStore()
    }

    private func persistAIChatStore() {
        guard let storeURL = try? aiChatStoreURL() else { return }

        let store = AIChatStore(
            currentSessionID: currentAIChatSessionID,
            sessions: aiChatSessions
        )

        guard let data = try? JSONEncoder().encode(store) else { return }
        try? data.write(to: storeURL, options: [.atomic])
    }

    private func aiChatStoreURL() throws -> URL {
        try historiesDirectoryURL().appendingPathComponent(Self.aiChatFileName)
    }
}

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    private let lock = NSLock()
    private let progressHandler: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var hasResolved = false

    init(progressHandler: @escaping @Sendable (Double) -> Void) {
        self.progressHandler = progressHandler
    }

    func download(with request: URLRequest) async throws -> (URL, URLResponse) {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            session.downloadTask(with: request).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }

        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        progressHandler(min(max(progress, 0), 1))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let response = downloadTask.response else {
            resolve(with: .failure(SoraDownloadError.invalidResponse), session: session)
            return
        }

        progressHandler(1)
        do {
            let preservedURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(location.pathExtension.isEmpty ? "mp4" : location.pathExtension)

            if FileManager.default.fileExists(atPath: preservedURL.path) {
                try FileManager.default.removeItem(at: preservedURL)
            }

            try FileManager.default.copyItem(at: location, to: preservedURL)
            resolve(with: .success((preservedURL, response)), session: session)
        } catch {
            resolve(with: .failure(error), session: session)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        resolve(with: .failure(error), session: session)
    }

    private func resolve(with result: Result<(URL, URLResponse), Error>, session: URLSession) {
        lock.lock()
        guard !hasResolved else {
            lock.unlock()
            return
        }

        hasResolved = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        switch result {
        case .success(let value):
            continuation?.resume(returning: value)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }

        session.finishTasksAndInvalidate()
    }
}

enum SoraDownloadError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case photoSaveFailed

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The server response was not valid."
        case .httpStatus(let statusCode):
            return "The server returned HTTP \(statusCode)."
        case .photoSaveFailed:
            return "The video could not be written to Photos."
        }
    }
}
