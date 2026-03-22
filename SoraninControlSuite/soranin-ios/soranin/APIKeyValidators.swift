import Foundation

enum OpenAIAPIKeyValidationError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case emptyOutput
    case httpStatus(Int, String?)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Paste an OpenAI API key first."
        case .invalidResponse:
            return "OpenAI returned a response soranin could not read."
        case .emptyOutput:
            return "OpenAI did not return a validation response."
        case .httpStatus(let statusCode, let message):
            if let message, !message.isEmpty {
                return "OpenAI error \(statusCode): \(message)"
            }
            return "OpenAI error \(statusCode)."
        }
    }
}

enum GoogleAIAPIKeyValidationError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case emptyOutput
    case httpStatus(Int, String?)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Paste a Google AI Studio API key first."
        case .invalidResponse:
            return "Google AI Studio returned a response soranin could not read."
        case .emptyOutput:
            return "Google AI Studio did not return a validation response."
        case .httpStatus(let statusCode, let message):
            if let message, !message.isEmpty {
                return "Google AI Studio error \(statusCode): \(message)"
            }
            return "Google AI Studio error \(statusCode)."
        }
    }
}

private struct OpenAIValidationEnvelope: Decodable {
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

private struct GoogleAIValidationEnvelope: Decodable {
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

enum OpenAIAPIKeyValidator {
    static func validate(_ rawKey: String, modelID: String) async throws {
        let trimmedKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw OpenAIAPIKeyValidationError.missingAPIKey
        }

        guard let encodedModelID = modelID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let endpoint = URL(string: "https://api.openai.com/v1/models/\(encodedModelID)") else {
            throw OpenAIAPIKeyValidationError.invalidResponse
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIAPIKeyValidationError.invalidResponse
        }

        let envelope = try? JSONDecoder().decode(OpenAIValidationEnvelope.self, from: data)
        guard (200...299).contains(httpResponse.statusCode) else {
            throw OpenAIAPIKeyValidationError.httpStatus(
                httpResponse.statusCode,
                envelope?.error?.message
            )
        }
    }
}

enum GoogleAIAPIKeyValidator {
    static func validate(_ rawKey: String, modelID: String) async throws {
        let trimmedKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw GoogleAIAPIKeyValidationError.missingAPIKey
        }
        guard let encodedModelID = modelID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(encodedModelID)") else {
            throw GoogleAIAPIKeyValidationError.invalidResponse
        }

        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "key", value: trimmedKey)
        ]

        guard let url = components?.url else {
            throw GoogleAIAPIKeyValidationError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GoogleAIAPIKeyValidationError.invalidResponse
        }

        if !(200...299).contains(httpResponse.statusCode) {
            let apiError = try? JSONDecoder().decode(GoogleAIValidationEnvelope.APIErrorEnvelope.self, from: data)
            throw GoogleAIAPIKeyValidationError.httpStatus(
                httpResponse.statusCode,
                apiError?.error?.message
            )
        }
    }
}
