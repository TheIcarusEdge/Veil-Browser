import AVKit
import Photos
import SwiftUI

struct DownloadsView: View {
    @ObservedObject private var manager = DownloadManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var edits: [URL] = []

    var body: some View {
        NavigationStack {
            List {
                Section("Downloads") {
                    if manager.items.isEmpty {
                        Text("Nothing downloaded yet.").foregroundStyle(.secondary)
                    }
                    ForEach(manager.items) { item in
                        DownloadRow(item: item)
                    }
                    .onDelete { offsets in
                        offsets.map { manager.items[$0] }.forEach(manager.remove)
                    }
                }

                if !edits.isEmpty {
                    Section("Edits") {
                        ForEach(edits, id: \.self) { url in
                            NavigationLink {
                                EditorView(fileURL: url)
                            } label: {
                                Label(url.lastPathComponent, systemImage: "film")
                            }
                        }
                        .onDelete { offsets in
                            for i in offsets { try? FileManager.default.removeItem(at: edits[i]) }
                            loadEdits()
                        }
                    }
                }
            }
            .navigationTitle("Downloads")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear(perform: loadEdits)
        }
    }

    private func loadEdits() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: DownloadManager.editsDir, includingPropertiesForKeys: nil
        )) ?? []
        edits = files.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

struct DownloadRow: View {
    let item: DownloadItem

    var body: some View {
        if item.status == .finished, let url = DownloadManager.shared.fileURL(for: item) {
            NavigationLink { EditorView(fileURL: url) } label: { details }
        } else {
            details
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.title).lineLimit(2)
            switch item.status {
            case .downloading:
                ProgressView(value: item.progress)
            case .converting:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Converting to MP4").font(.caption).foregroundStyle(.secondary)
                }
            case .finished:
                Text(item.fileName ?? "").font(.caption).foregroundStyle(.secondary)
            case .failed:
                Text(item.error ?? "Failed").font(.caption).foregroundStyle(.red)
            }
        }
    }
}

// MARK: - Editor

struct EditorView: View {
    let fileURL: URL

    @State private var player: AVPlayer
    @State private var duration: Double = 0
    @State private var start: Double = 0
    @State private var end: Double = 0
    @State private var muted = false
    @State private var speed: Double = 1
    @State private var crop: CropAspect = .off
    @State private var cropPosition: Double = 0.5
    @State private var displaySize: CGSize = .zero
    @State private var exporting = false
    @State private var exported: URL?
    @State private var message: String?

    init(fileURL: URL) {
        self.fileURL = fileURL
        _player = State(initialValue: AVPlayer(url: fileURL))
    }

    private var upperBound: Double { max(duration, 0.1) }

    var body: some View {
        Form {
            Section {
                VideoPlayer(player: player)
                    .overlay {
                        CropOverlay(display: displaySize, aspect: crop, position: cropPosition)
                    }
                    .frame(height: 240)
                    .listRowInsets(EdgeInsets())
            }

            Section("Trim") {
                LabeledContent("Start", value: format(start))
                Slider(value: $start, in: 0...upperBound, onEditingChanged: { isEditing in
                    if !isEditing { seek(start) }
                })
                LabeledContent("End", value: format(end))
                Slider(value: $end, in: 0...upperBound, onEditingChanged: { isEditing in
                    if !isEditing { seek(end) }
                })
                LabeledContent("Final Length", value: format(max(end - start, 0) / speed))
            }

            Section("Crop") {
                Picker("Shape", selection: $crop) {
                    ForEach(CropAspect.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                if crop != .off {
                    let horizontal = VideoExporter.cropSlidesHorizontally(display: displaySize, aspect: crop)
                    Slider(value: $cropPosition, in: 0...1) {
                        Text("Position")
                    } minimumValueLabel: {
                        Text(horizontal ? "Left" : "Top").font(.caption)
                    } maximumValueLabel: {
                        Text(horizontal ? "Right" : "Bottom").font(.caption)
                    }
                    Button("Center") { cropPosition = 0.5 }
                        .disabled(cropPosition == 0.5)
                }

                LabeledContent("Output Size", value: outputSizeText)
            }

            Section("Options") {
                Toggle("Remove Audio", isOn: $muted)
                Picker("Speed", selection: $speed) {
                    ForEach([0.5, 1.0, 1.5, 2.0], id: \.self) { value in
                        Text("\(value.formatted())x").tag(value)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section {
                Button(exporting ? "Exporting..." : "Export Clip") {
                    Task { await runExport() }
                }
                .disabled(exporting || end - start < 0.5)

                if let exported {
                    ShareLink(item: exported) { Label("Share Clip", systemImage: "square.and.arrow.up") }
                    Button { saveToPhotos(exported) } label: { Label("Save to Photos", systemImage: "photo.on.rectangle") }
                }
                ShareLink(item: fileURL) { Label("Share Original", systemImage: "square.and.arrow.up.on.square") }
            }

            if let message {
                Section { Text(message).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle(fileURL.deletingPathExtension().lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let asset = AVURLAsset(url: fileURL)
            if let length = try? await asset.load(.duration), length.seconds.isFinite {
                duration = length.seconds
                end = length.seconds
            }
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let size = try? await VideoExporter.displaySize(of: track) {
                displaySize = size
            }
        }
        .onChange(of: start) { _, value in if value > end { end = value } }
        .onChange(of: end) { _, value in if value < start { start = value } }
        .onDisappear { player.pause() }
    }

    private var outputSizeText: String {
        guard displaySize.width > 0 else { return "Unknown" }
        let rect = VideoExporter.cropRect(display: displaySize, aspect: crop, position: cropPosition)
        return "\(Int(rect.width)) x \(Int(rect.height))"
    }

    private func seek(_ seconds: Double) {
        player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    private func format(_ seconds: Double) -> String {
        let safe = max(seconds, 0)
        return String(format: "%ld:%04.1f", Int(safe) / 60, safe.truncatingRemainder(dividingBy: 60))
    }

    private func runExport() async {
        exporting = true
        message = nil
        do {
            exported = try await VideoExporter.export(
                source: fileURL, start: start, end: min(end, duration), muted: muted, speed: speed,
                crop: crop, cropPosition: cropPosition
            )
            message = "Saved to Files under Veil > Edits."
        } catch {
            message = error.localizedDescription
        }
        exporting = false
    }

    private func saveToPhotos(_ url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { message = "Allow photo access in Settings to save clips." }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { success, error in
                DispatchQueue.main.async {
                    message = success ? "Saved to Photos." : (error?.localizedDescription ?? "Couldn't save to Photos.")
                }
            }
        }
    }
}

// MARK: - Crop Preview

/// Dims the parts of the video that the crop will cut off and outlines the part that stays.
/// It ignores touches so the player controls underneath still work.
struct CropOverlay: View {
    let display: CGSize
    let aspect: CropAspect
    let position: Double

    var body: some View {
        GeometryReader { geo in
            if aspect != .off, display.width > 0, display.height > 0 {
                let frame = fittedFrame(in: geo.size)
                let scale = frame.width / display.width
                let keep = VideoExporter.cropRect(display: display, aspect: aspect, position: position)
                let shown = CGRect(
                    x: frame.minX + keep.minX * scale,
                    y: frame.minY + keep.minY * scale,
                    width: keep.width * scale,
                    height: keep.height * scale
                )

                Path { path in
                    path.addRect(frame)
                    path.addRect(shown)
                }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))

                Rectangle()
                    .path(in: shown)
                    .stroke(Color.white, lineWidth: 2)
            }
        }
        .allowsHitTesting(false)
    }

    /// Where the video sits inside the player, which fits it to the space and centers it.
    private func fittedFrame(in container: CGSize) -> CGRect {
        let scale = min(container.width / display.width, container.height / display.height)
        let size = CGSize(width: display.width * scale, height: display.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }
}
