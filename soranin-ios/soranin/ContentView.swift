import AVKit
import ImageIO
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import UserNotifications

private enum EditorFocusTarget: String, CaseIterable, Identifiable {
    case video = "Video"
    case text = "Text"
    case emoji = "Emoji"
    case gif = "GIF"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .video:
            return "play.rectangle.fill"
        case .text:
            return "textformat"
        case .emoji:
            return "face.smiling.fill"
        case .gif:
            return "sparkles.tv.fill"
        }
    }
}

private enum MediaPanIntent {
    case undecided
    case panning
    case allowPageScroll
}

private func resolvedMediaPanIntent(for translation: CGSize, zoomScale: Double) -> MediaPanIntent {
    let horizontal = abs(translation.width)
    let vertical = abs(translation.height)

    guard max(horizontal, vertical) >= 10 else {
        return .undecided
    }

    if zoomScale <= 1.01, vertical > horizontal * 1.12 {
        return .allowPageScroll
    }

    return .panning
}

private enum ContentTextFocusField: Hashable {
    case rawInput
    case editorText
    case editorEmoji
    case googleAIKey
    case openAIKey
}

private enum OverlayInputMode: Identifiable {
    case text
    case emoji

    var id: String {
        switch self {
        case .text:
            return "text"
        case .emoji:
            return "emoji"
        }
    }
}

private struct TimelineScrubRequest: Equatable {
    let clipID: EditorClip.ID
    let seconds: Double
    let isInteractive: Bool
    let revision: UUID

    init(clipID: EditorClip.ID, seconds: Double, isInteractive: Bool) {
        self.clipID = clipID
        self.seconds = seconds
        self.isInteractive = isInteractive
        self.revision = UUID()
    }
}

private struct TimelinePlaybackSegment {
    let clipID: EditorClip.ID
    let fileURL: URL
    let startTime: Double
    let duration: Double
    let aspectRatio: CGFloat

    var endTime: Double {
        startTime + duration
    }
}

private struct TimelinePlaybackConfiguration {
    let playerItem: AVPlayerItem
    let segments: [TimelinePlaybackSegment]
    let totalDuration: Double
    let initialAspectRatio: CGFloat
}

private struct MacControlPackagesCache: Codable {
    let ownerKey: String
    let packages: [MacControlPackageCard]
}

struct ContentView: View {
    @StateObject private var viewModel = SoraDownloadViewModel()
    @AppStorage("macControlServerURL") private var macControlServerURL = ""
    @AppStorage("macControlRemoteServerURL") private var macControlRemoteServerURL = ""
    @AppStorage("macControlPassword") private var macControlPassword = ""
    @AppStorage("macControlNotificationsRequested") private var macControlNotificationsRequested = false
    @AppStorage("macControlPackagesCacheJSON") private var macControlPackagesCacheJSON = ""
    @AppStorage("macControlLinkInput") private var macControlLinkInput = ""
    @AppStorage("macPostChromeName") private var macPostChromeName = ""
    @AppStorage("macPostPageName") private var macPostPageName = ""
    @AppStorage("macPostFolders") private var macPostFolders = ""
    @AppStorage("macPostIntervalMinutes") private var macPostIntervalMinutes = 30
    @AppStorage("macPostCloseAfterEach") private var macPostCloseAfterEach = false
    @AppStorage("macPostCloseAfterFinish") private var macPostCloseAfterFinish = true
    @AppStorage("macPostAdvanceQueue") private var macPostAdvanceQueue = false
    @State private var showingShareSheet = false
    @State private var showingVideoImporter = false
    @State private var showingMergeImporter = false
    @State private var showingGIFImporter = false
    @State private var showingPromptVideoImporter = false
    @State private var showingMacDropVideoImporter = false
    @State private var showingMacControlSheet = false
    @State private var didAutoLoadMacControlSheet = false
    @State private var macControlProfiles: [String] = []
    @State private var macControlResultMessage = ""
    @State private var macControlDisplayName = ""
    @State private var macControlDeviceName = ""
    @State private var macControlUserName = ""
    @State private var macControlPackages: [MacControlPackageCard] = []
    @State private var macControlSelectedPackageIDs: Set<String> = []
    @State private var macSourceVideoUploadProgress = 0.0
    @State private var macControlIsOnline = false
    @State private var macControlLiveProgress = 0.0
    @State private var macControlLiveProgressLabel = ""
    @State private var macControlLiveStatusText = ""
    @State private var lastSeenMacControlRuntimeAlertID = 0
    @State private var lastMacControlPackagesVerificationAt: Date = .distantPast
    @State private var lastMacControlPackagesVerificationOwnerKey = ""
    @State private var macControlStatusTask: Task<Void, Never>?
    @State private var showingMacActionAlert = false
    @State private var macActionAlertTitle = ""
    @State private var macActionAlertMessage = ""
    @State private var isLoadingMacControl = false
    @AppStorage("mainInputRoutesToMacOnly") private var isSendingMainInputToMac = false
    @State private var isShowingPromptFramePicker = false
    @State private var editorZoomScale = 1.0
    @State private var editorPanOffset = CGSize.zero
    @State private var editorCaptionText = ""
    @State private var editorCaptionPosition = CGPoint(x: 0.5, y: 0.82)
    @State private var editorCaptionScale = 1.0
    @State private var editorCaptionRotation = 0.0
    @State private var editorEmojiText = ""
    @State private var editorEmojiPosition = CGPoint(x: 0.5, y: 0.18)
    @State private var editorEmojiScale = 1.0
    @State private var editorEmojiRotation = 0.0
    @State private var editorGIFData: Data?
    @State private var editorGIFPosition = CGPoint(x: 0.8, y: 0.26)
    @State private var editorGIFScale = 1.0
    @State private var editorGIFRotation = 0.0
    @State private var selectedEditorTarget: EditorFocusTarget = .video
    @State private var timelineSelectionID: EditorClip.ID?
    @State private var timelineZoomLevel = 1.0
    @State private var timelinePlayheadTime = 0.0
    @State private var timelineScrubRequest: TimelineScrubRequest?
    @State private var draggedTimelineClipID: EditorClip.ID?
    @State private var photoEditorZoomScale = 1.0
    @State private var photoEditorPanOffset = CGSize.zero
    @State private var photoEditorCaptionText = ""
    @State private var photoEditorCaptionPosition = CGPoint(x: 0.5, y: 0.82)
    @State private var photoEditorCaptionScale = 1.0
    @State private var photoEditorCaptionRotation = 0.0
    @State private var photoEditorEmojiText = ""
    @State private var photoEditorEmojiPosition = CGPoint(x: 0.5, y: 0.18)
    @State private var photoEditorEmojiScale = 1.0
    @State private var photoEditorEmojiRotation = 0.0
    @State private var photoEditorGIFData: Data?
    @State private var photoEditorGIFPosition = CGPoint(x: 0.8, y: 0.26)
    @State private var photoEditorGIFScale = 1.0
    @State private var photoEditorGIFRotation = 0.0
    @State private var selectedPhotoEditorTarget: EditorFocusTarget = .video
    @State private var promptFramePickerZoomScale = 1.0
    @State private var promptFramePickerPanOffset = CGSize.zero
    @State private var activeOverlayInputMode: OverlayInputMode?
    @State private var overlayInputText = ""
    @State private var googleAIAPIKeyDraft = ""
    @State private var openAIAPIKeyDraft = ""
    @FocusState private var focusedField: ContentTextFocusField?
    private let topAnchorID = "soranin-top-anchor"

    var body: some View {
        bodyView
    }

    private var bodyBaseView: some View {
        GeometryReader { geometry in
            rootContent(geometry: geometry)
        }
    }

    private var bodyPresentationView: some View {
        bodyBaseView
        .sheet(isPresented: $showingShareSheet) {
            if let fileURL = viewModel.lastSavedFileURL {
                ShareSheet(items: [fileURL])
            }
        }
        .fullScreenCover(isPresented: $viewModel.isShowingAIChat) {
            AIChatPopup(
                model: viewModel,
                isKhmer: viewModel.appLanguage == .khmer,
                onClose: {
                    viewModel.dismissAIChat()
                }
            )
        }
        .sheet(isPresented: $showingMacControlSheet) {
            macControlSheetView
        }
        .onChange(of: macPostFolders) { _ in
            syncMacControlSelectedPackagesFromFolders()
        }
        .sheet(isPresented: $showingVideoImporter) {
            PhotoVideoPicker(selectionLimit: 0) { urls in
                guard !urls.isEmpty else { return }
                Task {
                    await viewModel.inputVideosForEditing(from: urls)
                }
            }
        }
        .sheet(isPresented: $showingMergeImporter) {
            PhotoVideoPicker(selectionLimit: 0) { urls in
                guard !urls.isEmpty else { return }
                Task {
                    await viewModel.mergeVideosForEditing(from: urls)
                }
            }
        }
        .sheet(isPresented: $showingGIFImporter) {
            PhotoGIFPicker { data in
                guard let data else { return }
                editorGIFData = data
                editorGIFPosition = CGPoint(x: 0.8, y: 0.26)
                editorGIFScale = 1
                editorGIFRotation = 0
                selectedEditorTarget = .gif
                viewModel.statusMessage = "GIF sticker ready. Drag it on the preview before convert."
            }
        }
        .sheet(isPresented: $showingPromptVideoImporter) {
            PhotoVideoPicker(selectionLimit: 1) { urls in
                guard !urls.isEmpty else { return }
                Task {
                    await viewModel.inputVideoForPrompt(from: urls)
                }
            }
        }
        .sheet(isPresented: $showingMacDropVideoImporter) {
            PhotoVideoPicker(selectionLimit: 1) { urls in
                guard let first = urls.first else { return }
                uploadPickedVideoToMac(first)
            }
        }
    }

    private var bodyObservedStateView: some View {
        bodyPresentationView
        .onChange(of: viewModel.editorVideoURL) { _, _ in
            resetEditorFraming()
        }
        .onChange(of: viewModel.promptInputVideoURL) { _, _ in
            resetPromptFramePickerFraming()
        }
        .onChange(of: viewModel.selectedClipID) { _, newValue in
            timelineSelectionID = newValue
            loadSelectedClipSettings()
        }
        .onChange(of: viewModel.isShowingOpenAIKeyPrompt) { _, isShowing in
            if isShowing {
                openAIAPIKeyDraft = ""
            } else if focusedField == .openAIKey {
                focusedField = nil
            }
        }
        .onChange(of: viewModel.isShowingGoogleAIKeyPrompt) { _, isShowing in
            if isShowing {
                googleAIAPIKeyDraft = ""
            } else if focusedField == .googleAIKey {
                focusedField = nil
            }
        }
        .onChange(of: viewModel.isShowingExportPreview) { _, isShowing in
            guard isShowing, viewModel.shouldRunAIAutoCreateTitlesWhenExportAppears() else { return }
            viewModel.markAIAutoCreateTitlesStarted()
            Task {
                await viewModel.createTitlesForLatestExport()
            }
        }
        .onChange(of: viewModel.isShowingGeneratedTitles) { _, isShowing in
            guard isShowing, viewModel.shouldRunAIAutoCopyTitlesWhenPopupAppears() else { return }
            viewModel.markAIAutoCopyTitlesStarted()
            Task {
                await viewModel.copyGeneratedTitlesToClipboard()
            }
        }
        .onChange(of: viewModel.editorClips) { _, _ in
            if draggedTimelineClipID == nil {
                syncTimelinePlayheadToSelectedClip()
            }
        }
        .onChange(of: timelineSelectionID) { _, newValue in
            viewModel.selectClip(newValue)
            syncTimelinePlayheadToSelectedClip()
        }
        .onChange(of: viewModel.photoPreviewURL) { _, newValue in
            guard newValue != nil else { return }
            syncPhotoEditorFromVideoEditor()
        }
        .onChange(of: editorSettings) { _, newValue in
            viewModel.updateSelectedClipSettings(newValue)
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = false
            timelineSelectionID = viewModel.selectedClipID
            loadSelectedClipSettings()
            syncTimelinePlayheadToSelectedClip()
        }
    }

    private var bodyView: some View {
        bodyObservedStateView
        .alert(macActionAlertTitle, isPresented: $showingMacActionAlert) {
            Button(tr("OK", "យល់ព្រម"), role: .cancel) {}
        } message: {
            Text(macActionAlertMessage)
        }
        .toolbar {
            if !viewModel.isShowingAIChat {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()

                    Button("Done") {
                        focusedField = nil
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func rootContent(geometry: GeometryProxy) -> some View {
            let isWideLayout = geometry.size.width >= 860 || geometry.size.width > geometry.size.height
            let isPhoneLayout = !isWideLayout
            let isCompactPhoneLayout = isPhoneLayout && geometry.size.width < 390

            ScrollViewReader { scrollProxy in
                ZStack {
                    backgroundView

                    ScrollView(showsIndicators: false) {
                        VStack(spacing: isCompactPhoneLayout ? 18 : 22) {
                            Color.clear
                                .frame(height: 0)
                                .id(topAnchorID)

                            headerRow(isCompact: isCompactPhoneLayout)

                            if isWideLayout {
                                HStack(alignment: .top, spacing: 18) {
                                    actionPanel(phoneLayout: false)
                                        .frame(maxWidth: 540, alignment: .top)

                                    sidePanel
                                        .frame(maxWidth: .infinity, alignment: .top)
                                }
                            } else {
                                VStack(spacing: isCompactPhoneLayout ? 16 : 18) {
                                    actionPanel(phoneLayout: true)
                                    cardsGrid(isWideLayout: false)
                                }
                            }
                        }
                        .frame(maxWidth: 980)
                        .padding(.horizontal, isWideLayout ? 28 : (isCompactPhoneLayout ? 16 : 18))
                        .padding(.top, geometry.safeAreaInsets.top + (isCompactPhoneLayout ? 12 : 18))
                        .padding(.bottom, max(geometry.safeAreaInsets.bottom + 28, 30))
                        .frame(maxWidth: .infinity)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            focusedField = nil
                        }
                    )

                    if viewModel.isConverting {
                        ExportingReelsPopup(
                            progress: viewModel.conversionProgress,
                            progressText: viewModel.conversionPercentText,
                            speedText: viewModel.selectedSpeed.label,
                            title: tr("Creating Reels HD", "កំពុងបង្កើត Reels HD"),
                            subtitle: tr(
                                "Please wait while soranin exports your video.",
                                "សូមរង់ចាំ ខណៈ soranin កំពុង export វីដេអូរបស់អ្នក។"
                            )
                        )
                    } else if viewModel.isGeneratingTitles {
                        ExportingReelsPopup(
                            progress: 0.82,
                            progressText: "AI",
                            speedText: "AI",
                            title: tr("Creating Titles", "កំពុងបង្កើតចំណងជើង"),
                            subtitle: tr(
                                "Please wait while soranin analyzes your video and writes title ideas.",
                                "សូមរង់ចាំ ខណៈ soranin កំពុងវិភាគវីដេអូ និងសរសេរចំណងជើង។"
                            )
                        )
                    } else if viewModel.isShowingPhotoPreview, let fileURL = viewModel.photoPreviewURL {
                        PhotoEditorPopup(
                            fileURL: fileURL,
                            isBusy: viewModel.isBusy,
                            zoomScale: $photoEditorZoomScale,
                            panOffset: $photoEditorPanOffset,
                            captionText: $photoEditorCaptionText,
                            captionPosition: $photoEditorCaptionPosition,
                            captionScale: $photoEditorCaptionScale,
                            captionRotation: $photoEditorCaptionRotation,
                            emojiText: $photoEditorEmojiText,
                            emojiPosition: $photoEditorEmojiPosition,
                            emojiScale: $photoEditorEmojiScale,
                            emojiRotation: $photoEditorEmojiRotation,
                            gifData: $photoEditorGIFData,
                            gifPosition: $photoEditorGIFPosition,
                            gifScale: $photoEditorGIFScale,
                            gifRotation: $photoEditorGIFRotation,
                            selectedTarget: $selectedPhotoEditorTarget,
                            onClose: {
                                viewModel.dismissPhotoPreview()
                            },
                            onSave: { renderedURL in
                                Task {
                                    await viewModel.saveEditedPhotoToPhotos(from: renderedURL)
                                    viewModel.dismissPhotoPreview()
                                }
                            },
                            onShare: { renderedURL in
                                viewModel.lastSavedFileURL = renderedURL
                                viewModel.dismissPhotoPreview()
                                showingShareSheet = true
                            }
                        )
                    } else if isShowingPromptFramePicker, let fileURL = viewModel.promptInputVideoURL {
                        PromptFramePickerPopup(
                            fileURL: fileURL,
                            isWorking: viewModel.isBusy,
                            isKhmer: viewModel.appLanguage == .khmer,
                            zoomScale: $promptFramePickerZoomScale,
                            panOffset: $promptFramePickerPanOffset,
                            onClose: {
                                isShowingPromptFramePicker = false
                                resetPromptFramePickerFraming()
                            },
                            onUseFrame: { seconds in
                                Task {
                                    await viewModel.capturePromptInputFramePreview(at: seconds)
                                    isShowingPromptFramePicker = false
                                    resetPromptFramePickerFraming()
                                }
                            }
                        )
                    } else if viewModel.isShowingTitlesHistory {
                        TitlesHistoryPopup(
                            entries: viewModel.generatedTitlesHistory,
                            trashedEntries: viewModel.trashedGeneratedTitlesHistory,
                            isKhmer: viewModel.appLanguage == .khmer,
                            thumbnailURLProvider: { entry in
                                viewModel.historyThumbnailURL(for: entry)
                            },
                            onClose: {
                                viewModel.dismissTitlesHistory()
                            },
                            onCopyAll: {
                                viewModel.copyAllGeneratedTitlesToClipboard()
                            },
                            onCopyEntry: { entry in
                                viewModel.copyGeneratedTitleHistoryEntryToClipboard(entry)
                            },
                            onMoveToTrash: { entry in
                                viewModel.moveGeneratedTitleHistoryEntryToTrash(entry)
                            },
                            onRestore: { entry in
                                viewModel.restoreGeneratedTitleHistoryEntry(entry)
                            }
                        )
                    } else if viewModel.isShowingPromptHistory {
                        PromptHistoryPopup(
                            entries: viewModel.generatedPromptsHistory,
                            trashedEntries: viewModel.trashedGeneratedPromptsHistory,
                            isKhmer: viewModel.appLanguage == .khmer,
                            thumbnailURLProvider: { entry in
                                viewModel.historyThumbnailURL(for: entry)
                            },
                            onClose: {
                                viewModel.dismissPromptHistory()
                            },
                            onCopyAll: {
                                viewModel.copyAllGeneratedPromptsToClipboard()
                            },
                            onCopyEntry: { entry in
                                viewModel.copyGeneratedPromptHistoryEntryToClipboard(entry)
                            },
                            onMoveToTrash: { entry in
                                viewModel.moveGeneratedPromptHistoryEntryToTrash(entry)
                            },
                            onRestore: { entry in
                                viewModel.restoreGeneratedPromptHistoryEntry(entry)
                            }
                        )
                    } else if viewModel.isShowingAIAutoDonePopup {
                        AIAutoDonePopup(
                            isKhmer: viewModel.appLanguage == .khmer,
                            message: viewModel.aiAutoDoneMessage,
                            onClose: {
                                viewModel.dismissAIAutoDonePopup()
                            }
                        )
                    } else if viewModel.isShowingGeneratedTitles {
                        GeneratedTitlesPopup(
                            titlesText: viewModel.generatedTitlesText,
                            onClose: {
                                viewModel.dismissGeneratedTitles()
                            },
                            onCopy: {
                                Task {
                                    await viewModel.copyGeneratedTitlesToClipboard()
                                }
                            }
                        )
                    } else if viewModel.isShowingGeneratedPrompt {
                        GeneratedPromptPopup(
                            promptText: viewModel.generatedPromptText,
                            isKhmer: viewModel.appLanguage == .khmer,
                            onClose: {
                                viewModel.dismissGeneratedPrompt()
                            },
                            onCopy: {
                                Task {
                                    await viewModel.copyGeneratedPromptToClipboard()
                                }
                            }
                        )
                    } else if viewModel.isGeneratingThumbnail {
                        ExportingReelsPopup(
                            progress: max(viewModel.thumbnailGenerationProgress, 0.06),
                            progressText: "\(Int((viewModel.thumbnailGenerationProgress * 100).rounded()))%",
                            speedText: "AI",
                            title: viewModel.appLanguage == .khmer ? "កំពុងបង្កើត Thumbnail" : "Creating Thumbnail",
                            subtitle: viewModel.statusMessage.isEmpty
                                ? (viewModel.appLanguage == .khmer
                                    ? "សូមរង់ចាំ ខណៈដែល soranin កំពុងវិភាគវីដេអូទាំងមូល ហើយបង្កើត thumbnail ដោយ AI។"
                                    : "Please wait while soranin analyzes the full video and builds an AI thumbnail.")
                                : viewModel.statusMessage
                        )
                    } else if viewModel.isShowingGeneratedThumbnail,
                              let imageURL = viewModel.generatedThumbnailImageURL {
                        GeneratedThumbnailPopup(
                            imageURL: imageURL,
                            headline: viewModel.generatedThumbnailHeadline,
                            reason: viewModel.generatedThumbnailReason,
                            saveMessage: viewModel.generatedThumbnailPhotoSaveMessage,
                            savedToPhotos: viewModel.generatedThumbnailSavedToPhotos,
                            isBusy: viewModel.isBusy,
                            isKhmer: viewModel.appLanguage == .khmer,
                            onClose: {
                                viewModel.dismissGeneratedThumbnail()
                            },
                            onSaveToPhotos: {
                                Task {
                                    await viewModel.saveGeneratedThumbnailToPhotos()
                                }
                            },
                            onCreateTitles: {
                                viewModel.dismissGeneratedThumbnail()
                                Task {
                                    await viewModel.createTitlesForLatestExport()
                                }
                            },
                            onCreateAgain: {
                                Task {
                                    await viewModel.createThumbnailAgain()
                                }
                            }
                        )
                    } else if viewModel.isShowingGoogleAIKeyPrompt {
                        GoogleAIKeyPopup(
                            apiKeyText: $googleAIAPIKeyDraft,
                            hasConfiguredKey: viewModel.hasConfiguredGoogleAIKey,
                            isChecking: viewModel.isCheckingGoogleAIKey,
                            selectedModelID: viewModel.selectedGoogleModelID,
                            modelOptions: viewModel.activeGoogleModelOptions,
                            isRefreshingModels: viewModel.isRefreshingGoogleModels,
                            messageText: viewModel.googleAIKeyCheckMessage,
                            focusedField: $focusedField,
                            isKhmer: viewModel.appLanguage == .khmer,
                            onClose: {
                                googleAIAPIKeyDraft = ""
                                viewModel.dismissGoogleAIKeyPrompt()
                            },
                            onPasteAndCheck: {
                                Task {
                                    let didSave = await viewModel.pasteAndCheckGoogleAIKey(googleAIAPIKeyDraft)
                                    googleAIAPIKeyDraft = ""
                                    if didSave {
                                        focusedField = nil
                                    }
                                }
                            },
                            onSelectModel: { modelID in
                                viewModel.setSelectedModel(modelID, for: .googleGemini)
                            },
                            onRemove: {
                                googleAIAPIKeyDraft = ""
                                viewModel.removeGoogleAIAPIKey()
                            }
                        )
                    } else if viewModel.isShowingOpenAIKeyPrompt {
                        OpenAIKeyPopup(
                            apiKeyText: $openAIAPIKeyDraft,
                            hasConfiguredKey: viewModel.hasConfiguredOpenAIKey,
                            isChecking: viewModel.isCheckingOpenAIKey,
                            selectedModelID: viewModel.selectedOpenAIModelID,
                            modelOptions: viewModel.activeOpenAIModelOptions,
                            isRefreshingModels: viewModel.isRefreshingOpenAIModels,
                            messageText: viewModel.openAIKeyCheckMessage,
                            focusedField: $focusedField,
                            isKhmer: viewModel.appLanguage == .khmer,
                            onClose: {
                                openAIAPIKeyDraft = ""
                                viewModel.dismissOpenAIKeyPrompt()
                            },
                            onPasteAndCheck: {
                                Task {
                                    let didSave = await viewModel.pasteAndCheckOpenAIAPIKey(openAIAPIKeyDraft)
                                    openAIAPIKeyDraft = ""
                                    if didSave {
                                        focusedField = nil
                                    }
                                }
                            },
                            onSelectModel: { modelID in
                                viewModel.setSelectedModel(modelID, for: .openAI)
                            },
                            onRemove: {
                                openAIAPIKeyDraft = ""
                                viewModel.removeOpenAIAPIKey()
                            }
                        )
                    } else if viewModel.isShowingExportPreview, let fileURL = viewModel.exportPreviewURL {
                        ExportPreviewPopup(
                            fileURL: fileURL,
                            isBusy: viewModel.isBusy,
                            autoSaveMessage: viewModel.exportPreviewPhotoSaveMessage,
                            autoSavedToPhotos: viewModel.exportPreviewAlreadySavedToPhotos,
                            onClose: {
                                viewModel.dismissExportPreview()
                            },
                            onCreateThumbnail: {
                                Task {
                                    await viewModel.createThumbnailForLatestExport()
                                }
                            },
                            onCreateTitles: {
                                Task {
                                    await viewModel.createTitlesForLatestExport()
                                }
                            },
                            onShare: {
                                viewModel.dismissExportPreview()
                                showingShareSheet = true
                            }
                        )
                    }

                    if let activeOverlayInputMode {
                        OverlayInputPopup(
                            mode: activeOverlayInputMode,
                            text: $overlayInputText,
                            focusedField: $focusedField,
                            onClose: {
                                dismissOverlayInputPopup()
                            },
                            onApply: {
                                applyOverlayInput()
                            }
                        )
                    }
                }
            }
            .ignoresSafeArea()
        }
    private var editorSettings: ReelsEditorSettings {
        ReelsEditorSettings(
            zoomScale: editorZoomScale,
            panX: Double(editorPanOffset.width),
            panY: Double(editorPanOffset.height),
            captionText: editorCaptionText,
            captionX: Double(editorCaptionPosition.x),
            captionY: Double(editorCaptionPosition.y),
            captionScale: editorCaptionScale,
            captionRotation: editorCaptionRotation,
            emojiText: editorEmojiText,
            emojiX: Double(editorEmojiPosition.x),
            emojiY: Double(editorEmojiPosition.y),
            emojiScale: editorEmojiScale,
            emojiRotation: editorEmojiRotation,
            gifData: editorGIFData,
            gifX: Double(editorGIFPosition.x),
            gifY: Double(editorGIFPosition.y),
            gifScale: editorGIFScale,
            gifRotation: editorGIFRotation
        )
    }

    private var photoEditorSettings: ReelsEditorSettings {
        ReelsEditorSettings(
            zoomScale: photoEditorZoomScale,
            panX: Double(photoEditorPanOffset.width),
            panY: Double(photoEditorPanOffset.height),
            captionText: photoEditorCaptionText,
            captionX: Double(photoEditorCaptionPosition.x),
            captionY: Double(photoEditorCaptionPosition.y),
            captionScale: photoEditorCaptionScale,
            captionRotation: photoEditorCaptionRotation,
            emojiText: photoEditorEmojiText,
            emojiX: Double(photoEditorEmojiPosition.x),
            emojiY: Double(photoEditorEmojiPosition.y),
            emojiScale: photoEditorEmojiScale,
            emojiRotation: photoEditorEmojiRotation,
            gifData: photoEditorGIFData,
            gifX: Double(photoEditorGIFPosition.x),
            gifY: Double(photoEditorGIFPosition.y),
            gifScale: photoEditorGIFScale,
            gifRotation: photoEditorGIFRotation
        )
    }

    private func resetEditorFraming() {
        editorZoomScale = 1
        editorPanOffset = .zero
    }

    private func resetPromptFramePickerFraming() {
        promptFramePickerZoomScale = 1
        promptFramePickerPanOffset = .zero
    }

    private func resetOverlayLayout() {
        editorCaptionPosition = CGPoint(x: 0.5, y: 0.82)
        editorCaptionScale = 1
        editorCaptionRotation = 0
        editorEmojiPosition = CGPoint(x: 0.5, y: 0.18)
        editorEmojiScale = 1
        editorEmojiRotation = 0
        editorGIFPosition = CGPoint(x: 0.8, y: 0.26)
        editorGIFScale = 1
        editorGIFRotation = 0
    }

    private func loadSelectedClipSettings() {
        let settings = viewModel.selectedClipSettings
        editorZoomScale = settings.zoomScale
        editorPanOffset = CGSize(width: settings.panX, height: settings.panY)
        editorCaptionText = settings.captionText
        editorCaptionPosition = CGPoint(x: settings.captionX, y: settings.captionY)
        editorCaptionScale = settings.captionScale
        editorCaptionRotation = settings.captionRotation
        editorEmojiText = settings.emojiText
        editorEmojiPosition = CGPoint(x: settings.emojiX, y: settings.emojiY)
        editorEmojiScale = settings.emojiScale
        editorEmojiRotation = settings.emojiRotation
        editorGIFData = settings.gifData
        editorGIFPosition = CGPoint(x: settings.gifX, y: settings.gifY)
        editorGIFScale = settings.gifScale
        editorGIFRotation = settings.gifRotation
        selectedEditorTarget = .video
    }

    private func syncPhotoEditorFromVideoEditor() {
        photoEditorZoomScale = editorZoomScale
        photoEditorPanOffset = editorPanOffset
        photoEditorCaptionText = editorCaptionText
        photoEditorCaptionPosition = editorCaptionPosition
        photoEditorCaptionScale = editorCaptionScale
        photoEditorCaptionRotation = editorCaptionRotation
        photoEditorEmojiText = editorEmojiText
        photoEditorEmojiPosition = editorEmojiPosition
        photoEditorEmojiScale = editorEmojiScale
        photoEditorEmojiRotation = editorEmojiRotation
        photoEditorGIFData = editorGIFData
        photoEditorGIFPosition = editorGIFPosition
        photoEditorGIFScale = editorGIFScale
        photoEditorGIFRotation = editorGIFRotation
        selectedPhotoEditorTarget = .video
    }

    private func syncTimelinePlayheadToSelectedClip() {
        guard let selectedID = viewModel.selectedClipID else {
            timelinePlayheadTime = 0
            return
        }

        var runningTime = 0.0
        for clip in viewModel.editorClips {
            if clip.id == selectedID {
                timelinePlayheadTime = runningTime
                return
            }
            runningTime += max(clip.duration, 0)
        }
        timelinePlayheadTime = 0
    }

    private var macControlSheetView: some View {
        MacControlSheet(
            isKhmer: viewModel.appLanguage == .khmer,
            serverURL: $macControlServerURL,
            password: $macControlPassword,
            chromeName: $macPostChromeName,
            pageName: $macPostPageName,
            folders: $macPostFolders,
            manualLinkInput: $macControlLinkInput,
            intervalMinutes: $macPostIntervalMinutes,
            closeAfterEach: $macPostCloseAfterEach,
            closeAfterFinish: $macPostCloseAfterFinish,
            postNowAdvanceSlot: $macPostAdvanceQueue,
            isLoading: isLoadingMacControl,
            profiles: macControlProfiles,
            macDisplayName: macControlDisplayName,
            macDeviceName: macControlDeviceName,
            macUserName: macControlUserName,
            isOnline: macControlIsOnline,
            liveStatusText: macControlLiveStatusText,
            liveProgress: macControlLiveProgress,
            liveProgressLabel: macControlLiveProgressLabel,
            packages: macControlPackages,
            selectedPackageIDs: macControlSelectedPackageIDs,
            uploadVideoProgress: macSourceVideoUploadProgress,
            thumbnailURLForPackage: { item in
                thumbnailURLForMacControlPackage(item)
            },
            resultMessage: macControlResultMessage,
            onClose: {
                showingMacControlSheet = false
                didAutoLoadMacControlSheet = false
            },
            onLoad: {
                refreshMacControlBootstrap()
            },
            onScan: {
                scanMacControlServer()
            },
            onSendCurrentInput: {
                sendCurrentInputToMac()
            },
            onSendManualLink: {
                sendManualLinkToMac()
            },
            onUploadVideoToMac: {
                openMacDropVideoPicker()
            },
            onTogglePackage: { item in
                toggleMacControlPackageSelection(item)
            },
            onAddSelectedPackages: {
                addSelectedMacControlPackagesToFolders()
            },
            onRefreshPackages: {
                refreshMacControlPackageCards()
            },
            onDeletePackage: { item in
                deleteMacControlPackage(item)
            },
            onPreflight: {
                preflightMacFacebookPost()
            },
            onRun: {
                runMacFacebookPost()
            },
            onQuitChrome: {
                quitMacChrome()
            }
        )
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear {
            guard !didAutoLoadMacControlSheet else { return }
            didAutoLoadMacControlSheet = true
            refreshMacControlBootstrap()
            startMacControlStatusPolling()
        }
        .onDisappear {
            stopMacControlStatusPolling()
        }
    }

    private func presentOverlayInputPopup(_ mode: OverlayInputMode) {
        activeOverlayInputMode = mode
        switch mode {
        case .text:
            selectedEditorTarget = .text
            overlayInputText = editorCaptionText
            DispatchQueue.main.async {
                focusedField = .editorText
            }
        case .emoji:
            selectedEditorTarget = .emoji
            overlayInputText = editorEmojiText
            DispatchQueue.main.async {
                focusedField = .editorEmoji
            }
        }
    }

    private func dismissOverlayInputPopup() {
        activeOverlayInputMode = nil
        focusedField = nil
    }

    private func applyOverlayInput() {
        guard let activeOverlayInputMode else { return }

        switch activeOverlayInputMode {
        case .text:
            editorCaptionText = overlayInputText.trimmingCharacters(in: .newlines)
            selectedEditorTarget = .text
        case .emoji:
            editorEmojiText = overlayInputText.trimmingCharacters(in: .whitespacesAndNewlines)
            selectedEditorTarget = .emoji
        }

        dismissOverlayInputPopup()
    }

    private func formattedTimelineTime(_ seconds: Double) -> String {
        let totalSeconds = max(Int(seconds.rounded(.down)), 0)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60

        if hours > 0 {
            return String(format: "Total %d:%02d:%02d", hours, minutes, secs)
        }

        return String(format: "Total %02d:%02d", minutes, secs)
    }

    private var selectedClipNumberText: String {
        guard let selectedID = viewModel.selectedClipID,
              let index = viewModel.editorClips.firstIndex(where: { $0.id == selectedID }) else {
            return viewModel.editorClipCount > 1 ? "\(tr("Clip", "Clip")) 1/\(max(viewModel.editorClipCount, 1))" : tr("Ready", "រួចរាល់")
        }

        return viewModel.editorClipCount > 1
            ? "\(tr("Clip", "Clip")) \(index + 1)/\(viewModel.editorClipCount)"
            : tr("Ready", "រួចរាល់")
    }

    private var selectedClipTitleText: String? {
        guard let clip = viewModel.selectedClip else { return nil }
        return clip.title
    }

    private func tr(_ english: String, _ khmer: String) -> String {
        viewModel.appLanguage == .khmer ? khmer : english
    }

    private func openMacControlSheet() {
        showingMacControlSheet = true
        didAutoLoadMacControlSheet = false
        normalizeMacControlServerURLsForCurrentDevice()
        restoreMacControlPackagesCacheIfNeeded()
        requestMacControlNotificationsIfNeeded()
        if macPostIntervalMinutes <= 0 {
            macPostIntervalMinutes = 30
        }
        if macControlResultMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            macControlResultMessage = tr(
                "Use Scan Mac (Wi-Fi Fast) when you are nearby, or use Remote Mac for Relay / Tailscale access. If one path is unavailable, Soranin will switch to the other automatically.",
                "ប្រើ Scan Mac (Wi‑Fi Fast) ពេលនៅជិតគ្នា ឬប្រើ Remote Mac សម្រាប់ Relay / Tailscale។ បើមួយណាមិនមាន វានឹងប្តូរទៅមួយទៀតអោយស្វ័យប្រវត្តិ។"
            )
        }
    }

    private func startMacControlStatusPolling() {
        stopMacControlStatusPolling()
        macControlStatusTask = Task {
            while !Task.isCancelled {
                let result = await viewModel.loadMacControlRuntimeStatus(
                    preferredServerURL: effectiveMacControlCardsServerURL(),
                    password: macControlPassword
                )
                if result.ok {
                    macControlIsOnline = true
                    macControlLiveProgress = max(0, min(1, Double(result.progressPercent) / 100.0))
                    macControlLiveProgressLabel = result.progressLabel
                    macControlLiveStatusText = [
                        result.statusText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : result.statusText,
                        result.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : result.detail,
                    ]
                    .compactMap { $0 }
                    .joined(separator: "\n")
                    let liveMessage = result.message.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !liveMessage.isEmpty {
                        macControlResultMessage = liveMessage
                    }
                    if result.latestAlertID > 0,
                       result.latestAlertID > lastSeenMacControlRuntimeAlertID {
                        lastSeenMacControlRuntimeAlertID = result.latestAlertID
                        let alertTitle = result.latestAlertTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? tr("Mac Update", "ព័ត៌មានពី Mac")
                            : result.latestAlertTitle
                        let alertMessage = result.latestAlertMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? liveMessage
                            : result.latestAlertMessage
                        if !alertMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            presentMacActionAlert(title: alertTitle, message: alertMessage)
                        }
                    }
                    await silentlyVerifyMacControlPackageCardsIfNeeded()
                } else {
                    macControlIsOnline = false
                    macControlLiveProgress = 0
                    macControlLiveProgressLabel = ""
                    macControlLiveStatusText = ""
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private func stopMacControlStatusPolling() {
        macControlStatusTask?.cancel()
        macControlStatusTask = nil
    }

    private func requestMacControlNotificationsIfNeeded() {
        guard !macControlNotificationsRequested else { return }
        macControlNotificationsRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func scheduleMacControlLocalNotification(title: String, message: String) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty || !trimmedMessage.isEmpty else { return }

        let content = UNMutableNotificationContent()
        content.title = trimmedTitle.isEmpty ? "soranin" : trimmedTitle
        content.body = trimmedMessage.isEmpty ? tr("Done on Mac.", "ការងារលើ Mac បានចប់ហើយ។") : trimmedMessage
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "soranin.maccontrol.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func bootstrapMessage(
        from result: (
            ok: Bool,
            message: String,
            profiles: [String],
            summary: String,
            macDisplayName: String,
            macDeviceName: String,
            macUserName: String,
            relayClientURL: String,
            relayEnabled: Bool
        )
    ) -> String {
        let summary = result.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return summary.isEmpty ? result.message : "\(result.message)\n\n\(summary)"
    }

    private func effectiveMacControlCardsServerURL() -> String {
        let primary = macControlServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !primary.isEmpty, !isLoopbackMacControlURL(primary) {
            return primary
        }
        let remote = macControlRemoteServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remote.isEmpty {
            return remote
        }
        return primary
    }

    private func currentMacControlPackagesOwnerKey() -> String {
        let remote = macControlRemoteServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remote.isEmpty {
            return remote.lowercased()
        }
        let server = macControlServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !server.isEmpty {
            return server.lowercased()
        }
        let display = macControlDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return display.lowercased()
    }

    private func persistMacControlPackagesCache(_ packages: [MacControlPackageCard]) {
        let ownerKey = currentMacControlPackagesOwnerKey()
        guard !ownerKey.isEmpty else { return }
        let payload = MacControlPackagesCache(ownerKey: ownerKey, packages: packages)
        guard let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        macControlPackagesCacheJSON = json
    }

    private func clearMacControlPackagesCache() {
        macControlPackagesCacheJSON = ""
        macControlPackages = []
        macControlSelectedPackageIDs.removeAll()
        lastMacControlPackagesVerificationOwnerKey = ""
    }

    private func restoreMacControlPackagesCacheIfNeeded() {
        guard macControlPackages.isEmpty,
              let data = macControlPackagesCacheJSON.data(using: .utf8),
              let payload = try? JSONDecoder().decode(MacControlPackagesCache.self, from: data)
        else {
            return
        }
        let currentOwner = currentMacControlPackagesOwnerKey()
        if !currentOwner.isEmpty, payload.ownerKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != currentOwner {
            clearMacControlPackagesCache()
            return
        }
        macControlPackages = payload.packages
        syncMacControlSelectedPackagesFromFolders()
    }

    private func isLikelyRemoteMacControlURL(_ value: String) -> Bool {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return false }
        return text.contains("/client/")
            || text.contains("https://")
            || !(text.contains("192.168.") || text.contains("10.") || text.contains("172.") || text.contains("127.0.0.1") || text.contains("localhost"))
    }

    private func isLoopbackMacControlURL(_ value: String) -> Bool {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return false }
        return text.contains("127.0.0.1") || text.contains("localhost")
    }

    private func normalizeMacControlServerURLsForCurrentDevice() {
        let primary = macControlServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let remote = macControlRemoteServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if isLoopbackMacControlURL(primary) {
            if !remote.isEmpty {
                macControlServerURL = remote
            } else {
                macControlServerURL = ""
            }
        }
    }

    private func shouldAutoVerifyMacControlPackages() -> Bool {
        let ownerKey = currentMacControlPackagesOwnerKey()
        guard !ownerKey.isEmpty else { return false }
        if ownerKey != lastMacControlPackagesVerificationOwnerKey {
            return true
        }
        return Date().timeIntervalSince(lastMacControlPackagesVerificationAt) >= 15
    }

    private func silentlyVerifyMacControlPackageCardsIfNeeded() async {
        guard showingMacControlSheet, !isLoadingMacControl, shouldAutoVerifyMacControlPackages() else {
            return
        }
        let ownerKey = currentMacControlPackagesOwnerKey()
        let result = await viewModel.loadMacFacebookPackages(
            preferredServerURL: effectiveMacControlCardsServerURL(),
            password: macControlPassword
        )
        guard result.ok else {
            if isLikelyRemoteMacControlURL(effectiveMacControlCardsServerURL()) {
                clearMacControlPackagesCache()
            }
            return
        }
        macControlPackages = result.packages
        syncMacControlSelectedPackagesFromFolders()
        persistMacControlPackagesCache(result.packages)
        lastMacControlPackagesVerificationOwnerKey = ownerKey
        lastMacControlPackagesVerificationAt = Date()
    }

    private func applyMacControlBootstrap(
        _ result: (
            ok: Bool,
            message: String,
            profiles: [String],
            summary: String,
            macDisplayName: String,
            macDeviceName: String,
            macUserName: String,
            relayClientURL: String,
            relayEnabled: Bool
        ),
        serverURL: String? = nil
    ) {
        if let serverURL, !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            macControlServerURL = serverURL
        }
        macControlProfiles = result.profiles
        macControlDisplayName = result.macDisplayName
        macControlDeviceName = result.macDeviceName
        macControlUserName = result.macUserName
        if !result.relayClientURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            macControlRemoteServerURL = result.relayClientURL
            if macControlServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || isLoopbackMacControlURL(macControlServerURL) {
                macControlServerURL = result.relayClientURL
            }
        }
        normalizeMacControlServerURLsForCurrentDevice()
        if macPostChromeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let first = result.profiles.first {
            macPostChromeName = first
        }
    }

    private func syncMacControlSelectedPackagesFromFolders() {
        let tokens = macPostFolders
            .components(separatedBy: CharacterSet(charactersIn: ", \n\t"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let available = Set(macControlPackages.map(\.id))
        macControlSelectedPackageIDs = Set(tokens).intersection(available)
    }

    private func syncMacControlFoldersFromSelectedPackages() {
        let selectedNames = macControlPackages
            .filter { macControlSelectedPackageIDs.contains($0.id) }
            .map(\.packageName)
        macPostFolders = selectedNames.joined(separator: "\n")
    }

    private func toggleMacControlPackageSelection(_ item: MacControlPackageCard) {
        if macControlSelectedPackageIDs.contains(item.id) {
            macControlSelectedPackageIDs.remove(item.id)
        } else {
            macControlSelectedPackageIDs.insert(item.id)
        }
        syncMacControlFoldersFromSelectedPackages()
    }

    private func addSelectedMacControlPackagesToFolders() {
        let selectedNames = macControlPackages
            .filter { macControlSelectedPackageIDs.contains($0.id) }
            .map(\.packageName)
        macPostFolders = selectedNames.joined(separator: "\n")
        syncMacControlSelectedPackagesFromFolders()
    }

    private func thumbnailURLForMacControlPackage(_ item: MacControlPackageCard) -> URL? {
        guard item.hasThumbnail else { return nil }
        let base = effectiveMacControlCardsServerURL().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty,
              var components = URLComponents(string: base + "/facebook-package-thumbnail") else {
            return nil
        }
        components.queryItems = [URLQueryItem(name: "package_name", value: item.packageName)]
        return components.url
    }

    @discardableResult
    private func loadMacControlPackageCards() async -> String? {
        let ownerKey = currentMacControlPackagesOwnerKey()
        let result = await viewModel.loadMacFacebookPackages(
            preferredServerURL: effectiveMacControlCardsServerURL(),
            password: macControlPassword
        )
        if result.ok {
            macControlPackages = result.packages
            syncMacControlSelectedPackagesFromFolders()
            persistMacControlPackagesCache(result.packages)
            if !ownerKey.isEmpty {
                lastMacControlPackagesVerificationOwnerKey = ownerKey
                lastMacControlPackagesVerificationAt = Date()
            }
            let packageNote = result.packages.isEmpty
                ? tr("No package cards found on Mac.", "មិនទាន់មាន package cards លើ Mac ទេ។")
                : tr("Loaded \(result.packages.count) package cards from Mac.", "បានទាញ \(result.packages.count) package cards ពី Mac។")
            if macControlResultMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                macControlResultMessage = packageNote
            } else if !macControlResultMessage.contains(packageNote) {
                macControlResultMessage += "\n\n\(packageNote)"
            }
            return packageNote
        } else if isLikelyRemoteMacControlURL(effectiveMacControlCardsServerURL()) {
            clearMacControlPackagesCache()
        }
        return nil
    }

    private func refreshMacControlPackageCards() {
        guard !isLoadingMacControl else { return }
        isLoadingMacControl = true
        Task {
            await loadMacControlPackageCards()
            isLoadingMacControl = false
        }
    }

    private func deleteMacControlPackage(_ item: MacControlPackageCard) {
        guard !isLoadingMacControl else { return }
        isLoadingMacControl = true
        macControlResultMessage = tr(
            "Deleting \(item.packageName) on Mac...",
            "កំពុងលុប \(item.packageName) លើ Mac..."
        )
        Task {
            let result = await viewModel.deleteMacFacebookPackage(
                packageName: item.packageName,
                preferredServerURL: effectiveMacControlCardsServerURL(),
                password: macControlPassword
            )
            if result.ok {
                macControlPackages = result.packages
                macControlSelectedPackageIDs.remove(item.id)
                syncMacControlSelectedPackagesFromFolders()
                persistMacControlPackagesCache(result.packages)
            }
            macControlResultMessage = result.message
            isLoadingMacControl = false
        }
    }

    private func refreshMacControlBootstrap(allowDiscovery: Bool = true) {
        guard !isLoadingMacControl else { return }
        isLoadingMacControl = true
        macControlResultMessage = tr(
            "Loading Mac control...",
            "កំពុងទាញ Mac control..."
        )
        Task {
            let originalServerURL = macControlServerURL
            var result = await viewModel.loadMacControlBootstrap(
                preferredServerURL: originalServerURL,
                chromeName: macPostChromeName,
                pageName: macPostPageName,
                password: macControlPassword
            )

            if !result.ok, allowDiscovery {
                macControlResultMessage = tr(
                    "Scanning Wi-Fi for your Mac...",
                    "កំពុងស្កេន Wi-Fi ដើម្បីរក Mac របស់អ្នក..."
                )
                let discovery = await viewModel.discoverMacControlServer(
                    preferredServerURL: originalServerURL,
                    includeDirectCandidates: false
                )
                if discovery.ok, let discoveredServerURL = discovery.serverURL {
                    result = await viewModel.loadMacControlBootstrap(
                        preferredServerURL: discoveredServerURL,
                        chromeName: macPostChromeName,
                        pageName: macPostPageName,
                        password: macControlPassword
                    )
                    if !result.ok {
                        let remoteMessage = bootstrapMessage(from: result)
                        macControlResultMessage = "\(discovery.message)\n\n\(remoteMessage)"
                        isLoadingMacControl = false
                        return
                    }
                    applyMacControlBootstrap(result, serverURL: discoveredServerURL)
                    let packageNote = await loadMacControlPackageCards()
                    macControlResultMessage = [
                        discovery.message,
                        bootstrapMessage(from: result),
                        packageNote
                    ]
                    .compactMap { value in
                        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        return trimmed.isEmpty ? nil : trimmed
                    }
                    .joined(separator: "\n\n")
                    isLoadingMacControl = false
                    return
                }
                macControlResultMessage = "\(result.message)\n\n\(discovery.message)"
                if isLikelyRemoteMacControlURL(originalServerURL) || isLikelyRemoteMacControlURL(macControlRemoteServerURL) {
                    clearMacControlPackagesCache()
                }
                isLoadingMacControl = false
                return
            }

            if result.ok {
                applyMacControlBootstrap(result)
                let packageNote = await loadMacControlPackageCards()
                macControlResultMessage = [
                    bootstrapMessage(from: result),
                    packageNote
                ]
                .compactMap { value in
                    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return trimmed.isEmpty ? nil : trimmed
                }
                .joined(separator: "\n\n")
            } else {
                macControlResultMessage = result.message
                if isLikelyRemoteMacControlURL(originalServerURL) || isLikelyRemoteMacControlURL(macControlRemoteServerURL) {
                    clearMacControlPackagesCache()
                }
            }
            isLoadingMacControl = false
        }
    }

    private func scanMacControlServer() {
        guard !isLoadingMacControl else { return }
        isLoadingMacControl = true
        macControlResultMessage = tr(
            "Scanning Wi-Fi for your Mac...",
            "កំពុងស្កេន Wi-Fi ដើម្បីរក Mac របស់អ្នក..."
        )
        Task {
            let originalServerURL = macControlServerURL
            let discovery = await viewModel.discoverMacControlServer(
                preferredServerURL: originalServerURL,
                includeDirectCandidates: false
            )

            if discovery.ok, let discoveredServerURL = discovery.serverURL {
                let localResult = await viewModel.loadMacControlBootstrap(
                    preferredServerURL: discoveredServerURL,
                    chromeName: macPostChromeName,
                    pageName: macPostPageName,
                    password: macControlPassword
                )
                if localResult.ok {
                    applyMacControlBootstrap(localResult, serverURL: discoveredServerURL)
                    let packageNote = await loadMacControlPackageCards()
                    macControlResultMessage = [
                        discovery.message,
                        bootstrapMessage(from: localResult),
                        packageNote
                    ]
                    .compactMap { value in
                        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        return trimmed.isEmpty ? nil : trimmed
                    }
                    .joined(separator: "\n\n")
                    isLoadingMacControl = false
                    return
                }
            }

            macControlResultMessage = tr(
                "Wi-Fi Fast is not available. Switching to Remote Mac...",
                "Wi‑Fi Fast មិនមានទេ។ កំពុងប្តូរទៅ Remote Mac..."
            )
            let remoteResult = await viewModel.loadMacControlBootstrap(
                preferredServerURL: originalServerURL,
                chromeName: macPostChromeName,
                pageName: macPostPageName,
                password: macControlPassword
            )
            if remoteResult.ok {
                applyMacControlBootstrap(remoteResult)
                let packageNote = await loadMacControlPackageCards()
                macControlResultMessage = [
                    discovery.message,
                    bootstrapMessage(from: remoteResult),
                    packageNote
                ]
                .compactMap { value in
                    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return trimmed.isEmpty ? nil : trimmed
                }
                .joined(separator: "\n\n")
            } else {
                macControlResultMessage = "\(discovery.message)\n\n\(remoteResult.message)"
                if isLikelyRemoteMacControlURL(originalServerURL) || isLikelyRemoteMacControlURL(macControlRemoteServerURL) {
                    clearMacControlPackagesCache()
                }
            }
            isLoadingMacControl = false
        }
    }

    private func sendCurrentInputToMac() {
        guard !isLoadingMacControl else { return }
        isLoadingMacControl = true
        macControlResultMessage = tr(
            "Sending current Sora links to Mac...",
            "កំពុងផ្ញើ Sora links បច្ចុប្បន្នទៅ Mac..."
        )
        Task {
            viewModel.copyMacControlCommandFromInput(preferredServerURL: macControlServerURL)
            try? await Task.sleep(nanoseconds: 800_000_000)
            macControlResultMessage = viewModel.statusMessage
            isLoadingMacControl = false
        }
    }

    private func presentMacActionAlert(title: String, message: String) {
        requestMacControlNotificationsIfNeeded()
        macActionAlertTitle = title
        macActionAlertMessage = message
        showingMacActionAlert = true
        scheduleMacControlLocalNotification(title: title, message: message)
    }

    private func sendMainRawInputToMac() {
        guard !isLoadingMacControl else { return }
        let trimmed = viewModel.rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            let message = tr(
                "Paste at least one Sora link first.",
                "សូម paste Sora link យ៉ាងហោចណាស់ 1 ជាមុនសិន។"
            )
            macControlResultMessage = message
            viewModel.statusMessage = message
            return
        }

        isLoadingMacControl = true
        let loadingMessage = tr(
            "Sending pasted Sora link to Mac only...",
            "កំពុងផ្ញើ Sora link ដែលបាន paste ទៅ Mac ប៉ុណ្ណោះ..."
        )
        macControlResultMessage = loadingMessage
        viewModel.statusMessage = loadingMessage

        Task {
            let result = await viewModel.sendRawInputToMacController(
                trimmed,
                preferredServerURL: macControlServerURL,
                password: macControlPassword
            )
            let finalMessage = result.message ?? tr(
                "Sent to Mac.",
                "បានផ្ញើទៅ Mac ហើយ។"
            )
            macControlResultMessage = finalMessage
            viewModel.statusMessage = finalMessage
            if result.ok {
                presentMacActionAlert(
                    title: tr("Link Sent to Mac", "បានផ្ញើ Link ទៅ Mac"),
                    message: finalMessage
                )
            }
            isLoadingMacControl = false
        }
    }

    private func sendManualLinkToMac() {
        guard !isLoadingMacControl else { return }
        let trimmed = macControlLinkInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            macControlResultMessage = tr(
                "Paste at least one link first.",
                "សូម paste link យ៉ាងហោចណាស់ 1 ជាមុនសិន។"
            )
            return
        }

        isLoadingMacControl = true
        let loadingMessage = tr(
            "Sending pasted links to Mac download...",
            "កំពុងផ្ញើ links ដែលបាន paste ទៅ Mac download..."
        )
        macControlResultMessage = loadingMessage
        viewModel.statusMessage = loadingMessage

        Task {
            let result = await viewModel.sendRawInputToMacController(
                trimmed,
                preferredServerURL: macControlServerURL,
                password: macControlPassword
            )
            if result.ok {
                macControlLinkInput = ""
            }
            let finalMessage = result.message ?? tr(
                "Sent pasted links to Mac.",
                "បានផ្ញើ links ដែលបាន paste ទៅ Mac ហើយ។"
            )
            macControlResultMessage = finalMessage
            viewModel.statusMessage = finalMessage
            if result.ok {
                presentMacActionAlert(
                    title: tr("Link Sent to Mac", "បានផ្ញើ Link ទៅ Mac"),
                    message: finalMessage
                )
            }
            isLoadingMacControl = false
        }
    }

    private func openMacDropVideoPicker() {
        guard !isLoadingMacControl else { return }
        showingMacDropVideoImporter = true
    }

    private func uploadPickedVideoToMac(_ fileURL: URL) {
        guard !isLoadingMacControl else { return }
        let clipLabel = fileURL.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)

        macSourceVideoUploadProgress = 0
        isLoadingMacControl = true
        let loadingMessage = tr(
            "Uploading video to Drop Videos on Mac... 0%",
            "កំពុង upload video ទៅ Drop Videos លើ Mac... 0%"
        )
        macControlResultMessage = loadingMessage
        viewModel.statusMessage = loadingMessage

        Task {
            let result = await viewModel.uploadVideoToMacSourceVideos(
                fileURL: fileURL,
                displayName: clipLabel,
                preferredServerURL: macControlServerURL,
                password: macControlPassword,
                onProgress: { progress in
                    macSourceVideoUploadProgress = progress
                    let percent = Int((progress * 100).rounded())
                    let progressMessage = tr(
                        "Uploading video to Drop Videos on Mac... \(percent)%",
                        "កំពុង upload video ទៅ Drop Videos លើ Mac... \(percent)%"
                    )
                    macControlResultMessage = progressMessage
                    viewModel.statusMessage = progressMessage
                }
            )
            macSourceVideoUploadProgress = result.ok ? 1 : 0
            macControlResultMessage = result.message
            viewModel.statusMessage = result.message
            if result.ok {
                presentMacActionAlert(
                    title: tr("Upload Done", "Upload រួចហើយ"),
                    message: result.message
                )
            }
            isLoadingMacControl = false
        }
    }

    private func preflightMacFacebookPost() {
        guard !isLoadingMacControl else { return }
        isLoadingMacControl = true
        macControlResultMessage = tr(
            "Running Facebook preflight on Mac...",
            "កំពុងរត់ Facebook preflight លើ Mac..."
        )
        Task {
            let result = await viewModel.preflightMacFacebookPost(
                preferredServerURL: macControlServerURL,
                chromeName: macPostChromeName,
                pageName: macPostPageName,
                foldersText: macPostFolders,
                intervalMinutes: macPostIntervalMinutes,
                closeAfterEach: macPostCloseAfterEach,
                closeAfterFinish: macPostCloseAfterFinish,
                postNowAdvanceSlot: macPostAdvanceQueue,
                password: macControlPassword
            )
            macControlResultMessage = result.summary.isEmpty ? result.message : "\(result.message)\n\n\(result.summary)"
            isLoadingMacControl = false
        }
    }

    private func runMacFacebookPost() {
        guard !isLoadingMacControl else { return }
        isLoadingMacControl = true
        macControlResultMessage = tr(
            "Starting Facebook post run on Mac...",
            "កំពុងចាប់ផ្តើម Facebook post run លើ Mac..."
        )
        Task {
            let result = await viewModel.runMacFacebookPost(
                preferredServerURL: macControlServerURL,
                chromeName: macPostChromeName,
                pageName: macPostPageName,
                foldersText: macPostFolders,
                intervalMinutes: macPostIntervalMinutes,
                closeAfterEach: macPostCloseAfterEach,
                closeAfterFinish: macPostCloseAfterFinish,
                postNowAdvanceSlot: macPostAdvanceQueue,
                password: macControlPassword
            )
            macControlResultMessage = result.message
            isLoadingMacControl = false
        }
    }

    private func quitMacChrome() {
        guard !isLoadingMacControl else { return }
        isLoadingMacControl = true
        macControlResultMessage = tr(
            "Asking Mac to quit Chrome...",
            "កំពុងស្នើឲ្យ Mac បិទ Chrome..."
        )
        Task {
            let result = await viewModel.quitMacChrome(preferredServerURL: macControlServerURL, password: macControlPassword)
            macControlResultMessage = result.message
            isLoadingMacControl = false
        }
    }

    private func headerRow(isCompact: Bool) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("soranin")
                    .font(.system(size: isCompact ? 28 : 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text(tr(
                    "Paste the Sora link, keep only the ID, save fast, and convert for Reels.",
                    "បិទភ្ជាប់ Sora link, កាត់ទុកតែ ID, ទាញយកលឿន ហើយបម្លែងសម្រាប់ Reels។"
                ))
                    .font(.system(size: isCompact ? 13 : 14, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Menu {
                Button {
                    viewModel.setLanguage(.english)
                } label: {
                    Label("English", systemImage: viewModel.appLanguage == .english ? "checkmark" : "globe")
                }

                Button {
                    viewModel.setLanguage(.khmer)
                } label: {
                    Label("ខ្មែរ", systemImage: viewModel.appLanguage == .khmer ? "checkmark" : "globe")
                }

                Divider()

                Button {
                    googleAIAPIKeyDraft = ""
                    viewModel.presentGoogleAIKeyPrompt(runCreateTitlesAfterSave: false)
                } label: {
                    Label(
                        tr("Google AI Studio Key", "Google AI Studio Key"),
                        systemImage: viewModel.hasConfiguredGoogleAIKey ? "sparkles.rectangle.stack.fill" : "key.horizontal.fill"
                    )
                }

                Button {
                    openAIAPIKeyDraft = ""
                    viewModel.presentOpenAIKeyPrompt(runCreateTitlesAfterSave: false)
                } label: {
                    Label(
                        tr("OpenAI Key", "OpenAI Key"),
                        systemImage: viewModel.hasConfiguredOpenAIKey ? "sparkles" : "key.horizontal.fill"
                    )
                }

                Divider()

                Button {
                    viewModel.setSelectedAIProvider(.googleGemini)
                } label: {
                    Label(
                        tr("Use Google Gemini", "ប្រើ Google Gemini"),
                        systemImage: viewModel.selectedAIProvider == .googleGemini ? "checkmark.circle.fill" : "circle"
                    )
                }

                Button {
                    viewModel.setSelectedAIProvider(.openAI)
                } label: {
                    Label(
                        tr("Use OpenAI", "ប្រើ OpenAI"),
                        systemImage: viewModel.selectedAIProvider == .openAI ? "checkmark.circle.fill" : "circle"
                    )
                }

                Divider()

                Button {
                    focusedField = nil
                    viewModel.showAIChat()
                } label: {
                    Label(
                        tr("AI Chat", "AI Chat"),
                        systemImage: "bubble.left.and.bubble.right.fill"
                    )
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.10))
                        .frame(width: isCompact ? 54 : 60, height: isCompact ? 54 : 60)

                    Image(systemName: "globe")
                        .font(.system(size: isCompact ? 20 : 22, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func actionPanel(phoneLayout: Bool) -> AnyView {
        let panelContent = VStack(alignment: .leading, spacing: phoneLayout ? 16 : 20) {
            if !phoneLayout {
                Text("soranin")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text(tr(
                    "Paste the Sora link, keep only the Sora ID, download fast, then edit with zoom, text, emoji, GIF, and multi-video input before you convert.",
                    "បិទភ្ជាប់ Sora link, កាត់ទុកតែ Sora ID, ទាញយកលឿន ហើយកែដោយ zoom, text, emoji, GIF និង multi-video មុនពេល convert។"
                ))
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
            }

            downloadSaveModeToggle
            mainLinkRouteToggle
            inputBar
            if !viewModel.downloadStatusBadges.isEmpty {
                downloadStatusBadgesRow
            }
            helperChips(phoneLayout: phoneLayout)
            downloadButton

            if viewModel.hasDownloadQueueEntries {
                progressPanel
            }

            if viewModel.isMerging {
                mergePanel
            }

            reelsConvertPanel
            editorAIActionsRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        return AnyView(
            Group {
                if phoneLayout {
                    panelContent
                } else {
                    panelContent
                        .padding(24)
                        .background(heroPanelBackground)
                        .overlay(heroStars)
                }
            }
        )
    }

    private var inputBar: AnyView {
        let isCompactSummary = viewModel.shouldShowConcealedDownloadInputSummary && focusedField != .rawInput

        return AnyView(
            HStack(alignment: .center, spacing: 10) {
                inputField
                pasteButton
            }
            .padding(.horizontal, isCompactSummary ? 12 : 12)
            .padding(.vertical, isCompactSummary ? 6 : 12)
            .frame(minHeight: isCompactSummary ? 54 : nil)
            .background(
                RoundedRectangle(cornerRadius: isCompactSummary ? 22 : 28, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: isCompactSummary ? 22 : 28, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        )
    }

    private var mainLinkRouteToggle: some View {
        Button {
            focusedField = nil
            isSendingMainInputToMac.toggle()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSendingMainInputToMac ? "laptopcomputer.and.arrow.down" : "iphone")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 3) {
                    Text(tr("Paste Link Destination", "គោលដៅ Link ដែលបាន Paste"))
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.68))

                    Text(
                        isSendingMainInputToMac
                            ? tr("Send to Mac Only", "ផ្ញើទៅ Mac ប៉ុណ្ណោះ")
                            : tr("Use on Phone iOS", "ប្រើលើទូរស័ព្ទ iOS")
                    )
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                }

                Spacer(minLength: 10)

                Text(isSendingMainInputToMac ? tr("MAC", "MAC") : tr("PHONE", "PHONE"))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.14))
                    )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        isSendingMainInputToMac
                            ? Color(red: 0.39, green: 0.22, blue: 0.22).opacity(0.92)
                            : Color(red: 0.15, green: 0.25, blue: 0.38).opacity(0.92)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(
                        isSendingMainInputToMac
                            ? Color(red: 1.00, green: 0.55, blue: 0.45).opacity(0.36)
                            : Color(red: 0.44, green: 0.80, blue: 1.00).opacity(0.32),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isBusy || isLoadingMacControl)
        .opacity((viewModel.isBusy || isLoadingMacControl) ? 0.5 : 1)
    }

    private var inputField: some View {
        let isCompactSummary = viewModel.shouldShowConcealedDownloadInputSummary && focusedField != .rawInput
        let iconSize: CGFloat = isCompactSummary ? 30 : 42
        let iconFontSize: CGFloat = isCompactSummary ? 13 : 17

        return HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: iconSize, height: iconSize)

                Image(systemName: "link")
                    .font(.system(size: iconFontSize, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.82))

                if viewModel.downloadQueueCount > 0 {
                    Text(viewModel.downloadQueueCount > 99 ? "99+" : "\(viewModel.downloadQueueCount)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, viewModel.downloadQueueCount > 99 ? 5 : 0)
                    .frame(minWidth: 18, minHeight: 18)
                        .background(
                            Capsule()
                                .fill(Color(red: 0.47, green: 0.63, blue: 1.00))
                        )
                        .offset(x: 15, y: -15)
                }
            }

            ZStack(alignment: .topLeading) {
                if viewModel.rawInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(
                        isSendingMainInputToMac
                            ? tr("Paste Sora link to send to Mac", "បិទភ្ជាប់ Sora link ដើម្បីផ្ញើទៅ Mac")
                            : tr("Paste Sora link", "បិទភ្ជាប់ Sora link")
                    )
                        .foregroundStyle(Color.white.opacity(0.36))
                        .font(.system(size: 17, weight: .medium, design: .rounded))
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                } else if viewModel.shouldShowConcealedDownloadInputSummary && focusedField != .rawInput {
                    Text(viewModel.concealedDownloadInputSummary)
                        .foregroundStyle(Color.white.opacity(0.72))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.top, isCompactSummary ? 8 : 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }

                TextEditor(
                    text: Binding(
                        get: { viewModel.rawInput },
                        set: { viewModel.updateRawInput($0) }
                    )
                )
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .focused($focusedField, equals: .rawInput)
                .disabled(viewModel.isBusy && !viewModel.isDownloading)
                .foregroundStyle(
                    viewModel.shouldShowConcealedDownloadInputSummary && focusedField != .rawInput
                        ? Color.clear
                        : Color.white
                )
                .tint(.white)
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .frame(
                    minHeight: isCompactSummary ? 40 : 68,
                    maxHeight: isCompactSummary ? 40 : 108
                )
            }
            .layoutPriority(1)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: isCompactSummary ? 42 : 68)
    }

    private var pasteButton: some View {
        let isCompactSummary = viewModel.shouldShowConcealedDownloadInputSummary && focusedField != .rawInput

        return Button {
            viewModel.captureIDFromClipboard()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 15, weight: .bold))

                Text(tr("Past", "បិទភ្ជាប់"))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(.white)
            .frame(width: isCompactSummary ? 98 : 132)
            .padding(.horizontal, isCompactSummary ? 10 : 14)
            .padding(.vertical, isCompactSummary ? 5 : 12)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isBusy && !viewModel.isDownloading)
    }

    private var downloadStatusBadgesRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(viewModel.downloadStatusBadges) { badge in
                    downloadStatusBadgeChip(badge)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func downloadStatusBadgeChip(_ badge: DownloadStatusBadge) -> some View {
        let styling = downloadStatusBadgeStyling(for: badge.tone)

        return HStack(spacing: 7) {
            Circle()
                .fill(styling.dot)
                .frame(width: 8, height: 8)

            Text(badge.label)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(styling.foreground)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            Capsule()
                .fill(styling.background)
        )
        .overlay(
            Capsule()
                .stroke(styling.border, lineWidth: 1)
        )
    }

    private func downloadStatusBadgeStyling(for tone: DownloadStatusBadgeTone) -> (
        foreground: Color,
        background: Color,
        border: Color,
        dot: Color
    ) {
        switch tone {
        case .accent:
            return (
                foreground: .white,
                background: Color(red: 0.24, green: 0.36, blue: 0.68).opacity(0.42),
                border: Color(red: 0.41, green: 0.63, blue: 1.00).opacity(0.38),
                dot: Color(red: 0.54, green: 0.75, blue: 1.00)
            )
        case .success:
            return (
                foreground: Color(red: 0.88, green: 1.00, blue: 0.95),
                background: Color(red: 0.17, green: 0.38, blue: 0.29).opacity(0.48),
                border: Color(red: 0.42, green: 0.92, blue: 0.73).opacity(0.45),
                dot: Color(red: 0.44, green: 0.94, blue: 0.73)
            )
        case .warning:
            return (
                foreground: Color(red: 1.00, green: 0.97, blue: 0.86),
                background: Color(red: 0.43, green: 0.32, blue: 0.12).opacity(0.46),
                border: Color(red: 1.00, green: 0.76, blue: 0.34).opacity(0.42),
                dot: Color(red: 1.00, green: 0.76, blue: 0.34)
            )
        case .danger:
            return (
                foreground: Color(red: 1.00, green: 0.92, blue: 0.92),
                background: Color(red: 0.42, green: 0.16, blue: 0.20).opacity(0.48),
                border: Color(red: 1.00, green: 0.49, blue: 0.49).opacity(0.42),
                dot: Color(red: 1.00, green: 0.49, blue: 0.49)
            )
        }
    }

    private func helperChips(phoneLayout: Bool) -> AnyView {
        AnyView(
            LazyVGrid(columns: helperChipColumns(phoneLayout: phoneLayout), alignment: .leading, spacing: 10) {
                aiAutoModeChipButton
                chip(icon: "rectangle.portrait", label: tr("Reels 9:16 HD", "Reels 9:16 HD"))
                chipButton(
                    icon: "text.bubble.fill",
                    label: tr("Titles History", "ប្រវត្តិ Titles"),
                    count: viewModel.generatedTitlesHistory.count + viewModel.trashedGeneratedTitlesHistory.count
                ) {
                    viewModel.showTitlesHistory()
                }
                chipButton(
                    icon: "sparkles.rectangle.stack.fill",
                    label: tr("Prompt History", "ប្រវត្តិ Prompt"),
                    count: viewModel.generatedPromptsHistory.count + viewModel.trashedGeneratedPromptsHistory.count
                ) {
                    viewModel.showPromptHistory()
                }
                chipButton(
                    icon: "bubble.left.and.bubble.right.fill",
                    label: tr("AI Chat", "AI Chat"),
                    count: viewModel.aiChatSessions.count
                ) {
                    focusedField = nil
                    viewModel.showAIChat()
                }
                chipButton(
                    icon: "laptopcomputer",
                    label: tr("Control Mac", "គ្រប់គ្រង Mac"),
                    count: 0
                ) {
                    focusedField = nil
                    openMacControlSheet()
                }
            }
        )
    }

    private var aiAutoModeChipButton: some View {
        Button {
            focusedField = nil
            viewModel.toggleAIAutoMode()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 16, alignment: .center)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text(viewModel.aiAutoModeTitle)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Text(viewModel.aiAutoModeSubtitle)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.62))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(viewModel.aiAutoModeStatusText)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(
                                viewModel.isAIAutoModeEnabled
                                ? Color(red: 0.28, green: 0.83, blue: 0.71).opacity(0.95)
                                : Color.white.opacity(0.12)
                            )
                    )
            }
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(
                        viewModel.isAIAutoModeEnabled
                        ? Color(red: 0.14, green: 0.21, blue: 0.36).opacity(0.96)
                        : Color.white.opacity(0.08)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(
                        viewModel.isAIAutoModeEnabled
                        ? Color(red: 0.39, green: 0.75, blue: 0.98).opacity(0.38)
                        : Color.white.opacity(0.05),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func helperChipColumns(phoneLayout: Bool) -> [GridItem] {
        if phoneLayout {
            return [
                GridItem(.flexible(minimum: 0, maximum: .infinity), spacing: 10, alignment: .top),
                GridItem(.flexible(minimum: 0, maximum: .infinity), spacing: 10, alignment: .top),
            ]
        }

        return [
            GridItem(.adaptive(minimum: 118, maximum: 180), spacing: 8, alignment: .top)
        ]
    }

    private func chip(icon: String, label: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .frame(width: 16, alignment: .center)
                .padding(.top, 1)

            Text(label)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(Color.white.opacity(0.84))
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.05), lineWidth: 1)
        )
    }

    private func chipButton(icon: String, label: String, count: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                chip(icon: icon, label: label)

                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Color(red: 0.21, green: 0.54, blue: 0.97).opacity(0.96))
                        )
                        .padding(8)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var downloadButton: AnyView {
        AnyView(
            Button {
                focusedField = nil
                if isSendingMainInputToMac {
                    sendMainRawInputToMac()
                } else {
                    Task {
                        await viewModel.downloadVideo()
                    }
                }
            } label: {
                HStack(spacing: 12) {
                    if viewModel.isDownloading || isLoadingMacControl {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: isSendingMainInputToMac ? "paperplane.circle.fill" : "arrow.down.circle.fill")
                            .font(.system(size: 20, weight: .semibold))
                    }

                    Text(downloadButtonTitle)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .background(
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    isSendingMainInputToMac
                                        ? Color(red: 0.90, green: 0.42, blue: 0.32)
                                        : Color(red: 0.57, green: 0.31, blue: 0.89),
                                    isSendingMainInputToMac
                                        ? Color(red: 0.72, green: 0.22, blue: 0.56)
                                        : Color(red: 0.25, green: 0.45, blue: 0.96)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                )
                .shadow(
                    color: (
                        isSendingMainInputToMac
                            ? Color(red: 0.82, green: 0.31, blue: 0.39)
                            : Color(red: 0.37, green: 0.41, blue: 0.98)
                    ).opacity(0.45),
                    radius: 24,
                    x: 0,
                    y: 14
                )
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isBusy || isLoadingMacControl)
            .opacity((viewModel.isBusy || isLoadingMacControl) ? 0.92 : 1)
        )
    }

    private var downloadButtonTitle: String {
        if isSendingMainInputToMac {
            return isLoadingMacControl
                ? tr("Sending to Mac...", "កំពុងផ្ញើទៅ Mac...")
                : tr("Send to Mac Only", "ផ្ញើទៅ Mac ប៉ុណ្ណោះ")
        }

        guard viewModel.isDownloading else { return tr("Start Download", "ចាប់ផ្ដើមទាញយក") }
        return viewModel.downloadProgress > 0
            ? tr("Downloading \(viewModel.downloadPercentText)", "កំពុងទាញយក \(viewModel.downloadPercentText)")
            : tr("Downloading...", "កំពុងទាញយក...")
    }

    private var progressPanel: AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(tr("Download Queue", "បញ្ជីទាញយក"))
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.72))

                    Spacer(minLength: 8)

                    Text("\(viewModel.completedDownloadQueueCount)/\(viewModel.downloadQueueCount)")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }

                if let activeItem = viewModel.activeDownloadQueueItem {
                    HStack(spacing: 8) {
                        Text(activeItem.displayTitle)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        Spacer(minLength: 6)

                        Text(activeItem.percentText)
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    }

                    ProgressView(value: viewModel.downloadProgress, total: 1)
                        .tint(.white)
                        .progressViewStyle(.linear)
                        .scaleEffect(x: 1, y: 1.2, anchor: .center)
                }

                VStack(spacing: 8) {
                    ForEach(viewModel.downloadQueue) { item in
                        downloadQueueRow(item)
                    }
                }
            }
        )
    }

    private func downloadQueueRow(_ item: DownloadQueueItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(item.displayTitle)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Spacer(minLength: 6)

                Text(downloadQueueStatusText(item))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(queueStatusColor(item))
            }

            ProgressView(value: item.progress, total: 1)
                .tint(queueStatusColor(item))
                .progressViewStyle(.linear)
                .scaleEffect(x: 1, y: 1.05, anchor: .center)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }

    private func downloadQueueStatusText(_ item: DownloadQueueItem) -> String {
        switch item.state {
        case .queued:
            return tr("Queued", "រង់ចាំ")
        case .downloading:
            return item.percentText
        case .completed:
            return tr("Done", "រួច")
        case .failed:
            return tr("Failed", "បរាជ័យ")
        }
    }

    private func queueStatusColor(_ item: DownloadQueueItem) -> Color {
        switch item.state {
        case .queued:
            return Color.white.opacity(0.72)
        case .downloading:
            return .white
        case .completed:
            return Color(red: 0.44, green: 0.94, blue: 0.73)
        case .failed:
            return Color(red: 1.00, green: 0.49, blue: 0.49)
        }
    }

    private var conversionPanel: AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    ProgressView()
                        .tint(.white)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(tr("Creating Facebook Reels", "កំពុងបង្កើត Facebook Reels"))
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)

                        Text(tr("9:16 full size at \(viewModel.selectedSpeed.label)", "9:16 full size ល្បឿន \(viewModel.selectedSpeed.label)"))
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.68))
                    }

                    Spacer(minLength: 8)

                    Text(viewModel.conversionPercentText)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }

                ProgressView(value: viewModel.conversionProgress, total: 1)
                    .tint(.white)
                    .progressViewStyle(.linear)
                    .scaleEffect(x: 1, y: 1.2, anchor: .center)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
        )
    }

    private var mergePanel: AnyView {
        AnyView(
            HStack(spacing: 12) {
                ProgressView()
                    .tint(.white)

                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("Merging Videos", "កំពុងបញ្ចូលវីដេអូ"))
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)

                    Text(tr("Joining clips for one convert-ready video.", "កំពុងភ្ជាប់ clips សម្រាប់វីដេអូ convert តែមួយ។"))
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.68))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
        )
    }

    private var reelsConvertPanel: AnyView {
        AnyView(
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("Facebook Reels", "Facebook Reels"))
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Text(tr("Full size 9:16 portrait export in 1080 x 1920 with zoom, text, emoji, and GIF stickers.", "បម្លែង 9:16 1080 x 1920 ជាមួយ zoom, text, emoji និង GIF stickers។"))
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.68))
                }

                Spacer(minLength: 12)

                HStack(spacing: 8) {
                    if !viewModel.editorClips.isEmpty {
                        clearClipsButton
                    }

                    addClipsButton
                }
            }

            convertSourceEditorPanel

            Button {
                focusedField = nil
                Task {
                    await viewModel.convertLatestVideoForReels(editorSettings: editorSettings)
                }
            } label: {
                HStack(spacing: 12) {
                    if viewModel.isConverting {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "sparkles.rectangle.stack.fill")
                            .font(.system(size: 18, weight: .semibold))
                    }

                    Text(viewModel.isConverting ? tr("Exporting \(viewModel.conversionPercentText)", "កំពុង Export \(viewModel.conversionPercentText)") : tr("Convert to Reels HD", "បម្លែងទៅ Reels HD"))
                        .font(.system(size: 16, weight: .bold, design: .rounded))

                    Spacer(minLength: 0)

                    Text(viewModel.selectedSpeed.label)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.20, green: 0.60, blue: 0.98),
                                    Color(red: 0.14, green: 0.82, blue: 0.74)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                )
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canConvertLatestVideo)
            .opacity(viewModel.canConvertLatestVideo ? 1 : 0.76)

            timelinePanel

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text(tr("Convert Speed", "ល្បឿនបម្លែង"))
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.76))

                    Spacer(minLength: 8)

                    Text(viewModel.selectedSpeed.label)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(0.10))
                        )
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(VideoSpeedOption.allCases) { option in
                            speedButton(option)
                                .frame(width: 96)
                        }
                    }
                    .padding(.vertical, 1)
                }
            }

            Text(tr("Convert opens a popup when it finishes. soranin saves the export to Photos first, then you can create titles or share it.", "ពេល convert ចប់ វានឹងបើក popup។ soranin នឹង Save វីដេអូទៅ Photos ជាមុនសិន បន្ទាប់មកអាច Create Titles ឬ Share បាន។"))
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.62))
                .fixedSize(horizontal: false, vertical: true)

            editorToolsPanel
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        )
    }

    private var convertSourceEditorPanel: AnyView {
        AnyView(
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("Selected Clip", "Clip ដែលបានជ្រើស"))
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    if let selectedClipTitleText {
                        Text(selectedClipTitleText)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.54))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if viewModel.hasEditorVideo {
                    Text(selectedClipNumberText)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.88))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(0.10))
                        )
                }
            }

            if let fileURL = viewModel.editorVideoURL {
                InteractiveEditorCanvas(
                    clips: viewModel.editorClips,
                    selectedClipID: viewModel.selectedClipID,
                    clipID: viewModel.selectedClip?.id,
                    fileURL: fileURL,
                    isWorking: viewModel.isBusy,
                    isGeneratingAIPhoto: viewModel.isGeneratingThumbnail,
                    zoomScale: $editorZoomScale,
                    panOffset: $editorPanOffset,
                    captionText: $editorCaptionText,
                    captionPosition: $editorCaptionPosition,
                    captionScale: $editorCaptionScale,
                    captionRotation: $editorCaptionRotation,
                    emojiText: $editorEmojiText,
                    emojiPosition: $editorEmojiPosition,
                    emojiScale: $editorEmojiScale,
                    emojiRotation: $editorEmojiRotation,
                    gifData: $editorGIFData,
                    gifPosition: $editorGIFPosition,
                    gifScale: $editorGIFScale,
                    gifRotation: $editorGIFRotation,
                    selectedTarget: $selectedEditorTarget,
                    timelineScrubRequest: timelineScrubRequest,
                    aiActionLabel: tr("AI Photo", "AI រូប"),
                    aiActionSystemImage: "sparkles",
                    onAIPhoto: {
                        Task {
                            await viewModel.createThumbnailForCurrentEditorVideo()
                        }
                    },
                    onCutPhoto: { seconds in
                        Task {
                            await viewModel.capturePhotoFromLatestVideo(at: seconds)
                        }
                    }
                )
                .id(fileURL.absoluteString)

                Text(
                        viewModel.editorClipCount > 1
                            ? tr("This big player edits only the selected clip. The clip timeline stays below.", "Player ធំនេះកែបានតែ clip ដែលបានជ្រើសប៉ុណ្ណោះ។ Clip timeline នៅខាងក្រោម។")
                            : tr("This big player edits the current clip here.", "Player ធំនេះកែ clip បច្ចុប្បន្ននៅទីនេះ។")
                )
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.62))
                    .lineLimit(3)
            } else {
                editorVideoPlaceholder

                Text(tr("Download, input, or merge videos first, then edit them here with zoom, text, emoji, and GIF before you convert.", "សូមទាញយក ឬបញ្ចូលវីដេអូមុនសិន បន្ទាប់មកកែវានៅទីនេះដោយ zoom, text, emoji និង GIF មុនពេល convert។"))
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.66))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.black.opacity(0.14))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.05), lineWidth: 1)
        )
        )
    }

    private var editorAIActionsRow: some View {
        editorPromptButton
    }

    private var usesStackedPromptLayout: Bool {
        UIScreen.main.bounds.width < 430
    }

    private var editorPromptButton: some View {
        VStack(alignment: .leading, spacing: 12) {
            Group {
                if usesStackedPromptLayout {
                    VStack(alignment: .leading, spacing: 14) {
                        PromptSourceUploadBox(
                            fileURL: viewModel.promptInputVideoURL,
                            previewImageURL: viewModel.promptInputFramePreviewURL,
                            isKhmer: viewModel.appLanguage == .khmer,
                            fillsWidth: true,
                            onAdd: {
                                focusedField = nil
                                showingPromptVideoImporter = true
                            },
                            onPreviewTap: {
                                focusedField = nil
                                guard viewModel.promptInputVideoURL != nil else { return }
                                isShowingPromptFramePicker = true
                            }
                        )

                        promptControlsContent
                    }
                } else {
                    HStack(alignment: .top, spacing: 14) {
                        PromptSourceUploadBox(
                            fileURL: viewModel.promptInputVideoURL,
                            previewImageURL: viewModel.promptInputFramePreviewURL,
                            isKhmer: viewModel.appLanguage == .khmer,
                            fillsWidth: false,
                            onAdd: {
                                focusedField = nil
                                showingPromptVideoImporter = true
                            },
                            onPreviewTap: {
                                focusedField = nil
                                guard viewModel.promptInputVideoURL != nil else { return }
                                isShowingPromptFramePicker = true
                            }
                        )

                        promptControlsContent
                    }
                }
            }

            if viewModel.isGeneratingPrompt {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)

                        Text(tr("Creating prompt with AI", "កំពុងបង្កើត prompt ដោយ AI"))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)

                        Spacer(minLength: 8)

                        Text(viewModel.promptPercentText)
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    }

                    ProgressView(value: viewModel.promptGenerationProgress, total: 1)
                        .tint(.white)
                        .progressViewStyle(.linear)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
            }

            if !trimmedGeneratedPromptText.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(tr("Prompt Result", "Prompt ដែលបានបង្កើត"))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Text(trimmedGeneratedPromptText)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color.white.opacity(0.07))
                        )

                    Button {
                        Task {
                            await viewModel.copyGeneratedPromptToClipboard()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "doc.on.doc.fill")
                                .font(.system(size: 14, weight: .bold))

                            Text(tr("Copy Prompt", "ចម្លង Prompt"))
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            Capsule()
                                .fill(Color(red: 0.21, green: 0.54, blue: 0.97).opacity(0.92))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(red: 0.20, green: 0.60, blue: 0.98).opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var promptControlsContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .bold))

                Text(tr("Create Prompt", "បង្កើត Prompt"))
                    .font(.system(size: 15, weight: .bold, design: .rounded))

                Spacer(minLength: 0)

                Text(viewModel.selectedAIProviderName)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(
                                viewModel.selectedAIProvider == .googleGemini
                                    ? Color(red: 0.21, green: 0.54, blue: 0.97).opacity(0.88)
                                    : Color(red: 0.14, green: 0.82, blue: 0.74).opacity(0.88)
                            )
                    )

                if viewModel.isGeneratingPrompt {
                    Text(viewModel.promptPercentText)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(0.10))
                        )
                }
            }

            Text("First describe the video clearly, then convert it into a Sora prompt.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)

            Text(promptSourceSummaryText)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.56))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                aiProviderButton(.googleGemini)
                aiProviderButton(.openAI)
            }

            HStack(spacing: 8) {
                Text(tr("Model", "Model"))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.70))

                Spacer(minLength: 8)

                AIModelMenuButton(
                    selectedModelID: viewModel.selectedModelID(for: viewModel.selectedAIProvider),
                    options: viewModel.modelOptions(for: viewModel.selectedAIProvider),
                    isRefreshing: viewModel.selectedAIProvider == .googleGemini
                        ? viewModel.isRefreshingGoogleModels
                        : viewModel.isRefreshingOpenAIModels,
                    isKhmer: viewModel.appLanguage == .khmer,
                    onSelect: { modelID in
                        viewModel.setSelectedModel(modelID, for: viewModel.selectedAIProvider)
                    }
                )
            }

            Text(viewModel.selectedAIProviderSubtitle)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(
                    viewModel.selectedAIProviderIsConfigured
                        ? Color(red: 0.70, green: 0.95, blue: 0.80)
                        : Color(red: 1.00, green: 0.73, blue: 0.49)
                )
                .fixedSize(horizontal: false, vertical: true)

            Button {
                focusedField = nil
                Task {
                    await viewModel.createPromptForCurrentEditorVideo()
                }
            } label: {
                HStack(spacing: 8) {
                    if viewModel.isGeneratingPrompt {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(0.9)
                    } else {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 14, weight: .bold))
                    }

                    Text(viewModel.isGeneratingPrompt ? tr("Submitting \(viewModel.promptPercentText)", "កំពុងបង្កើត \(viewModel.promptPercentText)") : tr("Submit Video", "បញ្ជូនវីដេអូ"))
                        .font(.system(size: 13, weight: .bold, design: .rounded))

                    Spacer(minLength: 0)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.20, green: 0.60, blue: 0.98),
                                    Color(red: 0.14, green: 0.82, blue: 0.74)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                )
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.hasPromptInputVideo || viewModel.isBusy)
            .opacity(viewModel.hasPromptInputVideo ? 1 : 0.62)

            Button {
                focusedField = nil
                Task {
                    await viewModel.createTitlesForCurrentEditorVideo()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "text.badge.star")
                        .font(.system(size: 14, weight: .bold))

                    Text(tr("Create Titles", "បង្កើត Titles"))
                        .font(.system(size: 13, weight: .bold, design: .rounded))

                    Spacer(minLength: 0)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    Capsule()
                        .fill(Color(red: 0.90, green: 0.52, blue: 0.18).opacity(0.78))
                )
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.hasPromptInputVideo || viewModel.isBusy)
            .opacity(viewModel.hasPromptInputVideo ? 1 : 0.62)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var promptSourceSummaryText: String {
        if viewModel.hasPromptInputVideo {
            return tr(
                "Uses the video in this prompt box only.",
                "ប្រើតែវីដេអូក្នុងប្រអប់ Prompt នេះប៉ុណ្ណោះ។"
            )
        }

        return tr(
            "Tap Add Video in this box first, then submit it here.",
            "សូមចុច Add Video នៅក្នុងប្រអប់នេះសិន បន្ទាប់មកបញ្ជូនវានៅទីនេះ។"
        )
    }

    private func aiProviderButton(_ provider: AIProvider) -> some View {
        let isSelected = viewModel.selectedAIProvider == provider
        let hasKey = provider == .googleGemini ? viewModel.hasConfiguredGoogleAIKey : viewModel.hasConfiguredOpenAIKey

        return Button {
            viewModel.setSelectedAIProvider(provider)
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(hasKey ? Color(red: 0.44, green: 0.94, blue: 0.73) : Color(red: 1.00, green: 0.55, blue: 0.55))
                    .frame(width: 8, height: 8)

                Text(provider == .googleGemini ? "Google Gemini" : "OpenAI")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                Capsule()
                    .fill(
                        isSelected
                            ? Color.white.opacity(0.18)
                            : Color.white.opacity(0.08)
                    )
            )
            .overlay(
                Capsule()
                    .stroke(
                        isSelected
                            ? Color.white.opacity(0.28)
                            : Color.white.opacity(0.08),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var trimmedGeneratedPromptText: String {
        viewModel.generatedPromptText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var timelinePanel: AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(tr("Clip Timeline", "Clip Timeline"))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.76))

                    Spacer(minLength: 8)

                    Text(formattedTimelineTime(viewModel.adjustedTotalClipDuration))
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(0.10))
                        )

                    clipCountBadge
                }

                if viewModel.editorClips.isEmpty {
                    Text(tr("Add videos from Photos. They will appear in a clip line here.", "បន្ថែមវីដេអូពី Photos។ វានឹងបង្ហាញនៅក្នុង clip line ខាងនេះ។"))
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.62))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ClipTimelineStrip(
                        clips: viewModel.editorClips,
                        selectedClipID: $timelineSelectionID,
                        playheadTime: $timelinePlayheadTime,
                        zoomLevel: $timelineZoomLevel,
                        draggedClipID: $draggedTimelineClipID,
                        isBusy: viewModel.isBusy,
                        onReorder: { sourceID, targetID in
                            viewModel.moveClip(from: sourceID, to: targetID)
                        },
                        onScrub: { clip, seconds, isInteractive in
                            viewModel.selectClip(clip.id)
                            timelineSelectionID = clip.id
                            loadSelectedClipSettings()
                            syncTimelinePlayheadToSelectedClip()
                            timelineScrubRequest = TimelineScrubRequest(
                                clipID: clip.id,
                                seconds: seconds,
                                isInteractive: isInteractive
                            )
                        },
                        onRemove: { clip in
                            Task {
                                await viewModel.removeClip(clip)
                            }
                        }
                    )

                    Text(tr("Tap to edit. Pinch with 2 fingers to resize. Hold and drag to move. Drop on trash to delete.", "ចុចដើម្បីកែ។ ប្រើម្រាមដៃ 2 ដើម្បីបង្រួមពង្រីក។ ចុចជាប់ហើយអូសដើម្បីផ្លាស់ទី។ ដាក់លើធុងសំរាមដើម្បីលុប។"))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.58))
                        .lineLimit(2)
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.black.opacity(0.14))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.05), lineWidth: 1)
            )
        )
    }

    private var editorToolsPanel: AnyView {
        AnyView(
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                    Text(tr("Edit Tools", "ឧបករណ៍កែសម្រួល"))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.76))

                Spacer(minLength: 8)

                if editorGIFData != nil {
                    Text("GIF ready")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(Color(red: 0.20, green: 0.60, blue: 0.98).opacity(0.38))
                        )
                    }
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(EditorFocusTarget.allCases) { target in
                    targetFocusButton(target)
                }
            }

            ViewThatFits {
                HStack(spacing: 8) {
                    gifButton
                    clearStickerButton
                }

                VStack(spacing: 8) {
                    gifButton
                    clearStickerButton
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.black.opacity(0.14))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.05), lineWidth: 1)
        )
        )
    }

    private var gifButton: some View {
        Button {
            showingGIFImporter = true
        } label: {
            Label(editorGIFData == nil ? "Add GIF" : "Replace GIF", systemImage: "sparkles.tv")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.white.opacity(0.10))
                )
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isBusy)
    }

    private var clearStickerButton: some View {
        Button {
            editorGIFData = nil
            editorCaptionText = ""
            editorEmojiText = ""
            resetOverlayLayout()
            selectedEditorTarget = .video
        } label: {
            Label("Clear", systemImage: "trash")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
        }
        .buttonStyle(.plain)
        .disabled(
            viewModel.isBusy ||
            (editorGIFData == nil && editorCaptionText.isEmpty && editorEmojiText.isEmpty)
        )
    }

    private func overlayField(
        title: String,
        icon: String,
        text: Binding<String>,
        prompt: String,
        focusField: ContentTextFocusField,
        onTap: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.72))

            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.72))

                TextField(
                    "",
                    text: text,
                    prompt: Text(prompt).foregroundStyle(Color.white.opacity(0.30))
                )
                .textInputAutocapitalization(.sentences)
                .autocorrectionDisabled()
                .focused($focusedField, equals: focusField)
                .submitLabel(.done)
                .foregroundStyle(.white)
                .tint(.white)
                .disabled(viewModel.isBusy)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .onTapGesture {
                    focusedField = focusField
                    onTap()
                }
                .onSubmit {
                    focusedField = nil
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
        }
    }

    private func editorIconButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.10))
                )
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isBusy)
    }

    private var currentTargetScale: Double {
        switch selectedEditorTarget {
        case .video:
            return editorZoomScale
        case .text:
            return editorCaptionScale
        case .emoji:
            return editorEmojiScale
        case .gif:
            return editorGIFScale
        }
    }

    private var minimumTargetScale: Double {
        selectedEditorTarget == .video ? 1 : 0.5
    }

    private var maximumTargetScale: Double {
        selectedEditorTarget == .video ? 4 : 3.6
    }

    private func updateCurrentTargetScale(_ value: Double) {
        switch selectedEditorTarget {
        case .video:
            editorZoomScale = value
        case .text:
            editorCaptionScale = value
        case .emoji:
            editorEmojiScale = value
        case .gif:
            editorGIFScale = value
        }
    }

    private func resetCurrentTargetTransform() {
        switch selectedEditorTarget {
        case .video:
            resetEditorFraming()
        case .text:
            editorCaptionScale = 1
            editorCaptionRotation = 0
            editorCaptionPosition = CGPoint(x: 0.5, y: 0.82)
        case .emoji:
            editorEmojiScale = 1
            editorEmojiRotation = 0
            editorEmojiPosition = CGPoint(x: 0.5, y: 0.18)
        case .gif:
            editorGIFScale = 1
            editorGIFRotation = 0
            editorGIFPosition = CGPoint(x: 0.8, y: 0.26)
        }
    }

    private func targetFocusButton(_ target: EditorFocusTarget) -> some View {
        let isSelected = selectedEditorTarget == target

        return Button {
            switch target {
            case .video:
                selectedEditorTarget = .video
            case .text:
                presentOverlayInputPopup(.text)
            case .emoji:
                presentOverlayInputPopup(.emoji)
            case .gif:
                selectedEditorTarget = .gif
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: target.icon)
                    .font(.system(size: 13, weight: .bold))

                Text(target.rawValue)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isSelected ? Color(red: 0.20, green: 0.60, blue: 0.98).opacity(0.34) : Color.white.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(isSelected ? Color.white.opacity(0.28) : Color.white.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isBusy || (target == .gif && editorGIFData == nil))
        .opacity(target == .gif && editorGIFData == nil ? 0.58 : 1)
    }

    private var sidePanel: some View {
        VStack(spacing: 18) {
            cardsGrid(isWideLayout: true)
        }
    }

    private var addClipsButton: some View {
        Button {
            if viewModel.editorClips.isEmpty {
                showingVideoImporter = true
            } else {
                showingMergeImporter = true
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 14, weight: .bold))

                Text(viewModel.editorClips.isEmpty ? tr("Add Clips", "បន្ថែម Clips") : tr("More Clips", "Clips បន្ថែម"))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.10))
            )
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isBusy)
    }

    private var clearClipsButton: some View {
        Button {
            focusedField = nil
            timelineSelectionID = nil
            timelinePlayheadTime = 0
            timelineZoomLevel = 1
            viewModel.clearAllEditorClips()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "trash.fill")
                    .font(.system(size: 13, weight: .bold))

                Text(tr("Clear All", "លុបទាំងអស់"))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                Capsule()
                    .fill(Color(red: 0.88, green: 0.30, blue: 0.35).opacity(0.88))
            )
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isBusy)
    }

    private var clipCountBadge: some View {
        Text(viewModel.editorClips.isEmpty ? tr("No Clips", "គ្មាន Clips") : "\(viewModel.editorClips.count) \(tr("Clips", "Clips"))")
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.10))
            )
    }

    private func cardsGrid(isWideLayout: Bool) -> some View {
        let columns = isWideLayout
            ? [GridItem(.flexible()), GridItem(.flexible())]
            : [GridItem(.flexible())]

        return LazyVGrid(columns: columns, spacing: 16) {
            statusCard
            autosaveCard
            cleanupCard
        }
    }

    private var statusCard: AnyView {
        AnyView(
            infoCard(
                title: tr("Status", "ស្ថានភាព"),
                icon: "bolt.fill",
                accent: Color(red: 0.50, green: 0.36, blue: 0.94)
            ) {
                Text(viewModel.statusMessage)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.78))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        )
    }

    private var editorVideoPlaceholder: AnyView {
        AnyView(
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.black.opacity(0.24))

                VStack(spacing: 10) {
                    Image(systemName: "play.rectangle")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.86))

                        Text(tr("Input or download a video to edit it here", "បញ្ចូល ឬទាញយកវីដេអូដើម្បីកែនៅទីនេះ"))
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.72))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 170)
        )
    }

    private var autosaveCard: AnyView {
        AnyView(
            infoCard(
                title: tr("Save Flow", "Flow នៃការរក្សាទុក"),
                icon: "photo.on.rectangle.angled",
                accent: Color(red: 0.22, green: 0.78, blue: 0.74)
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(tr("Download mode", "របៀបទាញយក"))
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Text(
                        viewModel.downloadAutoSavesToPhotos
                            ? tr("Download -> Photos + Clip Timeline", "ទាញយក -> Photos + Clip Timeline")
                            : tr("Download -> Clip Timeline only", "ទាញយក -> Clip Timeline ប៉ុណ្ណោះ")
                    )
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.78))

                    Text(tr("This switch changes downloads only.", "ប៊ូតុងនេះប្ដូរតែរបៀបទាញយកប៉ុណ្ណោះ។"))
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.72))

                    Text(tr("Export popup", "Export popup"))
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Text(tr("Convert Done popup -> Auto save to Photos + Create Titles or Share", "Convert Done popup -> Save ទៅ Photos ដោយស្វ័យប្រវត្តិ + Create Titles ឬ Share"))
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.72))

                    Text(tr("The popup saves the export to Photos first, then lets you create titles or share it.", "popup នឹង Save វីដេអូ export ទៅ Photos ជាមុនសិន បន្ទាប់មកអាច Create Titles ឬ Share បាន។"))
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.72))

                    Text(tr("Export can keep running while you switch apps, but force-closing iPhone apps can still stop it.", "Export អាចបន្តដំណើរការពេលអ្នកប្ដូរ app ប៉ុន្តែបើបិទ app ដាច់ វាអាចឈប់បាន។"))
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.72))

                    Text(tr("Files app: On My iPhone > soranin", "Files app: On My iPhone > soranin"))
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        )
    }

    private var downloadSaveModeToggle: some View {
        Button {
            viewModel.toggleDownloadSaveMode()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.downloadSaveModeTitle)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)

                    Text(viewModel.downloadSaveModeSubtitle)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.66))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 10)

                HStack(spacing: 10) {
                    Image(systemName: viewModel.downloadAutoSavesToPhotos ? "photo.badge.arrow.down.fill" : "film.stack.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)

                    Text(viewModel.downloadAutoSavesToPhotos ? "ON" : "OFF")
                        .font(.system(size: 13, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(viewModel.downloadAutoSavesToPhotos ? 0.18 : 0.10))
                )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func speedButton(_ option: VideoSpeedOption) -> some View {
        let isSelected = viewModel.selectedSpeed == option

        return Button {
            viewModel.selectedSpeed = option
        } label: {
            Text(option.label)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(isSelected ? Color.white.opacity(0.22) : Color.white.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(
                            isSelected ? Color.white.opacity(0.28) : Color.white.opacity(0.08),
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isBusy)
    }

    private var mergeButton: some View {
        Button {
            showingMergeImporter = true
        } label: {
            VStack(spacing: 6) {
                if viewModel.isMerging {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 15, weight: .bold))
                }

                Text("Add More +")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 50)
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(red: 0.42, green: 0.46, blue: 0.88).opacity(0.34))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isBusy)
    }

    private var cleanupCard: AnyView {
        AnyView(
            infoCard(
                title: tr("Clipboard Clean-Up", "សម្អាត Clipboard"),
                icon: "wand.and.stars",
                accent: Color(red: 0.98, green: 0.59, blue: 0.33)
            ) {
                Text(tr("Tap Past and the app removes extra text, keeping only the Sora ID before download.", "ចុច Paste ហើយ app នឹងកាត់អត្ថបទបន្ថែមចេញ ដោយទុកតែ Sora ID មុនពេលទាញយក។"))
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.78))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        )
    }

    private func infoCard<Content: View>(
        title: String,
        icon: String,
        accent: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(accent.opacity(0.18))
                        .frame(width: 42, height: 42)

                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                }

                Text(title)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }

            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 184, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
        )
    }

    private var heroPanelBackground: some View {
        RoundedRectangle(cornerRadius: 34, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.10, green: 0.11, blue: 0.25),
                        Color(red: 0.09, green: 0.12, blue: 0.26),
                        Color(red: 0.11, green: 0.18, blue: 0.31)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
    }

    private var heroStars: some View {
        RoundedRectangle(cornerRadius: 34, style: .continuous)
            .fill(.clear)
            .overlay(alignment: .topLeading) {
                ZStack {
                    ForEach(0..<18, id: \.self) { index in
                        Circle()
                            .fill(Color.white.opacity(index.isMultiple(of: 4) ? 0.34 : 0.16))
                            .frame(
                                width: index.isMultiple(of: 5) ? 3 : 2,
                                height: index.isMultiple(of: 5) ? 3 : 2
                            )
                            .offset(
                                x: starX(for: index),
                                y: starY(for: index)
                            )
                    }
                }
                .padding(.top, 18)
                .padding(.leading, 18)
            }
            .allowsHitTesting(false)
    }

    private var backgroundView: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.03, green: 0.04, blue: 0.10),
                    Color(red: 0.06, green: 0.08, blue: 0.17),
                    Color(red: 0.08, green: 0.10, blue: 0.19)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [
                    Color(red: 0.50, green: 0.28, blue: 0.94).opacity(0.45),
                    .clear
                ],
                center: .bottomLeading,
                startRadius: 20,
                endRadius: 440
            )
            .offset(x: -120, y: 120)

            RadialGradient(
                colors: [
                    Color(red: 0.22, green: 0.52, blue: 0.98).opacity(0.34),
                    .clear
                ],
                center: .topTrailing,
                startRadius: 10,
                endRadius: 360
            )
            .offset(x: 80, y: -100)

            ZStack {
                ForEach(0..<30, id: \.self) { index in
                    Circle()
                        .fill(Color.white.opacity(index.isMultiple(of: 3) ? 0.22 : 0.10))
                        .frame(width: index.isMultiple(of: 4) ? 3 : 2, height: index.isMultiple(of: 4) ? 3 : 2)
                        .offset(x: backgroundStarX(for: index), y: backgroundStarY(for: index))
                }
            }
        }
    }

    private func starX(for index: Int) -> CGFloat {
        let values: [CGFloat] = [36, 104, 182, 244, 302, 372, 428, 88, 152, 220, 286, 346, 406, 126, 196, 262, 334, 390]
        return values[index]
    }

    private func starY(for index: Int) -> CGFloat {
        let values: [CGFloat] = [12, 40, 22, 66, 18, 54, 32, 90, 108, 98, 126, 88, 116, 150, 166, 148, 178, 138]
        return values[index]
    }

    private func backgroundStarX(for index: Int) -> CGFloat {
        let values: [CGFloat] = [-180, -130, -80, -20, 40, 100, 170, 220, -210, -150, -40, 20, 110, 190, -190, -120, -60, 30, 90, 180, -170, -100, -10, 70, 150, -200, -140, -30, 60, 140]
        return values[index]
    }

    private func backgroundStarY(for index: Int) -> CGFloat {
        let values: [CGFloat] = [-360, -320, -340, -300, -350, -310, -330, -290, -180, -150, -170, -140, -160, -120, 20, 40, 10, 30, 0, 24, 180, 230, 210, 250, 220, 360, 330, 350, 320, 370]
        return values[index]
    }
}

private struct InteractiveEditorCanvas: View {
    let clips: [EditorClip]
    let selectedClipID: EditorClip.ID?
    let clipID: EditorClip.ID?
    let fileURL: URL
    let isWorking: Bool
    let isGeneratingAIPhoto: Bool
    @Binding var zoomScale: Double
    @Binding var panOffset: CGSize
    @Binding var captionText: String
    @Binding var captionPosition: CGPoint
    @Binding var captionScale: Double
    @Binding var captionRotation: Double
    @Binding var emojiText: String
    @Binding var emojiPosition: CGPoint
    @Binding var emojiScale: Double
    @Binding var emojiRotation: Double
    @Binding var gifData: Data?
    @Binding var gifPosition: CGPoint
    @Binding var gifScale: Double
    @Binding var gifRotation: Double
    @Binding var selectedTarget: EditorFocusTarget
    let timelineScrubRequest: TimelineScrubRequest?
    let aiActionLabel: String
    let aiActionSystemImage: String
    let onAIPhoto: () -> Void
    let onCutPhoto: (Double) -> Void

    @State private var player = AVPlayer()
    @State private var sourceAspectRatio: CGFloat = 9.0 / 16.0
    @State private var duration = 0.0
    @State private var currentTime = 0.0
    @State private var scrubTime = 0.0
    @State private var isScrubbing = false
    @State private var isPlaying = false
    @State private var shouldResumeAfterScrub = false
    @State private var timeObserver: Any?
    @State private var dragStartPan = CGSize.zero
    @State private var isDraggingVideo = false
    @State private var videoPanIntent: MediaPanIntent = .undecided
    @State private var pinchStartZoom = 1.0
    @State private var isPinchingVideo = false
    @State private var isTimelinePlaybackMode = false

    var body: some View {
        VStack(spacing: 12) {
            GeometryReader { geometry in
                let canvasSize = geometry.size
                let videoSize = videoFillSize(for: canvasSize)
                let clampedPan = clampedPanOffset(for: canvasSize, videoSize: videoSize)

                ZStack {
                    EditorPlayerSurface(player: player, videoGravity: .resizeAspectFill)
                        .frame(width: canvasSize.width, height: canvasSize.height)
                        .scaleEffect(1.08)
                        .blur(radius: 22)
                        .opacity(0.42)
                        .overlay(
                            LinearGradient(
                                colors: [
                                    Color.black.opacity(0.34),
                                    Color.black.opacity(0.56)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .onTapGesture {
                            selectedTarget = .video
                        }

                    EditorPlayerSurface(player: player, videoGravity: .resizeAspect)
                        .frame(width: videoSize.width, height: videoSize.height)
                        .scaleEffect(CGFloat(zoomScale))
                        .offset(
                            x: clampedPan.width * canvasSize.width,
                            y: clampedPan.height * canvasSize.height
                        )

                    if !captionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        InteractiveOverlayItem(
                            canvasSize: canvasSize,
                            baseSize: CGSize(width: min(canvasSize.width * 0.76, 300), height: 116),
                            isWorking: isWorking,
                            center: $captionPosition,
                            scale: $captionScale,
                            rotation: $captionRotation,
                            isSelected: selectedTarget == .text,
                            isInteractive: selectedTarget == .text,
                            onSelect: {
                                selectedTarget = .text
                            }
                        ) {
                            TextBubblePreview(text: captionText)
                        }
                    }

                    if !emojiText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        InteractiveOverlayItem(
                            canvasSize: canvasSize,
                            baseSize: CGSize(width: 132, height: 132),
                            isWorking: isWorking,
                            center: $emojiPosition,
                            scale: $emojiScale,
                            rotation: $emojiRotation,
                            isSelected: selectedTarget == .emoji,
                            isInteractive: selectedTarget == .emoji,
                            onSelect: {
                                selectedTarget = .emoji
                            }
                        ) {
                            EmojiOverlayPreview(text: emojiText)
                        }
                    }

                    if let gifData {
                        InteractiveOverlayItem(
                            canvasSize: canvasSize,
                            baseSize: CGSize(width: min(canvasSize.width * 0.34, 160), height: min(canvasSize.width * 0.34, 160)),
                            isWorking: isWorking,
                            center: $gifPosition,
                            scale: $gifScale,
                            rotation: $gifRotation,
                            isSelected: selectedTarget == .gif,
                            isInteractive: selectedTarget == .gif,
                            onSelect: {
                                selectedTarget = .gif
                            }
                        ) {
                            GIFOverlayPreview(data: gifData)
                        }
                    }

                    overlayHint
                }
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(
                            selectedTarget == .video ? Color(red: 0.20, green: 0.60, blue: 0.98) : Color.white.opacity(0.08),
                            lineWidth: selectedTarget == .video ? 2 : 1
                        )
                )
                .simultaneousGesture(videoPanGesture(canvasSize: canvasSize, baseVideoSize: videoSize))
                .simultaneousGesture(videoMagnificationGesture())
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(9.0 / 16.0, contentMode: .fit)

            VStack(spacing: 12) {
                Slider(
                    value: Binding(
                        get: { displayedTime },
                        set: { newValue in
                            let clampedValue = min(max(newValue, 0), sliderUpperBound)
                            scrubTime = clampedValue
                            currentTime = clampedValue

                            if isScrubbing {
                                seekInteractively(to: clampedValue)
                            }
                        }
                    ),
                    in: 0...sliderUpperBound,
                    onEditingChanged: handleScrubbingChanged
                )
                .tint(.white)
                .disabled(duration <= 0 || isWorking)

                playbackControls
            }
        }
        .onAppear {
            configurePlayer()
        }
        .onChange(of: fileURL) { _, _ in
            configurePlayer()
        }
        .onChange(of: selectedClipID) { _, _ in
            if !isTimelinePlaybackMode {
                configurePlayer()
            }
        }
        .onChange(of: clips.map(\.id)) { _, _ in
            if !isTimelinePlaybackMode {
                configurePlayer()
            }
        }
        .onChange(of: timelineScrubRequest) { _, newValue in
            guard let newValue, newValue.clipID == clipID else { return }
            applyTimelineScrub(newValue)
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
            guard notification.object as? AVPlayerItem === player.currentItem else { return }
            isPlaying = false
            currentTime = duration
            scrubTime = duration
        }
        .onDisappear {
            teardownPlayer()
        }
    }

    private var overlayHint: some View {
        VStack {
            HStack {
                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text("Editing \(selectedTarget.rawValue)")
                    Text(selectedTarget == .video ? "Pinch + Drag" : "Drag + Pinch + Rotate")
                }
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.76))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.black.opacity(0.34))
                )
            }

            Spacer()
        }
        .padding(12)
        .allowsHitTesting(false)
    }

    private var displayedTime: Double {
        isScrubbing ? scrubTime : currentTime
    }

    private var sliderUpperBound: Double {
        max(duration, 0.1)
    }

    private var playbackControls: some View {
        ViewThatFits {
            HStack(spacing: 8) {
                playPauseButton
                timeBadge
                photoActionButtons
            }

            VStack(spacing: 8) {
                timeBadge

                HStack(spacing: 8) {
                    playPauseButton
                    photoActionButtons
                }
            }
        }
    }

    private var playPauseButton: some View {
        Button {
            togglePlayback()
        } label: {
            Label(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(0.12))
                )
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
    }

    private var cutPhotoButton: some View {
        Button {
            onCutPhoto(displayedTime)
        } label: {
            Image(systemName: "camera.fill")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(red: 0.22, green: 0.52, blue: 0.98).opacity(0.92))
                )
        }
        .buttonStyle(.plain)
        .disabled(isWorking || (isTimelinePlaybackMode && clips.count > 1))
        .accessibilityLabel("Cut Photo")
    }

    private var aiPhotoButton: some View {
        Button {
            onAIPhoto()
        } label: {
            Image(systemName: aiActionSystemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.72))
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(Color(red: 0.21, green: 0.22, blue: 0.30).opacity(0.86))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(Color.white.opacity(0.05), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(isWorking || isGeneratingAIPhoto)
        .accessibilityLabel(aiActionLabel)
    }

    private var photoActionButtons: some View {
        HStack(spacing: 8) {
            aiPhotoButton
            cutPhotoButton
        }
    }

    private var timeBadge: some View {
        Text("\(formattedTime(displayedTime)) / \(formattedTime(duration))")
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.76))
            .monospacedDigit()
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.08))
            )
    }

    private func configurePlayer() {
        teardownPlayer()
        isTimelinePlaybackMode = false
        duration = 0
        currentTime = 0
        scrubTime = 0
        isScrubbing = false
        isPlaying = false
        shouldResumeAfterScrub = false

        let item = AVPlayerItem(url: fileURL)
        player.replaceCurrentItem(with: item)
        player.actionAtItemEnd = .pause
        installTimeObserver()

        if let timelineScrubRequest, timelineScrubRequest.clipID == clipID {
            let initialSeconds = max(timelineScrubRequest.seconds, 0)
            let time = CMTime(seconds: initialSeconds, preferredTimescale: 600)
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            currentTime = initialSeconds
            scrubTime = initialSeconds
        }

        Task {
            await loadDuration()
        }
    }

    private func teardownPlayer() {
        player.pause()
        isPlaying = false

        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
    }

    private func installTimeObserver() {
        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            let seconds = CMTimeGetSeconds(time)
            guard seconds.isFinite else { return }

            Task { @MainActor in
                if !isScrubbing {
                    let clampedSeconds = min(max(seconds, 0), duration > 0 ? duration : seconds)
                    currentTime = clampedSeconds
                    scrubTime = clampedSeconds
                }
            }
        }
    }

    private func loadDuration() async {
        do {
            let asset = AVURLAsset(url: fileURL)
            let assetDuration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(assetDuration)
            guard seconds.isFinite else { return }

            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            if let sourceVideoTrack = videoTracks.first {
                let naturalSize = try await sourceVideoTrack.load(.naturalSize)
                let preferredTransform = try await sourceVideoTrack.load(.preferredTransform)
                let transformedRect = CGRect(origin: .zero, size: naturalSize)
                    .applying(preferredTransform)
                    .standardized
                let width = abs(transformedRect.width)
                let height = abs(transformedRect.height)

                if width > 0, height > 0 {
                    sourceAspectRatio = width / height
                }
            }

            duration = max(seconds, 0)
            currentTime = min(currentTime, duration)
            scrubTime = min(scrubTime, duration)
        } catch {
            duration = 0
            sourceAspectRatio = 9.0 / 16.0
        }
    }

    private func handleScrubbingChanged(_ editing: Bool) {
        guard duration > 0 else { return }

        if editing {
            isScrubbing = true
            shouldResumeAfterScrub = isPlaying
            player.pause()
            isPlaying = false
            scrubTime = currentTime
        } else {
            isScrubbing = false
            seek(to: scrubTime, resumeAfterSeek: shouldResumeAfterScrub)
            shouldResumeAfterScrub = false
        }
    }

    private func togglePlayback() {
        if isPlaying {
            player.pause()
            isPlaying = false
            return
        }

        if clips.count > 1 {
            if !isTimelinePlaybackMode {
                startTimelinePlayback()
                return
            }
        }

        if duration > 0, currentTime >= duration {
            seek(to: 0, resumeAfterSeek: true)
        } else {
            player.play()
            isPlaying = true
        }
    }

    private func startTimelinePlayback() {
        guard clips.count > 1, let configuration = buildTimelinePlaybackConfiguration() else {
            if duration > 0, currentTime >= duration {
                seek(to: 0, resumeAfterSeek: true)
            } else {
                player.play()
                isPlaying = true
            }
            return
        }

        teardownPlayer()
        isTimelinePlaybackMode = true
        sourceAspectRatio = configuration.initialAspectRatio
        duration = configuration.totalDuration

        let desiredStartTime = 0.0
        currentTime = desiredStartTime
        scrubTime = desiredStartTime
        isScrubbing = false
        shouldResumeAfterScrub = false

        player.replaceCurrentItem(with: configuration.playerItem)
        player.actionAtItemEnd = .pause
        installTimeObserver()

        let startTime = CMTime(seconds: desiredStartTime, preferredTimescale: 600)
        player.seek(to: startTime, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            Task { @MainActor in
                player.play()
                isPlaying = true
            }
        }
    }

    private func buildTimelinePlaybackConfiguration() -> TimelinePlaybackConfiguration? {
        guard clips.count > 1 else { return nil }

        let composition = AVMutableComposition()
        var segments: [TimelinePlaybackSegment] = []
        var runningTime = CMTime.zero
        var initialAspectRatio = sourceAspectRatio
        let preferredSelectedClipID = selectedClipID ?? clipID ?? clips.first?.id

        for clip in clips {
            let asset = AVURLAsset(url: clip.fileURL)
            let assetDuration = asset.duration
            let durationSeconds = CMTimeGetSeconds(assetDuration)
            guard durationSeconds.isFinite, durationSeconds > 0 else { continue }

            guard let sourceVideoTrack = asset.tracks(withMediaType: .video).first,
                  let compositionVideoTrack = composition.addMutableTrack(
                    withMediaType: .video,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                  ) else {
                continue
            }

            do {
                try compositionVideoTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: assetDuration),
                    of: sourceVideoTrack,
                    at: runningTime
                )
            } catch {
                continue
            }
            compositionVideoTrack.preferredTransform = sourceVideoTrack.preferredTransform

            if let sourceAudioTrack = asset.tracks(withMediaType: .audio).first,
               let compositionAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
               ) {
                try? compositionAudioTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: assetDuration),
                    of: sourceAudioTrack,
                    at: runningTime
                )
            }

            let transformedRect = CGRect(origin: .zero, size: sourceVideoTrack.naturalSize)
                .applying(sourceVideoTrack.preferredTransform)
                .standardized
            let width = abs(transformedRect.width)
            let height = abs(transformedRect.height)
            let aspectRatio = width > 0 && height > 0 ? (width / height) : sourceAspectRatio

            if segments.isEmpty || preferredSelectedClipID == clip.id {
                initialAspectRatio = aspectRatio
            }

            segments.append(
                TimelinePlaybackSegment(
                    clipID: clip.id,
                    fileURL: clip.fileURL,
                    startTime: CMTimeGetSeconds(runningTime),
                    duration: durationSeconds,
                    aspectRatio: aspectRatio
                )
            )

            runningTime = CMTimeAdd(runningTime, assetDuration)
        }

        guard !segments.isEmpty else { return nil }

        return TimelinePlaybackConfiguration(
            playerItem: AVPlayerItem(asset: composition),
            segments: segments,
            totalDuration: CMTimeGetSeconds(runningTime),
            initialAspectRatio: initialAspectRatio
        )
    }

    private func seek(to seconds: Double, resumeAfterSeek: Bool) {
        let clampedSeconds = min(max(seconds, 0), duration > 0 ? duration : seconds)
        let time = CMTime(seconds: clampedSeconds, preferredTimescale: 600)

        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            Task { @MainActor in
                currentTime = clampedSeconds
                scrubTime = clampedSeconds

                if resumeAfterSeek {
                    player.play()
                    isPlaying = true
                } else {
                    isPlaying = false
                }
            }
        }
    }

    private func seekInteractively(to seconds: Double) {
        let clampedSeconds = min(max(seconds, 0), duration > 0 ? duration : seconds)
        let time = CMTime(seconds: clampedSeconds, preferredTimescale: 600)
        let tolerance = CMTime(seconds: 1.0 / 60.0, preferredTimescale: 600)
        player.currentItem?.cancelPendingSeeks()
        player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance)
        currentTime = clampedSeconds
        scrubTime = clampedSeconds
    }

    private func applyTimelineScrub(_ request: TimelineScrubRequest) {
        let clampedSeconds = min(max(request.seconds, 0), duration > 0 ? duration : request.seconds)
        player.pause()
        isPlaying = false
        shouldResumeAfterScrub = false
        if request.isInteractive {
            seekInteractively(to: clampedSeconds)
        } else {
            seek(to: clampedSeconds, resumeAfterSeek: false)
        }
    }

    private func videoFillSize(for canvasSize: CGSize) -> CGSize {
        let targetAspectRatio = canvasSize.width / max(canvasSize.height, 1)
        if sourceAspectRatio > targetAspectRatio {
            return CGSize(width: canvasSize.height * sourceAspectRatio, height: canvasSize.height)
        }
        return CGSize(width: canvasSize.width, height: canvasSize.width / max(sourceAspectRatio, 0.01))
    }

    private func clampedPanOffset(for canvasSize: CGSize, videoSize: CGSize) -> CGSize {
        let scaledWidth = videoSize.width * CGFloat(zoomScale)
        let scaledHeight = videoSize.height * CGFloat(zoomScale)
        let maxOffsetX = max(0, (scaledWidth - canvasSize.width) / 2) / max(canvasSize.width, 1)
        let maxOffsetY = max(0, (scaledHeight - canvasSize.height) / 2) / max(canvasSize.height, 1)

        return CGSize(
            width: min(max(panOffset.width, -maxOffsetX), maxOffsetX),
            height: min(max(panOffset.height, -maxOffsetY), maxOffsetY)
        )
    }

    private func videoPanGesture(canvasSize: CGSize, baseVideoSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard !isWorking, selectedTarget == .video else { return }

                if !isDraggingVideo {
                    let intent = resolvedMediaPanIntent(for: value.translation, zoomScale: zoomScale)
                    videoPanIntent = intent

                    guard intent == .panning else { return }
                    dragStartPan = panOffset
                    isDraggingVideo = true
                }

                guard videoPanIntent == .panning else { return }

                let startOffset = dragStartPan
                let proposed = CGSize(
                    width: startOffset.width + (value.translation.width / max(canvasSize.width, 1)),
                    height: startOffset.height + (value.translation.height / max(canvasSize.height, 1))
                )
                panOffset = clampedPanOffset(proposed, canvasSize: canvasSize, baseVideoSize: baseVideoSize)
            }
            .onEnded { _ in
                defer {
                    dragStartPan = .zero
                    isDraggingVideo = false
                    videoPanIntent = .undecided
                }

                guard selectedTarget == .video, videoPanIntent == .panning else { return }
                dragStartPan = .zero
                panOffset = clampedPanOffset(panOffset, canvasSize: canvasSize, baseVideoSize: baseVideoSize)
            }
    }

    private func videoMagnificationGesture() -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard !isWorking, selectedTarget == .video else { return }
                let startZoom = isPinchingVideo ? pinchStartZoom : zoomScale
                pinchStartZoom = startZoom
                isPinchingVideo = true
                zoomScale = min(max(startZoom * value.magnification, 1), 4)
            }
            .onEnded { _ in
                guard selectedTarget == .video else { return }
                pinchStartZoom = zoomScale
                isPinchingVideo = false
            }
    }

    private func clampedPanOffset(_ proposed: CGSize, canvasSize: CGSize, baseVideoSize: CGSize) -> CGSize {
        let scaledWidth = baseVideoSize.width * CGFloat(zoomScale)
        let scaledHeight = baseVideoSize.height * CGFloat(zoomScale)
        let maxOffsetX = max(0, (scaledWidth - canvasSize.width) / 2) / max(canvasSize.width, 1)
        let maxOffsetY = max(0, (scaledHeight - canvasSize.height) / 2) / max(canvasSize.height, 1)

        return CGSize(
            width: min(max(proposed.width, -maxOffsetX), maxOffsetX),
            height: min(max(proposed.height, -maxOffsetY), maxOffsetY)
        )
    }

    private func formattedTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "00:00" }

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

private struct ExportingReelsPopup: View {
    let progress: Double
    let progressText: String
    let speedText: String
    let title: String
    let subtitle: String

    @State private var animateParticles = false

    private let vaporSizes: [CGFloat] = [148, 118, 104, 92, 78]
    private let vaporOffsets: [CGSize] = [
        CGSize(width: -88, height: 24),
        CGSize(width: 84, height: -22),
        CGSize(width: -24, height: -72),
        CGSize(width: 52, height: 74),
        CGSize(width: -62, height: 78),
    ]
    private let sparkleOffsets: [CGSize] = [
        CGSize(width: -102, height: -84),
        CGSize(width: 96, height: -68),
        CGSize(width: -120, height: 58),
        CGSize(width: 112, height: 72),
        CGSize(width: -16, height: -108),
        CGSize(width: 20, height: 104),
    ]

    var body: some View {
        ZStack {
            Color.black.opacity(0.58)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                popupHeader
                animatedStage
            }
            .padding(22)
            .frame(maxWidth: 420)
            .background(
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .fill(Color(red: 0.09, green: 0.11, blue: 0.22))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .padding(.horizontal, 18)
        }
        .onAppear {
            animateParticles = true
        }
    }

    private var popupHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text(subtitle)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.68))
            }

            Spacer(minLength: 10)

            Text(speedText)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(0.10))
                )
        }
    }

    private var animatedStage: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.18, green: 0.22, blue: 0.42),
                            Color(red: 0.11, green: 0.13, blue: 0.28)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            ForEach(Array(vaporSizes.enumerated()), id: \.offset) { index, size in
                vaporCloud(index: index, size: size)
            }

            ForEach(Array(sparkleOffsets.enumerated()), id: \.offset) { index, offset in
                sparkle(index: index, offset: offset)
            }

            stageContent
                .padding(.horizontal, 18)
        }
        .frame(height: 288)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var stageContent: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.10))
                    .frame(width: 78, height: 78)

                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white)
            }

            Text(progressText)
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)

            ProgressView(value: progress, total: 1)
                .tint(.white)
                .progressViewStyle(.linear)
                .frame(maxWidth: 220)
                .scaleEffect(x: 1, y: 1.8, anchor: .center)

            Text("soranin")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.58))
        }
    }

    private func vaporCloud(index: Int, size: CGFloat) -> some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.34, green: 0.78, blue: 0.99).opacity(0.26),
                        Color(red: 0.69, green: 0.40, blue: 0.98).opacity(0.20)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: size, height: size)
            .blur(radius: 22)
            .offset(x: vaporXOffset(index: index), y: vaporYOffset(index: index))
            .scaleEffect(animateParticles ? 1.14 : 0.84)
            .animation(
                .easeInOut(duration: 2.8 + Double(index) * 0.34).repeatForever(autoreverses: true),
                value: animateParticles
            )
    }

    private func sparkle(index: Int, offset: CGSize) -> some View {
        Image(systemName: index.isMultiple(of: 2) ? "sparkles" : "star.fill")
            .font(.system(size: index.isMultiple(of: 2) ? 14 : 10, weight: .bold))
            .foregroundStyle(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.98),
                        Color(red: 0.52, green: 0.91, blue: 0.98)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .shadow(color: Color.white.opacity(0.40), radius: 10, x: 0, y: 0)
            .offset(x: sparkleXOffset(index: index, base: offset.width), y: sparkleYOffset(index: index, base: offset.height))
            .rotationEffect(.degrees(animateParticles ? (index.isMultiple(of: 2) ? 14 : -16) : (index.isMultiple(of: 2) ? -10 : 10)))
            .scaleEffect(animateParticles ? (index.isMultiple(of: 2) ? 1.18 : 0.86) : (index.isMultiple(of: 2) ? 0.84 : 1.14))
            .opacity(animateParticles ? 1 : 0.46)
            .animation(
                .easeInOut(duration: 1.7 + Double(index) * 0.18).repeatForever(autoreverses: true),
                value: animateParticles
            )
    }

    private func vaporXOffset(index: Int) -> CGFloat {
        let base = vaporOffsets[index].width
        let shift = animateParticles
            ? CGFloat(index.isMultiple(of: 2) ? 18 : -14)
            : CGFloat(index.isMultiple(of: 2) ? -12 : 12)
        return base + shift
    }

    private func vaporYOffset(index: Int) -> CGFloat {
        let base = vaporOffsets[index].height
        let shift = animateParticles
            ? CGFloat(index.isMultiple(of: 2) ? -18 : 16)
            : CGFloat(index.isMultiple(of: 2) ? 14 : -10)
        return base + shift
    }

    private func sparkleXOffset(index: Int, base: CGFloat) -> CGFloat {
        let shift = animateParticles
            ? CGFloat(index.isMultiple(of: 2) ? -10 : 12)
            : CGFloat(index.isMultiple(of: 2) ? 8 : -6)
        return base + shift
    }

    private func sparkleYOffset(index: Int, base: CGFloat) -> CGFloat {
        let shift = animateParticles
            ? CGFloat(index.isMultiple(of: 2) ? 10 : -12)
            : CGFloat(index.isMultiple(of: 2) ? -8 : 10)
        return base + shift
    }
}

private struct ExportPreviewPopup: View {
    let fileURL: URL
    let isBusy: Bool
    let autoSaveMessage: String
    let autoSavedToPhotos: Bool
    let onClose: () -> Void
    let onCreateThumbnail: () -> Void
    let onCreateTitles: () -> Void
    let onShare: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.56)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Convert Done")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)

                        Text(autoSavedToPhotos ? "Saved to Photos automatically. Create titles, share, or close this result." : "Photos auto-save failed. Create titles, share, or close this result.")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.66))
                    }

                    Spacer(minLength: 12)

                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 42, height: 42)
                            .background(
                                Circle()
                                    .fill(Color.white.opacity(0.08))
                            )
                    }
                    .buttonStyle(.plain)
                }

                ExportResultPlayer(fileURL: fileURL)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(9.0 / 16.0, contentMode: .fit)

                HStack(spacing: 8) {
                    Circle()
                        .fill(autoSavedToPhotos ? Color(red: 0.44, green: 0.94, blue: 0.73) : Color(red: 1.00, green: 0.55, blue: 0.55))
                        .frame(width: 8, height: 8)

                    Text(autoSaveMessage)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 2)

                Button(action: onCreateThumbnail) {
                    Label("Create Thumbnail", systemImage: "photo.badge.sparkles")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color(red: 0.77, green: 0.48, blue: 0.16).opacity(0.96))
                        )
                }
                .buttonStyle(.plain)
                .disabled(isBusy)

                HStack(spacing: 10) {
                    Button(action: onCreateTitles) {
                        Label("Create Titles", systemImage: "sparkles.rectangle.stack.fill")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(Color(red: 0.21, green: 0.54, blue: 0.97).opacity(0.92))
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy)

                    Button(action: onShare) {
                        Label("Share", systemImage: "square.and.arrow.up.fill")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(Color.white.opacity(0.10))
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy)
                }
            }
            .padding(20)
            .frame(maxWidth: 420)
            .background(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(Color(red: 0.10, green: 0.12, blue: 0.24))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .padding(.horizontal, 18)
        }
    }
}

private struct GeneratedThumbnailPopup: View {
    let imageURL: URL
    let headline: String
    let reason: String
    let saveMessage: String
    let savedToPhotos: Bool
    let isBusy: Bool
    let isKhmer: Bool
    let onClose: () -> Void
    let onSaveToPhotos: () -> Void
    let onCreateTitles: () -> Void
    let onCreateAgain: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.58)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(isKhmer ? "Thumbnail រួចរាល់" : "Thumbnail Ready")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)

                        Text(isKhmer
                             ? "Google Gemini បានជ្រើសរូបដែលទាក់ទាញពីវីដេអូទាំងមូល។ អ្នកអាចរក្សាទុក បង្កើតថែម ឬបន្តទៅ Create Titles បាន។"
                             : "Google Gemini chose a strong image from the full video. Save it, add more, or continue to Create Titles.")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.66))
                    }

                    Spacer(minLength: 12)

                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 42, height: 42)
                            .background(
                                Circle()
                                    .fill(Color.white.opacity(0.08))
                            )
                    }
                    .buttonStyle(.plain)
                }

                GeneratedThumbnailImageView(imageURL: imageURL)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(9.0 / 16.0, contentMode: .fit)

                if !headline.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(isKhmer ? "ចំណុចទាក់ទាញ" : "Headline")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.52))
                        Text(headline)
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !reason.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(isKhmer ? "ហេតុអ្វីរូបនេះ" : "Why This Image")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.52))
                        Text(reason)
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.82))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !saveMessage.isEmpty {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(savedToPhotos ? Color(red: 0.44, green: 0.94, blue: 0.73) : Color(red: 1.00, green: 0.55, blue: 0.55))
                            .frame(width: 8, height: 8)

                        Text(saveMessage)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.78))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 10) {
                    Button(action: onSaveToPhotos) {
                        Label(isKhmer ? "រក្សាទុកទៅ Photos" : "Save to Photos", systemImage: "square.and.arrow.down.fill")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(Color(red: 0.21, green: 0.54, blue: 0.97).opacity(0.92))
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy)

                    Button(action: onCreateAgain) {
                        Label(isKhmer ? "បង្កើតថែម" : "Add More", systemImage: "plus.circle.fill")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(Color(red: 0.20, green: 0.24, blue: 0.38).opacity(0.96))
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy)
                }

                Button(action: onCreateTitles) {
                    Label(isKhmer ? "បង្កើត Titles" : "Create Titles", systemImage: "sparkles.rectangle.stack.fill")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color(red: 0.18, green: 0.58, blue: 0.98),
                                            Color(red: 0.20, green: 0.82, blue: 0.77)
                                        ],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                        )
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
            }
            .padding(20)
            .frame(maxWidth: 430)
            .background(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(Color(red: 0.10, green: 0.12, blue: 0.24))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .padding(.horizontal, 18)
        }
    }
}

private struct GeneratedThumbnailImageView: View {
    let imageURL: URL

    var body: some View {
        Group {
            if let image = UIImage(contentsOfFile: imageURL.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .overlay(
                        VStack(spacing: 10) {
                            Image(systemName: "photo")
                                .font(.system(size: 34, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.84))
                            Text("Thumbnail preview unavailable")
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.white.opacity(0.72))
                        }
                    )
            }
        }
    }
}

private struct GeneratedTitlesPopup: View {
    let titlesText: String
    let onClose: () -> Void
    let onCopy: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.58)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Titles Ready")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)

                        Text("Copy this AI title with emoji and hashtags.")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.66))
                    }

                    Spacer(minLength: 12)

                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 42, height: 42)
                            .background(
                                Circle()
                                    .fill(Color.white.opacity(0.08))
                            )
                    }
                    .buttonStyle(.plain)
                }

                ScrollView(showsIndicators: false) {
                    Text(titlesText)
                        .font(.system(size: 17, weight: .medium, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(18)
                }
                .frame(minHeight: 220, maxHeight: 320)
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )

                Button(action: onCopy) {
                    Label("Copy", systemImage: "doc.on.doc.fill")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(Color(red: 0.21, green: 0.54, blue: 0.97).opacity(0.94))
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(20)
            .frame(maxWidth: 430)
            .background(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(Color(red: 0.10, green: 0.12, blue: 0.24))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .padding(.horizontal, 18)
        }
    }
}

private struct AIAutoDonePopup: View {
    let isKhmer: Bool
    let message: String
    let onClose: () -> Void

    private var titleText: String {
        isKhmer ? "AI បានធ្វើការរួចហើយ" : "AI Done Working"
    }

    private var subtitleText: String {
        isKhmer
            ? "flow ស្វ័យប្រវត្តិបានរួចហើយ។ អ្នកអាចបិទ popup នេះ ហើយចាប់ផ្តើមម្ដងទៀតបាន។"
            : "The auto flow finished. Close this popup when you are ready to start again."
    }

    private var closeLabel: String {
        isKhmer ? "បិទ" : "Close"
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.58)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.33, green: 0.60, blue: 0.99),
                                        Color(red: 0.24, green: 0.88, blue: 0.78)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 56, height: 56)

                        Image(systemName: "face.smiling.fill")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(.white)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(titleText)
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)

                        Text(subtitleText)
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.70))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Text(message)
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )

                Button(action: onClose) {
                    Label(closeLabel, systemImage: "xmark.circle.fill")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color(red: 0.25, green: 0.52, blue: 0.98),
                                            Color(red: 0.24, green: 0.88, blue: 0.78)
                                        ],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(22)
            .frame(maxWidth: 420)
            .background(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(Color(red: 0.10, green: 0.12, blue: 0.24))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .padding(.horizontal, 18)
        }
    }
}

private struct TitlesHistoryPopup: View {
    let entries: [GeneratedHistoryEntry]
    let trashedEntries: [GeneratedHistoryEntry]
    let isKhmer: Bool
    let thumbnailURLProvider: (GeneratedHistoryEntry) -> URL?
    let onClose: () -> Void
    let onCopyAll: () -> Void
    let onCopyEntry: (GeneratedHistoryEntry) -> Void
    let onMoveToTrash: (GeneratedHistoryEntry) -> Void
    let onRestore: (GeneratedHistoryEntry) -> Void

    var body: some View {
        HistoryEntriesPopup(
            popupTitle: isKhmer ? "ប្រវត្តិ Titles" : "Titles History",
            popupSubtitle: isKhmer ? "Titles ថ្មីនៅលើ ហើយចាស់ៗនៅខាងក្រោម។" : "Newest titles stay on top. Older titles stay below.",
            emptyMessage: isKhmer ? "មិនទាន់មាន titles នៅឡើយ។" : "No titles yet.",
            trashEmptyMessage: isKhmer ? "មិនទាន់មាន titles នៅក្នុងធុងសម្រាមទេ។" : "No trashed titles yet.",
            copyAllLabel: isKhmer ? "ចម្លង Titles ទាំងអស់" : "Copy All Titles",
            entries: entries,
            trashedEntries: trashedEntries,
            isKhmer: isKhmer,
            thumbnailURLProvider: thumbnailURLProvider,
            onClose: onClose,
            onCopyAll: onCopyAll,
            onCopyEntry: onCopyEntry,
            onMoveToTrash: onMoveToTrash,
            onRestore: onRestore
        )
    }
}

private struct PromptHistoryPopup: View {
    let entries: [GeneratedHistoryEntry]
    let trashedEntries: [GeneratedHistoryEntry]
    let isKhmer: Bool
    let thumbnailURLProvider: (GeneratedHistoryEntry) -> URL?
    let onClose: () -> Void
    let onCopyAll: () -> Void
    let onCopyEntry: (GeneratedHistoryEntry) -> Void
    let onMoveToTrash: (GeneratedHistoryEntry) -> Void
    let onRestore: (GeneratedHistoryEntry) -> Void

    var body: some View {
        HistoryEntriesPopup(
            popupTitle: isKhmer ? "ប្រវត្តិ Prompt" : "Prompt History",
            popupSubtitle: isKhmer ? "Prompt ថ្មីនៅលើ ហើយចាស់ៗនៅខាងក្រោម។" : "Newest prompts stay on top. Older prompts stay below.",
            emptyMessage: isKhmer ? "មិនទាន់មាន prompt នៅឡើយ។" : "No prompts yet.",
            trashEmptyMessage: isKhmer ? "មិនទាន់មាន prompt នៅក្នុងធុងសម្រាមទេ។" : "No trashed prompts yet.",
            copyAllLabel: isKhmer ? "ចម្លង Prompt ទាំងអស់" : "Copy All Prompts",
            entries: entries,
            trashedEntries: trashedEntries,
            isKhmer: isKhmer,
            thumbnailURLProvider: thumbnailURLProvider,
            onClose: onClose,
            onCopyAll: onCopyAll,
            onCopyEntry: onCopyEntry,
            onMoveToTrash: onMoveToTrash,
            onRestore: onRestore
        )
    }
}

private struct HistoryEntriesPopup: View {
    let popupTitle: String
    let popupSubtitle: String
    let emptyMessage: String
    let trashEmptyMessage: String
    let copyAllLabel: String
    let entries: [GeneratedHistoryEntry]
    let trashedEntries: [GeneratedHistoryEntry]
    let isKhmer: Bool
    let thumbnailURLProvider: (GeneratedHistoryEntry) -> URL?
    let onClose: () -> Void
    let onCopyAll: () -> Void
    let onCopyEntry: (GeneratedHistoryEntry) -> Void
    let onMoveToTrash: (GeneratedHistoryEntry) -> Void
    let onRestore: (GeneratedHistoryEntry) -> Void
    @State private var showingTrash = false

    private var visibleEntries: [GeneratedHistoryEntry] {
        showingTrash ? trashedEntries : entries
    }

    private func tr(_ english: String, _ khmer: String) -> String {
        isKhmer ? khmer : english
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.58)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                popupHeader
                historyList
                    .frame(minHeight: 240, maxHeight: 430)

                if !showingTrash {
                    Button(action: onCopyAll) {
                        Label(copyAllLabel, systemImage: "doc.on.doc.fill")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .fill(Color(red: 0.21, green: 0.54, blue: 0.97).opacity(0.94))
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(entries.isEmpty)
                    .opacity(entries.isEmpty ? 0.55 : 1)
                }
            }
            .padding(20)
            .frame(maxWidth: 450)
            .background(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(Color(red: 0.10, green: 0.12, blue: 0.24))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .padding(.horizontal, 18)
        }
    }

    private var popupHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(showingTrash ? tr("Trash", "ធុងសម្រាម") : popupTitle)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text(showingTrash ? trashEmptyMessage : popupSubtitle)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.66))
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showingTrash.toggle()
                }
            } label: {
                Image(systemName: showingTrash ? "tray.full.fill" : "trash.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private var historyList: some View {
        Group {
            if visibleEntries.isEmpty {
                Text(showingTrash ? trashEmptyMessage : emptyMessage)
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                List {
                    ForEach(Array(visibleEntries.enumerated()), id: \.element.id) { index, entry in
                        HistoryEntryRow(
                            entry: entry,
                            index: index,
                            isKhmer: isKhmer,
                            isTrashMode: showingTrash,
                            thumbnailURL: thumbnailURLProvider(entry),
                            onCopy: {
                                onCopyEntry(entry)
                            },
                            onRestore: {
                                onRestore(entry)
                            }
                        )
                        .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if !showingTrash {
                                Button(role: .destructive) {
                                    onMoveToTrash(entry)
                                } label: {
                                    Label(tr("Delete", "លុប"), systemImage: "trash.fill")
                                }
                            }
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            if showingTrash {
                                Button {
                                    onRestore(entry)
                                } label: {
                                    Label(tr("Restore", "ស្តារ"), systemImage: "arrow.uturn.left.circle.fill")
                                }
                                .tint(Color(red: 0.21, green: 0.54, blue: 0.97))
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
            }
        }
    }
}

private struct HistoryEntryRow: View {
    let entry: GeneratedHistoryEntry
    let index: Int
    let isKhmer: Bool
    let isTrashMode: Bool
    let thumbnailURL: URL?
    let onCopy: () -> Void
    let onRestore: () -> Void

    private func tr(_ english: String, _ khmer: String) -> String {
        isKhmer ? khmer : english
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            HistoryThumbnailView(fileURL: thumbnailURL)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(index == 0 && !isTrashMode ? tr("Newest", "ថ្មីបំផុត") : tr("Saved", "បានរក្សាទុក"))
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(index == 0 && !isTrashMode ? Color(red: 0.21, green: 0.54, blue: 0.97).opacity(0.94) : Color.white.opacity(0.10))
                        )

                    Spacer(minLength: 8)

                    Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.48))
                }

                Text(entry.sourceName)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.64))
                    .lineLimit(1)

                Text(entry.text)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(6)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 10) {
                    Button(action: onCopy) {
                        Label(tr("Copy", "ចម្លង"), systemImage: "doc.on.doc.fill")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .fill(Color(red: 0.21, green: 0.54, blue: 0.97).opacity(0.86))
                            )
                    }
                    .buttonStyle(.plain)

                    if isTrashMode {
                        Button(action: onRestore) {
                            Label(tr("Restore", "ស្តារ"), systemImage: "arrow.uturn.left.circle.fill")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    Capsule()
                                        .fill(Color.white.opacity(0.10))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct HistoryThumbnailView: View {
    let fileURL: URL?
    private let thumbnailWidth: CGFloat = 92
    private let thumbnailAspectRatio: CGFloat = 9.0 / 16.0

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.22))

            if let fileURL, let image = UIImage(contentsOfFile: fileURL.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Image(systemName: "photo.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.58))
            }
        }
        .frame(width: thumbnailWidth, height: thumbnailWidth / thumbnailAspectRatio)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.92), lineWidth: 1.4)
        )
    }
}

private struct PromptSourceUploadBox: View {
    let fileURL: URL?
    let previewImageURL: URL?
    let isKhmer: Bool
    let fillsWidth: Bool
    let onAdd: () -> Void
    let onPreviewTap: () -> Void

    private func tr(_ english: String, _ khmer: String) -> String {
        isKhmer ? khmer : english
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.06))

            if let fileURL {
                Button(action: onPreviewTap) {
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if let previewImageURL, let image = UIImage(contentsOfFile: previewImageURL.path) {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                VideoThumbnailView(fileURL: fileURL)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .stroke(Color.white.opacity(0.92), lineWidth: 1.6)
                        )

                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(8)
                    }
                }
                .buttonStyle(.plain)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "video.badge.plus")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.72))

                    Text(tr("Add Video", "ដាក់វីដេអូ"))
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.66))
                }
            }

            Button(action: onAdd) {
                HStack(spacing: 6) {
                    Image(systemName: "video.badge.plus")
                        .font(.system(size: 12, weight: .bold))

                    Text(tr(fileURL == nil ? "Add" : "Change", fileURL == nil ? "ដាក់" : "ប្តូរ"))
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    Capsule()
                        .fill(Color.black.opacity(0.50))
                )
            }
            .buttonStyle(.plain)
            .padding(8)
        }
        .frame(maxWidth: fillsWidth ? .infinity : 148)
        .frame(height: fillsWidth ? 232 : 228)
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct PromptFramePickerPopup: View {
    let fileURL: URL
    let isWorking: Bool
    let isKhmer: Bool
    @Binding var zoomScale: Double
    @Binding var panOffset: CGSize
    let onClose: () -> Void
    let onUseFrame: (Double) -> Void

    private func tr(_ english: String, _ khmer: String) -> String {
        isKhmer ? khmer : english
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.60)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tr("Pick Prompt Frame", "ជ្រើសរើស Frame សម្រាប់ Prompt"))
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)

                        Text(
                            tr(
                                "Play or scrub smoothly, then use one frame for Titles History and Prompt History.",
                                "អាច Play ឬអូស slider ឲ្យរលូន បន្ទាប់មកយក frame មួយសម្រាប់ Titles History និង Prompt History។"
                            )
                        )
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.68))
                    }

                    Spacer(minLength: 12)

                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 42, height: 42)
                            .background(
                                Circle()
                                    .fill(Color.white.opacity(0.08))
                            )
                    }
                    .buttonStyle(.plain)
                }

                LatestVideoPreview(
                    fileURL: fileURL,
                    isWorking: isWorking,
                    zoomScale: $zoomScale,
                    panOffset: $panOffset,
                    actionLabel: tr("Use This Frame", "យក Frame នេះ"),
                    actionSystemImage: "photo.badge.checkmark",
                    onCutPhoto: onUseFrame
                )
            }
            .padding(20)
            .frame(maxWidth: min(UIScreen.main.bounds.width - 24, 540))
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Color(red: 0.11, green: 0.12, blue: 0.25).opacity(0.96))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .padding(.horizontal, 12)
        }
    }
}

private struct GeneratedPromptPopup: View {
    let promptText: String
    let isKhmer: Bool
    let onClose: () -> Void
    let onCopy: () -> Void

    private func tr(_ english: String, _ khmer: String) -> String {
        isKhmer ? khmer : english
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.58)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tr("Sora Prompt Ready", "Sora Prompt បានរួចរាល់"))
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)

                        Text(tr("This includes a clear video description first, then a Sora prompt.", "នេះមានការពិពណ៌នាវីដេអូច្បាស់ជាមុនសិន បន្ទាប់មកជា Sora prompt។"))
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.66))
                    }

                    Spacer(minLength: 12)

                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 42, height: 42)
                            .background(
                                Circle()
                                    .fill(Color.white.opacity(0.08))
                            )
                    }
                    .buttonStyle(.plain)
                }

                ScrollView(showsIndicators: false) {
                    Text(promptText)
                        .font(.system(size: 17, weight: .medium, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(18)
                }
                .frame(minHeight: 220, maxHeight: 360)
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )

                Button(action: onCopy) {
                    Label(tr("Copy", "ចម្លង"), systemImage: "doc.on.doc.fill")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(Color(red: 0.21, green: 0.54, blue: 0.97).opacity(0.94))
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(20)
            .frame(maxWidth: 430)
            .background(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(Color(red: 0.10, green: 0.12, blue: 0.24))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .padding(.horizontal, 18)
        }
    }
}

private enum AIChatMediaQuickAction: String, CaseIterable, Identifiable {
    case describe
    case createPrompt
    case createTitles
    case createThumbnail
    case swapEditPrompt

    var id: String { rawValue }
}

private struct AIChatPopup: View {
    @ObservedObject var model: SoraDownloadViewModel
    let isKhmer: Bool
    let onClose: () -> Void

    @StateObject private var voiceController = AIChatVoiceController()
    @State private var draft = ""
    @State private var keyboardHeight: CGFloat = 0
    @State private var composerTextHeight: CGFloat = 24
    @State private var voiceDraftPrefix = ""
    @State private var isPreparingVoiceInput = false
    @State private var pendingVoiceAutoSend = false
    @State private var lastSpokenAssistantMessageID: UUID?
    @State private var playbackSpeedByMessageID: [UUID: AIChatSpeechPlaybackSpeed] = [:]
    @State private var isShowingMediaPicker = false
    @FocusState private var isComposerFocused: Bool

    private func tr(_ english: String, _ khmer: String) -> String {
        isKhmer ? khmer : english
    }

    private var canSend: Bool {
        (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.aiChatDraftAttachments.isEmpty) && !model.isSendingAIChat
    }

    private var activeStatusText: String {
        let voiceError = voiceController.voiceErrorText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !voiceError.isEmpty {
            return voiceError
        }
        if voiceController.isTranscribing {
            return tr(
                "Turning your voice into text...",
                "កំពុងបម្លែងសំឡេងទៅអក្សរ..."
            )
        }
        if voiceController.isRecording {
            return tr(
                "Listening... tap the mic again to stop.",
                "កំពុងស្តាប់... ចុច mic ម្តងទៀតដើម្បីបញ្ឈប់។"
            )
        }
        if isPreparingVoiceInput {
            return tr(
                "Preparing microphone...",
                "កំពុងរៀបចំមីក្រូហ្វូន..."
            )
        }
        if voiceController.isSpeaking {
            return tr("AI is speaking...", "AI កំពុងនិយាយ...")
        }
        let trimmed = model.aiChatStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        if voiceController.isSpeechOutputEnabled {
            return tr("Voice replies are on.", "សំឡេងឆ្លើយតបបានបើកហើយ។")
        }
        return tr("AI chat is ready.", "AI chat រួចរាល់ហើយ។")
    }

    private func dismissComposerFocus() {
        isComposerFocused = false
        keyboardHeight = 0
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func stopVoiceSession(resetTranscript: Bool = false) {
        isPreparingVoiceInput = false
        pendingVoiceAutoSend = false
        voiceDraftPrefix = ""
        voiceController.stopAll(resetTranscript: resetTranscript)
    }

    private func closeAIChatPopup() {
        stopVoiceSession(resetTranscript: true)
        dismissComposerFocus()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            onClose()
        }
    }

    private func mergedVoiceDraft(prefix: String, transcript: String) -> String {
        let trimmedPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedPrefix.isEmpty {
            return trimmedTranscript
        }
        if trimmedTranscript.isEmpty {
            return trimmedPrefix
        }

        return trimmedPrefix + " " + trimmedTranscript
    }

    private func playbackSpeed(for messageID: UUID) -> AIChatSpeechPlaybackSpeed {
        playbackSpeedByMessageID[messageID] ?? .fast
    }

    private func setPlaybackSpeed(_ speed: AIChatSpeechPlaybackSpeed, for message: AIChatMessage) {
        playbackSpeedByMessageID[message.id] = speed

        guard voiceController.speakingMessageID == message.id, voiceController.isSpeaking else {
            return
        }

        voiceController.clearVoiceError()
        voiceController.speak(
            message.content,
            isKhmer: isKhmer,
            messageID: message.id,
            obeyEnabledToggle: false,
            playbackSpeed: speed
        )
    }

    private func handleVoiceButtonTap() {
        voiceController.clearVoiceError()

        if voiceController.isRecording {
            guard !voiceController.isTranscribing else { return }
            isPreparingVoiceInput = false
            Task {
                _ = await voiceController.finishRecording()
            }
            return
        }

        guard !isPreparingVoiceInput else { return }

        voiceController.stopSpeaking()
        dismissComposerFocus()
        voiceDraftPrefix = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingVoiceAutoSend = voiceController.isSpeechOutputEnabled
        isPreparingVoiceInput = true

        Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            let started = await voiceController.startRecording(isKhmer: isKhmer)
            isPreparingVoiceInput = false
            if !started {
                pendingVoiceAutoSend = false
                voiceDraftPrefix = ""
            }
        }
    }

    private func handleVoiceReplyButtonTap() {
        voiceController.clearVoiceError()
        if voiceController.isSpeaking {
            voiceController.stopSpeaking()
            return
        }

        let nextValue = !voiceController.isSpeechOutputEnabled
        voiceController.setSpeechOutputEnabled(nextValue)
        if nextValue {
            lastSpokenAssistantMessageID = model.aiChatMessages.last(where: { $0.role == "assistant" })?.id
        }
    }

    private func sendDraft() {
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty || !model.aiChatDraftAttachments.isEmpty else { return }
        if voiceController.isRecording {
            isPreparingVoiceInput = false
            pendingVoiceAutoSend = false
            _ = voiceController.stopRecording()
        }
        voiceDraftPrefix = ""
        voiceController.clearVoiceError()
        voiceController.stopSpeaking()
        draft = ""
        dismissComposerFocus()
        model.submitAIChatMessage(message)
    }

    private func sendMediaQuickAction(_ action: AIChatMediaQuickAction) {
        guard !model.aiChatDraftAttachments.isEmpty else { return }
        voiceController.clearVoiceError()
        voiceController.stopSpeaking()
        dismissComposerFocus()
        draft = ""

        if action == .createThumbnail {
            Task {
                await model.createThumbnailForAIChatDraftVideo()
            }
            return
        }

        let message: String
        switch action {
        case .describe:
            message = """
            Analyze the attached media carefully. If there is a video, use the full video from start to finish, not just one frame. Describe the real subject, action, setting, mood, camera view, and any clear spoken words or audio cues that are actually present.
            """
        case .createPrompt:
            message = """
            Analyze the attached media carefully. If there is a video, use the full video from start to finish. Write 1 polished English Sora prompt based on the real media. Then add a short Khmer explanation below it.

            Format exactly like this:
            Prompt 1:
            [English prompt]
            Khmer:
            [Short Khmer explanation]
            """
        case .createTitles:
            message = """
            Analyze the attached media carefully. If there is a video, use the full video from start to finish. Create exactly 5 fresh English Facebook or Reels title ideas with emoji and 5 hashtags that match the real content. Make sure all 5 ideas are complete and not cut off.
            """
        case .createThumbnail:
            message = ""
        case .swapEditPrompt:
            message = """
            Analyze the attached media carefully. Write 1 strong English swap or edit prompt based on this media for image editing, face swap, style change, or creative transformation. Then add a short Khmer explanation below it.

            Format exactly like this:
            Prompt 1:
            [English edit prompt]
            Khmer:
            [Short Khmer explanation]
            """
        }

        model.submitAIChatMessage(message)
    }

    var body: some View {
        GeometryReader { proxy in
            let isPhoneLayout = proxy.size.width <= 500
            let keyboardLift = max(keyboardHeight - proxy.safeAreaInsets.bottom, 0)
            let isKeyboardOpen = keyboardLift > 0
            let topPadding = isPhoneLayout
                ? max(proxy.safeAreaInsets.top * 0.14, 6.0)
                : proxy.safeAreaInsets.top + 18.0
            let maxComposerHeight = isPhoneLayout
                ? min(max(120.0, proxy.size.height * 0.28), 260.0)
                : 260.0

            ZStack(alignment: .top) {
                LinearGradient(
                    colors: [
                        Color(red: 0.04, green: 0.06, blue: 0.14),
                        Color(red: 0.09, green: 0.11, blue: 0.24)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    dismissComposerFocus()
                }

                VStack(alignment: .leading, spacing: isPhoneLayout ? 6 : 16) {
                    header(isPhoneLayout: isPhoneLayout, isKeyboardOpen: isComposerFocused)
                    providerStatusPanel(isPhoneLayout: isPhoneLayout, isKeyboardOpen: isComposerFocused)
                    if !(isPhoneLayout && isComposerFocused) {
                        sessionStrip(isPhoneLayout: isPhoneLayout)
                    }
                    messagesPanel(isKeyboardOpen: isComposerFocused, isPhoneLayout: isPhoneLayout)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .frame(maxWidth: isPhoneLayout ? .infinity : 820, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, isPhoneLayout ? 14 : 24)
                .padding(.top, topPadding)
                .padding(.bottom, isPhoneLayout ? 22 : 18)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                composerPanel(
                    isPhoneLayout: isPhoneLayout,
                    isKeyboardOpen: isKeyboardOpen,
                    maxComposerHeight: maxComposerHeight
                )
                .padding(.horizontal, isPhoneLayout ? 16 : 24)
                .padding(.top, isPhoneLayout ? 26 : 6)
                .padding(.bottom, isPhoneLayout ? max(proxy.safeAreaInsets.bottom - 18, 4) : max(proxy.safeAreaInsets.bottom, 6))
                .background(
                    LinearGradient(
                        colors: [
                            Color(red: 0.07, green: 0.09, blue: 0.20).opacity(0.96),
                            Color(red: 0.09, green: 0.11, blue: 0.24).opacity(0.98)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(Color.white.opacity(0.06))
                            .frame(height: 1)
                    }
                )
            }
            .animation(.easeOut(duration: 0.20), value: keyboardHeight)
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notification in
                guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
                    return
                }
                keyboardHeight = frame.height
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboardHeight = 0
            }
            .onAppear {
                lastSpokenAssistantMessageID = model.aiChatMessages.last(where: { $0.role == "assistant" })?.id
            }
            .onDisappear {
                stopVoiceSession(resetTranscript: true)
            }
            .onChange(of: voiceController.recognizedText) { _, newValue in
                draft = mergedVoiceDraft(prefix: voiceDraftPrefix, transcript: newValue)
            }
            .onChange(of: voiceController.isRecording) { oldValue, newValue in
                guard oldValue, !newValue else { return }
                isPreparingVoiceInput = false
                let mergedDraft = mergedVoiceDraft(prefix: voiceDraftPrefix, transcript: voiceController.recognizedText)
                draft = mergedDraft
                voiceDraftPrefix = ""
                let shouldSend = pendingVoiceAutoSend && !mergedDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                pendingVoiceAutoSend = false
                if shouldSend {
                    sendDraft()
                }
            }
            .onChange(of: model.aiChatMessages) { _, messages in
                guard voiceController.isSpeechOutputEnabled,
                      let lastAssistantMessage = messages.last(where: { $0.role == "assistant" }),
                      lastAssistantMessage.id != lastSpokenAssistantMessageID else {
                    return
                }
                lastSpokenAssistantMessageID = lastAssistantMessage.id
                voiceController.speak(
                    lastAssistantMessage.content,
                    isKhmer: isKhmer,
                    messageID: lastAssistantMessage.id,
                    playbackSpeed: playbackSpeed(for: lastAssistantMessage.id)
                )
            }
            .sheet(isPresented: $isShowingMediaPicker) {
                AIChatMediaPicker(selectionLimit: max(1, 8 - model.aiChatDraftAttachments.count)) { urls in
                    model.addAIChatAttachments(urls)
                }
            }
        }
    }

    private func header(isPhoneLayout: Bool, isKeyboardOpen: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("AI Chat", "AI Chat"))
                    .font(.system(size: isPhoneLayout ? 16 : 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                if !(isPhoneLayout && isKeyboardOpen) {
                    Text(model.currentAIChatSessionLabel)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.92))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(0.08))
                        )
                        .padding(.top, 1)

                    if !isPhoneLayout {
                        Text(tr(
                            "Use the full phone width and switch AI here, just like the desktop flow.",
                            "ប្រើទំហំទូរស័ព្ទពេញ ហើយប្ដូរ AI នៅទីនេះ ដូច flow លើ desktop។"
                        ))
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.66))
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Spacer(minLength: 8)

            Button {
                dismissComposerFocus()
                model.startNewAIChatSession()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)

            Button {
                closeAIChatPopup()
            } label: {
                Label(tr("Close", "បិទ"), systemImage: "xmark.circle.fill")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, isPhoneLayout ? 10 : 14)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
        }
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded {
                dismissComposerFocus()
            }
        )
    }

    private func providerStatusPanel(isPhoneLayout: Bool, isKeyboardOpen: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    AIChatProviderChip(
                        title: "Gemini",
                        isSelected: model.selectedAIProvider == .googleGemini,
                        isConfigured: model.hasConfiguredGoogleAIKey
                    ) {
                        dismissComposerFocus()
                        model.setSelectedAIProvider(.googleGemini)
                    }

                    AIChatProviderChip(
                        title: "OpenAI",
                        isSelected: model.selectedAIProvider == .openAI,
                        isConfigured: model.hasConfiguredOpenAIKey
                    ) {
                        dismissComposerFocus()
                        model.setSelectedAIProvider(.openAI)
                    }

                    AIModelMenuButton(
                        selectedModelID: model.selectedModelID(for: model.selectedAIProvider),
                        options: model.modelOptions(for: model.selectedAIProvider),
                        isRefreshing: model.selectedAIProvider == .googleGemini ? model.isRefreshingGoogleModels : model.isRefreshingOpenAIModels,
                        isKhmer: isKhmer
                    ) { modelID in
                        dismissComposerFocus()
                        model.setSelectedModel(modelID, for: model.selectedAIProvider)
                    }

                    voiceReplyButton
                }
                .padding(.vertical, 1)
            }

            if !(isPhoneLayout && isKeyboardOpen) {
                HStack(spacing: 8) {
                    HStack(spacing: 7) {
                        Image(systemName: model.isSendingAIChat ? "sparkles" : "message.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                        Text(activeStatusText)
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )

                    if model.isSendingAIChat {
                        ProgressView()
                            .tint(.white)
                            .padding(.horizontal, 8)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded {
                dismissComposerFocus()
            }
        )
    }

    private func sessionStrip(isPhoneLayout: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(tr("Chats", "Chats"))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Spacer(minLength: 8)

                if !model.aiChatMessages.isEmpty {
                    Button {
                        dismissComposerFocus()
                        model.copyAIChatConversationToClipboard()
                    } label: {
                        Label(tr("Copy All", "ចម្លងទាំងអស់"), systemImage: "doc.on.doc")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                Capsule()
                                    .fill(Color(red: 0.19, green: 0.53, blue: 0.96).opacity(0.88))
                            )
                    }
                    .buttonStyle(.plain)
                }

                if model.currentAIChatSession != nil {
                    Button {
                        dismissComposerFocus()
                        model.deleteCurrentAIChatSession()
                    } label: {
                        Label(tr("Delete", "លុប"), systemImage: "trash.fill")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                Capsule()
                                    .fill(Color.white.opacity(0.08))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.aiChatSessions) { session in
                        AIChatSessionChip(
                            session: session,
                            isSelected: session.id == model.currentAIChatSessionID,
                            onTap: {
                                dismissComposerFocus()
                                model.loadAIChatSession(session)
                            }
                        )
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded {
                dismissComposerFocus()
            }
        )
    }

    private func messagesPanel(isKeyboardOpen: Bool, isPhoneLayout: Bool) -> some View {
        ScrollViewReader { proxy in
            GeometryReader { geometry in
                ScrollView(showsIndicators: false) {
                    messagesScrollContent(panelHeight: geometry.size.height)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .frame(minHeight: isPhoneLayout ? 120 : 260, maxHeight: .infinity)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .onAppear {
                proxy.scrollTo("ai-chat-bottom", anchor: .bottom)
            }
            .onChange(of: model.aiChatMessages.count) { _ in
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo("ai-chat-bottom", anchor: .bottom)
                }
            }
            .onChange(of: isComposerFocused) { _, focused in
                guard focused else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo("ai-chat-bottom", anchor: .bottom)
                    }
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
                TapGesture().onEnded {
                    dismissComposerFocus()
                }
            )
        }
    }

    @ViewBuilder
    private func messagesScrollContent(panelHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.aiChatMessages.isEmpty {
                emptyMessagesCard
            } else {
                messageBubbleList
            }

            messagesBottomAnchor
        }
        .frame(maxWidth: .infinity, minHeight: max(panelHeight - 4, 0), alignment: .bottomLeading)
        .padding(.vertical, 2)
    }

    private var emptyMessagesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tr("Start a new AI thread", "ចាប់ផ្តើម AI thread ថ្មី"))
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text(tr(
                "Ask about prompts, titles, workflows, bugs, or anything you need help with.",
                "អ្នកអាចសួរអំពី prompt, titles, workflow, bug ឬអ្វីៗដែលអ្នកត្រូវការជំនួយ។"
            ))
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.68))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }

    @ViewBuilder
    private var messageBubbleList: some View {
        ForEach(model.aiChatMessages) { message in
            let promptBlocks = AIChatPromptExtractor.extractPromptBlocks(from: message.content)
            AIChatMessageBubble(
                message: message,
                isKhmer: isKhmer,
                isCurrentlySpeaking: voiceController.speakingMessageID == message.id && voiceController.isSpeaking,
                selectedPlaybackSpeed: playbackSpeed(for: message.id),
                promptBlocks: promptBlocks,
                attachments: message.attachments,
                onCopy: {
                    model.copyAIChatMessageToClipboard(message)
                },
                onCopyPrompt: { prompt in
                    model.copyAIChatPromptToClipboard(prompt)
                },
                onSelectPlaybackSpeed: { speed in
                    setPlaybackSpeed(speed, for: message)
                },
                onTogglePlayback: {
                    if voiceController.speakingMessageID == message.id && voiceController.isSpeaking {
                        voiceController.stopSpeaking()
                    } else {
                        voiceController.clearVoiceError()
                        voiceController.speak(
                            message.content,
                            isKhmer: isKhmer,
                            messageID: message.id,
                            obeyEnabledToggle: false,
                            playbackSpeed: playbackSpeed(for: message.id)
                        )
                    }
                }
            )
            .id(message.id)
        }
    }

    private var messagesBottomAnchor: some View {
        Color.clear
            .frame(height: 1)
            .id("ai-chat-bottom")
    }

    private func composerPanel(isPhoneLayout: Bool, isKeyboardOpen: Bool, maxComposerHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !isPhoneLayout && !isKeyboardOpen {
                HStack(spacing: 10) {
                    composerAccessoryButton(systemName: "plus.circle.fill", foreground: Color(red: 0.24, green: 0.70, blue: 0.98)) {
                        model.startNewAIChatSession()
                    }

                    Text(tr(
                        "New chat and send from here, like the Mac app.",
                        "បង្កើត chat ថ្មី ហើយផ្ញើពីទីនេះ ដូច mac app។"
                    ))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.62))
                    .lineLimit(2)

                    Spacer(minLength: 10)
                }
            }

            mediaComposerPanel(isPhoneLayout: isPhoneLayout, isKeyboardOpen: isKeyboardOpen)

            HStack(alignment: .bottom, spacing: 12) {
                composerInputField(isPhoneLayout: isPhoneLayout, maxVisibleHeight: maxComposerHeight)
                voiceInputButton
                composerSendButton
            }
        }
        .padding(.top, isPhoneLayout ? 0 : 4)
        .layoutPriority(2)
    }

    private var composerPlaceholder: String {
        tr(
            "Ask about prompts, titles, media edit ideas, or workflow...",
            "សួរអំពី prompt, titles, media edit ideas ឬ workflow..."
        )
    }

    @ViewBuilder
    private func mediaComposerPanel(isPhoneLayout: Bool, isKeyboardOpen: Bool) -> some View {
        let shouldCollapseMediaPanel = isPhoneLayout && isKeyboardOpen

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    dismissComposerFocus()
                    isShowingMediaPicker = true
                } label: {
                    Label(
                        tr("Add Media", "បន្ថែម Media"),
                        systemImage: "photo.on.rectangle.angled"
                    )
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        Capsule()
                            .fill(Color(red: 0.19, green: 0.53, blue: 0.96).opacity(0.88))
                    )
                }
                .buttonStyle(.plain)

                if !model.aiChatDraftAttachments.isEmpty {
                    Button {
                        dismissComposerFocus()
                        model.clearAIChatAttachments()
                    } label: {
                        Label(tr("Clear", "សម្អាត"), systemImage: "xmark.circle.fill")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(
                                Capsule()
                                    .fill(Color.white.opacity(0.08))
                            )
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 8)

                Text(
                    model.aiChatDraftAttachments.isEmpty
                        ? tr("Upload image or video like Mac chat.", "អាច upload image ឬ video ដូច Mac chat។")
                        : tr("\(model.aiChatDraftAttachments.count) media ready", "media \(model.aiChatDraftAttachments.count) រួចរាល់")
                )
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.60))
                .lineLimit(2)
            }

            if shouldCollapseMediaPanel {
                if !model.aiChatDraftAttachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(model.aiChatDraftAttachments) { attachment in
                                AIChatComposerAttachmentChip(
                                    attachment: attachment,
                                    onRemove: {
                                        model.removeAIChatAttachment(attachment)
                                    }
                                )
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            } else if model.aiChatDraftAttachments.isEmpty {
                Button {
                    dismissComposerFocus()
                    isShowingMediaPicker = true
                } label: {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: "video.badge.plus")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(Color(red: 0.38, green: 0.86, blue: 0.98))
                            .frame(width: 38, height: 38)
                            .background(
                                Circle()
                                    .fill(Color.white.opacity(0.06))
                            )

                        VStack(alignment: .leading, spacing: 3) {
                            Text(tr("Upload video or image", "Upload video ឬ image"))
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                            Text(tr(
                                "Ask AI to read the full video, describe it, create prompts, titles, or swap/edit ideas.",
                                "អាចអោយ AI អានវីដេអូទាំងមូល ពិពណ៌នា បង្កើត prompt, titles ឬ swap/edit ideas។"
                            ))
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.62))
                            .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [7, 6]))
                    )
                }
                .buttonStyle(.plain)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.aiChatDraftAttachments) { attachment in
                            AIChatComposerAttachmentChip(
                                attachment: attachment,
                                onRemove: {
                                    model.removeAIChatAttachment(attachment)
                                }
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        mediaQuickActionButton(.describe)
                        mediaQuickActionButton(.createPrompt)
                        mediaQuickActionButton(.createTitles)
                        mediaQuickActionButton(.createThumbnail)
                        mediaQuickActionButton(.swapEditPrompt)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func composerInputField(isPhoneLayout: Bool, maxVisibleHeight: CGFloat) -> some View {
        let clampedTextHeight = min(max(composerTextHeight, isPhoneLayout ? 24 : 28), maxVisibleHeight)

        return HStack(spacing: 10) {
            ZStack(alignment: .leading) {
                if draft.isEmpty {
                    Text(composerPlaceholder)
                        .font(.system(size: isPhoneLayout ? 17 : 21, weight: .regular, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.38))
                        .lineLimit(1)
                        .padding(.leading, 2)
                        .padding(.bottom, 2)
                        .allowsHitTesting(false)
                }

                AIChatComposerTextView(
                    text: $draft,
                    measuredHeight: $composerTextHeight,
                    isFocused: Binding(
                        get: { isComposerFocused },
                        set: { isComposerFocused = $0 }
                    ),
                    fontSize: isPhoneLayout ? 17 : 21,
                    maxVisibleHeight: maxVisibleHeight
                )
                .frame(height: clampedTextHeight)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, isPhoneLayout ? 9 : 12)
        .frame(
            height: min(
                maxVisibleHeight + (isPhoneLayout ? 18 : 24),
                max(isPhoneLayout ? 50 : 74, clampedTextHeight + (isPhoneLayout ? 18 : 24))
            ),
            alignment: .top
        )
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.white.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var composerSendButton: some View {
        Button(action: sendDraft) {
            Group {
                if model.isSendingAIChat {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(0.9)
                } else if canSend {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 18, weight: .bold))
                } else {
                    Image(systemName: "hand.thumbsup.fill")
                        .font(.system(size: 18, weight: .bold))
                }
            }
            .foregroundStyle(.white)
            .frame(width: 46, height: 46)
            .background(
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.20, green: 0.60, blue: 0.98),
                                Color(red: 0.14, green: 0.82, blue: 0.74)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(model.isSendingAIChat)
        .opacity(model.isSendingAIChat ? 0.8 : 1)
    }

    private var voiceInputButton: some View {
        Button(action: handleVoiceButtonTap) {
            Image(systemName: voiceController.isRecording ? "stop.fill" : "mic.fill")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(
                    Circle()
                        .fill(
                            voiceController.isRecording
                                ? Color(red: 0.92, green: 0.29, blue: 0.32)
                                : Color.white.opacity(0.12)
                        )
                )
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(voiceController.isRecording ? 0.32 : 0.08), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(isPreparingVoiceInput || voiceController.isTranscribing || (model.isSendingAIChat && !voiceController.isRecording))
        .opacity((isPreparingVoiceInput || voiceController.isTranscribing || (model.isSendingAIChat && !voiceController.isRecording)) ? 0.75 : 1)
    }

    private var voiceReplyButton: some View {
        Button(action: handleVoiceReplyButtonTap) {
            HStack(spacing: 7) {
                Image(systemName: voiceReplyButtonIcon)
                    .font(.system(size: 11, weight: .bold))

                Text(voiceReplyButtonTitle)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(
                Capsule()
                    .fill(
                        voiceController.isSpeechOutputEnabled
                            ? Color(red: 0.17, green: 0.54, blue: 0.95).opacity(0.96)
                            : Color.white.opacity(0.08)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var voiceReplyButtonIcon: String {
        if voiceController.isSpeaking {
            return "speaker.slash.fill"
        }
        return voiceController.isSpeechOutputEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill"
    }

    private var voiceReplyButtonTitle: String {
        if voiceController.isSpeaking {
            return tr("Stop Voice", "បិទសំឡេង")
        }
        return voiceController.isSpeechOutputEnabled ? tr("Auto Voice On", "អានស្វ័យប្រវត្តិបើក") : tr("Auto Voice Off", "អានស្វ័យប្រវត្តិបិទ")
    }

    private func mediaQuickActionButton(_ action: AIChatMediaQuickAction) -> some View {
        let title: String
        let icon: String

        switch action {
        case .describe:
            title = tr("Describe", "ពិពណ៌នា")
            icon = "text.quote"
        case .createPrompt:
            title = tr("Create Prompt", "បង្កើត Prompt")
            icon = "sparkles.rectangle.stack"
        case .createTitles:
            title = tr("Create Titles", "បង្កើត Titles")
            icon = "text.badge.star"
        case .createThumbnail:
            title = tr("Create Thumbnail", "បង្កើត Thumbnail")
            icon = "photo.badge.sparkles"
        case .swapEditPrompt:
            title = tr("Swap/Edit", "Swap/Edit")
            icon = "arrow.triangle.2.circlepath"
        }

        return Button {
            sendMediaQuickAction(action)
        } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(0.08))
                )
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func composerAccessoryButton(systemName: String, foreground: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
    }
}

private struct AIChatComposerTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var measuredHeight: CGFloat
    @Binding var isFocused: Bool
    let fontSize: CGFloat
    let maxVisibleHeight: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.textColor = .white
        textView.font = UIFont.systemFont(ofSize: fontSize, weight: .regular)
        textView.textContainerInset = UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.isScrollEnabled = false
        textView.showsVerticalScrollIndicator = false
        textView.showsHorizontalScrollIndicator = false
        textView.alwaysBounceVertical = false
        textView.alwaysBounceHorizontal = false
        textView.keyboardDismissMode = .interactive
        textView.returnKeyType = .default
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.clipsToBounds = true
        textView.textContainer.maximumNumberOfLines = 0
        textView.textContainer.widthTracksTextView = true
        textView.textContainer.lineBreakMode = .byWordWrapping
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }

        if uiView.font?.pointSize != fontSize {
            uiView.font = UIFont.systemFont(ofSize: fontSize, weight: .regular)
        }

        DispatchQueue.main.async {
            let newHeight = context.coordinator.measuredHeight(for: uiView)
            if abs(measuredHeight - newHeight) > 0.5 {
                measuredHeight = newHeight
            }
            let shouldScroll = newHeight > maxVisibleHeight - 0.5
            if uiView.isScrollEnabled != shouldScroll {
                uiView.isScrollEnabled = shouldScroll
            }
        }

        if isFocused, !uiView.isFirstResponder {
            uiView.becomeFirstResponder()
        } else if !isFocused, uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        private let parent: AIChatComposerTextView

        init(_ parent: AIChatComposerTextView) {
            self.parent = parent
        }

        func measuredHeight(for textView: UITextView) -> CGFloat {
            let fittingWidth = max(textView.bounds.width, 40)
            let fittingSize = CGSize(width: fittingWidth, height: .greatestFiniteMagnitude)
            let size = textView.sizeThatFits(fittingSize)
            return ceil(max(parent.fontSize + 6, size.height))
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text ?? ""
            let newHeight = measuredHeight(for: textView)
            if abs(parent.measuredHeight - newHeight) > 0.5 {
                parent.measuredHeight = newHeight
            }
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.isFocused = true
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.isFocused = false
        }
    }
}

private struct AIChatSelectableTextView: UIViewRepresentable {
    let text: String
    let fontSize: CGFloat

    func makeUIView(context: Context) -> SelectableTextView {
        let textView = SelectableTextView()
        textView.backgroundColor = .clear
        textView.textColor = .white
        textView.font = UIFont.systemFont(ofSize: fontSize, weight: .medium)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.showsVerticalScrollIndicator = false
        textView.showsHorizontalScrollIndicator = false
        textView.alwaysBounceVertical = false
        textView.alwaysBounceHorizontal = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.maximumNumberOfLines = 0
        textView.textContainer.widthTracksTextView = true
        textView.textContainer.lineBreakMode = .byWordWrapping
        textView.tintColor = .white
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return textView
    }

    func updateUIView(_ uiView: SelectableTextView, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }

        if uiView.font?.pointSize != fontSize {
            uiView.font = UIFont.systemFont(ofSize: fontSize, weight: .medium)
        }

        DispatchQueue.main.async {
            uiView.invalidateIntrinsicContentSize()
        }
    }

    final class SelectableTextView: UITextView {
        private var lastKnownBoundsSize: CGSize = .zero

        override var intrinsicContentSize: CGSize {
            let targetWidth = max(bounds.width, 40)
            let fittedSize = sizeThatFits(CGSize(width: targetWidth, height: .greatestFiniteMagnitude))
            return CGSize(width: UIView.noIntrinsicMetric, height: ceil(fittedSize.height))
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard bounds.size != lastKnownBoundsSize else { return }
            lastKnownBoundsSize = bounds.size
            invalidateIntrinsicContentSize()
        }
    }
}

private struct AIChatProviderChip: View {
    let title: String
    let isSelected: Bool
    let isConfigured: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Circle()
                    .fill(isConfigured ? Color(red: 0.42, green: 0.95, blue: 0.66) : Color(red: 1.00, green: 0.73, blue: 0.49))
                    .frame(width: 9, height: 9)

                Text(title)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(isSelected ? Color(red: 0.21, green: 0.54, blue: 0.97).opacity(0.82) : Color.white.opacity(0.08))
            )
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(isSelected ? 0.16 : 0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct AIChatSessionChip: View {
    let session: AIChatSession
    let isSelected: Bool
    let onTap: () -> Void

    private var chipWidth: CGFloat {
        min(max(UIScreen.main.bounds.width * 0.34, 130), 176)
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.previewText)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(session.labelText)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.56))
                    .lineLimit(1)
            }
            .frame(width: chipWidth, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isSelected ? Color(red: 0.20, green: 0.60, blue: 0.98).opacity(0.28) : Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(isSelected ? 0.18 : 0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct AIChatMessageBubble: View {
    private struct PromptBlock: Identifiable, Equatable {
        let id: String
        let label: String
        let prompt: String
    }

    let message: AIChatMessage
    let isKhmer: Bool
    let isCurrentlySpeaking: Bool
    let selectedPlaybackSpeed: AIChatSpeechPlaybackSpeed
    let promptBlocks: [String]
    let attachments: [AIChatAttachment]
    let onCopy: () -> Void
    let onCopyPrompt: (String) -> Void
    let onSelectPlaybackSpeed: (AIChatSpeechPlaybackSpeed) -> Void
    let onTogglePlayback: () -> Void
    @State private var copiedPromptBlockID: String?

    private func tr(_ english: String, _ khmer: String) -> String {
        isKhmer ? khmer : english
    }

    private var isUser: Bool {
        message.role == "user"
    }

    private var bubbleMaxWidth: CGFloat {
        min(max(UIScreen.main.bounds.width * 0.78, 240), 520)
    }

    private var displayPromptBlocks: [PromptBlock] {
        guard !isUser else { return [] }

        let promptItems: [String]
        if !promptBlocks.isEmpty {
            promptItems = promptBlocks
        } else if hasExplicitPromptHeader,
                  let fallbackPrompt = AIChatPromptExtractor.extractGenerationPrompt(from: message.content),
                  !fallbackPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            promptItems = [fallbackPrompt]
        } else {
            promptItems = []
        }

        return promptItems.enumerated().map { index, prompt in
            let itemNumber = index + 1
            return PromptBlock(
                id: "\(message.id.uuidString)-\(itemNumber)",
                label: "\(itemNumber). Prompt \(itemNumber)",
                prompt: prompt
            )
        }
    }

    private var hasExplicitPromptHeader: Bool {
        message.content.range(
            of: #"(?im)(?:^|\n)\s*(?:#{1,6}\s*)?(?:[-*•]\s*)?(?:\d+[.)-]?\s*)?(?:english\s+)?(?:image|video)?\s*prompt(?:\s*\(english\))?(?:\s*\d+)?\s*:"#,
            options: .regularExpression
        ) != nil
    }

    private var shouldShowRawContentText: Bool {
        let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if isUser {
            return true
        }
        return displayPromptBlocks.isEmpty
    }

    private var khmerSupplementText: String {
        guard !displayPromptBlocks.isEmpty else { return "" }

        let lines = message.content
            .components(separatedBy: .newlines)
            .map { cleanedSupplementaryLine($0) }
            .filter { line in
                !line.isEmpty && containsKhmerCharacters(line)
            }

        guard !lines.isEmpty else { return "" }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if !isUser {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .frame(width: 24, height: 24)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.10))
                    )
            }

            if isUser {
                Spacer(minLength: 40)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(isUser ? tr("You", "អ្នក") : "AI")
                        .font(.system(size: 11, weight: .black, design: .rounded))
                        .foregroundStyle(.white.opacity(0.76))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.white.opacity(isUser ? 0.14 : 0.08))
                        )

                    if !isUser {
                        Button(action: onTogglePlayback) {
                            Label(
                                isCurrentlySpeaking ? tr("Stop", "បិទ") : tr("Play", "បើកស្តាប់"),
                                systemImage: isCurrentlySpeaking ? "stop.fill" : "play.fill"
                            )
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(
                                        isCurrentlySpeaking
                                            ? Color(red: 0.90, green: 0.31, blue: 0.34).opacity(0.94)
                                            : Color.white.opacity(0.10)
                                    )
                            )
                        }
                        .buttonStyle(.plain)

                        playbackSpeedButton(title: tr("Slow", "យឺត"), speed: .slow)
                        playbackSpeedButton(title: tr("Fast", "លឿន"), speed: .fast)
                    }

                    Spacer(minLength: 0)
                }

                if shouldShowRawContentText {
                    AIChatSelectableTextView(
                        text: message.content,
                        fontSize: 14
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                }

                if !attachments.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(attachments) { attachment in
                            switch attachment.kind {
                            case .image:
                                AIChatImageAttachmentCard(attachment: attachment)
                            case .video:
                                AIChatVideoAttachmentCard(attachment: attachment)
                            }
                        }
                    }
                }

                if !displayPromptBlocks.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(displayPromptBlocks.enumerated()), id: \.element.id) { index, block in
                            promptBlockCard(block, index: index)
                        }
                    }
                }

                if !khmerSupplementText.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(tr("Khmer", "ខ្មែរ"))
                            .font(.system(size: 11, weight: .black, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.80))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.white.opacity(0.08))
                            )

                        AIChatSelectableTextView(
                            text: khmerSupplementText,
                            fontSize: 13
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                    }
                }

                if shouldShowRawContentText || displayPromptBlocks.isEmpty {
                    HStack {
                        Spacer(minLength: 0)

                        Button(action: onCopy) {
                            Label(tr("Copy", "ចម្លង"), systemImage: "doc.on.doc.fill")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    Capsule()
                                        .fill(Color(red: 0.21, green: 0.54, blue: 0.97).opacity(0.86))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: bubbleMaxWidth, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        isUser
                        ? LinearGradient(
                            colors: [
                                Color(red: 0.18, green: 0.51, blue: 0.98),
                                Color(red: 0.12, green: 0.72, blue: 0.92)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        : LinearGradient(
                            colors: [
                                Color.white.opacity(0.10),
                                Color.white.opacity(0.07)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(isUser ? 0.12 : 0.08), lineWidth: 1)
            )

            if !isUser {
                Spacer(minLength: 40)
            }
        }
    }

    @ViewBuilder
    private func promptBlockCard(_ block: PromptBlock, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Text(block.label)
                    .font(.system(size: 11, weight: .black, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.80))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.08))
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
                        Text(copyPromptButtonTitle(isCopied: isCopied, index: index, totalCount: displayPromptBlocks.count))
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(
                                isCopied
                                    ? Color(red: 0.24, green: 0.77, blue: 0.54).opacity(0.94)
                                    : Color.white.opacity(0.10)
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(isCopied ? 0.18 : 0.08), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .scaleEffect(isCopied ? 1.02 : 1)
                .animation(.easeInOut(duration: 0.16), value: isCopied)
            }

            AIChatSelectableTextView(
                text: block.prompt,
                fontSize: 13
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(red: 0.08, green: 0.10, blue: 0.20).opacity(0.56))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            )
        }
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

    private func copyPromptButtonTitle(isCopied: Bool, index: Int, totalCount: Int) -> String {
        if isCopied {
            return tr("Copied", "បានចម្លង")
        }
        if totalCount > 1 {
            return "Copy \(index + 1)"
        }
        return tr("Copy Prompt", "ចម្លង Prompt")
    }

    private func cleanedSupplementaryLine(_ line: String) -> String {
        line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^\s*#{1,6}\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^\s*[-*•]+\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^\s*\d+[.)]\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func containsKhmerCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x1780...0x17FF).contains(scalar.value) || (0x19E0...0x19FF).contains(scalar.value)
        }
    }

    private func playbackSpeedButton(title: String, speed: AIChatSpeechPlaybackSpeed) -> some View {
        Button {
            onSelectPlaybackSpeed(speed)
        } label: {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(
                            selectedPlaybackSpeed == speed
                                ? Color(red: 0.19, green: 0.53, blue: 0.96).opacity(0.90)
                                : Color.white.opacity(0.08)
                        )
                )
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(selectedPlaybackSpeed == speed ? 0.18 : 0.08), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

private struct AIChatComposerAttachmentChip: View {
    let attachment: AIChatAttachment
    let onRemove: () -> Void

    private var iconName: String {
        switch attachment.kind {
        case .image:
            return "photo.fill"
        case .video:
            return "video.fill"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 11, weight: .bold))

            Text(attachment.resolvedDisplayName)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .lineLimit(1)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .black))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct AIChatImageAttachmentCard: View {
    let attachment: AIChatAttachment

    private var fileExists: Bool {
        FileManager.default.fileExists(atPath: attachment.url.path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if fileExists, let image = UIImage(contentsOfFile: attachment.url.path) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 240, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 170)
                    .overlay(
                        Text("Image unavailable")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.52))
                    )
            }

            HStack(spacing: 8) {
                Image(systemName: "photo.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.70))

                Text(attachment.resolvedDisplayName)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.70))
                    .lineLimit(1)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct AIChatVideoAttachmentCard: View {
    let attachment: AIChatAttachment

    private var fileExists: Bool {
        FileManager.default.fileExists(atPath: attachment.url.path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if fileExists {
                    VideoThumbnailView(fileURL: attachment.url)
                        .frame(maxWidth: .infinity)
                        .frame(height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(alignment: .center) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(16)
                                .background(
                                    Circle()
                                        .fill(Color.black.opacity(0.34))
                                )
                        }
                } else {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                        .frame(height: 170)
                        .overlay(
                            VStack(spacing: 8) {
                                Image(systemName: "video.fill")
                                    .font(.system(size: 24, weight: .bold))
                                    .foregroundStyle(Color.white.opacity(0.52))
                                Text(fileExists ? "Video preview" : "Video unavailable")
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                    .foregroundStyle(Color.white.opacity(0.52))
                            }
                        )
                }

                HStack(spacing: 6) {
                    Image(systemName: "video.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text("Video")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(Color.black.opacity(0.48))
                )
                .padding(12)
            }

            HStack(spacing: 8) {
                Image(systemName: "video.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.70))

                Text(attachment.resolvedDisplayName)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.70))
                    .lineLimit(1)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct AIModelMenuButton: View {
    let selectedModelID: String
    let options: [AIModelOption]
    let isRefreshing: Bool
    let isKhmer: Bool
    let onSelect: (String) -> Void

    private func tr(_ english: String, _ khmer: String) -> String {
        isKhmer ? khmer : english
    }

    private var selectedOption: AIModelOption {
        options.first(where: { $0.id == selectedModelID }) ?? AIModelOption(
            id: selectedModelID,
            title: selectedModelID,
            isLatest: false,
            isPreview: selectedModelID.localizedCaseInsensitiveContains("preview")
        )
    }

    var body: some View {
        Menu {
            ForEach(options) { option in
                Button {
                    onSelect(option.id)
                } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.title)
                            if let badgeText = option.badgeText {
                                Text(badgeText)
                                    .font(.caption2.bold())
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer(minLength: 8)

                        if option.id == selectedModelID {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "cpu")
                    .font(.system(size: 11, weight: .bold))

                Text(selectedOption.title)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .lineLimit(1)

                if let badgeText = selectedOption.badgeText {
                    Text(tr(badgeText, badgeText))
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(0.12))
                        )
                }

                if isRefreshing {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.10))
            )
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
    }
}

private struct OpenAIKeyPopup: View {
    @Binding var apiKeyText: String
    let hasConfiguredKey: Bool
    let isChecking: Bool
    let selectedModelID: String
    let modelOptions: [AIModelOption]
    let isRefreshingModels: Bool
    let messageText: String
    let focusedField: FocusState<ContentTextFocusField?>.Binding
    let isKhmer: Bool
    let onClose: () -> Void
    let onPasteAndCheck: () -> Void
    let onSelectModel: (String) -> Void
    let onRemove: () -> Void

    private func tr(_ english: String, _ khmer: String) -> String {
        isKhmer ? khmer : english
    }

    private var messageColor: Color {
        if isChecking {
            return Color(red: 0.42, green: 0.76, blue: 1.0)
        }
        if hasConfiguredKey && apiKeyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Color(red: 0.45, green: 0.98, blue: 0.68)
        }
        return Color(red: 1.0, green: 0.72, blue: 0.52)
    }

    private var showsKeyInput: Bool {
        !hasConfiguredKey || !apiKeyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.58)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tr("OpenAI Key", "OpenAI Key"))
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)

                        Text(tr(
                            "Tap Paste & Check. soranin saves the key only if OpenAI can really run it.",
                            "ចុច Paste & Check។ soranin នឹងរក្សាទុក key តែនៅពេល OpenAI អាចប្រើវាបានពិតៗប៉ុណ្ណោះ។"
                        ))
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.66))
                    }

                    Spacer(minLength: 12)

                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 42, height: 42)
                            .background(
                                Circle()
                                    .fill(Color.white.opacity(0.08))
                            )
                    }
                    .buttonStyle(.plain)
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text(tr("Model", "Model"))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.72))

                        Spacer(minLength: 8)

                        AIModelMenuButton(
                            selectedModelID: selectedModelID,
                            options: modelOptions,
                            isRefreshing: isRefreshingModels,
                            isKhmer: isKhmer,
                            onSelect: onSelectModel
                        )
                    }

                    if showsKeyInput {
                        Text(tr("API Key", "API Key"))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.72))

                        SecureField("sk-...", text: $apiKeyText)
                            .font(.system(size: 16, weight: .medium, design: .rounded))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.asciiCapable)
                            .focused(focusedField, equals: .openAIKey)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 15)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(Color.white.opacity(0.08))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
                            )
                    } else {
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(Color(red: 0.45, green: 0.98, blue: 0.68))

                            VStack(alignment: .leading, spacing: 3) {
                                Text(tr("Saved OpenAI Key Found", "បានរកឃើញ OpenAI Key ដែលបានរក្សាទុក"))
                                    .font(.system(size: 15, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)

                                Text(tr("This iPhone already had a saved OpenAI key. Paste & Check replaces it with a new clipboard key.", "iPhone នេះមាន OpenAI key ដែលបានរក្សាទុករួចហើយ។ ចុច Paste & Check ដើម្បីប្ដូរទៅ key ថ្មីពី clipboard។"))
                                    .font(.system(size: 13, weight: .medium, design: .rounded))
                                    .foregroundStyle(Color.white.opacity(0.66))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color(red: 0.16, green: 0.22, blue: 0.34))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(Color(red: 0.45, green: 0.98, blue: 0.68).opacity(0.45), lineWidth: 1)
                        )
                    }

                    Text(hasConfiguredKey
                         ? tr("A working key is already saved. Paste & Check replaces it only if the new key works.", "មាន key ដែលប្រើបានត្រូវបានរក្សាទុករួចហើយ។ Paste & Check នឹងជំនួសវា តែនៅពេល key ថ្មីប្រើបានប៉ុណ្ណោះ។")
                         : tr("If the check fails, the box stays empty and nothing is saved.", "បើការពិនិត្យបរាជ័យ ប្រអប់នេះនឹងនៅទទេ ហើយមិនមានអ្វីត្រូវបានរក្សាទុកទេ។"))
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.62))
                        .fixedSize(horizontal: false, vertical: true)

                    if !messageText.isEmpty {
                        Text(messageText)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(messageColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: 10) {
                    Button(action: onPasteAndCheck) {
                        Label(
                            isChecking
                                ? tr("Checking...", "កំពុងពិនិត្យ...")
                                : (hasConfiguredKey ? tr("Paste New Key", "Paste Key ថ្មី") : tr("Paste & Check", "Paste & Check")),
                            systemImage: isChecking ? "hourglass" : "doc.on.clipboard.fill"
                        )
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(Color(red: 0.21, green: 0.54, blue: 0.97).opacity(0.92))
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(isChecking)

                    if hasConfiguredKey {
                        Button(action: onRemove) {
                            Label(tr("Remove", "លុប"), systemImage: "trash.fill")
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .fill(Color.white.opacity(0.10))
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(isChecking)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 420)
            .background(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(Color(red: 0.10, green: 0.12, blue: 0.24))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .padding(.horizontal, 18)
        }
    }
}

private struct GoogleAIKeyPopup: View {
    @Binding var apiKeyText: String
    let hasConfiguredKey: Bool
    let isChecking: Bool
    let selectedModelID: String
    let modelOptions: [AIModelOption]
    let isRefreshingModels: Bool
    let messageText: String
    let focusedField: FocusState<ContentTextFocusField?>.Binding
    let isKhmer: Bool
    let onClose: () -> Void
    let onPasteAndCheck: () -> Void
    let onSelectModel: (String) -> Void
    let onRemove: () -> Void

    private func tr(_ english: String, _ khmer: String) -> String {
        isKhmer ? khmer : english
    }

    private var messageColor: Color {
        if isChecking {
            return Color(red: 0.42, green: 0.76, blue: 1.0)
        }
        if hasConfiguredKey && apiKeyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Color(red: 0.45, green: 0.98, blue: 0.68)
        }
        return Color(red: 1.0, green: 0.72, blue: 0.52)
    }

    private var showsKeyInput: Bool {
        !hasConfiguredKey || !apiKeyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.58)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tr("Google AI Studio Key", "Google AI Studio Key"))
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)

                        Text(tr(
                            "Tap Paste & Check. soranin saves the key only if Google Gemini can really run it.",
                            "ចុច Paste & Check។ soranin នឹងរក្សាទុក key តែនៅពេល Google Gemini អាចប្រើវាបានពិតៗប៉ុណ្ណោះ។"
                        ))
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.66))
                    }

                    Spacer(minLength: 12)

                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 42, height: 42)
                            .background(
                                Circle()
                                    .fill(Color.white.opacity(0.08))
                            )
                    }
                    .buttonStyle(.plain)
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text(tr("Model", "Model"))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.72))

                        Spacer(minLength: 8)

                        AIModelMenuButton(
                            selectedModelID: selectedModelID,
                            options: modelOptions,
                            isRefreshing: isRefreshingModels,
                            isKhmer: isKhmer,
                            onSelect: onSelectModel
                        )
                    }

                    if showsKeyInput {
                        Text(tr("API Key", "API Key"))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.72))

                        SecureField("AIza...", text: $apiKeyText)
                            .font(.system(size: 16, weight: .medium, design: .rounded))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.asciiCapable)
                            .focused(focusedField, equals: .googleAIKey)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 15)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(Color.white.opacity(0.08))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
                            )
                    } else {
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(Color(red: 0.45, green: 0.98, blue: 0.68))

                            VStack(alignment: .leading, spacing: 3) {
                                Text(tr("Saved Google Key Found", "បានរកឃើញ Google Key ដែលបានរក្សាទុក"))
                                    .font(.system(size: 15, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)

                                Text(tr("This iPhone already had a saved Google key. Paste & Check replaces it with a new clipboard key.", "iPhone នេះមាន Google key ដែលបានរក្សាទុករួចហើយ។ ចុច Paste & Check ដើម្បីប្ដូរទៅ key ថ្មីពី clipboard។"))
                                    .font(.system(size: 13, weight: .medium, design: .rounded))
                                    .foregroundStyle(Color.white.opacity(0.66))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color(red: 0.16, green: 0.22, blue: 0.34))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(Color(red: 0.45, green: 0.98, blue: 0.68).opacity(0.45), lineWidth: 1)
                        )
                    }

                    Text(hasConfiguredKey
                         ? tr("A working key is already saved. Paste & Check replaces it only if the new key works.", "មាន key ដែលប្រើបានត្រូវបានរក្សាទុករួចហើយ។ Paste & Check នឹងជំនួសវា តែនៅពេល key ថ្មីប្រើបានប៉ុណ្ណោះ។")
                         : tr("If the check fails, the box stays empty and nothing is saved.", "បើការពិនិត្យបរាជ័យ ប្រអប់នេះនឹងនៅទទេ ហើយមិនមានអ្វីត្រូវបានរក្សាទុកទេ។"))
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.62))
                        .fixedSize(horizontal: false, vertical: true)

                    if !messageText.isEmpty {
                        Text(messageText)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(messageColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: 10) {
                    Button(action: onPasteAndCheck) {
                        Label(
                            isChecking
                                ? tr("Checking...", "កំពុងពិនិត្យ...")
                                : (hasConfiguredKey ? tr("Paste New Key", "Paste Key ថ្មី") : tr("Paste & Check", "Paste & Check")),
                            systemImage: isChecking ? "hourglass" : "doc.on.clipboard.fill"
                        )
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(Color(red: 0.21, green: 0.54, blue: 0.97).opacity(0.92))
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(isChecking)

                    if hasConfiguredKey {
                        Button(action: onRemove) {
                            Label(tr("Remove Key", "លុប Key"), systemImage: "trash.fill")
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .fill(Color.white.opacity(0.10))
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(isChecking)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 430)
            .background(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(Color(red: 0.10, green: 0.12, blue: 0.24))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .padding(.horizontal, 18)
        }
    }
}

private struct PhotoEditorPopup: View {
    private enum PhotoTextFocusField: Hashable {
        case caption
        case emoji
    }

    let fileURL: URL
    let isBusy: Bool
    @Binding var zoomScale: Double
    @Binding var panOffset: CGSize
    @Binding var captionText: String
    @Binding var captionPosition: CGPoint
    @Binding var captionScale: Double
    @Binding var captionRotation: Double
    @Binding var emojiText: String
    @Binding var emojiPosition: CGPoint
    @Binding var emojiScale: Double
    @Binding var emojiRotation: Double
    @Binding var gifData: Data?
    @Binding var gifPosition: CGPoint
    @Binding var gifScale: Double
    @Binding var gifRotation: Double
    @Binding var selectedTarget: EditorFocusTarget
    let onClose: () -> Void
    let onSave: (URL) -> Void
    let onShare: (URL) -> Void

    @State private var localErrorMessage: String?
    @FocusState private var focusedField: PhotoTextFocusField?

    var body: some View {
        ZStack {
            Color.black.opacity(0.58)
                .ignoresSafeArea()
                .onTapGesture {
                    focusedField = nil
                }

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Photo Cut Ready")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)

                        Text("Edit this photo, then save to Photos or share it.")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.66))
                    }

                    Spacer(minLength: 12)

                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 42, height: 42)
                            .background(
                                Circle()
                                    .fill(Color.white.opacity(0.08))
                            )
                    }
                    .buttonStyle(.plain)
                }

                PhotoEditorCanvas(
                    fileURL: fileURL,
                    isWorking: isBusy,
                    zoomScale: $zoomScale,
                    panOffset: $panOffset,
                    captionText: $captionText,
                    captionPosition: $captionPosition,
                    captionScale: $captionScale,
                    captionRotation: $captionRotation,
                    emojiText: $emojiText,
                    emojiPosition: $emojiPosition,
                    emojiScale: $emojiScale,
                    emojiRotation: $emojiRotation,
                    gifData: $gifData,
                    gifPosition: $gifPosition,
                    gifScale: $gifScale,
                    gifRotation: $gifRotation,
                    selectedTarget: $selectedTarget
                )
                .frame(maxWidth: .infinity)
                .aspectRatio(9.0 / 16.0, contentMode: .fit)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 86, maximum: 140), spacing: 8)], spacing: 8) {
                    ForEach(EditorFocusTarget.allCases.filter { $0 != .gif || gifData != nil }) { target in
                        photoTargetButton(target)
                    }
                }

                ViewThatFits {
                    HStack(spacing: 10) {
                        photoField(title: "Text", text: $captionText) {
                            selectedTarget = .text
                        }
                        photoField(title: "Emoji", text: $emojiText) {
                            selectedTarget = .emoji
                        }
                    }

                    VStack(spacing: 10) {
                        photoField(title: "Text", text: $captionText) {
                            selectedTarget = .text
                        }
                        photoField(title: "Emoji", text: $emojiText) {
                            selectedTarget = .emoji
                        }
                    }
                }

                if let localErrorMessage {
                    Text(localErrorMessage)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.red.opacity(0.92))
                }

                HStack(spacing: 10) {
                    Button {
                        renderAndForward(onSave)
                    } label: {
                        Label("Save to Photos", systemImage: "square.and.arrow.down.fill")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(Color(red: 0.21, green: 0.54, blue: 0.97).opacity(0.92))
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy)

                    Button {
                        renderAndForward(onShare)
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up.fill")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(Color.white.opacity(0.10))
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy)
                }
            }
            .padding(20)
            .frame(maxWidth: 430)
            .background(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(Color(red: 0.10, green: 0.12, blue: 0.24))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .padding(.horizontal, 18)
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()

                Button("Done") {
                    focusedField = nil
                }
            }
        }
    }

    private func photoTargetButton(_ target: EditorFocusTarget) -> some View {
        let isSelected = selectedTarget == target

        return Button {
            selectedTarget = target
        } label: {
            HStack(spacing: 8) {
                Image(systemName: target.icon)
                    .font(.system(size: 14, weight: .bold))

                Text(target.rawValue)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isSelected ? Color(red: 0.20, green: 0.60, blue: 0.98).opacity(0.34) : Color.white.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
    }

    private func photoField(title: String, text: Binding<String>, onTap: @escaping () -> Void) -> some View {
        let focusTarget: PhotoTextFocusField = title == "Text" ? .caption : .emoji

        return VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.70))

            TextField(title, text: text)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .focused($focusedField, equals: focusTarget)
                .submitLabel(.done)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
                .onTapGesture {
                    focusedField = focusTarget
                    onTap()
                }
                .onSubmit {
                    focusedField = nil
                }
        }
    }

    private func renderAndForward(_ action: (URL) -> Void) {
        do {
            let renderedURL = try PhotoEditorRenderer.render(to: fileURL, settings: ReelsEditorSettings(
                zoomScale: zoomScale,
                panX: Double(panOffset.width),
                panY: Double(panOffset.height),
                captionText: captionText,
                captionX: Double(captionPosition.x),
                captionY: Double(captionPosition.y),
                captionScale: captionScale,
                captionRotation: captionRotation,
                emojiText: emojiText,
                emojiX: Double(emojiPosition.x),
                emojiY: Double(emojiPosition.y),
                emojiScale: emojiScale,
                emojiRotation: emojiRotation,
                gifData: gifData,
                gifX: Double(gifPosition.x),
                gifY: Double(gifPosition.y),
                gifScale: gifScale,
                gifRotation: gifRotation
            ))
            localErrorMessage = nil
            action(renderedURL)
        } catch {
            localErrorMessage = error.localizedDescription
        }
    }
}

private struct PhotoEditorCanvas: View {
    let fileURL: URL
    let isWorking: Bool
    @Binding var zoomScale: Double
    @Binding var panOffset: CGSize
    @Binding var captionText: String
    @Binding var captionPosition: CGPoint
    @Binding var captionScale: Double
    @Binding var captionRotation: Double
    @Binding var emojiText: String
    @Binding var emojiPosition: CGPoint
    @Binding var emojiScale: Double
    @Binding var emojiRotation: Double
    @Binding var gifData: Data?
    @Binding var gifPosition: CGPoint
    @Binding var gifScale: Double
    @Binding var gifRotation: Double
    @Binding var selectedTarget: EditorFocusTarget

    @State private var baseImage: UIImage?
    @State private var sourceAspectRatio: CGFloat = 9.0 / 16.0
    @State private var dragStartPan = CGSize.zero
    @State private var isDraggingImage = false
    @State private var pinchStartZoom = 1.0
    @State private var isPinchingImage = false
    @State private var imagePanIntent: MediaPanIntent = .undecided

    var body: some View {
        GeometryReader { geometry in
            let canvasSize = geometry.size
            let imageSize = imageFillSize(for: canvasSize)
            let clampedPan = clampedPanOffset(for: canvasSize, imageSize: imageSize)

            ZStack {
                Color.black.opacity(0.92)
                    .onTapGesture {
                        selectedTarget = .video
                    }

                if let baseImage {
                    Image(uiImage: baseImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: imageSize.width, height: imageSize.height)
                        .scaleEffect(CGFloat(zoomScale))
                        .offset(
                            x: clampedPan.width * canvasSize.width,
                            y: clampedPan.height * canvasSize.height
                        )
                }

                if !captionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    InteractiveOverlayItem(
                        canvasSize: canvasSize,
                        baseSize: CGSize(width: min(canvasSize.width * 0.76, 300), height: 116),
                        isWorking: isWorking,
                        center: $captionPosition,
                        scale: $captionScale,
                        rotation: $captionRotation,
                        isSelected: selectedTarget == .text,
                        isInteractive: selectedTarget == .text,
                        onSelect: {
                            selectedTarget = .text
                        }
                    ) {
                        TextBubblePreview(text: captionText)
                    }
                }

                if !emojiText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    InteractiveOverlayItem(
                        canvasSize: canvasSize,
                        baseSize: CGSize(width: 132, height: 132),
                        isWorking: isWorking,
                        center: $emojiPosition,
                        scale: $emojiScale,
                        rotation: $emojiRotation,
                        isSelected: selectedTarget == .emoji,
                        isInteractive: selectedTarget == .emoji,
                        onSelect: {
                            selectedTarget = .emoji
                        }
                    ) {
                        EmojiOverlayPreview(text: emojiText)
                    }
                }

                if let gifData {
                    InteractiveOverlayItem(
                        canvasSize: canvasSize,
                        baseSize: CGSize(width: min(canvasSize.width * 0.34, 160), height: min(canvasSize.width * 0.34, 160)),
                        isWorking: isWorking,
                        center: $gifPosition,
                        scale: $gifScale,
                        rotation: $gifRotation,
                        isSelected: selectedTarget == .gif,
                        isInteractive: selectedTarget == .gif,
                        onSelect: {
                            selectedTarget = .gif
                        }
                    ) {
                        GIFOverlayPreview(data: gifData)
                    }
                }

                VStack {
                    HStack {
                        Spacer()

                        VStack(alignment: .trailing, spacing: 4) {
                            Text("Editing \(selectedTarget.rawValue)")
                            Text(selectedTarget == .video ? "Pinch + Drag" : "Drag + Pinch + Rotate")
                        }
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.76))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.black.opacity(0.34))
                        )
                    }

                    Spacer()
                }
                .padding(12)
                .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(
                        selectedTarget == .video ? Color(red: 0.20, green: 0.60, blue: 0.98) : Color.white.opacity(0.08),
                        lineWidth: selectedTarget == .video ? 2 : 1
                    )
            )
            .simultaneousGesture(imagePanGesture(canvasSize: canvasSize, baseImageSize: imageSize))
            .simultaneousGesture(imageMagnificationGesture())
        }
        .onAppear {
            loadImage()
        }
        .onChange(of: fileURL) { _, _ in
            loadImage()
        }
    }

    private func loadImage() {
        baseImage = UIImage(contentsOfFile: fileURL.path)
        if let baseImage, baseImage.size.width > 0, baseImage.size.height > 0 {
            sourceAspectRatio = baseImage.size.width / baseImage.size.height
        } else {
            sourceAspectRatio = 9.0 / 16.0
        }
    }

    private func imageFillSize(for canvasSize: CGSize) -> CGSize {
        let targetAspectRatio = canvasSize.width / max(canvasSize.height, 1)
        if sourceAspectRatio > targetAspectRatio {
            return CGSize(width: canvasSize.height * sourceAspectRatio, height: canvasSize.height)
        }
        return CGSize(width: canvasSize.width, height: canvasSize.width / max(sourceAspectRatio, 0.01))
    }

    private func clampedPanOffset(for canvasSize: CGSize, imageSize: CGSize) -> CGSize {
        clampedPanOffset(panOffset, canvasSize: canvasSize, imageSize: imageSize)
    }

    private func clampedPanOffset(_ proposed: CGSize, canvasSize: CGSize, imageSize: CGSize) -> CGSize {
        let scaledWidth = imageSize.width * CGFloat(zoomScale)
        let scaledHeight = imageSize.height * CGFloat(zoomScale)
        let maxOffsetX = max(0, (scaledWidth - canvasSize.width) / 2) / max(canvasSize.width, 1)
        let maxOffsetY = max(0, (scaledHeight - canvasSize.height) / 2) / max(canvasSize.height, 1)

        return CGSize(
            width: min(max(proposed.width, -maxOffsetX), maxOffsetX),
            height: min(max(proposed.height, -maxOffsetY), maxOffsetY)
        )
    }

    private func imagePanGesture(canvasSize: CGSize, baseImageSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard !isWorking, selectedTarget == .video else { return }

                if !isDraggingImage {
                    let intent = resolvedMediaPanIntent(for: value.translation, zoomScale: zoomScale)
                    imagePanIntent = intent

                    guard intent == .panning else { return }
                    dragStartPan = panOffset
                    isDraggingImage = true
                }

                guard imagePanIntent == .panning else { return }

                let startOffset = dragStartPan
                let proposed = CGSize(
                    width: startOffset.width + (value.translation.width / max(canvasSize.width, 1)),
                    height: startOffset.height + (value.translation.height / max(canvasSize.height, 1))
                )
                panOffset = clampedPanOffset(proposed, canvasSize: canvasSize, imageSize: baseImageSize)
            }
            .onEnded { _ in
                defer {
                    dragStartPan = .zero
                    isDraggingImage = false
                    imagePanIntent = .undecided
                }

                guard selectedTarget == .video, imagePanIntent == .panning else { return }
                dragStartPan = .zero
                panOffset = clampedPanOffset(panOffset, canvasSize: canvasSize, imageSize: baseImageSize)
            }
    }

    private func imageMagnificationGesture() -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard !isWorking, selectedTarget == .video else { return }
                let startZoom = isPinchingImage ? pinchStartZoom : zoomScale
                pinchStartZoom = startZoom
                isPinchingImage = true
                zoomScale = min(max(startZoom * value.magnification, 1), 4)
            }
            .onEnded { _ in
                guard selectedTarget == .video else { return }
                pinchStartZoom = zoomScale
                isPinchingImage = false
            }
    }
}

private enum PhotoEditorRenderer {
    static func render(to fileURL: URL, settings: ReelsEditorSettings) throws -> URL {
        guard let baseImage = UIImage(contentsOfFile: fileURL.path) else {
            throw NSError(domain: "PhotoEditorRenderer", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The photo could not be loaded for editing."
            ])
        }

        let size = baseImage.size
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            let canvasRect = CGRect(origin: .zero, size: size)
            let cgContext = context.cgContext

            cgContext.saveGState()
            cgContext.translateBy(
                x: (size.width / 2) + (CGFloat(settings.panX) * size.width),
                y: (size.height / 2) + (CGFloat(settings.panY) * size.height)
            )
            cgContext.scaleBy(x: CGFloat(settings.zoomScale), y: CGFloat(settings.zoomScale))
            baseImage.draw(in: CGRect(
                x: -size.width / 2,
                y: -size.height / 2,
                width: size.width,
                height: size.height
            ))
            cgContext.restoreGState()

            drawCaption(settings.captionText, in: canvasRect, settings: settings)
            drawEmoji(settings.emojiText, in: canvasRect, settings: settings)
            drawGIF(settings.gifData, in: canvasRect, settings: settings)
        }

        guard let data = image.jpegData(compressionQuality: 0.96) else {
            throw NSError(domain: "PhotoEditorRenderer", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "The edited photo could not be written."
            ])
        }

        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    private static func drawCaption(_ text: String, in rect: CGRect, settings: ReelsEditorSettings) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let maxBubbleWidth = min(rect.width * 0.76, 660)
        let font = UIFont.systemFont(ofSize: 44, weight: .bold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white,
            .paragraphStyle: paragraph
        ]

        let baseBounds = NSString(string: trimmed).boundingRect(
            with: CGSize(width: maxBubbleWidth - 48, height: rect.height),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes,
            context: nil
        ).integral

        let bubbleSize = CGSize(
            width: min(max(baseBounds.width + 48, 180), maxBubbleWidth),
            height: max(baseBounds.height + 34, 100)
        )

        let center = CGPoint(x: rect.width * settings.captionX, y: rect.height * settings.captionY)

        let bubbleRect = CGRect(
            x: center.x - (bubbleSize.width / 2),
            y: center.y - (bubbleSize.height / 2),
            width: bubbleSize.width,
            height: bubbleSize.height
        )

        let path = UIBezierPath(
            roundedRect: bubbleRect,
            cornerRadius: 26
        )

        let context = UIGraphicsGetCurrentContext()
        context?.saveGState()
        context?.translateBy(x: center.x, y: center.y)
        context?.rotate(by: CGFloat(settings.captionRotation))
        context?.scaleBy(x: CGFloat(settings.captionScale), y: CGFloat(settings.captionScale))
        context?.translateBy(x: -center.x, y: -center.y)

        UIColor.black.withAlphaComponent(0.42).setFill()
        path.fill()
        UIColor.white.withAlphaComponent(0.14).setStroke()
        path.lineWidth = 2
        path.stroke()

        let textRect = bubbleRect.insetBy(dx: 24, dy: 16)
        NSString(string: trimmed).draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes, context: nil)
        context?.restoreGState()
    }

    private static func drawEmoji(_ text: String, in rect: CGRect, settings: ReelsEditorSettings) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let font = UIFont.systemFont(ofSize: 140)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font
        ]
        let baseSize = NSString(string: trimmed).size(withAttributes: attributes)
        let center = CGPoint(x: rect.width * settings.emojiX, y: rect.height * settings.emojiY)
        let drawRect = CGRect(
            x: center.x - (baseSize.width / 2),
            y: center.y - (baseSize.height / 2),
            width: baseSize.width,
            height: baseSize.height
        )

        let context = UIGraphicsGetCurrentContext()
        context?.saveGState()
        context?.translateBy(x: center.x, y: center.y)
        context?.rotate(by: CGFloat(settings.emojiRotation))
        context?.scaleBy(x: CGFloat(settings.emojiScale), y: CGFloat(settings.emojiScale))
        context?.translateBy(x: -center.x, y: -center.y)
        NSString(string: trimmed).draw(in: drawRect, withAttributes: attributes)
        context?.restoreGState()
    }

    private static func drawGIF(_ data: Data?, in rect: CGRect, settings: ReelsEditorSettings) {
        guard let data,
              let image = GIFSequence.make(from: data).images.first else {
            return
        }

        let width = rect.width * CGFloat(settings.gifWidthRatio) * CGFloat(settings.gifScale)
        let aspectRatio = image.size.width / max(image.size.height, 1)
        let height = width / max(aspectRatio, 0.01)
        let center = CGPoint(x: rect.width * settings.gifX, y: rect.height * settings.gifY)
        let drawRect = CGRect(
            x: center.x - (width / 2),
            y: center.y - (height / 2),
            width: width,
            height: height
        )

        let context = UIGraphicsGetCurrentContext()
        context?.saveGState()
        context?.translateBy(x: center.x, y: center.y)
        context?.rotate(by: CGFloat(settings.gifRotation))
        context?.translateBy(x: -center.x, y: -center.y)
        image.draw(in: drawRect)
        context?.restoreGState()
    }
}

private struct InteractiveOverlayItem<Content: View>: View {
    let canvasSize: CGSize
    let baseSize: CGSize
    let isWorking: Bool
    @Binding var center: CGPoint
    @Binding var scale: Double
    @Binding var rotation: Double
    let isSelected: Bool
    let isInteractive: Bool
    let onSelect: () -> Void
    let content: () -> Content

    @State private var dragStartCenter = CGPoint(x: 0.5, y: 0.5)
    @State private var isDragging = false
    @State private var scaleStart = 1.0
    @State private var isScaling = false
    @State private var rotationStart = 0.0
    @State private var isRotating = false

    var body: some View {
        content()
            .frame(width: baseSize.width, height: baseSize.height)
            .scaleEffect(CGFloat(scale))
            .rotationEffect(.radians(rotation))
            .position(clampedCenterPoint)
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(
                        isSelected ? Color(red: 0.20, green: 0.60, blue: 0.98) : .clear,
                        lineWidth: 2
                    )
            }
            .onTapGesture {
                onSelect()
            }
            .gesture(dragGesture)
            .simultaneousGesture(scaleGesture)
            .simultaneousGesture(rotationGesture)
    }

    private var clampedCenterPoint: CGPoint {
        let clamped = clamped(center)
        return CGPoint(x: clamped.x * canvasSize.width, y: clamped.y * canvasSize.height)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard !isWorking, isInteractive else { return }
                let start = isDragging ? dragStartCenter : center
                dragStartCenter = start
                isDragging = true

                let proposed = CGPoint(
                    x: start.x + (value.translation.width / max(canvasSize.width, 1)),
                    y: start.y + (value.translation.height / max(canvasSize.height, 1))
                )
                center = clamped(proposed)
            }
            .onEnded { _ in
                guard isInteractive else { return }
                dragStartCenter = center
                isDragging = false
            }
    }

    private var scaleGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard !isWorking, isInteractive else { return }
                let start = isScaling ? scaleStart : scale
                scaleStart = start
                isScaling = true
                scale = min(max(start * value.magnification, 0.5), 3.6)
            }
            .onEnded { _ in
                guard isInteractive else { return }
                scaleStart = scale
                isScaling = false
            }
    }

    private var rotationGesture: some Gesture {
        RotateGesture()
            .onChanged { value in
                guard !isWorking, isInteractive else { return }
                let start = isRotating ? rotationStart : rotation
                rotationStart = start
                isRotating = true
                rotation = start + value.rotation.radians
            }
            .onEnded { _ in
                guard isInteractive else { return }
                rotationStart = rotation
                isRotating = false
            }
    }

    private func clamped(_ proposed: CGPoint) -> CGPoint {
        let scaleRadius = max(baseSize.width, baseSize.height) * CGFloat(max(scale, 0.5)) * 0.5
        let insetX = min(scaleRadius / max(canvasSize.width, 1), 0.42)
        let insetY = min(scaleRadius / max(canvasSize.height, 1), 0.42)

        return CGPoint(
            x: min(max(proposed.x, insetX), 1 - insetX),
            y: min(max(proposed.y, insetY), 1 - insetY)
        )
    }
}

private struct TextBubblePreview: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 22, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .lineLimit(5)
            .minimumScaleFactor(0.55)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.black.opacity(0.42))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.28), radius: 12, x: 0, y: 8)
    }
}

private struct EmojiOverlayPreview: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 88))
            .minimumScaleFactor(0.45)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .shadow(color: .black.opacity(0.32), radius: 10, x: 0, y: 8)
    }
}

private struct GIFOverlayPreview: View {
    let data: Data

    var body: some View {
        AnimatedGIFView(data: data)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.28), radius: 12, x: 0, y: 8)
    }
}

private struct ExportResultPlayer: View {
    let fileURL: URL

    @State private var player = AVPlayer()

    var body: some View {
        ZStack {
            EditorPlayerSurface(player: player, videoGravity: .resizeAspectFill)
                .scaleEffect(1.08)
                .blur(radius: 20)
                .opacity(0.38)
                .overlay(
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.30),
                            Color.black.opacity(0.52)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            EditorPlayerSurface(player: player, videoGravity: .resizeAspect)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .onAppear {
            configurePlayer()
        }
        .onChange(of: fileURL) { _, _ in
            configurePlayer()
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
            guard notification.object as? AVPlayerItem === player.currentItem else { return }
            player.seek(to: .zero)
            player.play()
        }
        .onDisappear {
            player.pause()
        }
    }

    private func configurePlayer() {
        player.pause()
        let item = AVPlayerItem(url: fileURL)
        player.replaceCurrentItem(with: item)
        player.isMuted = true
        player.seek(to: .zero)
        player.play()
    }
}

private struct EditorPlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    let videoGravity: AVLayerVideoGravity

    func makeUIView(context: Context) -> EditorPlayerSurfaceView {
        let view = EditorPlayerSurfaceView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = videoGravity
        return view
    }

    func updateUIView(_ uiView: EditorPlayerSurfaceView, context: Context) {
        uiView.playerLayer.player = player
        uiView.playerLayer.videoGravity = videoGravity
    }
}

private final class EditorPlayerSurfaceView: UIView {
    override class var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private struct AnimatedGIFView: UIViewRepresentable {
    let data: Data

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIImageView {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.backgroundColor = .clear
        updateImageView(imageView, coordinator: context.coordinator)
        return imageView
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {
        updateImageView(uiView, coordinator: context.coordinator)
    }

    private func updateImageView(_ imageView: UIImageView, coordinator: Coordinator) {
        let hashValue = data.hashValue
        guard coordinator.lastHash != hashValue else { return }

        coordinator.lastHash = hashValue
        let sequence = GIFSequence.make(from: data)

        if sequence.images.count > 1 {
            imageView.animationImages = sequence.images
            imageView.animationDuration = max(sequence.duration, 0.1)
            imageView.image = sequence.images.first
            imageView.startAnimating()
        } else {
            imageView.stopAnimating()
            imageView.animationImages = nil
            imageView.image = sequence.images.first
        }
    }

    final class Coordinator {
        var lastHash = 0
    }
}

private struct GIFSequence {
    let images: [UIImage]
    let duration: Double

    static func make(from data: Data) -> GIFSequence {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return GIFSequence(images: UIImage(data: data).map { [$0] } ?? [], duration: 0.1)
        }

        let count = CGImageSourceGetCount(source)
        guard count > 0 else {
            return GIFSequence(images: UIImage(data: data).map { [$0] } ?? [], duration: 0.1)
        }

        var images: [UIImage] = []
        var totalDuration = 0.0

        for index in 0..<count {
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gifProperties = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let unclamped = gifProperties?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
            let clamped = gifProperties?[kCGImagePropertyGIFDelayTime] as? Double
            let delay = max(unclamped ?? clamped ?? 0.1, 0.04)

            images.append(UIImage(cgImage: cgImage))
            totalDuration += delay
        }

        if images.isEmpty, let image = UIImage(data: data) {
            images = [image]
        }

        return GIFSequence(images: images, duration: max(totalDuration, 0.1))
    }
}

private struct LatestVideoPreview: View {
    let fileURL: URL
    let isWorking: Bool
    @Binding var zoomScale: Double
    @Binding var panOffset: CGSize
    let actionLabel: String
    let actionSystemImage: String
    let onCutPhoto: (Double) -> Void

    @State private var player = AVPlayer()
    @State private var sourceAspectRatio: CGFloat = 9.0 / 16.0
    @State private var duration = 0.0
    @State private var currentTime = 0.0
    @State private var scrubTime = 0.0
    @State private var isScrubbing = false
    @State private var isPlaying = false
    @State private var shouldResumeAfterScrub = false
    @State private var timeObserver: Any?
    @State private var dragStartPan = CGSize.zero
    @State private var isDraggingVideo = false
    @State private var videoPanIntent: MediaPanIntent = .undecided

    var body: some View {
        VStack(spacing: 12) {
            GeometryReader { geometry in
                let canvasSize = geometry.size
                let videoSize = videoFillSize(for: canvasSize)
                let clampedPan = clampedPanOffset(for: canvasSize, videoSize: videoSize)

                ZStack {
                    PlayerSurface(player: player, videoGravity: .resizeAspectFill)
                        .frame(width: canvasSize.width, height: canvasSize.height)
                        .scaleEffect(1.08)
                        .blur(radius: 20)
                        .opacity(0.40)
                        .overlay(
                            LinearGradient(
                                colors: [
                                    Color.black.opacity(0.30),
                                    Color.black.opacity(0.52)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    PlayerSurface(player: player, videoGravity: .resizeAspect)
                        .frame(width: videoSize.width, height: videoSize.height)
                        .scaleEffect(CGFloat(zoomScale))
                        .offset(
                            x: clampedPan.width * canvasSize.width,
                            y: clampedPan.height * canvasSize.height
                        )
                }
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
                .simultaneousGesture(videoPanGesture(canvasSize: canvasSize, baseVideoSize: videoSize))
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(9.0 / 16.0, contentMode: .fit)

            VStack(spacing: 12) {
                Slider(
                    value: Binding(
                        get: { displayedTime },
                        set: { newValue in
                            let clampedValue = min(max(newValue, 0), sliderUpperBound)
                            scrubTime = clampedValue
                            currentTime = clampedValue

                            if isScrubbing {
                                seekInteractively(to: clampedValue)
                            }
                        }
                    ),
                    in: 0...sliderUpperBound,
                    onEditingChanged: handleScrubbingChanged
                )
                .tint(.white)
                .disabled(duration <= 0 || isWorking)

                playbackControls
            }
        }
        .onAppear {
            configurePlayer()
        }
        .onChange(of: fileURL) { _, _ in
            configurePlayer()
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
            guard notification.object as? AVPlayerItem === player.currentItem else { return }
            isPlaying = false
            currentTime = duration
            scrubTime = duration
        }
        .onDisappear {
            teardownPlayer()
        }
    }

    private var displayedTime: Double {
        isScrubbing ? scrubTime : currentTime
    }

    private var sliderUpperBound: Double {
        max(duration, 0.1)
    }

    private var playbackControls: some View {
        ViewThatFits {
            HStack(spacing: 10) {
                playPauseButton

                timeBadge

                cutPhotoButton
            }

            VStack(spacing: 10) {
                timeBadge

                HStack(spacing: 10) {
                    playPauseButton
                    cutPhotoButton
                }
            }
        }
    }

    private var playPauseButton: some View {
        Button {
            togglePlayback()
        } label: {
            Label(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(0.12))
                )
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
    }

    private var cutPhotoButton: some View {
        Button {
            onCutPhoto(displayedTime)
        } label: {
            Label(actionLabel, systemImage: actionSystemImage)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    Capsule()
                        .fill(Color(red: 0.22, green: 0.52, blue: 0.98).opacity(0.92))
                )
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
    }

    private var timeBadge: some View {
        Text("\(formattedTime(displayedTime)) / \(formattedTime(duration))")
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.76))
            .monospacedDigit()
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.08))
            )
    }

    private func configurePlayer() {
        teardownPlayer()
        duration = 0
        currentTime = 0
        scrubTime = 0
        isScrubbing = false
        isPlaying = false
        shouldResumeAfterScrub = false

        player.replaceCurrentItem(with: AVPlayerItem(url: fileURL))
        installTimeObserver()

        Task {
            await loadDuration()
        }
    }

    private func teardownPlayer() {
        player.pause()
        isPlaying = false

        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
    }

    private func installTimeObserver() {
        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            let seconds = CMTimeGetSeconds(time)
            guard seconds.isFinite else { return }

            Task { @MainActor in
                if !isScrubbing {
                    let clampedSeconds = min(max(seconds, 0), duration > 0 ? duration : seconds)
                    currentTime = clampedSeconds
                    scrubTime = clampedSeconds
                }
            }
        }
    }

    private func loadDuration() async {
        do {
            let asset = AVURLAsset(url: fileURL)
            let assetDuration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(assetDuration)
            guard seconds.isFinite else { return }

            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            if let sourceVideoTrack = videoTracks.first {
                let naturalSize = try await sourceVideoTrack.load(.naturalSize)
                let preferredTransform = try await sourceVideoTrack.load(.preferredTransform)
                let transformedRect = CGRect(origin: .zero, size: naturalSize)
                    .applying(preferredTransform)
                    .standardized
                let width = abs(transformedRect.width)
                let height = abs(transformedRect.height)

                if width > 0, height > 0 {
                    sourceAspectRatio = width / height
                }
            }

            duration = max(seconds, 0)
            currentTime = min(currentTime, duration)
            scrubTime = min(scrubTime, duration)
        } catch {
            duration = 0
            sourceAspectRatio = 9.0 / 16.0
        }
    }

    private func handleScrubbingChanged(_ editing: Bool) {
        guard duration > 0 else { return }

        if editing {
            isScrubbing = true
            shouldResumeAfterScrub = isPlaying
            player.pause()
            isPlaying = false
            scrubTime = currentTime
        } else {
            isScrubbing = false
            seek(to: scrubTime, resumeAfterSeek: shouldResumeAfterScrub)
            shouldResumeAfterScrub = false
        }
    }

    private func togglePlayback() {
        if isPlaying {
            player.pause()
            isPlaying = false
            return
        }

        if duration > 0, currentTime >= duration {
            seek(to: 0, resumeAfterSeek: true)
        } else {
            player.play()
            isPlaying = true
        }
    }

    private func seek(to seconds: Double, resumeAfterSeek: Bool) {
        let clampedSeconds = min(max(seconds, 0), duration > 0 ? duration : seconds)
        let time = CMTime(seconds: clampedSeconds, preferredTimescale: 600)

        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            Task { @MainActor in
                currentTime = clampedSeconds
                scrubTime = clampedSeconds

                if resumeAfterSeek {
                    player.play()
                    isPlaying = true
                } else {
                    isPlaying = false
                }
            }
        }
    }

    private func seekInteractively(to seconds: Double) {
        let clampedSeconds = min(max(seconds, 0), duration > 0 ? duration : seconds)
        let time = CMTime(seconds: clampedSeconds, preferredTimescale: 600)
        let tolerance = CMTime(seconds: 1.0 / 60.0, preferredTimescale: 600)
        player.currentItem?.cancelPendingSeeks()
        player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance)
    }

    private func videoFillSize(for canvasSize: CGSize) -> CGSize {
        let targetAspectRatio = canvasSize.width / max(canvasSize.height, 1)
        if sourceAspectRatio > targetAspectRatio {
            return CGSize(width: canvasSize.height * sourceAspectRatio, height: canvasSize.height)
        }
        return CGSize(width: canvasSize.width, height: canvasSize.width / max(sourceAspectRatio, 0.01))
    }

    private func clampedPanOffset(for canvasSize: CGSize, videoSize: CGSize) -> CGSize {
        let scaledWidth = videoSize.width * CGFloat(zoomScale)
        let scaledHeight = videoSize.height * CGFloat(zoomScale)
        let maxOffsetX = max(0, (scaledWidth - canvasSize.width) / 2) / max(canvasSize.width, 1)
        let maxOffsetY = max(0, (scaledHeight - canvasSize.height) / 2) / max(canvasSize.height, 1)

        return CGSize(
            width: min(max(panOffset.width, -maxOffsetX), maxOffsetX),
            height: min(max(panOffset.height, -maxOffsetY), maxOffsetY)
        )
    }

    private func videoPanGesture(canvasSize: CGSize, baseVideoSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard !isWorking else { return }

                if !isDraggingVideo {
                    let intent = resolvedMediaPanIntent(for: value.translation, zoomScale: zoomScale)
                    videoPanIntent = intent

                    guard intent == .panning else { return }
                    dragStartPan = panOffset
                    isDraggingVideo = true
                }

                guard videoPanIntent == .panning else { return }

                let startOffset = dragStartPan
                let proposed = CGSize(
                    width: startOffset.width + (value.translation.width / max(canvasSize.width, 1)),
                    height: startOffset.height + (value.translation.height / max(canvasSize.height, 1))
                )
                panOffset = clampedPanOffset(
                    proposed,
                    canvasSize: canvasSize,
                    baseVideoSize: baseVideoSize
                )
            }
            .onEnded { _ in
                defer {
                    dragStartPan = .zero
                    isDraggingVideo = false
                    videoPanIntent = .undecided
                }

                guard videoPanIntent == .panning else { return }
                panOffset = clampedPanOffset(
                    panOffset,
                    canvasSize: canvasSize,
                    baseVideoSize: baseVideoSize
                )
            }
    }

    private func clampedPanOffset(_ proposed: CGSize, canvasSize: CGSize, baseVideoSize: CGSize) -> CGSize {
        let scaledWidth = baseVideoSize.width * CGFloat(zoomScale)
        let scaledHeight = baseVideoSize.height * CGFloat(zoomScale)
        let maxOffsetX = max(0, (scaledWidth - canvasSize.width) / 2) / max(canvasSize.width, 1)
        let maxOffsetY = max(0, (scaledHeight - canvasSize.height) / 2) / max(canvasSize.height, 1)

        return CGSize(
            width: min(max(proposed.width, -maxOffsetX), maxOffsetX),
            height: min(max(proposed.height, -maxOffsetY), maxOffsetY)
        )
    }

    private func formattedTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "00:00" }

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

private struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    let videoGravity: AVLayerVideoGravity

    func makeUIView(context: Context) -> PlayerSurfaceView {
        let view = PlayerSurfaceView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = videoGravity
        return view
    }

    func updateUIView(_ uiView: PlayerSurfaceView, context: Context) {
        uiView.playerLayer.player = player
        uiView.playerLayer.videoGravity = videoGravity
    }
}

private final class PlayerSurfaceView: UIView {
    override class var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private struct OverlayInputPopup: View {
    let mode: OverlayInputMode
    @Binding var text: String
    @FocusState.Binding var focusedField: ContentTextFocusField?
    let onClose: () -> Void
    let onApply: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.44)
                .ignoresSafeArea()
                .onTapGesture {
                    onClose()
                }

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Text(titleText)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Spacer(minLength: 8)

                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(
                                Circle()
                                    .fill(Color.white.opacity(0.10))
                            )
                    }
                    .buttonStyle(.plain)
                }

                TextField(
                    "",
                    text: $text,
                    prompt: Text(promptText).foregroundStyle(Color.white.opacity(0.34))
                )
                .textInputAutocapitalization(mode == .text ? .sentences : .never)
                .autocorrectionDisabled()
                .focused($focusedField, equals: focusField)
                .submitLabel(.done)
                .foregroundStyle(.white)
                .tint(.white)
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
                .onSubmit {
                    onApply()
                }

                HStack(spacing: 10) {
                    Button {
                        onClose()
                    } label: {
                        Text("Close")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(Color.white.opacity(0.08))
                            )
                    }
                    .buttonStyle(.plain)

                    Button {
                        onApply()
                    } label: {
                        Text(mode == .text ? "Add Text" : "Add Emoji")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(Color(red: 0.22, green: 0.52, blue: 0.98).opacity(0.92))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(18)
            .frame(maxWidth: 360)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Color(red: 0.11, green: 0.13, blue: 0.24))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .padding(.horizontal, 24)
        }
        .onAppear {
            DispatchQueue.main.async {
                focusedField = focusField
            }
        }
    }

    private var titleText: String {
        switch mode {
        case .text:
            return "Add Text"
        case .emoji:
            return "Add Emoji"
        }
    }

    private var promptText: String {
        switch mode {
        case .text:
            return "Type text on video"
        case .emoji:
            return "Type emoji"
        }
    }

    private var focusField: ContentTextFocusField {
        switch mode {
        case .text:
            return .editorText
        case .emoji:
            return .editorEmoji
        }
    }
}

private struct ClipTimelineStrip: View {
    let clips: [EditorClip]
    @Binding var selectedClipID: EditorClip.ID?
    @Binding var playheadTime: Double
    @Binding var zoomLevel: Double
    @Binding var draggedClipID: EditorClip.ID?
    let isBusy: Bool
    let onReorder: (EditorClip.ID, EditorClip.ID) -> Void
    let onScrub: (EditorClip, Double, Bool) -> Void
    let onRemove: (EditorClip) -> Void

    @State private var timelinePinchStartZoom = 1.0
    @State private var isPinchingTimeline = false
    @State private var reorderVisualOffset = CGSize.zero
    @State private var isDragOverTrash = false
    @State private var isShowingTrash = false
    @State private var dragPreviewLocation: CGPoint?
    @State private var dragTranslation = CGSize.zero

    private let clipSpacing: CGFloat = 8
    private var clampedZoomLevel: CGFloat { CGFloat(min(max(zoomLevel, 0.72), 0.96)) }
    private var cardWidth: CGFloat { 34 * clampedZoomLevel }
    private var cardHeight: CGFloat { 52 * clampedZoomLevel }
    private var trashWidth: CGFloat { 78 }
    private var trashHeight: CGFloat { 48 }
    private var dragLiftHeight: CGFloat { draggedClipID == nil ? 0 : 18 }
    private var draggedClip: EditorClip? {
        guard let draggedClipID else { return nil }
        return clips.first(where: { $0.id == draggedClipID })
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                VStack(spacing: isShowingTrash ? 8 : 0) {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: clipSpacing) {
                                ForEach(Array(clips.enumerated()), id: \.element.id) { index, clip in
                                    TimelineClipCard(
                                        clip: clip,
                                        index: index + 1,
                                        cardWidth: cardWidth,
                                        cardHeight: cardHeight,
                                        isSelected: selectedClipID == clip.id,
                                        isDragging: false,
                                        dragOffset: .zero,
                                        liftHeight: dragLiftHeight,
                                        isHiddenDuringDrag: draggedClipID == clip.id
                                    )
                                    .id(clip.id)
                                    .onTapGesture {
                                        selectClip(clip, isInteractive: false)
                                    }
                                    .simultaneousGesture(reorderGesture(for: clip, in: geometry.size))
                                }
                            }
                            .padding(.horizontal, 2)
                            .padding(.top, dragLiftHeight)
                            .frame(maxHeight: .infinity, alignment: .topLeading)
                        }
                        .frame(maxWidth: .infinity, maxHeight: cardHeight + dragLiftHeight + 2, alignment: .topLeading)
                        .simultaneousGesture(timelineMagnificationGesture())
                        .onAppear {
                            scrollToSelection(with: proxy, animated: false)
                            scrubSelectedClip()
                        }
                        .onChange(of: selectedClipID) { _, _ in
                            scrubSelectedClip()
                        }
                    }

                    if isShowingTrash {
                        timelineTrashView
                            .frame(width: trashWidth, height: trashHeight)
                            .transition(.scale.combined(with: .opacity))
                    }
                }

                if let draggedClip {
                    floatingDraggedClipPreview(for: draggedClip, in: geometry.size)
                }
            }
            .animation(.easeInOut(duration: 0.16), value: isShowingTrash)
            .coordinateSpace(name: "timeline-strip")
        }
        .frame(height: cardHeight + dragLiftHeight + (isShowingTrash ? trashHeight + 10 : 0), alignment: .top)
        .opacity(isBusy ? 0.92 : 1)
    }

    private func timelineMagnificationGesture() -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard !isBusy, draggedClipID == nil else { return }
                let startZoom = isPinchingTimeline ? timelinePinchStartZoom : zoomLevel
                timelinePinchStartZoom = startZoom
                isPinchingTimeline = true
                zoomLevel = min(max(startZoom * value.magnification, 0.78), 1.02)
            }
            .onEnded { _ in
                timelinePinchStartZoom = zoomLevel
                isPinchingTimeline = false
            }
    }

    private func reorderGesture(for clip: EditorClip, in containerSize: CGSize) -> some Gesture {
        LongPressGesture(minimumDuration: 0.55, maximumDistance: 12)
            .sequenced(before: DragGesture(minimumDistance: 8, coordinateSpace: .named("timeline-strip")))
            .onChanged { value in
                guard !isBusy else { return }

                switch value {
                case .first(true):
                    if draggedClipID != clip.id {
                        draggedClipID = clip.id
                        reorderVisualOffset = .zero
                        dragTranslation = .zero
                        isDragOverTrash = false
                        isShowingTrash = true
                        dragPreviewLocation = CGPoint(
                            x: (cardWidth / 2) + 8,
                            y: (cardHeight / 2) + dragLiftHeight + 6
                        )
                    }
                case .second(true, let drag?):
                    if draggedClipID != clip.id {
                        draggedClipID = clip.id
                        reorderVisualOffset = .zero
                        dragTranslation = .zero
                        isShowingTrash = true
                    }

                    let deltaX = drag.translation.width
                    let deltaY = drag.translation.height
                    dragTranslation = drag.translation
                    dragPreviewLocation = drag.location
                    reorderVisualOffset = CGSize(
                        width: deltaX,
                        height: deltaY
                    )
                    isDragOverTrash = trashFrame(in: containerSize).contains(drag.location)
                default:
                    break
                }
            }
            .onEnded { _ in
                if isDragOverTrash {
                    onRemove(clip)
                } else if let targetClipID = dropTargetClipID(for: clip, translation: dragTranslation),
                          targetClipID != clip.id {
                    onReorder(clip.id, targetClipID)
                }

                draggedClipID = nil
                reorderVisualOffset = .zero
                dragTranslation = .zero
                isDragOverTrash = false
                isShowingTrash = false
                dragPreviewLocation = nil
            }
    }

    @ViewBuilder
    private func floatingDraggedClipPreview(for clip: EditorClip, in size: CGSize) -> some View {
        let point = dragPreviewLocation ?? CGPoint(
            x: (cardWidth / 2) + 6,
            y: (cardHeight / 2) + dragLiftHeight + 6
        )
        let previewX = min(max(point.x, (cardWidth / 2) + 8), max(size.width - (cardWidth / 2) - 8, (cardWidth / 2) + 8))
        let previewY = max((cardHeight / 2) + 2, point.y - (cardHeight * 1.95) - 10)

        TimelineClipCard(
            clip: clip,
            index: (clips.firstIndex(where: { $0.id == clip.id }) ?? 0) + 1,
            cardWidth: cardWidth,
            cardHeight: cardHeight,
            isSelected: true,
            isDragging: true,
            dragOffset: .zero,
            liftHeight: 0,
            isHiddenDuringDrag: false
        )
        .position(x: previewX, y: previewY)
        .allowsHitTesting(false)
        .zIndex(100)
    }

    private func dropTargetClipID(for clip: EditorClip, translation: CGSize) -> EditorClip.ID? {
        guard let currentIndex = clips.firstIndex(where: { $0.id == clip.id }) else { return nil }
        let stepWidth = max(cardWidth + clipSpacing, 1)
        let shift = Int((translation.width / stepWidth).rounded())
        let targetIndex = min(max(currentIndex + shift, 0), clips.count - 1)
        return clips[targetIndex].id
    }

    private func trashFrame(in size: CGSize) -> CGRect {
        CGRect(
            x: max((size.width - trashWidth) / 2, 0),
            y: max(size.height - trashHeight - 2, 0),
            width: trashWidth,
            height: trashHeight
        )
    }

    private var timelineTrashView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(isDragOverTrash ? Color.red.opacity(0.88) : Color.white.opacity(0.10))

            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(
                    isDragOverTrash ? Color.red.opacity(0.95) : Color.white.opacity(0.12),
                    lineWidth: 1
                )

            VStack(spacing: 4) {
                Image(systemName: isDragOverTrash ? "trash.fill" : "trash")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)

                Text(isDragOverTrash ? "Drop" : "Trash")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .shadow(
            color: isDragOverTrash ? Color.red.opacity(0.22) : Color.black.opacity(0.16),
            radius: 12,
            x: 0,
            y: 6
        )
    }

    private func scrubSelectedClip() {
        guard let clip = clips.first(where: { $0.id == (selectedClipID ?? clips.first?.id) }) ?? clips.first else {
            return
        }

        if selectedClipID != clip.id {
            selectedClipID = clip.id
        }
        playheadTime = startTime(for: clip.id)
        onScrub(clip, 0, false)
    }

    private func selectClip(_ clip: EditorClip, isInteractive: Bool) {
        selectedClipID = clip.id
        playheadTime = startTime(for: clip.id)
        onScrub(clip, 0, isInteractive)
    }

    private func startTime(for clipID: EditorClip.ID) -> Double {
        var runningTime = 0.0

        for clip in clips {
            if clip.id == clipID {
                return runningTime
            }
            runningTime += max(clip.duration, 0)
        }

        return 0
    }

    private func scrollToSelection(with proxy: ScrollViewProxy, animated: Bool = true) {
        guard let selectedID = selectedClipID ?? clips.first?.id else { return }

        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeInOut(duration: 0.18)) {
                    proxy.scrollTo(selectedID, anchor: .center)
                }
            } else {
                proxy.scrollTo(selectedID, anchor: .center)
            }
        }
    }
}

private struct TimelineClipCard: View {
    let clip: EditorClip
    let index: Int
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    let isSelected: Bool
    let isDragging: Bool
    let dragOffset: CGSize
    let liftHeight: CGFloat
    let isHiddenDuringDrag: Bool

    var body: some View {
        ZStack {
            VideoThumbnailView(fileURL: clip.fileURL)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topLeading) {
                    Text("\(index)")
                        .font(.system(size: 6, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(width: 12, height: 12)
                        .background(
                            Circle()
                                .fill(Color.black.opacity(0.54))
                        )
                        .padding(2)
                }
                .overlay(alignment: .bottomTrailing) {
                    Text(formattedTime(clip.duration))
                        .font(.system(size: 6, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(
                            Capsule()
                                .fill(Color.black.opacity(0.54))
                        )
                        .padding(2)
                }
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(
                            isSelected ? Color.white : Color.white.opacity(0.22),
                            lineWidth: isSelected ? 2.2 : 1
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(
                            Color.white.opacity(isSelected ? 0.32 : 0.08),
                            lineWidth: 0.8
                        )
                )
        }
        .frame(width: cardWidth, height: cardHeight)
        .offset(x: dragOffset.width, y: dragOffset.height - (isDragging ? liftHeight : 0))
        .scaleEffect(isDragging ? 1.14 : 1)
        .opacity(isHiddenDuringDrag ? 0.001 : 1)
        .zIndex(isDragging ? 20 : (isSelected ? 1 : 0))
        .shadow(
            color: isDragging ? Color.black.opacity(0.26) : (isSelected ? Color.white.opacity(0.18) : .clear),
            radius: isDragging ? 18 : 14,
            x: 0,
            y: isDragging ? 12 : 8
        )
    }

    private func formattedTime(_ seconds: Double) -> String {
        let totalSeconds = max(Int(seconds.rounded(.down)), 0)
        let minutes = totalSeconds / 60
        let secs = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, secs)
    }
}

private struct VideoThumbnailView: View {
    let fileURL: URL

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.82),
                            Color(red: 0.08, green: 0.10, blue: 0.18).opacity(0.92)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            if let image {
                GeometryReader { geometry in
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "video.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.74))

                    ProgressView()
                        .tint(.white)
                        .scaleEffect(0.8)
                }
            }
        }
        .clipped()
        .task(id: fileURL) {
            image = await loadThumbnail()
        }
    }

    private func loadThumbnail() async -> UIImage? {
        let asset = AVURLAsset(url: fileURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 280, height: 280)

        do {
            let cgImage = try generator.copyCGImage(at: .zero, actualTime: nil)
            return UIImage(cgImage: cgImage)
        } catch {
            return nil
        }
    }
}

private struct AIChatMediaPicker: UIViewControllerRepresentable {
    let selectionLimit: Int
    let onComplete: ([URL]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .any(of: [.images, .videos])
        configuration.selectionLimit = selectionLimit

        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let onComplete: ([URL]) -> Void

        init(onComplete: @escaping ([URL]) -> Void) {
            self.onComplete = onComplete
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)

            guard !results.isEmpty else {
                onComplete([])
                return
            }

            Task {
                let urls = await loadMediaURLs(from: results)
                await MainActor.run {
                    onComplete(urls)
                }
            }
        }

        private func loadMediaURLs(from results: [PHPickerResult]) async -> [URL] {
            var urls: [URL] = []
            urls.reserveCapacity(results.count)

            for result in results {
                if let url = await loadMediaURL(from: result.itemProvider) {
                    urls.append(url)
                }
            }

            return urls
        }

        private func loadMediaURL(from provider: NSItemProvider) async -> URL? {
            if let videoURL = await Self.copyPickedVideo(from: provider) {
                return videoURL
            }

            if let imageURL = await Self.copyPickedImage(from: provider) {
                return imageURL
            }

            return nil
        }

        private static func copyPickedVideo(from provider: NSItemProvider) async -> URL? {
            let supportedTypeIdentifiers = [
                UTType.movie.identifier,
                UTType.mpeg4Movie.identifier,
                UTType.quickTimeMovie.identifier
            ]

            guard let typeIdentifier = supportedTypeIdentifiers.first(where: { provider.hasItemConformingToTypeIdentifier($0) }) else {
                return nil
            }

            return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
                provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
                    guard let url else {
                        continuation.resume(returning: nil)
                        return
                    }

                    continuation.resume(
                        returning: copyPickedFile(
                            from: url,
                            preferredExtension: url.pathExtension.isEmpty ? "mov" : url.pathExtension,
                            preferredName: provider.suggestedName
                        )
                    )
                }
            }
        }

        private static func copyPickedImage(from provider: NSItemProvider) async -> URL? {
            let preferredTypes = [
                UTType.png,
                UTType.jpeg,
                UTType.heic,
                UTType.gif,
                UTType.image
            ]

            guard let selectedType = preferredTypes.first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) else {
                return nil
            }

            if let fileURL = await withCheckedContinuation({ (continuation: CheckedContinuation<URL?, Never>) in
                provider.loadFileRepresentation(forTypeIdentifier: selectedType.identifier) { url, _ in
                    continuation.resume(returning: url)
                }
            }) {
                return copyPickedFile(
                    from: fileURL,
                    preferredExtension: fileURL.pathExtension.isEmpty ? (selectedType.preferredFilenameExtension ?? "jpg") : fileURL.pathExtension,
                    preferredName: provider.suggestedName
                )
            }

            return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
                provider.loadDataRepresentation(forTypeIdentifier: selectedType.identifier) { data, _ in
                    guard let data else {
                        continuation.resume(returning: nil)
                        return
                    }

                    continuation.resume(
                        returning: copyPickedData(
                            data,
                            fileExtension: selectedType.preferredFilenameExtension ?? "jpg",
                            preferredName: provider.suggestedName
                        )
                    )
                }
            }
        }

        nonisolated private static func copyPickedFile(from sourceURL: URL, preferredExtension: String, preferredName: String? = nil) -> URL? {
            let tempDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("soranin-ai-chat-picker", isDirectory: true)

            do {
                if !FileManager.default.fileExists(atPath: tempDirectory.path) {
                    try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
                }

                let suggestedStem = sanitizedPickedMediaStem(preferredName)
                let destinationURL = tempDirectory
                    .appendingPathComponent("\(suggestedStem)-\(UUID().uuidString.prefix(8))")
                    .appendingPathExtension(preferredExtension)

                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }

                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                return destinationURL
            } catch {
                return nil
            }
        }

        nonisolated private static func copyPickedData(_ data: Data, fileExtension: String, preferredName: String? = nil) -> URL? {
            let tempDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("soranin-ai-chat-picker", isDirectory: true)

            do {
                if !FileManager.default.fileExists(atPath: tempDirectory.path) {
                    try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
                }

                let suggestedStem = sanitizedPickedMediaStem(preferredName)
                let destinationURL = tempDirectory
                    .appendingPathComponent("\(suggestedStem)-\(UUID().uuidString.prefix(8))")
                    .appendingPathExtension(fileExtension)

                try data.write(to: destinationURL, options: .atomic)
                return destinationURL
            } catch {
                return nil
            }
        }

        nonisolated private static func sanitizedPickedMediaStem(_ suggestedName: String?) -> String {
            let baseName = ((suggestedName ?? "") as NSString).deletingPathExtension
            let cleaned = baseName
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: #"[^A-Za-z0-9 _.-]+"#, with: "-", options: .regularExpression)
                .replacingOccurrences(of: #"\s+"#, with: "-", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-._ "))

            return cleaned.isEmpty ? "chat-media" : cleaned
        }
    }
}

private struct PhotoVideoPicker: UIViewControllerRepresentable {
    let selectionLimit: Int
    let onComplete: ([URL]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .videos
        configuration.selectionLimit = selectionLimit

        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let onComplete: ([URL]) -> Void

        init(onComplete: @escaping ([URL]) -> Void) {
            self.onComplete = onComplete
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)

            guard !results.isEmpty else {
                onComplete([])
                return
            }

            Task {
                let urls = await loadVideoURLs(from: results)
                await MainActor.run {
                    onComplete(urls)
                }
            }
        }

        private func loadVideoURLs(from results: [PHPickerResult]) async -> [URL] {
            var urls: [URL] = []
            urls.reserveCapacity(results.count)

            for result in results {
                if let url = await Self.copyPickedVideo(from: result.itemProvider) {
                    urls.append(url)
                }
            }

            return urls
        }

        private static func copyPickedVideo(from provider: NSItemProvider) async -> URL? {
            let supportedTypeIdentifiers = [
                UTType.movie.identifier,
                UTType.mpeg4Movie.identifier,
                UTType.quickTimeMovie.identifier
            ]

            guard let typeIdentifier = supportedTypeIdentifiers.first(where: { provider.hasItemConformingToTypeIdentifier($0) }) else {
                return nil
            }

            return await withCheckedContinuation { continuation in
                provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
                    guard let url else {
                        continuation.resume(returning: nil)
                        return
                    }

                    let tempDirectory = FileManager.default.temporaryDirectory
                        .appendingPathComponent("soranin-photo-picker", isDirectory: true)

                    do {
                        if !FileManager.default.fileExists(atPath: tempDirectory.path) {
                            try FileManager.default.createDirectory(
                                at: tempDirectory,
                                withIntermediateDirectories: true
                            )
                        }

                        let fileExtension = url.pathExtension.isEmpty ? "mov" : url.pathExtension
                        let destinationURL = tempDirectory
                            .appendingPathComponent(UUID().uuidString)
                            .appendingPathExtension(fileExtension)

                        if FileManager.default.fileExists(atPath: destinationURL.path) {
                            try FileManager.default.removeItem(at: destinationURL)
                        }

                        try FileManager.default.copyItem(at: url, to: destinationURL)
                        continuation.resume(returning: destinationURL)
                    } catch {
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
    }
}

private struct MacControlSheet: View {
    let isKhmer: Bool
    @Binding var serverURL: String
    @Binding var password: String
    @Binding var chromeName: String
    @Binding var pageName: String
    @Binding var folders: String
    @Binding var manualLinkInput: String
    @Binding var intervalMinutes: Int
    @Binding var closeAfterEach: Bool
    @Binding var closeAfterFinish: Bool
    @Binding var postNowAdvanceSlot: Bool
    let isLoading: Bool
    let profiles: [String]
    let macDisplayName: String
    let macDeviceName: String
    let macUserName: String
    let isOnline: Bool
    let liveStatusText: String
    let liveProgress: Double
    let liveProgressLabel: String
    let packages: [MacControlPackageCard]
    let selectedPackageIDs: Set<String>
    let uploadVideoProgress: Double
    let thumbnailURLForPackage: (MacControlPackageCard) -> URL?
    let resultMessage: String
    let onClose: () -> Void
    let onLoad: () -> Void
    let onScan: () -> Void
    let onSendCurrentInput: () -> Void
    let onSendManualLink: () -> Void
    let onUploadVideoToMac: () -> Void
    let onTogglePackage: (MacControlPackageCard) -> Void
    let onAddSelectedPackages: () -> Void
    let onRefreshPackages: () -> Void
    let onDeletePackage: (MacControlPackageCard) -> Void
    let onPreflight: () -> Void
    let onRun: () -> Void
    let onQuitChrome: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    sectionCard(title: tr("Mac Server", "Mac Server"), subtitle: tr("Use Scan Mac (Wi-Fi Fast) when you are nearby, or use Remote Mac with Relay / Tailscale when you are away. If one path is unavailable, Soranin switches to the other automatically.", "ប្រើ Scan Mac (Wi‑Fi Fast) ពេលនៅជិតគ្នា ឬប្រើ Remote Mac ជាមួយ Relay / Tailscale ពេលនៅឆ្ងាយ។ បើមួយណាមិនមាន Soranin នឹងប្តូរទៅមួយទៀតអោយស្វ័យប្រវត្តិ។")) {
                        VStack(alignment: .leading, spacing: 12) {
                            if !macDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 8) {
                                        Text(tr("Connected Mac", "Mac ដែលបានភ្ជាប់"))
                                            .font(.system(size: 12, weight: .bold, design: .rounded))
                                            .foregroundStyle(Color.white.opacity(0.7))
                                        Spacer(minLength: 0)
                                        HStack(spacing: 6) {
                                            Circle()
                                                .fill(isOnline ? Color.green : Color.red.opacity(0.9))
                                                .frame(width: 8, height: 8)
                                            Text(isOnline ? tr("Online", "Online") : tr("Offline", "Offline"))
                                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                                .foregroundStyle(.white)
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background((isOnline ? Color.green : Color.red).opacity(0.18), in: Capsule())
                                    }
                                    Text(macDisplayName)
                                        .font(.system(size: 16, weight: .bold, design: .rounded))
                                        .foregroundStyle(.white)
                                    if !macDeviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !macUserName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        Text([
                                            macDeviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : macDeviceName,
                                            macUserName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : "@\(macUserName)"
                                        ]
                                        .compactMap { $0 }
                                        .joined(separator: " • "))
                                        .font(.system(size: 12, weight: .medium, design: .rounded))
                                        .foregroundStyle(Color.white.opacity(0.62))
                                    }
                                    if !liveStatusText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        Text(liveStatusText)
                                            .font(.system(size: 12, weight: .medium, design: .rounded))
                                            .foregroundStyle(Color.white.opacity(0.84))
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    if liveProgress > 0 {
                                        VStack(alignment: .leading, spacing: 6) {
                                            HStack {
                                                Text(liveProgressLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? tr("Mac Progress", "ដំណើរការ Mac") : liveProgressLabel)
                                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                                    .foregroundStyle(Color.white.opacity(0.74))
                                                    .lineLimit(2)
                                                Spacer()
                                                Text("\(Int((liveProgress * 100).rounded()))%")
                                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                                    .foregroundStyle(.white)
                                            }
                                            ProgressView(value: liveProgress, total: 1)
                                                .tint(Color.green)
                                                .progressViewStyle(.linear)
                                        }
                                    }
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                )
                            }

                            TextField(tr("Server URL", "Server URL"), text: $serverURL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                            SecureField(tr("Mac Password (optional)", "ពាក្យសម្ងាត់ Mac (optional)"), text: $password)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                            Text(tr("Same Wi-Fi: tap Scan Mac (Wi-Fi Fast + Cards). Different Wi-Fi or cellular: paste the Relay or Tailscale URL, then tap Remote Mac + Cards. If one path fails, the other is tried automatically.", "Wi‑Fi ដូចគ្នា៖ ចុច Scan Mac (Wi‑Fi Fast + Cards)។ Wi‑Fi ផ្សេង ឬ cellular៖ បិទភ្ជាប់ Relay ឬ Tailscale URL រួចចុច Remote Mac + Cards។ បើមួយណាមិនបាន វានឹងសាកមួយទៀតអោយស្វ័យប្រវត្តិ។"))
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.white.opacity(0.62))

                            HStack(spacing: 10) {
                                actionButton(
                                    title: tr("Scan Mac (Wi-Fi Fast + Cards)", "ស្កេន Mac (Wi‑Fi Fast + Cards)"),
                                    systemImage: "dot.radiowaves.left.and.right",
                                    isPrimary: false,
                                    action: onScan
                                )
                                actionButton(
                                    title: tr("Remote Mac + Cards", "Remote Mac + Cards"),
                                    systemImage: "arrow.clockwise",
                                    isPrimary: true,
                                    action: onLoad
                                )
                                actionButton(
                                    title: tr("Quit Chrome", "បិទ Chrome"),
                                    systemImage: "xmark.circle",
                                    isPrimary: false,
                                    action: onQuitChrome
                                )
                            }
                        }
                    }

                    sectionCard(title: tr("Facebook Post", "Facebook Post"), subtitle: tr("Choose Chrome + Page + folders to run on Mac.", "ជ្រើស Chrome + Page + folders ដើម្បីអោយ Mac រត់។")) {
                        VStack(alignment: .leading, spacing: 12) {
                            if !profiles.isEmpty {
                                Menu {
                                    ForEach(profiles, id: \.self) { name in
                                        Button(name) {
                                            chromeName = name
                                        }
                                    }
                                } label: {
                                    HStack {
                                        Label(tr("Choose Chrome Profile", "ជ្រើស Chrome Profile"), systemImage: "person.crop.square")
                                        Spacer()
                                        Image(systemName: "chevron.down")
                                    }
                                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 12)
                                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                }
                            }

                            fieldLabel(tr("Chrome Name", "Chrome Name"))
                            TextField(tr("Chrome profile name", "ឈ្មោះ Chrome profile"), text: $chromeName)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                            fieldLabel(tr("Facebook Page", "Facebook Page"))
                            TextField(tr("Page name", "ឈ្មោះ Page"), text: $pageName)
                                .textInputAutocapitalization(.words)
                                .autocorrectionDisabled()
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                            fieldLabel(tr("Folders", "Folders"))
                            ZStack(alignment: .topLeading) {
                                TextEditor(text: $folders)
                                    .frame(minHeight: 92)
                                    .scrollContentBackground(.hidden)
                                    .padding(8)
                                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                if folders.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text(tr("Example: 25_Reels_Package 26_Reels_Package", "ឧទាហរណ៍៖ 25_Reels_Package 26_Reels_Package"))
                                        .font(.system(size: 14, weight: .medium, design: .rounded))
                                        .foregroundStyle(Color.white.opacity(0.38))
                                        .padding(.horizontal, 20)
                                        .padding(.vertical, 20)
                                        .allowsHitTesting(false)
                                }
                            }

                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 6) {
                                    fieldLabel(tr("Interval", "ចន្លោះម៉ោង"))
                                    Stepper(value: $intervalMinutes, in: 5 ... 240, step: 5) {
                                        Text("\(max(intervalMinutes, 5)) min")
                                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                                            .foregroundStyle(.white)
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 12)
                                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                }
                                Spacer(minLength: 0)
                            }

                            Toggle(isOn: $closeAfterEach) {
                                toggleLabel(tr("Close Chrome after each", "បិទ Chrome រាល់ folder"), subtitle: tr("Quit Chrome after every post/schedule.", "បិទ Chrome រាល់ពេល post/schedule ចប់។"))
                            }
                            .toggleStyle(SwitchToggleStyle(tint: Color.cyan))

                            Toggle(isOn: $closeAfterFinish) {
                                toggleLabel(tr("Close Chrome when done", "បិទ Chrome ពេលចប់"), subtitle: tr("Quit Chrome after the final folder.", "បិទ Chrome ពេល folder ចុងក្រោយចប់។"))
                            }
                            .toggleStyle(SwitchToggleStyle(tint: Color.cyan))

                            Toggle(isOn: $postNowAdvanceSlot) {
                                toggleLabel(tr("Post now + move queue", "Post now ហើយរុញម៉ោង"), subtitle: tr("Use post now but keep the saved queue moving forward.", "ប្រើ post now ប៉ុន្តែរក្សា queue ម៉ោងអោយទៅមុខ។"))
                            }
                            .toggleStyle(SwitchToggleStyle(tint: Color.cyan))
                        }
                    }

                    sectionCard(title: tr("Select From App Cards", "ជ្រើសពី App Cards"), subtitle: tr("These cards load from the connected Mac only. Tap cards to select folders, or delete a package on the Mac.", "cards ទាំងនេះទាញពី Mac ដែលបានភ្ជាប់ប៉ុណ្ណោះ។ ចុច card ដើម្បីជ្រើស folder ឬលុប package លើ Mac។")) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("\(packages.count)")
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.white.opacity(0.10), in: Capsule())
                                Spacer()
                                Button(tr("Refresh", "Refresh")) {
                                    onRefreshPackages()
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(Color.white.opacity(0.08), in: Capsule())
                                    .disabled(isLoading)
                            }

                            Text(tr("Tap a card to auto add its folder to the Folders box. Tap again to remove it automatically.", "ចុច card ដើម្បីបញ្ចូល folder ទៅក្នុង Folders box ស្វ័យប្រវត្តិ។ ចុចម្តងទៀតដើម្បីដកចេញវិញស្វ័យប្រវត្តិ។"))
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.white.opacity(0.66))

                            if packages.isEmpty {
                                Text(tr("No package cards loaded yet. Connect to Mac first. Cards should auto-load; use Refresh only if you want to reload them.", "មិនទាន់មាន package cards នៅឡើយទេ។ សូមភ្ជាប់ទៅ Mac ជាមុនសិន។ cards គួរតែ load ស្វ័យប្រវត្តិ ហើយប្រើ Refresh តែពេលចង់ reload ប៉ុណ្ណោះ។"))
                                    .font(.system(size: 13, weight: .medium, design: .rounded))
                                    .foregroundStyle(Color.white.opacity(0.64))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 8)
                            } else {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 12)], spacing: 12) {
                                    ForEach(packages) { item in
                                        macPackageCard(item)
                                    }
                                }
                            }
                        }
                    }

                    sectionCard(title: tr("Quick Actions", "Quick Actions"), subtitle: tr("Send links to Mac only, pick a video from this iPhone for Mac Drop Videos, or run Facebook posting.", "ផ្ញើ link ទៅ Mac ប៉ុណ្ណោះ, ជ្រើស video ពី iPhone នេះទៅ Drop Videos លើ Mac, ឬរត់ Facebook posting។")) {
                        VStack(alignment: .leading, spacing: 12) {
                            fieldLabel(tr("Send Sora link to Mac only", "ផ្ញើ Sora link ទៅ Mac ប៉ុណ្ណោះ"))
                            ZStack(alignment: .topLeading) {
                                TextEditor(text: $manualLinkInput)
                                    .frame(minHeight: 76)
                                    .scrollContentBackground(.hidden)
                                    .padding(8)
                                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                if manualLinkInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text(tr("Paste one Sora link or ID here. It will send to Mac only, not download on this iPhone.", "paste Sora link ឬ ID មួយនៅទីនេះ។ វានឹងផ្ញើទៅ Mac ប៉ុណ្ណោះ មិន download លើ iPhone នេះទេ។"))
                                        .font(.system(size: 14, weight: .medium, design: .rounded))
                                        .foregroundStyle(Color.white.opacity(0.38))
                                        .padding(.horizontal, 20)
                                        .padding(.vertical, 20)
                                        .allowsHitTesting(false)
                                }
                            }

                            Button {
                                onSendManualLink()
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "link")
                                    Text(tr("Send Link to Mac Only", "ផ្ញើ Link ទៅ Mac ប៉ុណ្ណោះ"))
                                }
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .fill(
                                            LinearGradient(
                                                colors: [Color.orange.opacity(0.94), Color.pink.opacity(0.88)],
                                                startPoint: .leading,
                                                endPoint: .trailing
                                            )
                                        )
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(isLoading || manualLinkInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .opacity((isLoading || manualLinkInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ? 0.5 : 1)

                            VStack(alignment: .leading, spacing: 6) {
                                Text(tr("Pick video from this iPhone for Mac Drop Videos", "ជ្រើស video ពី iPhone នេះទៅ Drop Videos លើ Mac"))
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                    .foregroundStyle(Color.white.opacity(0.68))
                                Text(
                                    tr(
                                        "Pick a video from this iPhone and Soranin will upload it straight into Drop Videos / Sora source videos on the connected Mac.",
                                        "ជ្រើស video មួយពី iPhone នេះ ហើយ Soranin នឹង upload វាទៅ Drop Videos / Sora source videos លើ Mac ដែលបានភ្ជាប់ដោយផ្ទាល់។"
                                    )
                                )
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                                .fixedSize(horizontal: false, vertical: true)
                            }

                            if uploadVideoProgress > 0, uploadVideoProgress < 1 {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(tr("Upload progress", "ដំណើរការ upload"))
                                            .font(.system(size: 12, weight: .bold, design: .rounded))
                                            .foregroundStyle(Color.white.opacity(0.68))
                                        Spacer()
                                        Text("\(Int((uploadVideoProgress * 100).rounded()))%")
                                            .font(.system(size: 12, weight: .bold, design: .rounded))
                                            .foregroundStyle(.white)
                                    }

                                    ProgressView(value: uploadVideoProgress, total: 1)
                                        .tint(Color(red: 0.34, green: 0.88, blue: 0.93))
                                        .progressViewStyle(.linear)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 12)
                                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            }

                            Button {
                                onUploadVideoToMac()
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "video.badge.plus")
                                    Text(tr("Pick Video From iPhone", "ជ្រើស Video ពី iPhone"))
                                }
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .fill(
                                            LinearGradient(
                                                colors: [Color.teal.opacity(0.95), Color.blue.opacity(0.88)],
                                                startPoint: .leading,
                                                endPoint: .trailing
                                            )
                                        )
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(isLoading)
                            .opacity(isLoading ? 0.5 : 1)

                            HStack(spacing: 10) {
                                actionButton(
                                    title: tr("Send Current Links", "ផ្ញើ Links បច្ចុប្បន្ន"),
                                    systemImage: "paperplane",
                                    isPrimary: false,
                                    action: onSendCurrentInput
                                )
                                actionButton(
                                    title: tr("Preflight", "Preflight"),
                                    systemImage: "checkmark.shield",
                                    isPrimary: false,
                                    action: onPreflight
                                )
                            }

                            actionButton(
                                title: tr("Run Facebook Post", "រត់ Facebook Post"),
                                systemImage: "play.fill",
                                isPrimary: true,
                                action: onRun
                            )
                        }
                    }

                    sectionCard(title: tr("Result", "លទ្ធផល"), subtitle: tr("The Mac server response and saved memory show here.", "Response ពី Mac និង memory ដែលបានចាំនឹងបង្ហាញនៅទីនេះ។")) {
                        Text(resultMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? tr("Nothing yet.", "មិនទាន់មាននៅឡើយ។")
                                : resultMessage)
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.88))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(20)
            }
            .background(
                LinearGradient(
                    colors: [Color(red: 0.06, green: 0.08, blue: 0.18), Color(red: 0.09, green: 0.12, blue: 0.22)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
            )
            .navigationTitle(tr("Control Mac", "គ្រប់គ្រង Mac"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(tr("Close", "បិទ")) {
                        onClose()
                    }
                    .foregroundStyle(.white)
                }
            }
            .overlay {
                if isLoading {
                    ZStack {
                        Color.black.opacity(0.22)
                            .ignoresSafeArea()
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(1.25)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func sectionCard<Content: View>(title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text(subtitle)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.64))

            content()
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func actionButton(title: String, systemImage: String, isPrimary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        isPrimary
                            ? LinearGradient(
                                colors: [Color.purple.opacity(0.92), Color.blue.opacity(0.9)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            : LinearGradient(
                                colors: [Color.white.opacity(0.10), Color.white.opacity(0.06)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .opacity(isLoading ? 0.65 : 1)
    }

    private func macPackageCard(_ item: MacControlPackageCard) -> some View {
        let isSelected = selectedPackageIDs.contains(item.id)
        return VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let imageURL = thumbnailURLForPackage(item) {
                        AsyncImage(url: imageURL) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .scaledToFill()
                            case .failure(_):
                                roundedCardPlaceholder(symbol: "photo")
                            default:
                                roundedCardPlaceholder(symbol: "photo")
                            }
                        }
                    } else {
                        roundedCardPlaceholder(symbol: "video")
                    }
                }
                .frame(height: 170)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                Button {
                    onDeletePackage(item)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(9)
                        .background(Color.black.opacity(0.42), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(10)
                .disabled(isLoading)
            }

            Text(item.packageName)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)

            Text(item.title)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.74))
                .lineLimit(2)

            Text(item.sourceName)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.52))
                .lineLimit(1)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.12) : Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(isSelected ? Color.cyan.opacity(0.95) : Color.white.opacity(0.08), lineWidth: isSelected ? 2 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onTogglePackage(item)
        }
        .opacity(isLoading ? 0.74 : 1)
    }

    private func roundedCardPlaceholder(symbol: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.08))
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.5))
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.68))
    }

    private func toggleLabel(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Text(subtitle)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.56))
        }
    }

    private func tr(_ english: String, _ khmer: String) -> String {
        isKhmer ? khmer : english
    }
}

private struct PhotoGIFPicker: UIViewControllerRepresentable {
    let onComplete: (Data?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = 1

        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let onComplete: (Data?) -> Void

        init(onComplete: @escaping (Data?) -> Void) {
            self.onComplete = onComplete
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)

            guard let provider = results.first?.itemProvider else {
                onComplete(nil)
                return
            }

            Task {
                let data = await Self.loadGIFData(from: provider)
                await MainActor.run {
                    onComplete(data)
                }
            }
        }

        private static func loadGIFData(from provider: NSItemProvider) async -> Data? {
            if provider.hasItemConformingToTypeIdentifier(UTType.gif.identifier) {
                return await loadDataRepresentation(
                    from: provider,
                    typeIdentifier: UTType.gif.identifier
                )
            }

            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                return await loadDataRepresentation(
                    from: provider,
                    typeIdentifier: UTType.image.identifier
                )
            }

            return nil
        }

        private static func loadDataRepresentation(from provider: NSItemProvider, typeIdentifier: String) async -> Data? {
            await withCheckedContinuation { continuation in
                provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                    continuation.resume(returning: data)
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
