import AVFoundation
import Foundation
import UniformTypeIdentifiers

enum GoogleAIVideoPromptGeneratorError: LocalizedError {
    case missingAPIKey
    case unreadableVideo
    case invalidResponse
    case emptyOutput
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
            return "soranin could not read the selected video for the AI prompt."
        case .invalidResponse:
            return "Google AI Studio returned a response soranin could not read."
        case .emptyOutput:
            return "Google AI Studio did not return any prompt text."
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

private struct GoogleAIVideoPromptResponse: Decodable {
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

private struct GoogleAIPromptUploadedFile: Decodable {
    let name: String
    let uri: String?
    let mimeType: String?
    let state: String?
}

private struct GoogleAIPromptUploadedFileEnvelope: Decodable {
    let file: GoogleAIPromptUploadedFile?
}

enum GoogleAIVideoPromptGenerator {
    private static let uploadEndpoint = URL(string: "https://generativelanguage.googleapis.com/upload/v1beta/files")!

    static func generatePrompt(
        for videoURL: URL,
        apiKey: String,
        modelName: String,
        appLanguage: AppLanguage
    ) async throws -> String {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw GoogleAIVideoPromptGeneratorError.missingAPIKey
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
            throw GoogleAIVideoPromptGeneratorError.missingFileURI
        }

        let prompt = prompt(for: videoURL, appLanguage: appLanguage)
        let body: [String: Any] = [
            "contents": [
                [
                    "role": "user",
                    "parts": [
                        [
                            "text": prompt
                        ],
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
                "temperature": 0.5,
                "maxOutputTokens": 1200,
                "responseMimeType": "text/plain"
            ]
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body, options: [])
        guard let encodedModelName = modelName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let generateEndpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(encodedModelName):generateContent") else {
            throw GoogleAIVideoPromptGeneratorError.invalidResponse
        }

        var components = URLComponents(url: generateEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "key", value: trimmedKey)
        ]

        guard let url = components?.url else {
            throw GoogleAIVideoPromptGeneratorError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GoogleAIVideoPromptGeneratorError.invalidResponse
        }

        if !(200...299).contains(httpResponse.statusCode) {
            let apiError = try? JSONDecoder().decode(GoogleAIVideoPromptResponse.APIErrorEnvelope.self, from: data)
            throw GoogleAIVideoPromptGeneratorError.httpStatus(
                httpResponse.statusCode,
                apiError?.error?.message
            )
        }

        let envelope = try JSONDecoder().decode(GoogleAIVideoPromptResponse.self, from: data)
        let outputText = envelope.candidates?
            .flatMap { $0.content?.parts ?? [] }
            .compactMap(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let outputText, !outputText.isEmpty else {
            throw GoogleAIVideoPromptGeneratorError.emptyOutput
        }

        return outputText
    }

    private static func prompt(
        for videoURL: URL,
        appLanguage: AppLanguage
    ) -> String {
        _ = appLanguage

        let asset = AVURLAsset(url: videoURL)
        let durationSeconds = max(CMTimeGetSeconds(asset.duration), 0)
        let fileNameHint = cleanedVideoName(from: videoURL)

        return """
        First describe the video clearly, then convert it into a Sora prompt.

        Write everything in natural English.
        Use the whole uploaded video to understand the real subject, action, setting, camera view, mood, motion, and any meaningful sound, dialogue, or audio cues if they are clearly present.
        Ignore editor chrome, UI, buttons, watermarks, or anything outside the actual video content.
        Do not invent people, actions, camera moves, environments, clothing, or story beats that are not visible.
        The source video name is only a hint if helpful: \(fileNameHint)

        Rules:
        - The first line must be exactly: Description
        - The second line must be one clear English description paragraph of the video.
        - The third line must be exactly: Sora Prompt
        - The fourth line must be one polished English Sora prompt ready to paste into Sora.
        - The Sora prompt should mention the visible subject, action, environment, framing, lighting, motion, style, and audio mood only when they are actually present in the uploaded video.
        - Keep the Sora prompt vivid and useful, but truthful to the video.
        - Do not use quotes or bullet points.
        - Output exactly 4 lines only.

        Video duration: \(playbackTimestamp(durationSeconds)).
        """
    }

    private static func uploadVideo(
        _ videoURL: URL,
        apiKey: String
    ) async throws -> GoogleAIPromptUploadedFile {
        guard let videoData = try? Data(contentsOf: videoURL), !videoData.isEmpty else {
            throw GoogleAIVideoPromptGeneratorError.unreadableVideo
        }

        let mimeType = mimeType(for: videoURL)
        let fileSize = videoData.count
        let displayName = cleanedVideoName(from: videoURL)

        var components = URLComponents(url: uploadEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "key", value: apiKey)
        ]

        guard let startURL = components?.url else {
            throw GoogleAIVideoPromptGeneratorError.invalidResponse
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
            throw GoogleAIVideoPromptGeneratorError.invalidResponse
        }

        if !(200...299).contains(startHTTPResponse.statusCode) {
            let apiError = try? JSONDecoder().decode(GoogleAIVideoPromptResponse.APIErrorEnvelope.self, from: startData)
            throw GoogleAIVideoPromptGeneratorError.httpStatus(
                startHTTPResponse.statusCode,
                apiError?.error?.message
            )
        }

        guard let uploadURLString = startHTTPResponse.value(forHTTPHeaderField: "X-Goog-Upload-URL"),
              let uploadURL = URL(string: uploadURLString) else {
            throw GoogleAIVideoPromptGeneratorError.missingUploadURL
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
            throw GoogleAIVideoPromptGeneratorError.invalidResponse
        }

        if !(200...299).contains(uploadHTTPResponse.statusCode) {
            let apiError = try? JSONDecoder().decode(GoogleAIVideoPromptResponse.APIErrorEnvelope.self, from: uploadData)
            throw GoogleAIVideoPromptGeneratorError.httpStatus(
                uploadHTTPResponse.statusCode,
                apiError?.error?.message
            )
        }

        let uploadedFile = try JSONDecoder().decode(GoogleAIPromptUploadedFileEnvelope.self, from: uploadData).file
        guard let uploadedFile else {
            throw GoogleAIVideoPromptGeneratorError.missingUploadedFile
        }

        return uploadedFile
    }

    private static func waitUntilVideoFileIsReady(
        named fileName: String,
        initialFile: GoogleAIPromptUploadedFile,
        apiKey: String
    ) async throws -> GoogleAIPromptUploadedFile {
        let initialState = initialFile.state?.uppercased() ?? "ACTIVE"
        if initialState == "ACTIVE" {
            return initialFile
        }

        if initialState == "FAILED" {
            throw GoogleAIVideoPromptGeneratorError.fileProcessingFailed(nil)
        }

        for _ in 0..<45 {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            let file = try await fetchUploadedFile(named: fileName, apiKey: apiKey)
            let state = file.state?.uppercased() ?? "ACTIVE"

            if state == "ACTIVE" {
                return file
            }

            if state == "FAILED" {
                throw GoogleAIVideoPromptGeneratorError.fileProcessingFailed(file.state)
            }
        }

        throw GoogleAIVideoPromptGeneratorError.fileProcessingTimedOut
    }

    private static func fetchUploadedFile(
        named fileName: String,
        apiKey: String
    ) async throws -> GoogleAIPromptUploadedFile {
        guard var components = URLComponents(
            string: "https://generativelanguage.googleapis.com/v1beta/\(fileName)"
        ) else {
            throw GoogleAIVideoPromptGeneratorError.invalidResponse
        }

        components.queryItems = [
            URLQueryItem(name: "key", value: apiKey)
        ]

        guard let url = components.url else {
            throw GoogleAIVideoPromptGeneratorError.invalidResponse
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GoogleAIVideoPromptGeneratorError.invalidResponse
        }

        if !(200...299).contains(httpResponse.statusCode) {
            let apiError = try? JSONDecoder().decode(GoogleAIVideoPromptResponse.APIErrorEnvelope.self, from: data)
            throw GoogleAIVideoPromptGeneratorError.httpStatus(
                httpResponse.statusCode,
                apiError?.error?.message
            )
        }

        return try JSONDecoder().decode(GoogleAIPromptUploadedFile.self, from: data)
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
        let safeSeconds = max(Int(seconds.rounded(.down)), 0)
        let minutes = safeSeconds / 60
        let remainingSeconds = safeSeconds % 60
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }
}
