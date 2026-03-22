import AVFoundation
import Foundation
import ImageIO
import UIKit
import Vision

struct ReelsEditorSettings: Sendable, Equatable {
    var zoomScale: Double = 1
    var panX: Double = 0
    var panY: Double = 0
    var captionText = ""
    var captionX: Double = 0.5
    var captionY: Double = 0.82
    var captionScale: Double = 1
    var captionRotation: Double = 0
    var emojiText = ""
    var emojiX: Double = 0.5
    var emojiY: Double = 0.18
    var emojiScale: Double = 1
    var emojiRotation: Double = 0
    var gifData: Data?
    var gifX: Double = 0.80
    var gifY: Double = 0.26
    var gifWidthRatio: Double = 0.26
    var gifScale: Double = 1
    var gifRotation: Double = 0

    var hasOverlayContent: Bool {
        !captionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !emojiText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        gifData != nil
    }
}

struct ReelsExportClip: Sendable {
    let sourceURL: URL
    let title: String
    let settings: ReelsEditorSettings
}

private struct TimedOverlayItem: Sendable {
    let editorSettings: ReelsEditorSettings
    let timeRange: CMTimeRange
}

private struct ReelsAutoFocusSuggestion: Sendable {
    let normalizedCenterX: Double
    let normalizedCenterY: Double
    let recommendedZoomScale: Double
    let prefersUpperThird: Bool
}

enum VideoSpeedOption: Double, CaseIterable, Identifiable {
    case slow = 0.75
    case slow90 = 0.9
    case normal = 1.0
    case fast = 1.25
    case faster = 1.5

    var id: Double { rawValue }

    var label: String {
        switch self {
        case .slow:
            return "0.75x"
        case .slow90:
            return "0.90x"
        case .normal:
            return "1.0x"
        case .fast:
            return "1.25x"
        case .faster:
            return "1.5x"
        }
    }

    var fileToken: String {
        switch self {
        case .slow:
            return "075x"
        case .slow90:
            return "090x"
        case .normal:
            return "100x"
        case .fast:
            return "125x"
        case .faster:
            return "150x"
        }
    }
}

enum ReelsVideoExporter {
    static let renderSize = CGSize(width: 1080, height: 1920)

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        return formatter
    }()

    static func export(
        sourceURL: URL,
        destinationDirectory: URL,
        speed: VideoSpeedOption,
        editorSettings: ReelsEditorSettings,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        let asset = AVURLAsset(url: sourceURL)
        let sourceDuration = try await asset.load(.duration)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)

        guard let sourceVideoTrack = videoTracks.first else {
            throw ReelsVideoExportError.noVideoTrack
        }

        let composition = AVMutableComposition()
        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ReelsVideoExportError.unableToCreateComposition
        }

        let sourceTimeRange = CMTimeRange(start: .zero, duration: sourceDuration)
        try compositionVideoTrack.insertTimeRange(sourceTimeRange, of: sourceVideoTrack, at: .zero)
        compositionVideoTrack.preferredTransform = .identity

        var compositionAudioTrack: AVMutableCompositionTrack?
        if let sourceAudioTrack = try await asset.loadTracks(withMediaType: .audio).first,
           let audioTrack = composition.addMutableTrack(
               withMediaType: .audio,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            try audioTrack.insertTimeRange(sourceTimeRange, of: sourceAudioTrack, at: .zero)
            compositionAudioTrack = audioTrack
        }

        let scaledDuration = CMTimeMultiplyByFloat64(sourceDuration, multiplier: 1.0 / speed.rawValue)
        compositionVideoTrack.scaleTimeRange(sourceTimeRange, toDuration: scaledDuration)
        compositionAudioTrack?.scaleTimeRange(sourceTimeRange, toDuration: scaledDuration)

        let videoComposition = try await makeVideoComposition(
            sourceURL: sourceURL,
            sourceVideoTrack: sourceVideoTrack,
            compositionTrack: compositionVideoTrack,
            duration: scaledDuration,
            editorSettings: editorSettings
        )

        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw ReelsVideoExportError.unableToCreateExportSession
        }

        let outputFileType = try preferredOutputFileType(for: exportSession)
        let outputURL = makeOutputURL(
            sourceURL: sourceURL,
            destinationDirectory: destinationDirectory,
            speed: speed,
            fileType: outputFileType
        )

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = outputFileType
        exportSession.videoComposition = videoComposition
        exportSession.shouldOptimizeForNetworkUse = true

        try await export(using: exportSession, progressHandler: progressHandler)
        return outputURL
    }

    static func exportSequence(
        clips: [ReelsExportClip],
        destinationDirectory: URL,
        speed: VideoSpeedOption,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        guard !clips.isEmpty else {
            throw ReelsVideoExportError.noSourceVideos
        }

        if clips.count == 1, let clip = clips.first {
            return try await export(
                sourceURL: clip.sourceURL,
                destinationDirectory: destinationDirectory,
                speed: speed,
                editorSettings: clip.settings,
                progressHandler: progressHandler
            )
        }

        let composition = AVMutableComposition()
        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ReelsVideoExportError.unableToCreateComposition
        }

        let compositionAudioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )

        var instructions: [AVMutableVideoCompositionInstruction] = []
        var overlayItems: [TimedOverlayItem] = []
        var insertTime = CMTime.zero
        var highestFrameRate: Float = 30

        for clip in clips {
            let asset = AVURLAsset(url: clip.sourceURL)
            let sourceDuration = try await asset.load(.duration)
            guard CMTimeCompare(sourceDuration, .zero) > 0 else { continue }

            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let sourceVideoTrack = videoTracks.first else {
                throw ReelsVideoExportError.noVideoTrack
            }

            let sourceTimeRange = CMTimeRange(start: .zero, duration: sourceDuration)
            try compositionVideoTrack.insertTimeRange(sourceTimeRange, of: sourceVideoTrack, at: insertTime)

            if let sourceAudioTrack = try await asset.loadTracks(withMediaType: .audio).first,
               let compositionAudioTrack {
                try compositionAudioTrack.insertTimeRange(sourceTimeRange, of: sourceAudioTrack, at: insertTime)
            }

            let scaledDuration = CMTimeMultiplyByFloat64(sourceDuration, multiplier: 1.0 / speed.rawValue)
            let compositionTimeRange = CMTimeRange(start: insertTime, duration: sourceDuration)
            compositionVideoTrack.scaleTimeRange(compositionTimeRange, toDuration: scaledDuration)
            compositionAudioTrack?.scaleTimeRange(compositionTimeRange, toDuration: scaledDuration)

            let scaledTimeRange = CMTimeRange(start: insertTime, duration: scaledDuration)
            let instruction = try await makeVideoCompositionInstruction(
                sourceURL: clip.sourceURL,
                sourceVideoTrack: sourceVideoTrack,
                compositionTrack: compositionVideoTrack,
                timeRange: scaledTimeRange,
                editorSettings: clip.settings
            )
            instructions.append(instruction)
            overlayItems.append(TimedOverlayItem(editorSettings: clip.settings, timeRange: scaledTimeRange))

            let nominalFrameRate = try await sourceVideoTrack.load(.nominalFrameRate)
            if nominalFrameRate > 0 {
                highestFrameRate = max(highestFrameRate, nominalFrameRate)
            }

            insertTime = CMTimeAdd(insertTime, scaledDuration)
        }

        guard !instructions.isEmpty else {
            throw ReelsVideoExportError.noSourceVideos
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.instructions = instructions
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(
            value: 1,
            timescale: normalizedFrameRate(from: highestFrameRate)
        )
        videoComposition.animationTool = makeAnimationTool(
            overlayItems: overlayItems,
            totalDuration: insertTime
        )

        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw ReelsVideoExportError.unableToCreateExportSession
        }

        let outputFileType = try preferredOutputFileType(for: exportSession)
        let outputURL = makeSequenceOutputURL(
            clips: clips,
            destinationDirectory: destinationDirectory,
            speed: speed,
            fileType: outputFileType
        )

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = outputFileType
        exportSession.videoComposition = videoComposition
        exportSession.shouldOptimizeForNetworkUse = true

        try await export(using: exportSession, progressHandler: progressHandler)
        return outputURL
    }

    static func merge(sourceURLs: [URL], destinationDirectory: URL) async throws -> URL {
        guard !sourceURLs.isEmpty else {
            throw ReelsVideoExportError.noSourceVideos
        }

        let composition = AVMutableComposition()
        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ReelsVideoExportError.unableToCreateComposition
        }

        let compositionAudioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )

        var instructions: [AVMutableVideoCompositionInstruction] = []
        var insertTime = CMTime.zero
        var highestFrameRate: Float = 30

        for sourceURL in sourceURLs {
            let asset = AVURLAsset(url: sourceURL)
            let sourceDuration = try await asset.load(.duration)
            guard CMTimeCompare(sourceDuration, .zero) > 0 else { continue }

            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let sourceVideoTrack = videoTracks.first else {
                throw ReelsVideoExportError.noVideoTrack
            }

            let sourceTimeRange = CMTimeRange(start: .zero, duration: sourceDuration)
            try compositionVideoTrack.insertTimeRange(sourceTimeRange, of: sourceVideoTrack, at: insertTime)

            if let sourceAudioTrack = try await asset.loadTracks(withMediaType: .audio).first,
               let compositionAudioTrack {
                try compositionAudioTrack.insertTimeRange(sourceTimeRange, of: sourceAudioTrack, at: insertTime)
            }

            let instruction = try await makeVideoCompositionInstruction(
                sourceURL: sourceURL,
                sourceVideoTrack: sourceVideoTrack,
                compositionTrack: compositionVideoTrack,
                timeRange: CMTimeRange(start: insertTime, duration: sourceDuration)
            )
            instructions.append(instruction)

            let nominalFrameRate = try await sourceVideoTrack.load(.nominalFrameRate)
            if nominalFrameRate > 0 {
                highestFrameRate = max(highestFrameRate, nominalFrameRate)
            }

            insertTime = CMTimeAdd(insertTime, sourceDuration)
        }

        guard !instructions.isEmpty else {
            throw ReelsVideoExportError.noSourceVideos
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.instructions = instructions
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(
            value: 1,
            timescale: normalizedFrameRate(from: highestFrameRate)
        )

        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw ReelsVideoExportError.unableToCreateExportSession
        }

        let outputFileType = try preferredOutputFileType(for: exportSession)
        let outputURL = makeMergedOutputURL(
            sourceURLs: sourceURLs,
            destinationDirectory: destinationDirectory,
            fileType: outputFileType
        )

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = outputFileType
        exportSession.videoComposition = videoComposition
        exportSession.shouldOptimizeForNetworkUse = true

        try await export(using: exportSession)
        return outputURL
    }

    static func capturePhotoData(sourceURL: URL, at seconds: Double) async throws -> Data {
        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        let clampedSeconds = durationSeconds.isFinite
            ? min(max(seconds, 0), max(durationSeconds, 0))
            : max(seconds, 0)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let captureTime = CMTime(seconds: clampedSeconds, preferredTimescale: 600)
        let cgImage = try generator.copyCGImage(at: captureTime, actualTime: nil)
        let image = UIImage(cgImage: cgImage)

        guard let data = image.jpegData(compressionQuality: 0.94) else {
            throw ReelsVideoExportError.unableToEncodeImage
        }

        return data
    }

    private static func makeVideoComposition(
        sourceURL: URL,
        sourceVideoTrack: AVAssetTrack,
        compositionTrack: AVCompositionTrack,
        duration: CMTime,
        editorSettings: ReelsEditorSettings
    ) async throws -> AVMutableVideoComposition {
        let nominalFrameRate = try await sourceVideoTrack.load(.nominalFrameRate)
        let videoComposition = AVMutableVideoComposition()
        videoComposition.instructions = [
            try await makeVideoCompositionInstruction(
                sourceURL: sourceURL,
                sourceVideoTrack: sourceVideoTrack,
                compositionTrack: compositionTrack,
                timeRange: CMTimeRange(start: .zero, duration: duration),
                editorSettings: editorSettings
            )
        ]
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(
            value: 1,
            timescale: normalizedFrameRate(from: nominalFrameRate)
        )
        videoComposition.animationTool = makeAnimationTool(
            editorSettings: editorSettings,
            duration: duration
        )

        return videoComposition
    }

    private static func makeVideoCompositionInstruction(
        sourceURL: URL,
        sourceVideoTrack: AVAssetTrack,
        compositionTrack: AVCompositionTrack,
        timeRange: CMTimeRange,
        editorSettings: ReelsEditorSettings = ReelsEditorSettings()
    ) async throws -> AVMutableVideoCompositionInstruction {
        let naturalSize = try await sourceVideoTrack.load(.naturalSize)
        let preferredTransform = try await sourceVideoTrack.load(.preferredTransform)

        let transformedRect = CGRect(origin: .zero, size: naturalSize)
            .applying(preferredTransform)
            .standardized

        let sourceSize = CGSize(
            width: abs(transformedRect.width),
            height: abs(transformedRect.height)
        )

        guard sourceSize.width > 0, sourceSize.height > 0 else {
            throw ReelsVideoExportError.invalidSourceSize
        }

        let normalizeTransform = preferredTransform.concatenating(
            CGAffineTransform(
                translationX: -transformedRect.minX,
                y: -transformedRect.minY
            )
        )

        let autoFocusSuggestion = shouldApplyAutoFocus(editorSettings)
            ? await suggestAutoFocus(for: sourceURL)
            : nil

        let zoomScale = max(
            CGFloat(editorSettings.zoomScale),
            CGFloat(autoFocusSuggestion?.recommendedZoomScale ?? 1)
        )
        let scale = max(
            renderSize.width / sourceSize.width,
            renderSize.height / sourceSize.height
        ) * zoomScale

        let scaledSize = CGSize(
            width: sourceSize.width * scale,
            height: sourceSize.height * scale
        )

        let maxPanX = max(0, (scaledSize.width - renderSize.width) / 2)
        let maxPanY = max(0, (scaledSize.height - renderSize.height) / 2)
        let requestedPanX: CGFloat
        let requestedPanY: CGFloat

        if let autoFocusSuggestion, shouldApplyAutoFocus(editorSettings) {
            let baseCenterX = (renderSize.width - scaledSize.width) / 2
            let baseCenterY = (renderSize.height - scaledSize.height) / 2
            let focusPoint = CGPoint(
                x: CGFloat(autoFocusSuggestion.normalizedCenterX) * scaledSize.width,
                y: CGFloat(autoFocusSuggestion.normalizedCenterY) * scaledSize.height
            )
            let targetPoint = CGPoint(
                x: renderSize.width / 2,
                y: renderSize.height * (autoFocusSuggestion.prefersUpperThird ? 0.42 : 0.50)
            )

            requestedPanX = targetPoint.x - (baseCenterX + focusPoint.x)
            requestedPanY = targetPoint.y - (baseCenterY + focusPoint.y)
        } else {
            requestedPanX = CGFloat(editorSettings.panX) * renderSize.width
            requestedPanY = CGFloat(editorSettings.panY) * renderSize.height
        }

        let clampedPanX = min(max(requestedPanX, -maxPanX), maxPanX)
        let clampedPanY = min(max(requestedPanY, -maxPanY), maxPanY)

        let centerTransform = CGAffineTransform(
            translationX: (renderSize.width - scaledSize.width) / 2 + clampedPanX,
            y: (renderSize.height - scaledSize.height) / 2 + clampedPanY
        )

        let finalTransform = normalizeTransform
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(centerTransform)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = timeRange

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionTrack)
        layerInstruction.setTransform(finalTransform, at: timeRange.start)
        instruction.layerInstructions = [layerInstruction]
        return instruction
    }

    private static func shouldApplyAutoFocus(_ settings: ReelsEditorSettings) -> Bool {
        abs(settings.zoomScale - 1) < 0.001 &&
        abs(settings.panX) < 0.0005 &&
        abs(settings.panY) < 0.0005
    }

    private static func suggestAutoFocus(for sourceURL: URL) async -> ReelsAutoFocusSuggestion? {
        let asset = AVURLAsset(url: sourceURL)
        let duration: CMTime

        do {
            duration = try await asset.load(.duration)
        } catch {
            return nil
        }

        let durationSeconds = max(CMTimeGetSeconds(duration), 0)
        let sampleFractions: [Double] = durationSeconds > 1.2 ? [0.12, 0.28, 0.46, 0.66, 0.84] : [0]

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.maximumSize = CGSize(width: 960, height: 960)

        var weightedCenterX = 0.0
        var weightedCenterY = 0.0
        var totalWeight = 0.0
        var strongestZoom = 1.0
        var shouldPreferUpperThird = false

        for fraction in sampleFractions {
            let sampleSecond = durationSeconds > 0 ? min(max(durationSeconds * fraction, 0), max(durationSeconds - 0.01, 0)) : 0
            let sampleTime = CMTime(seconds: sampleSecond, preferredTimescale: 600)

            guard let cgImage = try? generator.copyCGImage(at: sampleTime, actualTime: nil),
                  let focusCandidate = detectPrimaryFocus(in: cgImage) else {
                continue
            }

            weightedCenterX += focusCandidate.normalizedCenterX * focusCandidate.weight
            weightedCenterY += focusCandidate.normalizedCenterY * focusCandidate.weight
            totalWeight += focusCandidate.weight
            strongestZoom = max(strongestZoom, focusCandidate.recommendedZoomScale)
            shouldPreferUpperThird = shouldPreferUpperThird || focusCandidate.prefersUpperThird
        }

        guard totalWeight > 0 else { return nil }

        return ReelsAutoFocusSuggestion(
            normalizedCenterX: min(max(weightedCenterX / totalWeight, 0.12), 0.88),
            normalizedCenterY: min(max(weightedCenterY / totalWeight, 0.12), 0.88),
            recommendedZoomScale: min(max(strongestZoom, 1), 1.24),
            prefersUpperThird: shouldPreferUpperThird
        )
    }

    private static func detectPrimaryFocus(in cgImage: CGImage) -> (normalizedCenterX: Double, normalizedCenterY: Double, weight: Double, recommendedZoomScale: Double, prefersUpperThird: Bool)? {
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        let faceRequest = VNDetectFaceRectanglesRequest()
        try? handler.perform([faceRequest])

        if let faces = faceRequest.results as? [VNFaceObservation],
           let primaryFace = faces.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }) {
            let box = primaryFace.boundingBox
            let area = max(box.width * box.height, 0.01)
            let centerX = Double(box.midX)
            let centerY = Double(1 - box.midY)
            let recommendedZoomScale: Double
            switch area {
            case ..<0.05:
                recommendedZoomScale = 1.20
            case ..<0.11:
                recommendedZoomScale = 1.14
            default:
                recommendedZoomScale = 1.08
            }

            return (
                normalizedCenterX: centerX,
                normalizedCenterY: centerY,
                weight: Double(area) * 3.8,
                recommendedZoomScale: recommendedZoomScale,
                prefersUpperThird: true
            )
        }

        let saliencyRequest = VNGenerateAttentionBasedSaliencyImageRequest()
        try? handler.perform([saliencyRequest])

        if let observation = saliencyRequest.results?.first as? VNSaliencyImageObservation,
           let salientObject = observation.salientObjects?.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }) {
            let box = salientObject.boundingBox
            let area = max(box.width * box.height, 0.01)
            let recommendedZoomScale: Double = area < 0.18 ? 1.10 : 1.04

            return (
                normalizedCenterX: Double(box.midX),
                normalizedCenterY: Double(1 - box.midY),
                weight: Double(area) * 2.1,
                recommendedZoomScale: recommendedZoomScale,
                prefersUpperThird: false
            )
        }

        return nil
    }

    private static func makeAnimationTool(
        editorSettings: ReelsEditorSettings,
        duration: CMTime
    ) -> AVVideoCompositionCoreAnimationTool? {
        makeAnimationTool(
            overlayItems: [TimedOverlayItem(editorSettings: editorSettings, timeRange: CMTimeRange(start: .zero, duration: duration))],
            totalDuration: duration
        )
    }

    private static func makeAnimationTool(
        overlayItems: [TimedOverlayItem],
        totalDuration: CMTime
    ) -> AVVideoCompositionCoreAnimationTool? {
        guard overlayItems.contains(where: { $0.editorSettings.hasOverlayContent }) else {
            return nil
        }

        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: renderSize)

        let videoLayer = CALayer()
        videoLayer.frame = parentLayer.bounds
        parentLayer.addSublayer(videoLayer)

        for item in overlayItems {
            if let captionLayer = makeCaptionLayer(from: item.editorSettings) {
                applyVisibilityAnimation(to: captionLayer, timeRange: item.timeRange, totalDuration: totalDuration)
                parentLayer.addSublayer(captionLayer)
            }

            if let emojiLayer = makeEmojiLayer(from: item.editorSettings) {
                applyVisibilityAnimation(to: emojiLayer, timeRange: item.timeRange, totalDuration: totalDuration)
                parentLayer.addSublayer(emojiLayer)
            }

            if let gifLayer = makeGIFLayer(from: item.editorSettings, duration: item.timeRange.duration) {
                applyVisibilityAnimation(to: gifLayer, timeRange: item.timeRange, totalDuration: totalDuration)
                parentLayer.addSublayer(gifLayer)
            }
        }

        return AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: parentLayer
        )
    }

    private static func applyVisibilityAnimation(
        to layer: CALayer,
        timeRange: CMTimeRange,
        totalDuration: CMTime
    ) {
        let totalSeconds = max(CMTimeGetSeconds(totalDuration), 0.1)
        let startSeconds = max(CMTimeGetSeconds(timeRange.start), 0)
        let endSeconds = min(CMTimeGetSeconds(CMTimeRangeGetEnd(timeRange)), totalSeconds)
        let startKey = NSNumber(value: startSeconds / totalSeconds)
        let endKey = NSNumber(value: endSeconds / totalSeconds)

        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [0, 0, 1, 1, 0]
        animation.keyTimes = [0, startKey, startKey, endKey, 1]
        animation.duration = totalSeconds
        animation.beginTime = AVCoreAnimationBeginTimeAtZero
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        layer.opacity = 0
        layer.add(animation, forKey: "visibility")
    }

    private static func makeCaptionLayer(from editorSettings: ReelsEditorSettings) -> CALayer? {
        let text = editorSettings.captionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return nil
        }

        let maxWidth = renderSize.width * 0.76
        let font = UIFont.systemFont(ofSize: 60, weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white
        ]
        let boundingRect = NSString(string: text).boundingRect(
            with: CGSize(width: maxWidth - 48, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes,
            context: nil
        )

        let textSize = CGSize(
            width: min(maxWidth - 48, ceil(boundingRect.width) + 2),
            height: ceil(boundingRect.height) + 2
        )
        let bubbleSize = CGSize(
            width: min(maxWidth, textSize.width + 48),
            height: max(84, textSize.height + 30)
        )
        let bubbleLayer = overlayContainerLayer(
            centerX: editorSettings.captionX,
            centerY: editorSettings.captionY,
            size: bubbleSize,
            scale: editorSettings.captionScale,
            rotation: editorSettings.captionRotation
        )
        bubbleLayer.backgroundColor = UIColor.black.withAlphaComponent(0.34).cgColor
        bubbleLayer.cornerRadius = 30

        let textLayer = CATextLayer()
        textLayer.frame = bubbleLayer.bounds.insetBy(dx: 24, dy: 15)
        textLayer.alignmentMode = .center
        textLayer.contentsScale = 2
        textLayer.isWrapped = true
        textLayer.string = NSAttributedString(string: text, attributes: attributes)
        bubbleLayer.addSublayer(textLayer)

        return bubbleLayer
    }

    private static func makeEmojiLayer(from editorSettings: ReelsEditorSettings) -> CALayer? {
        let text = editorSettings.emojiText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return nil
        }

        let size = CGSize(width: 180, height: 180)
        let emojiLayer = overlayContainerLayer(
            centerX: editorSettings.emojiX,
            centerY: editorSettings.emojiY,
            size: size,
            scale: editorSettings.emojiScale,
            rotation: editorSettings.emojiRotation
        )

        let textLayer = CATextLayer()
        textLayer.frame = emojiLayer.bounds
        textLayer.alignmentMode = .center
        textLayer.contentsScale = 2
        textLayer.string = NSAttributedString(
            string: text,
            attributes: [
                .font: UIFont.systemFont(ofSize: 124),
                .foregroundColor: UIColor.white
            ]
        )
        emojiLayer.addSublayer(textLayer)
        return emojiLayer
    }

    private static func makeGIFLayer(
        from editorSettings: ReelsEditorSettings,
        duration: CMTime
    ) -> CALayer? {
        guard let data = editorSettings.gifData else {
            return nil
        }

        let sequence = makeGIFFrameSequence(from: data)
        guard let firstFrame = sequence.frames.first else {
            return nil
        }

        let width = max(120, renderSize.width * CGFloat(editorSettings.gifWidthRatio))
        let aspectRatio = firstFrame.width > 0 ? CGFloat(firstFrame.height) / CGFloat(firstFrame.width) : 1
        let size = CGSize(width: width, height: width * max(aspectRatio, 0.2))
        let gifLayer = overlayContainerLayer(
            centerX: editorSettings.gifX,
            centerY: editorSettings.gifY,
            size: size,
            scale: editorSettings.gifScale,
            rotation: editorSettings.gifRotation
        )
        gifLayer.contentsGravity = .resizeAspect
        gifLayer.contents = firstFrame
        gifLayer.cornerRadius = 24
        gifLayer.masksToBounds = true

        if sequence.frames.count > 1 {
            let animation = CAKeyframeAnimation(keyPath: "contents")
            animation.values = sequence.frames
            animation.keyTimes = sequence.keyTimes
            animation.duration = max(sequence.duration, 0.1)
            animation.beginTime = AVCoreAnimationBeginTimeAtZero
            animation.repeatCount = Float.greatestFiniteMagnitude
            animation.calculationMode = .discrete
            animation.isRemovedOnCompletion = false
            gifLayer.add(animation, forKey: "gif-contents")
        }

        let shadowLayer = CALayer()
        shadowLayer.frame = gifLayer.frame
        shadowLayer.shadowColor = UIColor.black.cgColor
        shadowLayer.shadowOpacity = 0.24
        shadowLayer.shadowRadius = 18
        shadowLayer.shadowOffset = CGSize(width: 0, height: 10)
        shadowLayer.transform = gifLayer.transform
        shadowLayer.backgroundColor = UIColor.black.withAlphaComponent(0.06).cgColor
        shadowLayer.cornerRadius = gifLayer.cornerRadius

        let containerLayer = CALayer()
        containerLayer.frame = CGRect(origin: .zero, size: renderSize)
        containerLayer.addSublayer(shadowLayer)
        containerLayer.addSublayer(gifLayer)
        return containerLayer
    }

    private static func overlayContainerLayer(
        centerX: Double,
        centerY: Double,
        size: CGSize,
        scale: Double,
        rotation: Double
    ) -> CALayer {
        let center = frameCenter(centerX: centerX, centerY: centerY, size: size)
        let clampedScale = min(max(CGFloat(scale), 0.4), 4.0)
        let transform = CGAffineTransform(rotationAngle: CGFloat(rotation))
            .scaledBy(x: clampedScale, y: clampedScale)

        let layer = CALayer()
        layer.bounds = CGRect(origin: .zero, size: size)
        layer.position = center
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.transform = CATransform3DMakeAffineTransform(transform)
        return layer
    }

    private static func frameCenter(centerX: Double, centerY: Double, size: CGSize) -> CGPoint {
        let minX = size.width / 2
        let maxX = renderSize.width - size.width / 2
        let minY = size.height / 2
        let maxY = renderSize.height - size.height / 2
        let clampedCenterX = min(max(CGFloat(centerX) * renderSize.width, minX), maxX)
        let clampedCenterY = min(max(CGFloat(centerY) * renderSize.height, minY), maxY)
        return CGPoint(x: clampedCenterX, y: clampedCenterY)
    }

    private static func frameOrigin(centerX: Double, centerY: Double, size: CGSize) -> CGPoint {
        let center = frameCenter(centerX: centerX, centerY: centerY, size: size)
        let clampedCenterX = center.x
        let clampedCenterY = center.y
        return CGPoint(x: clampedCenterX - size.width / 2, y: clampedCenterY - size.height / 2)
    }

    private static func makeGIFFrameSequence(from data: Data) -> (frames: [CGImage], keyTimes: [NSNumber], duration: Double) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            if let image = UIImage(data: data)?.cgImage {
                return ([image], [0], 0.1)
            }
            return ([], [], 0.1)
        }

        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 0 else {
            return ([], [], 0.1)
        }

        var frames: [CGImage] = []
        var durations: [Double] = []

        for index in 0..<frameCount {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gifProperties = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let unclamped = gifProperties?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
            let clamped = gifProperties?[kCGImagePropertyGIFDelayTime] as? Double
            let delay = max(unclamped ?? clamped ?? 0.1, 0.04)

            frames.append(image)
            durations.append(delay)
        }

        guard !frames.isEmpty else {
            return ([], [], 0.1)
        }

        let totalDuration = max(durations.reduce(0, +), 0.1)
        var elapsed = 0.0
        let keyTimes = durations.map { delay in
            defer { elapsed += delay }
            return NSNumber(value: elapsed / totalDuration)
        }

        return (frames, keyTimes, totalDuration)
    }

    private static func preferredOutputFileType(for exportSession: AVAssetExportSession) throws -> AVFileType {
        if exportSession.supportedFileTypes.contains(.mp4) {
            return .mp4
        }

        if exportSession.supportedFileTypes.contains(.mov) {
            return .mov
        }

        throw ReelsVideoExportError.unsupportedFileType
    }

    private static func makeOutputURL(
        sourceURL: URL,
        destinationDirectory: URL,
        speed: VideoSpeedOption,
        fileType: AVFileType
    ) -> URL {
        let sourceStem = sanitizedFileStem(from: sourceURL)
        let outputExtension = fileType == .mov ? "mov" : "mp4"
        let baseName = "\(sourceStem)-reels-\(speed.fileToken)"
        let candidateURL = destinationDirectory
            .appendingPathComponent(baseName)
            .appendingPathExtension(outputExtension)

        guard FileManager.default.fileExists(atPath: candidateURL.path) else {
            return candidateURL
        }

        let timestamp = timestampFormatter.string(from: .now)
        return destinationDirectory
            .appendingPathComponent("\(baseName)-\(timestamp)")
            .appendingPathExtension(outputExtension)
    }

    private static func makeMergedOutputURL(
        sourceURLs: [URL],
        destinationDirectory: URL,
        fileType: AVFileType
    ) -> URL {
        let outputExtension = fileType == .mov ? "mov" : "mp4"
        let firstStem = sanitizedFileStem(from: sourceURLs[0])
        let baseName = "\(firstStem)-merge-\(sourceURLs.count)clips"
        let candidateURL = destinationDirectory
            .appendingPathComponent(baseName)
            .appendingPathExtension(outputExtension)

        guard FileManager.default.fileExists(atPath: candidateURL.path) == false else {
            let timestamp = timestampFormatter.string(from: .now)
            return destinationDirectory
                .appendingPathComponent("\(baseName)-\(timestamp)")
                .appendingPathExtension(outputExtension)
        }

        return candidateURL
    }

    private static func makeSequenceOutputURL(
        clips: [ReelsExportClip],
        destinationDirectory: URL,
        speed: VideoSpeedOption,
        fileType: AVFileType
    ) -> URL {
        let outputExtension = fileType == .mov ? "mov" : "mp4"
        let firstStem = sanitizedFileStem(from: clips[0].sourceURL)
        let baseName = "\(firstStem)-timeline-\(clips.count)clips-\(speed.fileToken)"
        let candidateURL = destinationDirectory
            .appendingPathComponent(baseName)
            .appendingPathExtension(outputExtension)

        guard FileManager.default.fileExists(atPath: candidateURL.path) == false else {
            let timestamp = timestampFormatter.string(from: .now)
            return destinationDirectory
                .appendingPathComponent("\(baseName)-\(timestamp)")
                .appendingPathExtension(outputExtension)
        }

        return candidateURL
    }

    private static func normalizedFrameRate(from nominalFrameRate: Float) -> Int32 {
        nominalFrameRate > 0 ? min(max(Int32(nominalFrameRate.rounded()), 24), 60) : 30
    }

    private static func sanitizedFileStem(from sourceURL: URL) -> String {
        let rawValue = sourceURL.deletingPathExtension().lastPathComponent
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
        return trimmed.isEmpty ? "reels-video" : trimmed.lowercased()
    }

    private static func export(
        using exportSession: AVAssetExportSession,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        progressHandler?(0)
        let completionBox = ExportCompletionBox()

        exportSession.exportAsynchronously {
            switch exportSession.status {
            case .completed:
                completionBox.finish(with: .success(()))
            case .failed:
                completionBox.finish(with: .failure(exportSession.error ?? ReelsVideoExportError.exportFailed))
            case .cancelled:
                completionBox.finish(with: .failure(ReelsVideoExportError.exportCancelled))
            default:
                completionBox.finish(with: .failure(ReelsVideoExportError.exportFailed))
            }
        }

        while completionBox.result == nil {
            progressHandler?(Double(exportSession.progress))
            try? await Task.sleep(for: .milliseconds(90))
        }

        progressHandler?(1)

        switch completionBox.result {
        case .success:
            return
        case .failure(let error):
            throw error
        case .none:
            throw ReelsVideoExportError.exportFailed
        }
    }
}

private final class ExportCompletionBox {
    private let lock = NSLock()
    private var storedResult: Result<Void, Error>?

    var result: Result<Void, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return storedResult
    }

    func finish(with result: Result<Void, Error>) {
        lock.lock()
        defer { lock.unlock() }

        guard storedResult == nil else {
            return
        }

        storedResult = result
    }
}

enum ReelsVideoExportError: LocalizedError {
    case noSourceVideos
    case noVideoTrack
    case invalidSourceSize
    case unableToCreateComposition
    case unableToCreateExportSession
    case unsupportedFileType
    case unableToEncodeImage
    case exportFailed
    case exportCancelled

    var errorDescription: String? {
        switch self {
        case .noSourceVideos:
            return "Choose at least one more video to merge."
        case .noVideoTrack:
            return "The latest file does not contain a video track."
        case .invalidSourceSize:
            return "The source video size could not be read."
        case .unableToCreateComposition:
            return "The app could not prepare the Reels export."
        case .unableToCreateExportSession:
            return "The app could not create the export session."
        case .unsupportedFileType:
            return "The device does not support exporting this video type."
        case .unableToEncodeImage:
            return "The app could not turn the frame into a photo."
        case .exportFailed:
            return "The Reels export did not finish."
        case .exportCancelled:
            return "The Reels export was cancelled."
        }
    }
}
