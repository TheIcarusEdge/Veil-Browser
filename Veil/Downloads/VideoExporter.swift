import AVFoundation
import CoreGraphics
import Foundation

/// Crop shapes offered in the editor. `ratio` is width divided by height.
enum CropAspect: String, CaseIterable, Identifiable {
    case off, square, vertical, wide, portrait

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .square: return "1:1"
        case .vertical: return "9:16"
        case .wide: return "16:9"
        case .portrait: return "4:5"
        }
    }

    var ratio: CGFloat? {
        switch self {
        case .off: return nil
        case .square: return 1
        case .vertical: return 9.0 / 16.0
        case .wide: return 16.0 / 9.0
        case .portrait: return 4.0 / 5.0
        }
    }
}

enum VideoExporter {
    enum ExportError: LocalizedError {
        case noVideo
        case failed(Error?)

        var errorDescription: String? {
            switch self {
            case .noVideo: return "This file has no video track."
            case .failed(let error): return error?.localizedDescription ?? "Export failed."
            }
        }
    }

    /// The video's size as it appears on screen, after rotation.
    static func displaySize(of track: AVAssetTrack) async throws -> CGSize {
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let rect = CGRect(origin: .zero, size: natural).applying(transform)
        return CGSize(width: abs(rect.width), height: abs(rect.height))
    }

    /// The part of the frame to keep, in display coordinates with the origin at top left.
    /// `position` slides the crop along whichever side has room to spare: 0 is the left
    /// or top edge, 0.5 is centered, 1 is the right or bottom edge.
    static func cropRect(display: CGSize, aspect: CropAspect, position: Double) -> CGRect {
        guard let ratio = aspect.ratio, display.width > 0, display.height > 0 else {
            return CGRect(origin: .zero, size: display)
        }
        let p = CGFloat(min(max(position, 0), 1))
        // Even pixel sizes keep video encoders happy.
        func even(_ v: CGFloat) -> CGFloat { max(2, (v / 2).rounded(.down) * 2) }

        if display.width / display.height > ratio {
            let w = even(display.height * ratio)
            let h = even(display.height)
            return CGRect(x: ((display.width - w) * p).rounded(), y: 0, width: w, height: h)
        } else {
            let w = even(display.width)
            let h = even(display.width / ratio)
            return CGRect(x: 0, y: ((display.height - h) * p).rounded(), width: w, height: h)
        }
    }

    /// True when the crop slides left and right, false when it slides up and down.
    static func cropSlidesHorizontally(display: CGSize, aspect: CropAspect) -> Bool {
        guard let ratio = aspect.ratio, display.height > 0 else { return true }
        return display.width / display.height > ratio
    }

    /// Trims a clip, optionally crops it, drops the audio and changes speed, and writes an MP4 to Documents/Edits.
    static func export(
        source: URL,
        start: Double,
        end: Double,
        muted: Bool,
        speed: Double,
        crop: CropAspect = .off,
        cropPosition: Double = 0.5
    ) async throws -> URL {
        let asset = AVURLAsset(url: source)
        let composition = AVMutableComposition()
        let range = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            end: CMTime(seconds: end, preferredTimescale: 600)
        )

        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first,
              let compVideo = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
              ) else {
            throw ExportError.noVideo
        }
        try compVideo.insertTimeRange(range, of: videoTrack, at: .zero)
        let transform = try await videoTrack.load(.preferredTransform)
        compVideo.preferredTransform = transform

        if !muted,
           let audioTrack = try await asset.loadTracks(withMediaType: .audio).first,
           let compAudio = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            try compAudio.insertTimeRange(range, of: audioTrack, at: .zero)
        }

        if speed != 1 {
            let length = range.duration
            composition.scaleTimeRange(
                CMTimeRange(start: .zero, duration: length),
                toDuration: CMTimeMultiplyByFloat64(length, multiplier: 1 / speed)
            )
        }

        // Cropping: rotate the frame upright, shift the kept area to the origin,
        // and render only that area.
        var videoComposition: AVMutableVideoComposition?
        if crop != .off {
            let natural = try await videoTrack.load(.naturalSize)
            let rotated = CGRect(origin: .zero, size: natural).applying(transform)
            let display = CGSize(width: abs(rotated.width), height: abs(rotated.height))
            let keep = cropRect(display: display, aspect: crop, position: cropPosition)

            let layerTransform = transform
                .concatenating(CGAffineTransform(translationX: -rotated.minX, y: -rotated.minY))
                .concatenating(CGAffineTransform(translationX: -keep.minX, y: -keep.minY))

            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideo)
            layer.setTransform(layerTransform, at: .zero)

            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)
            instruction.layerInstructions = [layer]

            let fps = try await videoTrack.load(.nominalFrameRate)
            let vc = AVMutableVideoComposition()
            vc.renderSize = keep.size
            vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps > 0 ? fps.rounded() : 30))
            vc.instructions = [instruction]
            videoComposition = vc
        }

        let base = source.deletingPathExtension().lastPathComponent + " edit"
        let output = DownloadManager.uniqueURL(in: DownloadManager.editsDir, base: base, ext: "mp4")

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw ExportError.failed(nil)
        }
        session.outputURL = output
        session.outputFileType = .mp4
        session.audioTimePitchAlgorithm = .spectral
        if let videoComposition { session.videoComposition = videoComposition }

        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { done.resume() }
        }
        guard session.status == .completed else { throw ExportError.failed(session.error) }
        return output
    }
}
