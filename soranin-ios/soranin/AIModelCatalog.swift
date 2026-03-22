import Foundation

struct AIModelOption: Identifiable, Hashable {
    let id: String
    let title: String
    let isLatest: Bool
    let isPreview: Bool

    var badgeText: String? {
        if isLatest {
            return "New"
        }

        if isPreview {
            return "Preview"
        }

        return nil
    }
}

private struct OpenAIModelsEnvelope: Decodable {
    struct Model: Decodable {
        let id: String
    }

    let data: [Model]
}

private struct GoogleModelsEnvelope: Decodable {
    struct Model: Decodable {
        let name: String
        let displayName: String?
        let supportedGenerationMethods: [String]?
    }

    let models: [Model]
}

enum AIModelCatalog {
    private static let openAIDefaultModels: [AIModelOption] = [
        AIModelOption(id: "gpt-5.4", title: "gpt-5.4", isLatest: true, isPreview: false),
        AIModelOption(id: "gpt-5.2", title: "gpt-5.2", isLatest: true, isPreview: false),
        AIModelOption(id: "gpt-5.1", title: "gpt-5.1", isLatest: true, isPreview: false),
        AIModelOption(id: "gpt-5-mini", title: "gpt-5-mini", isLatest: true, isPreview: false),
        AIModelOption(id: "gpt-5-nano", title: "gpt-5-nano", isLatest: true, isPreview: false),
        AIModelOption(id: "gpt-4.1", title: "gpt-4.1", isLatest: false, isPreview: false),
        AIModelOption(id: "gpt-4.1-mini", title: "gpt-4.1-mini", isLatest: false, isPreview: false),
        AIModelOption(id: "gpt-4.1-nano", title: "gpt-4.1-nano", isLatest: false, isPreview: false),
        AIModelOption(id: "gpt-4o", title: "gpt-4o", isLatest: false, isPreview: false),
        AIModelOption(id: "gpt-4o-mini", title: "gpt-4o-mini", isLatest: false, isPreview: false),
        AIModelOption(id: "chatgpt-4o-latest", title: "chatgpt-4o-latest", isLatest: false, isPreview: true)
    ]

    private static let googleDefaultModels: [AIModelOption] = [
        AIModelOption(id: "gemini-2.5-pro", title: "gemini-2.5-pro", isLatest: true, isPreview: false),
        AIModelOption(id: "gemini-2.5-flash", title: "gemini-2.5-flash", isLatest: true, isPreview: false),
        AIModelOption(id: "gemini-2.5-flash-lite", title: "gemini-2.5-flash-lite", isLatest: true, isPreview: false),
        AIModelOption(id: "gemini-2.0-flash", title: "gemini-2.0-flash", isLatest: false, isPreview: false),
        AIModelOption(id: "gemini-1.5-pro", title: "gemini-1.5-pro", isLatest: false, isPreview: false),
        AIModelOption(id: "gemini-1.5-flash", title: "gemini-1.5-flash", isLatest: false, isPreview: false)
    ]

    static func defaultModels(for provider: AIProvider) -> [AIModelOption] {
        switch provider {
        case .googleGemini:
            return googleDefaultModels
        case .openAI:
            return openAIDefaultModels
        }
    }

    static func defaultModelID(for provider: AIProvider) -> String {
        defaultModels(for: provider).first?.id ?? ""
    }

    static func option(for provider: AIProvider, id: String) -> AIModelOption {
        if let known = defaultModels(for: provider).first(where: { $0.id == id }) {
            return known
        }

        return AIModelOption(
            id: id,
            title: id,
            isLatest: false,
            isPreview: id.localizedCaseInsensitiveContains("preview") || id.localizedCaseInsensitiveContains("latest")
        )
    }

    static func mergedModels(
        for provider: AIProvider,
        primary: [AIModelOption],
        fallback: [AIModelOption],
        selectedID: String?
    ) -> [AIModelOption] {
        var merged: [AIModelOption] = []
        var seen = Set<String>()

        for option in primary + fallback {
            guard seen.insert(option.id).inserted else { continue }
            merged.append(option)
        }

        if let selectedID, !selectedID.isEmpty, seen.insert(selectedID).inserted {
            merged.insert(option(for: provider, id: selectedID), at: 0)
        }

        return merged
    }

    static func fetchOpenAIModels(apiKey: String) async -> [AIModelOption]? {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return nil }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200 ... 299).contains(httpResponse.statusCode) else {
                return nil
            }

            let envelope = try JSONDecoder().decode(OpenAIModelsEnvelope.self, from: data)
            let filtered = envelope.data
                .map(\.id)
                .filter(isOpenAITextOrVisionModel(_:))
                .map { modelID in
                    AIModelOption(
                        id: modelID,
                        title: modelID,
                        isLatest: modelID.hasPrefix("gpt-5"),
                        isPreview: modelID.localizedCaseInsensitiveContains("preview") || modelID.localizedCaseInsensitiveContains("latest")
                    )
                }
                .sorted(by: { left, right in
                    openAISortRank(left.id) < openAISortRank(right.id)
                })

            return filtered.isEmpty ? nil : filtered
        } catch {
            return nil
        }
    }

    static func fetchGoogleModels(apiKey: String) async -> [AIModelOption]? {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return nil }

        var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models")
        components?.queryItems = [
            URLQueryItem(name: "key", value: trimmedKey)
        ]

        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200 ... 299).contains(httpResponse.statusCode) else {
                return nil
            }

            let envelope = try JSONDecoder().decode(GoogleModelsEnvelope.self, from: data)
            let filtered = envelope.models
                .compactMap { model -> AIModelOption? in
                    guard let methods = model.supportedGenerationMethods,
                          methods.contains("generateContent") else {
                        return nil
                    }

                    let modelID = model.name.replacingOccurrences(of: "models/", with: "")
                    guard isGooglePromptModel(modelID) else { return nil }

                    return AIModelOption(
                        id: modelID,
                        title: modelID,
                        isLatest: modelID.hasPrefix("gemini-2.5"),
                        isPreview: modelID.localizedCaseInsensitiveContains("preview") || modelID.localizedCaseInsensitiveContains("exp")
                    )
                }
                .sorted(by: { left, right in
                    googleSortRank(left.id) < googleSortRank(right.id)
                })

            return filtered.isEmpty ? nil : filtered
        } catch {
            return nil
        }
    }

    private static func isOpenAITextOrVisionModel(_ modelID: String) -> Bool {
        let lowercased = modelID.lowercased()

        guard lowercased.hasPrefix("gpt-") || lowercased == "chatgpt-4o-latest" else {
            return false
        }

        let excludedSnippets = [
            "audio",
            "transcribe",
            "tts",
            "realtime",
            "search",
            "moderation",
            "embedding",
            "image",
            "whisper",
            "babbage",
            "davinci"
        ]

        return !excludedSnippets.contains(where: { lowercased.contains($0) })
    }

    private static func isGooglePromptModel(_ modelID: String) -> Bool {
        let lowercased = modelID.lowercased()

        guard lowercased.hasPrefix("gemini-") else {
            return false
        }

        let excludedSnippets = [
            "embedding",
            "image",
            "live",
            "dialog",
            "aqa",
            "veo",
            "robotics",
            "computer",
            "deep-research",
            "tts"
        ]

        return !excludedSnippets.contains(where: { lowercased.contains($0) })
    }

    private static func openAISortRank(_ modelID: String) -> String {
        let priority = [
            "gpt-5.4",
            "gpt-5.2",
            "gpt-5.1",
            "gpt-5-mini",
            "gpt-5-nano",
            "gpt-4.1",
            "gpt-4.1-mini",
            "gpt-4.1-nano",
            "gpt-4o",
            "gpt-4o-mini",
            "chatgpt-4o-latest"
        ]

        if let index = priority.firstIndex(of: modelID) {
            return String(format: "%02d-%@", index, modelID)
        }

        return "99-\(modelID)"
    }

    private static func googleSortRank(_ modelID: String) -> String {
        let priority = [
            "gemini-2.5-pro",
            "gemini-2.5-flash",
            "gemini-2.5-flash-lite",
            "gemini-2.0-flash",
            "gemini-1.5-pro",
            "gemini-1.5-flash"
        ]

        if let index = priority.firstIndex(of: modelID) {
            return String(format: "%02d-%@", index, modelID)
        }

        return "99-\(modelID)"
    }
}
