import AVFoundation
import Foundation
import UIKit
import Vision

enum VideoTitleGeneratorError: LocalizedError {
    case frameAnalysisUnavailable

    var errorDescription: String? {
        switch self {
        case .frameAnalysisUnavailable:
            return "soranin could not read enough frames to create titles."
        }
    }
}

private struct FrameInsights {
    let keywords: [String]
    let detectedText: [String]
}

private enum VideoTheme: String {
    case animal
    case food
    case medical
    case people
    case nature
    case vehicle
    case sport
    case tech
    case generic

    var emojis: [String] {
        switch self {
        case .animal:
            return ["🦍", "🐾", "✨"]
        case .food:
            return ["😋", "🍽️", "🔥"]
        case .medical:
            return ["🩺", "✨", "📹"]
        case .people:
            return ["✨", "💫", "❤️"]
        case .nature:
            return ["🌿", "🌊", "✨"]
        case .vehicle:
            return ["🔥", "🚗", "⚡"]
        case .sport:
            return ["🔥", "🏃", "⚡"]
        case .tech:
            return ["📱", "✨", "⚡"]
        case .generic:
            return ["✨", "🔥", "🎬"]
        }
    }

    var fallbackKeywords: [String] {
        switch self {
        case .animal:
            return ["animal", "wildlife", "cute moment"]
        case .food:
            return ["food", "satisfying", "tasty clip"]
        case .medical:
            return ["medical", "behind the scenes", "clinic moment"]
        case .people:
            return ["moment", "story", "reel"]
        case .nature:
            return ["nature", "outdoor", "beautiful scene"]
        case .vehicle:
            return ["ride", "machine", "speed"]
        case .sport:
            return ["sport", "energy", "action"]
        case .tech:
            return ["tech", "screen", "digital moment"]
        case .generic:
            return ["viral moment", "reel", "fresh clip"]
        }
    }

    var baseHashtags: [String] {
        switch self {
        case .animal:
            return ["#AnimalVideo", "#WildlifeReels", "#CuteMoments", "#NatureVibes", "#TrendingAnimals"]
        case .food:
            return ["#FoodieReels", "#TastyVideo", "#SnackTime", "#FoodTrend", "#KitchenVibes"]
        case .medical:
            return ["#MedicalMoments", "#BehindTheScenes", "#HealthReels", "#ClinicLife", "#TrendingNow"]
        case .people:
            return ["#LifeReels", "#FeelGoodVideo", "#DailyMoments", "#FreshPost", "#TrendingNow"]
        case .nature:
            return ["#NatureReels", "#ScenicMoment", "#EarthMood", "#OutdoorVibes", "#TrendingNow"]
        case .vehicle:
            return ["#DriveReels", "#MachineLife", "#FastClip", "#RoadMoment", "#TrendingNow"]
        case .sport:
            return ["#ActionReels", "#SportsMoment", "#GameEnergy", "#MoveFast", "#TrendingNow"]
        case .tech:
            return ["#TechReels", "#DigitalMoment", "#ScreenLife", "#FreshPost", "#TrendingNow"]
        case .generic:
            return ["#ViralReels", "#FreshPost", "#TrendingNow", "#WatchThis", "#ReelsDaily"]
        }
    }
}

enum VideoTitleGenerator {
    static func generateTitles(for videoURL: URL) async throws -> String {
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration)
        let durationSeconds = max(CMTimeGetSeconds(duration), 0.2)
        let sampleTimes = candidateSampleTimes(for: durationSeconds)

        var keywordScores: [String: Int] = [:]
        var textScores: [String: Int] = [:]

        for sampleTime in sampleTimes {
            guard let imageData = try? await ReelsVideoExporter.capturePhotoData(sourceURL: videoURL, at: sampleTime) else {
                continue
            }

            let insights = try await analyzeFrame(data: imageData)
            for keyword in insights.keywords {
                keywordScores[keyword, default: 0] += 1
            }
            for text in insights.detectedText {
                textScores[text, default: 0] += 1
            }
        }

        let sortedKeywords = keywordScores
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key < rhs.key
                }
                return lhs.value > rhs.value
            }
            .map(\.key)

        let sortedDetectedText = textScores
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key < rhs.key
                }
                return lhs.value > rhs.value
            }
            .map(\.key)

        let theme = detectTheme(from: sortedKeywords)
        let chosenKeywords = Array((sortedKeywords.isEmpty ? theme.fallbackKeywords : sortedKeywords).prefix(3))
        guard !chosenKeywords.isEmpty else {
            throw VideoTitleGeneratorError.frameAnalysisUnavailable
        }

        let emojiPrefix = Array(theme.emojis.prefix(2)).joined(separator: " ")
        let freshness = freshnessWord(for: videoURL)
        let leadPhrase = leadPhrase(for: theme, keywords: chosenKeywords)
        let overlayPhrase = overlayTextPhrase(from: sortedDetectedText)

        let titleLine = overlayPhrase.map { "\(emojiPrefix) \(freshness) \($0) \(leadPhrase)" }
            ?? "\(emojiPrefix) \(freshness) \(leadPhrase)"

        let hashtags = hashtags(for: theme, keywords: chosenKeywords)
        return """
        \(titleLine)

        \(hashtags.joined(separator: " "))
        """
    }

    private static func analyzeFrame(data: Data) async throws -> FrameInsights {
        try await Task.detached(priority: .userInitiated) {
            guard let image = UIImage(data: data), let cgImage = image.cgImage else {
                throw VideoTitleGeneratorError.frameAnalysisUnavailable
            }

            let classificationRequest = VNClassifyImageRequest()
            let textRequest = VNRecognizeTextRequest()
            textRequest.recognitionLevel = .accurate
            textRequest.usesLanguageCorrection = false
            textRequest.minimumTextHeight = 0.05

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try handler.perform([classificationRequest, textRequest])

            let keywords = (classificationRequest.results ?? [])
                .filter { $0.confidence >= 0.08 }
                .prefix(10)
                .compactMap { normalizedKeyword(from: $0.identifier) }

            let detectedText = (textRequest.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { isUsefulDetectedText($0) }

            return FrameInsights(keywords: keywords, detectedText: detectedText)
        }.value
    }

    private static func candidateSampleTimes(for duration: Double) -> [Double] {
        let fractions: [Double] = [0.12, 0.34, 0.58, 0.82]
        return fractions.map { max(0, min(duration * $0, max(duration - 0.05, 0))) }
    }

    private static func normalizedKeyword(from rawIdentifier: String) -> String? {
        let leadingPart = rawIdentifier
            .components(separatedBy: ",")
            .first?
            .lowercased() ?? rawIdentifier.lowercased()

        let cleaned = leadingPart
            .replacingOccurrences(of: "[^a-z0-9 ]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard cleaned.count >= 3 else { return nil }
        guard !stopWords.contains(cleaned) else { return nil }
        return cleaned
    }

    private static func isUsefulDetectedText(_ text: String) -> Bool {
        let lowered = text.lowercased()
        guard lowered.count >= 4 else { return false }
        guard !lowered.contains("inshot"),
              !lowered.contains("facebook"),
              !lowered.contains("soranin"),
              !lowered.contains("clip timeline") else {
            return false
        }
        return lowered.range(of: "[a-z]", options: .regularExpression) != nil
    }

    private static func detectTheme(from keywords: [String]) -> VideoTheme {
        for keyword in keywords {
            switch keyword {
            case let value where animalKeywords.contains(value):
                return .animal
            case let value where foodKeywords.contains(value):
                return .food
            case let value where medicalKeywords.contains(value):
                return .medical
            case let value where natureKeywords.contains(value):
                return .nature
            case let value where vehicleKeywords.contains(value):
                return .vehicle
            case let value where sportKeywords.contains(value):
                return .sport
            case let value where techKeywords.contains(value):
                return .tech
            case let value where peopleKeywords.contains(value):
                return .people
            default:
                continue
            }
        }

        return .generic
    }

    private static func leadPhrase(for theme: VideoTheme, keywords: [String]) -> String {
        let primary = displayKeyword(keywords.first ?? theme.fallbackKeywords.first ?? "moment")

        switch theme {
        case .animal:
            return "\(primary) energy is way too cute to skip"
        case .food:
            return "this \(primary.lowercased()) moment looks too satisfying"
        case .medical:
            return "behind-the-scenes \(primary.lowercased()) footage you need to see"
        case .people:
            return "this \(primary.lowercased()) moment deserves another replay"
        case .nature:
            return "this \(primary.lowercased()) scene looks unreal"
        case .vehicle:
            return "\(primary) action is too smooth to scroll past"
        case .sport:
            return "\(primary) motion is bringing real energy"
        case .tech:
            return "this \(primary.lowercased()) clip feels straight out of the future"
        case .generic:
            return "this fresh clip deserves a second watch"
        }
    }

    private static func overlayTextPhrase(from detectedText: [String]) -> String? {
        guard let firstText = detectedText.first else { return nil }
        let shortened = firstText
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !shortened.isEmpty else { return nil }
        return "\"\(shortened.prefix(44))\""
    }

    private static func displayKeyword(_ keyword: String) -> String {
        keyword
            .split(separator: " ")
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    private static func freshnessWord(for videoURL: URL) -> String {
        let choices = ["Fresh", "New", "Just dropped", "Today’s", "Must-see"]
        let hash = abs(videoURL.lastPathComponent.lowercased().hashValue)
        return choices[hash % choices.count]
    }

    private static func hashtags(for theme: VideoTheme, keywords: [String]) -> [String] {
        var tags: [String] = keywords.map { "#\(tagToken(from: $0))" }
        tags.append(contentsOf: theme.baseHashtags)

        var uniqueTags: [String] = []
        var seen = Set<String>()
        for tag in tags {
            let normalized = tag.lowercased()
            guard seen.insert(normalized).inserted else { continue }
            uniqueTags.append(tag)
            if uniqueTags.count == 5 {
                break
            }
        }

        return uniqueTags
    }

    private static func tagToken(from keyword: String) -> String {
        let parts = keyword
            .split(separator: " ")
            .map { $0.capitalized }
        let joined = parts.joined()
        return joined.isEmpty ? "ViralReels" : joined
    }

    private static let stopWords: Set<String> = [
        "screen", "video", "image", "photo", "clip", "thumbnail", "indoor", "outdoor",
        "person", "people", "one", "close", "room", "event", "fun", "design", "art",
        "style", "text", "font", "night", "day", "light", "watermark"
    ]

    private static let animalKeywords: Set<String> = [
        "gorilla", "ape", "monkey", "dog", "puppy", "cat", "kitten", "bird", "duck", "bear",
        "panda", "lion", "tiger", "horse", "snake", "fish", "cow", "goat", "elephant"
    ]

    private static let foodKeywords: Set<String> = [
        "food", "meal", "dish", "snack", "dessert", "pizza", "burger", "bread", "coffee",
        "tea", "fruit", "vegetable", "soup", "rice", "noodle", "cake", "bowl"
    ]

    private static let medicalKeywords: Set<String> = [
        "doctor", "nurse", "medical", "hospital", "clinic", "ultrasound", "stethoscope", "patient"
    ]

    private static let peopleKeywords: Set<String> = [
        "man", "woman", "girl", "boy", "child", "baby", "family", "friend", "couple"
    ]

    private static let natureKeywords: Set<String> = [
        "forest", "tree", "flower", "grass", "beach", "ocean", "sea", "river", "mountain",
        "rain", "nature", "outdoor", "sky"
    ]

    private static let vehicleKeywords: Set<String> = [
        "car", "truck", "motorcycle", "bike", "bicycle", "boat", "plane", "train"
    ]

    private static let sportKeywords: Set<String> = [
        "sport", "soccer", "football", "basketball", "dance", "gym", "fitness", "running"
    ]

    private static let techKeywords: Set<String> = [
        "computer", "laptop", "phone", "tablet", "camera", "monitor", "keyboard", "screen"
    ]
}
