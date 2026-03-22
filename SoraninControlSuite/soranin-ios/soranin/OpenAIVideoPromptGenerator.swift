import AVFoundation
import Foundation
import UIKit

enum OpenAIVideoPromptGeneratorError: LocalizedError {
    case missingAPIKey
    case frameSamplingFailed
    case invalidResponse
    case emptyOutput
    case httpStatus(Int, String?)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add your OpenAI API key first."
        case .frameSamplingFailed:
            return "soranin could not prepare enough video frames for the AI prompt."
        case .invalidResponse:
            return "OpenAI returned a response soranin could not read."
        case .emptyOutput:
            return "OpenAI did not return any prompt text."
        case .httpStatus(let statusCode, let message):
            if let message, !message.isEmpty {
                return "OpenAI error \(statusCode): \(message)"
            }
            return "OpenAI error \(statusCode)."
        }
    }
}

private struct OpenAIPromptFrame {
    let second: Double
    let dataURL: String
}

private struct OpenAIPromptResponsesEnvelope: Decodable {
    struct ResponseError: Decodable {
        let message: String?
    }

    struct OutputItem: Decodable {
        let type: String
        let content: [ContentPart]?
    }

    struct ContentPart: Decodable {
        let type: String
        let text: String?
    }

    let error: ResponseError?
    let output: [OutputItem]?
}

enum OpenAIVideoPromptGenerator {
    private static let endpoint = URL(string: "https://api.openai.com/v1/responses")!

    static func generatePrompt(
        for videoURL: URL,
        apiKey: String,
        modelID: String,
        appLanguage: AppLanguage
    ) async throws -> String {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw OpenAIVideoPromptGeneratorError.missingAPIKey
        }

        let frames = try await sampledFrames(from: videoURL)
        guard !frames.isEmpty else {
            throw OpenAIVideoPromptGeneratorError.frameSamplingFailed
        }

        var content: [[String: Any]] = [
            [
                "type": "input_text",
                "text": prompt(for: videoURL, appLanguage: appLanguage, frames: frames)
            ]
        ]

        content.append(
            contentsOf: frames.map { frame in
                [
                    "type": "input_image",
                    "image_url": frame.dataURL
                ]
            }
        )

        let body: [String: Any] = [
            "model": modelID,
            "store": false,
            "temperature": 0.5,
            "max_output_tokens": 420,
            "input": [
                [
                    "role": "user",
                    "content": content
                ]
            ]
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body, options: [])

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = bodyData

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIVideoPromptGeneratorError.invalidResponse
        }

        let decoder = JSONDecoder()
        let envelope = try? decoder.decode(OpenAIPromptResponsesEnvelope.self, from: data)

        guard (200...299).contains(httpResponse.statusCode) else {
            throw OpenAIVideoPromptGeneratorError.httpStatus(
                httpResponse.statusCode,
                envelope?.error?.message
            )
        }

        guard let envelope else {
            throw OpenAIVideoPromptGeneratorError.invalidResponse
        }

        let outputText = envelope.output?
            .flatMap { $0.content ?? [] }
            .first(where: { $0.type == "output_text" })?
            .text?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let outputText, !outputText.isEmpty else {
            throw OpenAIVideoPromptGeneratorError.emptyOutput
        }

        return outputText
    }

    private static func prompt(
        for videoURL: URL,
        appLanguage: AppLanguage,
        frames: [OpenAIPromptFrame]
    ) -> String {
        _ = appLanguage

        let asset = AVURLAsset(url: videoURL)
        let durationSeconds = max(CMTimeGetSeconds(asset.duration), 0)
        let timeline = frames
            .enumerated()
            .map { index, frame in
                "Frame \(index + 1): \(playbackTimestamp(frame.second))"
            }
            .joined(separator: ", ")
        let fileNameHint = cleanedVideoName(from: videoURL)

        return """
        First describe the video clearly, then convert it into a Sora prompt.

        Write everything in natural English.
        Use only what is clearly visible in the provided frames and timeline order.
        Ignore editor UI, buttons, text fields, borders, and app chrome.
        Do not invent actions, people, objects, settings, or camera moves that are not clearly visible.
        Use the source video name only as a hint if helpful: \(fileNameHint)

        Rules:
        - The first line must be exactly: Description
        - The second line must be one clear English description paragraph of the video.
        - The third line must be exactly: Sora Prompt
        - The fourth line must be one polished English Sora prompt ready to paste into Sora.
        - The Sora prompt should mention the visible subject, action, environment, framing, lighting, motion, and style when they are clearly visible.
        - Keep it vivid but truthful to the visible video.
        - Do not use quotes or bullet points.
        - Output exactly 4 lines only.

        Video duration: \(playbackTimestamp(durationSeconds)).
        The frames are in chronological order: \(timeline).
        """
    }

    private static func sampledFrames(from videoURL: URL) async throws -> [OpenAIPromptFrame] {
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration)
        let durationSeconds = max(CMTimeGetSeconds(duration), 0.3)
        let fractions: [Double] = [0.06, 0.18, 0.32, 0.46, 0.60, 0.74, 0.88]
        var frames: [OpenAIPromptFrame] = []
        var seenMoments = Set<String>()

        for fraction in fractions {
            let second = max(0, min(durationSeconds * fraction, max(durationSeconds - 0.05, 0)))
            let momentKey = String(format: "%.2f", second)
            guard seenMoments.insert(momentKey).inserted else { continue }

            guard let rawData = try? await ReelsVideoExporter.capturePhotoData(sourceURL: videoURL, at: second),
                  let dataURL = makeDataURL(from: rawData) else {
                continue
            }

            frames.append(OpenAIPromptFrame(second: second, dataURL: dataURL))
        }

        guard frames.count >= 2 else {
            throw OpenAIVideoPromptGeneratorError.frameSamplingFailed
        }

        return frames
    }

    private static func makeDataURL(from imageData: Data) -> String? {
        guard let image = UIImage(data: imageData) else { return nil }
        let resized = resizedImage(image, maxDimension: 768)
        guard let jpegData = resized.jpegData(compressionQuality: 0.68) else { return nil }
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

    private static func playbackTimestamp(_ seconds: Double) -> String {
        let safeSeconds = max(Int(seconds.rounded(.down)), 0)
        let minutes = safeSeconds / 60
        let remainingSeconds = safeSeconds % 60
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }
}
