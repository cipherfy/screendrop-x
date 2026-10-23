//
//  RecordingStudioLook.swift
//  Screendrop
//
//  Studio's Styles strip, whose tiles are drawn from the recording’s own
//  frame.
//

import AppKit
import AVFoundation
import SwiftUI

// MARK: - Styles

/// Saved looks as thumbnails of this recording wearing them. Clicking one
/// applies it; the last tile saves the current look.
struct RecordingStudioStyleStrip: View {
    @Bindable var model: RecordingStudioModel
    @Bindable var presetStore: RecordingStudioStylePresetStore

    @State private var poster: CGImage?
    @State private var isNameEditorPresented = false
    @State private var draftName = ""
    @State private var presetPendingDeletion: RecordingStudioStylePreset?
    @FocusState private var isNameFieldFocused: Bool

    private static let tileWidth: CGFloat = 78
    private static let tileAspect: CGFloat = 1.5

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.groupLabelSpacing) {
            HStack(spacing: 6) {
                Text("Styles")
                    .font(.inspectorSectionHeader)
                    .foregroundStyle(Palette.label.opacity(0.95))
                Spacer(minLength: 0)
            }
            .frame(minHeight: 24)
            .padding(.horizontal, InspectorMetrics.horizontalPadding)

            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 6) {
                    ForEach(presetStore.presets) { preset in
                        tile(for: preset)
                    }
                    addTile
                }
                .padding(.horizontal, InspectorMetrics.horizontalPadding - 2.5)
            }
            .scrollIndicators(.never)
        }
        .padding(.top, InspectorMetrics.sectionVerticalPadding / 2 + 3)
        .padding(.bottom, 4)
        .task(id: model.screenURL) {
            poster = await Self.poster(for: model.screenURL)
        }
        .alert(
            "Delete Style?",
            isPresented: Binding(
                get: { presetPendingDeletion != nil },
                set: { if !$0 { presetPendingDeletion = nil } }
            ),
            presenting: presetPendingDeletion
        ) { preset in
            Button("Delete", role: .destructive) {
                presetStore.deletePreset(id: preset.id)
                if model.appliedStylePresetID == preset.id {
                    model.appliedStylePresetID = nil
                }
                presetPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                presetPendingDeletion = nil
            }
        } message: { preset in
            Text("“\(preset.name)” will be removed from your styles. This recording won’t change.")
        }
    }

    private func tile(for preset: RecordingStudioStylePreset) -> some View {
        let isApplied = model.appliedStylePresetID == preset.id && preset.matches(model.style)
        let isDefault = presetStore.activePreset?.id == preset.id
        let isMissing = preset.hasMissingWallpaper
        return VStack(spacing: 4) {
            InspectorTile(title: preset.name, aspectRatio: Self.tileAspect, isSelected: isApplied) {
                guard !isMissing else {
                    presetPendingDeletion = preset
                    return
                }
                withAnimation(.morphIfAllowed) { model.applyStylePreset(preset) }
            } content: {
                StudioStylePreview(
                    style: preset.value,
                    poster: poster,
                    contentAspect: model.sourceVideoAspect,
                    showsCamera: model.hasCameraVideo
                )
                .overlay {
                    if isMissing {
                        Color.black.opacity(0.45)
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
            }

            HStack(spacing: 3) {
                if isDefault {
                    Circle()
                        .fill(Palette.label)
                        .frame(width: 4, height: 4)
                        .help("Used for new recordings")
                }
                Text(preset.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.system(size: 10, weight: isApplied ? .semibold : .regular))
            .foregroundStyle(isApplied ? Palette.label : Palette.secondaryLabel)
            .padding(.horizontal, 2)
        }
        .frame(width: Self.tileWidth)
        .help(isMissing ? "\(preset.name)’s wallpaper can’t be found" : preset.name)
        .contextMenu {
            if !isMissing {
                Button(isDefault ? "Stop Using for New Recordings" : "Use for New Recordings") {
                    presetStore.setActivePreset(id: isDefault ? nil : preset.id)
                }
                Divider()
            }
            Button("Delete…", role: .destructive) {
                presetPendingDeletion = preset
            }
        }
    }

    private var addTile: some View {
        VStack(spacing: 4) {
            Button {
                draftName = ""
                isNameEditorPresented = true
            } label: {
                RoundedRectangle(cornerRadius: InspectorMetrics.tileRadius, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                    .foregroundStyle(.quaternary)
                    .aspectRatio(Self.tileAspect, contentMode: .fit)
                    .overlay {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(2.5)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Save this look as a style")
            .accessibilityLabel("Save Style")
            .popover(isPresented: $isNameEditorPresented, arrowEdge: .bottom) {
                nameEditor
            }

            Text(presetStore.presets.isEmpty ? "Save Look" : "Save")
                .font(.system(size: 10))
                .foregroundStyle(Palette.tertiaryLabel)
        }
        .frame(width: Self.tileWidth)
    }

    // MARK: Saving

    private var duplicateNamePreset: RecordingStudioStylePreset? {
        presetStore.preset(named: draftName)
    }

    private var canSaveName: Bool {
        !RecordingStudioStylePresetStore.normalizedName(draftName).isEmpty
            && duplicateNamePreset == nil
            && !model.style.hasMissingCustomWallpaper
    }

    private var nameEditor: some View {
        InspectorPopover(
            title: "New Style",
            message: "Saves the background, frame, cursor size and camera. New recordings start with it.",
            confirmTitle: "Save",
            isConfirmDisabled: !canSaveName,
            width: 292,
            onCancel: { isNameEditorPresented = false },
            onConfirm: savePreset
        ) {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Style name", text: $draftName)
                    .inspectorTextField()
                    .focused($isNameFieldFocused)
                    .onSubmit(savePreset)
                    .onChange(of: draftName) { _, newValue in
                        let limitedName = String(
                            newValue.prefix(RecordingStudioStylePresetStore.maximumNameLength)
                        )
                        if limitedName != newValue {
                            draftName = limitedName
                        }
                    }

                if model.style.hasMissingCustomWallpaper {
                    Label(
                        "The selected wallpaper can’t be found. Choose it again before saving.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.inspectorLabel)
                    .foregroundStyle(Palette.record)
                } else if duplicateNamePreset != nil {
                    Label(
                        "A style with this name already exists.",
                        systemImage: "exclamationmark.circle.fill"
                    )
                    .font(.inspectorLabel)
                    .foregroundStyle(Palette.record)
                }
            }
        }
        .onAppear {
            Task { @MainActor in
                isNameFieldFocused = true
            }
        }
    }

    private func savePreset() {
        guard canSaveName,
              let preset = presetStore.savePreset(named: draftName, style: model.style) else {
            return
        }
        model.appliedStylePresetID = preset.id
        presetStore.setActivePreset(id: preset.id)
        isNameEditorPresented = false
    }

    /// One small frame from early in the recording, for the thumbnails.
    nonisolated private static func poster(for url: URL) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 360, height: 360)
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        let seconds = duration.isFinite ? min(1, duration / 2) : 0
        return try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }
}

/// A style drawn the way the canvas lays it out: the background, the
/// recording inset by the style's padding with its corners and shadow, and
/// the camera bubble where it sits.
struct StudioStylePreview: View {
    let style: RecordingStudioStyle
    let poster: CGImage?
    let contentAspect: CGFloat
    var showsCamera = false

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let short = min(size.width, size.height)
            // The canvas pads the video whether or not there is a fill.
            let base = RecordingStudioLayout.make(
                canvasSize: size,
                style: style,
                contentAspect: max(0.1, contentAspect),
                contentMode: .fit
            )
            let frame = RecordingCameraLayoutResolver(
                base: base,
                style: style,
                showsCamera: showsCamera && style.camera.isVisible
            ).frame(for: style.camera.layout)
            let card = frame.screenRect

            ZStack(alignment: .topLeading) {
                BackgroundSwatch(style: style.background)
                    .frame(width: size.width, height: size.height)

                Group {
                    if let poster {
                        Image(decorative: poster, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Color(white: 0.16)
                    }
                }
                .frame(width: card.width, height: card.height)
                .clipShape(RoundedRectangle(cornerRadius: style.cornerRadius * short, style: .continuous))
                .shadow(
                    color: .black.opacity(style.background == .none ? 0 : 0.5 * style.shadow),
                    radius: short * 0.05 * style.shadow,
                    y: short * 0.02 * style.shadow
                )
                .opacity(frame.screenOpacity)
                .offset(x: card.minX, y: card.minY)

                if frame.cameraOpacity > 0.001, frame.cameraCutout > 0.5 {
                    let camera = frame.cameraRect
                    StudioPersonSilhouette()
                        .fill(Color(white: 0.7))
                        .shadow(color: .black.opacity(0.25), radius: short * 0.012, y: short * 0.004)
                        .frame(width: camera.width, height: camera.height)
                        .offset(x: camera.minX, y: camera.minY)
                } else if frame.cameraOpacity > 0.001 {
                    let camera = frame.cameraRect
                    RoundedRectangle(cornerRadius: frame.cameraCornerRadius, style: .continuous)
                        .fill(Color(white: 0.78))
                        .overlay {
                            Image(systemName: "person.fill")
                                .font(.system(size: min(camera.width, camera.height) * 0.45))
                                .foregroundStyle(Color(white: 0.55))
                        }
                        .clipShape(RoundedRectangle(cornerRadius: frame.cameraCornerRadius, style: .continuous))
                        .frame(width: camera.width, height: camera.height)
                        .offset(x: camera.minX, y: camera.minY)
                }
            }
            .frame(width: size.width, height: size.height)
        }
    }
}
