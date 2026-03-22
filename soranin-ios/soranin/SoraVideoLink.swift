import Foundation

enum SoraVideoLink {
    struct ExtractedVideoSource: Equatable {
        let videoID: String
        let sourceText: String
        let location: Int
    }

    private static let proxyHost = ["sora", "vdl.com"].joined()
    static let proxyBase = URL(string: "https://\(proxyHost)/api/proxy/video")!
    static let proxyPublicBase = URL(string: "https://\(proxyHost)/public/api/proxy/video")!
    private static let streamHost = "soradown.online"
    static let streamBase = URL(string: "https://\(streamHost)/api/stream.php")!

    private static let proxyRegex = try! NSRegularExpression(
        pattern: "https?://(?:www\\.)?" + NSRegularExpression.escapedPattern(for: proxyHost) + "/api/proxy/video/([^/?#]+)",
        options: [.caseInsensitive]
    )

    private static let proxyPublicRegex = try! NSRegularExpression(
        pattern: "https?://(?:www\\.)?" + NSRegularExpression.escapedPattern(for: proxyHost) + "/public/api/proxy/video/([^/?#]+)",
        options: [.caseInsensitive]
    )

    private static let streamRegex = try! NSRegularExpression(
        pattern: "https?://(?:www\\.)?" + NSRegularExpression.escapedPattern(for: streamHost) + "/api/stream\\.php\\?id=([^&#]+)",
        options: [.caseInsensitive]
    )

    private static let soraPageRegex = try! NSRegularExpression(
        pattern: #"https?://sora\.chatgpt\.com/(?:p|d)/([^/?#]+)"#,
        options: [.caseInsensitive]
    )

    private static let soraIDRegex = try! NSRegularExpression(
        pattern: #"\b(s_[A-Za-z0-9_-]{8,})\b"#,
        options: [.caseInsensitive]
    )

    private static let draftIDRegex = try! NSRegularExpression(
        pattern: #"\b(gen_[A-Za-z0-9_-]{8,})\b"#,
        options: [.caseInsensitive]
    )

    private static let exactIDRegex = try! NSRegularExpression(
        pattern: #"^(s_|gen_)[A-Za-z0-9_-]{8,}$"#,
        options: []
    )

    static func extractVideoID(from rawInput: String) -> String? {
        extractVideoIDs(from: rawInput).first
    }

    static func extractVideoIDs(from rawInput: String) -> [String] {
        extractVideoSources(from: rawInput).map(\.videoID)
    }

    static func extractVideoSources(from rawInput: String) -> [ExtractedVideoSource] {
        let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return [] }

        var orderedMatches: [ExtractedVideoSource] = []
        if isExactVideoID(input) {
            orderedMatches.append(
                ExtractedVideoSource(
                    videoID: input,
                    sourceText: input,
                    location: 0
                )
            )
        }

        orderedMatches += capturedSourceMatches(in: input, using: proxyRegex)
        orderedMatches += capturedSourceMatches(in: input, using: proxyPublicRegex)
        orderedMatches += capturedSourceMatches(in: input, using: streamRegex)
        orderedMatches += capturedSourceMatches(in: input, using: soraPageRegex)
        orderedMatches += capturedWholeMatches(in: input, using: soraIDRegex)
        orderedMatches += capturedWholeMatches(in: input, using: draftIDRegex)

        let sortedMatches = orderedMatches.sorted { lhs, rhs in
            if lhs.location == rhs.location {
                return lhs.videoID < rhs.videoID
            }
            return lhs.location < rhs.location
        }

        var uniqueSources: [ExtractedVideoSource] = []
        var seenIDs = Set<String>()
        for match in sortedMatches {
            let key = match.videoID.lowercased()
            guard seenIDs.insert(key).inserted else { continue }
            uniqueSources.append(match)
        }

        return uniqueSources
    }

    static func shouldNormalizeToVideoID(_ rawInput: String) -> Bool {
        let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return false }

        return input.contains("http://")
            || input.contains("https://")
            || input.contains("sora.chatgpt.com")
            || input.contains(proxyHost)
            || input.contains(streamHost)
            || input.contains("/")
            || input.contains("?")
            || input.contains("&")
            || input.contains(" ")
            || input.contains("\n")
    }

    static func proxyURL(for videoID: String) -> URL {
        let cleanID = videoID.trimmingCharacters(in: .whitespacesAndNewlines)
        return proxyBase.appending(path: cleanID)
    }

    static func proxyPublicURL(for videoID: String) -> URL {
        let cleanID = videoID.trimmingCharacters(in: .whitespacesAndNewlines)
        return proxyPublicBase.appending(path: cleanID)
    }

    static func streamURL(for videoID: String) -> URL {
        let cleanID = videoID.trimmingCharacters(in: .whitespacesAndNewlines)
        var components = URLComponents(url: streamBase, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "id", value: cleanID)
        ]
        return components.url!
    }

    static func downloadURLCandidates(for videoID: String) -> [URL] {
        let candidates = [
            proxyURL(for: videoID),
            proxyPublicURL(for: videoID),
            streamURL(for: videoID)
        ]

        var seen = Set<String>()
        return candidates.filter { url in
            let key = url.absoluteString.lowercased()
            return seen.insert(key).inserted
        }
    }

    static func fileName(for videoID: String) -> String {
        let safeID = videoID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"[^A-Za-z0-9_-]+"#, with: "_", options: .regularExpression)
        return "sora_\(safeID).mp4"
    }

    private static func isExactVideoID(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return exactIDRegex.firstMatch(in: text, options: [], range: range) != nil
    }

    private static func capturedSourceMatches(in text: String, using regex: NSRegularExpression) -> [ExtractedVideoSource] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let fullRange = Range(match.range(at: 0), in: text),
                  let captureRange = Range(match.range(at: 1), in: text) else {
                return nil
            }

            let sourceText = text[fullRange].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = text[captureRange].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            return ExtractedVideoSource(
                videoID: value,
                sourceText: sourceText.isEmpty ? value : sourceText,
                location: match.range.location
            )
        }
    }

    private static func capturedWholeMatches(in text: String, using regex: NSRegularExpression) -> [ExtractedVideoSource] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard let fullRange = Range(match.range(at: 0), in: text) else {
                return nil
            }

            let sourceText = text[fullRange].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sourceText.isEmpty else { return nil }
            return ExtractedVideoSource(
                videoID: sourceText,
                sourceText: sourceText,
                location: match.range.location
            )
        }
    }
}

enum FacebookVideoLink {
    struct ExtractedVideoSource: Equatable {
        let videoID: String
        let sourceText: String
        let location: Int
    }

    private static let supportedURLRegex = try! NSRegularExpression(
        pattern: #"(?:(?:https?://)?(?:[\w-]+\.)?(?:facebook\.com|fb\.watch)/[^\s<>'"]+)"#,
        options: [.caseInsensitive]
    )
    private static let reelPathRegex = try! NSRegularExpression(
        pattern: #"/reel/(\d+)"#,
        options: [.caseInsensitive]
    )
    private static let videoPathRegex = try! NSRegularExpression(
        pattern: #"/(\d{6,})(?:/|$)"#,
        options: []
    )

    static func containsSupportedURL(_ rawInput: String) -> Bool {
        !extractVideoSources(from: rawInput).isEmpty
    }

    static func extractVideoSources(from rawInput: String) -> [ExtractedVideoSource] {
        let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return [] }

        let nsRange = NSRange(input.startIndex..<input.endIndex, in: input)
        let matches = supportedURLRegex.matches(in: input, options: [], range: nsRange)

        var uniqueSources: [ExtractedVideoSource] = []
        var seen = Set<String>()

        for match in matches {
            guard let fullRange = Range(match.range(at: 0), in: input) else { continue }
            let rawSource = String(input[fullRange])
            guard let canonicalURL = canonicalURL(from: rawSource) else { continue }

            let dedupeKey = canonicalURL.lowercased()
            guard seen.insert(dedupeKey).inserted else { continue }

            uniqueSources.append(
                ExtractedVideoSource(
                    videoID: buildDownloadKey(for: canonicalURL),
                    sourceText: canonicalURL,
                    location: match.range.location
                )
            )
        }

        return uniqueSources
    }

    private static func canonicalURL(from rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)\\]}>\"'"))
        guard !trimmed.isEmpty else { return nil }

        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: candidate),
              let host = url.host?.lowercased() else {
            return nil
        }

        let isFacebookHost =
            host == "fb.watch" ||
            host.hasSuffix(".fb.watch") ||
            host == "facebook.com" ||
            host.hasSuffix(".facebook.com")

        guard isFacebookHost else { return nil }
        return url.absoluteString
    }

    private static func extractedNumericID(from rawValue: String) -> String? {
        guard let candidate = canonicalURL(from: rawValue),
              let url = URL(string: candidate) else {
            return nil
        }

        let path = url.path
        let nsPathRange = NSRange(path.startIndex..<path.endIndex, in: path)

        if let match = reelPathRegex.firstMatch(in: path, options: [], range: nsPathRange),
           match.numberOfRanges > 1,
           let idRange = Range(match.range(at: 1), in: path) {
            return String(path[idRange])
        }

        if path.hasSuffix("/watch"),
           let watchID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "v" })?
            .value,
           watchID.allSatisfy(\.isNumber) {
            return watchID
        }

        let matches = videoPathRegex.matches(in: path, options: [], range: nsPathRange)
        if let lastMatch = matches.last,
           lastMatch.numberOfRanges > 1,
           let idRange = Range(lastMatch.range(at: 1), in: path) {
            return String(path[idRange])
        }

        return nil
    }

    static func buildDownloadKey(for rawValue: String) -> String {
        if let numericID = extractedNumericID(from: rawValue) {
            return "facebook_\(numericID)"
        }
        let hashSeed = Array((canonicalURL(from: rawValue) ?? rawValue).utf8)
        let stableHash = hashSeed.reduce(into: UInt64(1469598103934665603)) { partial, byte in
            partial ^= UInt64(byte)
            partial = partial &* 1099511628211
        }
        return "facebook_\(String(stableHash, radix: 36))"
    }
}
