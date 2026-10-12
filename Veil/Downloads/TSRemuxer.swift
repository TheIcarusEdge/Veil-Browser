import AVFoundation
import CoreMedia
import Foundation

// MARK: - TS Demuxer

/// Splits an MPEG-TS byte stream (the usual HLS segment format) into H.264 video and
/// AAC audio packets with their timestamps. Timestamps are 90 kHz ticks.
final class TSDemuxer {
    var onVideo: ((Data, Int64, Int64) -> Void)?    // payload, pts, dts
    var onAudio: ((Data, Int64?) -> Void)?          // payload, pts

    private(set) var foundVideo = false
    private(set) var foundAudio = false
    private(set) var unsupportedVideo = false

    private var pmtPIDs = Set<Int>()
    private var videoPID: Int?
    private var audioPID: Int?
    private var pes: [Int: Data] = [:]

    func feed(_ data: Data) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: UInt8.self)
            let n = p.count
            var i = 0
            // Find the first packet boundary.
            while i + 188 <= n {
                if p[i] == 0x47 && (i + 188 >= n || p[i + 188] == 0x47) { break }
                i += 1
            }
            while i + 188 <= n {
                if p[i] != 0x47 {
                    i += 1
                    continue
                }
                handlePacket(p, at: i)
                i += 188
            }
        }
    }

    /// Emits any packet still being assembled. Call once after the last segment.
    func flush() {
        for (pid, buffer) in pes where !buffer.isEmpty {
            emit(pid: pid, buffer)
        }
        pes.removeAll()
    }

    private func handlePacket(_ p: UnsafeBufferPointer<UInt8>, at off: Int) {
        let start = (p[off + 1] & 0x40) != 0
        let pid = (Int(p[off + 1] & 0x1F) << 8) | Int(p[off + 2])
        let adaptation = (p[off + 3] >> 4) & 0x3
        if adaptation == 0 || adaptation == 2 { return }

        var payload = off + 4
        if adaptation == 3 { payload += 1 + Int(p[off + 4]) }
        let end = off + 188
        guard payload < end else { return }

        if pid == 0 {
            if start { parsePAT(p, from: payload, to: end) }
            return
        }
        if pmtPIDs.contains(pid) {
            if start { parsePMT(p, from: payload, to: end) }
            return
        }
        guard pid == videoPID || pid == audioPID else { return }

        let chunk = UnsafeBufferPointer(rebasing: p[payload..<end])
        if start {
            if let previous = pes[pid], !previous.isEmpty { emit(pid: pid, previous) }
            pes[pid] = Data(buffer: chunk)
        } else if pes[pid] != nil {
            pes[pid]?.append(chunk)
        }
    }

    private func parsePAT(_ p: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int) {
        let i = start + 1 + Int(p[start])
        guard i + 8 <= end, p[i] == 0x00 else { return }
        let sectionLength = (Int(p[i + 1] & 0x0F) << 8) | Int(p[i + 2])
        let sectionEnd = min(i + 3 + sectionLength - 4, end)
        var j = i + 8
        while j + 4 <= sectionEnd {
            let program = (Int(p[j]) << 8) | Int(p[j + 1])
            let pid = (Int(p[j + 2] & 0x1F) << 8) | Int(p[j + 3])
            if program != 0 { pmtPIDs.insert(pid) }
            j += 4
        }
    }

    private func parsePMT(_ p: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int) {
        let i = start + 1 + Int(p[start])
        guard i + 12 <= end, p[i] == 0x02 else { return }
        let sectionLength = (Int(p[i + 1] & 0x0F) << 8) | Int(p[i + 2])
        let sectionEnd = min(i + 3 + sectionLength - 4, end)
        let infoLength = (Int(p[i + 10] & 0x0F) << 8) | Int(p[i + 11])
        var j = i + 12 + infoLength
        while j + 5 <= sectionEnd {
            let type = p[j]
            let pid = (Int(p[j + 1] & 0x1F) << 8) | Int(p[j + 2])
            let esInfo = (Int(p[j + 3] & 0x0F) << 8) | Int(p[j + 4])
            switch type {
            case 0x1B:  // H.264
                if videoPID == nil { videoPID = pid }
                foundVideo = true
            case 0x0F:  // AAC with ADTS headers
                if audioPID == nil { audioPID = pid }
                foundAudio = true
            case 0x24, 0x10:  // HEVC, MPEG-4 Part 2
                unsupportedVideo = true
            default:
                break
            }
            j += 5 + esInfo
        }
    }

    private func emit(pid: Int, _ buffer: Data) {
        let result: (payload: Data, pts: Int64?, dts: Int64?)? = buffer.withUnsafeBytes { raw in
            let b = raw.bindMemory(to: UInt8.self)
            let count = b.count
            guard count >= 9, b[0] == 0, b[1] == 0, b[2] == 1 else { return nil }
            let flags = b[7]
            let headerEnd = 9 + Int(b[8])
            guard headerEnd <= count else { return nil }

            var pts: Int64?
            var dts: Int64?
            if (flags & 0x80) != 0, count >= 14 { pts = Self.timestamp(b, 9) }
            if (flags & 0xC0) == 0xC0, count >= 19 { dts = Self.timestamp(b, 14) }

            let declared = (Int(b[4]) << 8) | Int(b[5])
            let end = declared > 0 ? min(count, 6 + declared) : count
            guard headerEnd < end else { return nil }
            return (Data(buffer: UnsafeBufferPointer(rebasing: b[headerEnd..<end])), pts, dts)
        }
        guard let result else { return }

        if pid == videoPID {
            guard let pts = result.pts else { return }
            onVideo?(result.payload, pts, result.dts ?? pts)
        } else if pid == audioPID {
            onAudio?(result.payload, result.pts)
        }
    }

    static func timestamp(_ b: UnsafeBufferPointer<UInt8>, _ o: Int) -> Int64 {
        let a = (Int64(b[o]) >> 1) & 0x07
        let c = Int64(b[o + 1])
        let d = Int64(b[o + 2]) >> 1
        let e = Int64(b[o + 3])
        let f = Int64(b[o + 4]) >> 1
        return (a << 30) | (c << 22) | (d << 15) | (e << 7) | f
    }
}

// MARK: - MP4 Writer

/// Writes H.264 and AAC packets into an MP4 file without re-encoding.
final class TSRemuxer {
    enum Step { case appended, waiting, empty }

    private struct VideoFrame {
        let data: Data
        let pts: Int64
        let dts: Int64
        let key: Bool
        var duration: Int64
    }

    private struct AudioFrame {
        let data: Data
        let pts: Int64
    }

    /// Undoes the 33-bit timestamp rollover (about every 26 hours of stream time).
    private struct Unwrapper {
        var offset: Int64 = 0
        var last: Int64?
        mutating func unwrap(_ raw: Int64) -> Int64 {
            var value = raw + offset
            if let last, value < last - (Int64(1) << 32) {
                offset += Int64(1) << 33
                value += Int64(1) << 33
            }
            last = value
            return value
        }
        mutating func reset() { offset = 0; last = nil }
    }

    private let output: URL
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var videoDone = false
    private var audioDone = false

    private(set) var videoFormat: CMVideoFormatDescription?
    private(set) var audioFormat: CMAudioFormatDescription?
    private var sps: Data?
    private var pps: Data?
    private var seenKeyframe = false
    private var sampleRate: Int64 = 44_100

    private var videoQueue: [VideoFrame] = []
    private var audioQueue: [AudioFrame] = []
    private var heldVideo: VideoFrame?
    private var lastVideoDuration: Int64 = 3003

    private var audioLeftover = Data()
    private var nextAudioPTS: Int64?

    /// Keeps one track's timeline continuous across stream discontinuities.
    private struct Timeline {
        var clock = Unwrapper()
        var shift: Int64 = 0
        var pending = false
        var latest: Int64?

        mutating func mark() {
            pending = true
            clock.reset()
        }

        mutating func adjust(_ raw: Int64, step: Int64) -> Int64 {
            let t = clock.unwrap(raw)
            if pending {
                pending = false
                if let latest, abs(t + shift - latest) > 180_000 {  // more than 2 seconds away
                    shift = latest + step - t
                }
            }
            let value = t + shift
            latest = max(latest ?? value, value)
            return value
        }
    }

    private var videoTime = Timeline()
    private var audioTime = Timeline()
    private var lastVideoDTS: Int64?
    private var lastAudioEnd: Int64?
    private var firstSPS: Data?
    private var started = false
    private var base: Int64 = 0

    init(output: URL) {
        self.output = output
    }

    var hasVideoQueued: Bool { !videoQueue.isEmpty }
    var hasAudioQueued: Bool { !audioQueue.isEmpty }
    var queuedCount: Int { (videoActive ? videoQueue.count : 0) + (audioActive ? audioQueue.count : 0) }
    var videoActive: Bool { videoInput != nil && !videoDone }
    var audioActive: Bool { audioInput != nil && !audioDone }

    // MARK: Input

    /// The next video packets jump in time (an ad break or a re-encoded section).
    /// Call after flushing the demuxer, so the jump applies to the new packets only.
    func markVideoDiscontinuity() {
        videoTime.mark()
    }

    func markAudioDiscontinuity() {
        audioTime.mark()
        audioLeftover = Data()
        nextAudioPTS = nil
    }

    func handleVideo(_ payload: Data, pts rawPTS: Int64, dts rawDTS: Int64) {
        if started && videoInput == nil { return }  // no video track in the file
        let dts = videoTime.adjust(rawDTS, step: lastVideoDuration)
        let pts = max(dts, rawPTS - rawDTS + dts)

        var sample = Data()
        var key = false
        for nal in Self.nalUnits(in: payload) {
            guard let first = nal.first else { continue }
            switch first & 0x1F {
            case 7: sps = nal
            case 8: pps = nal
            case 9: continue  // access unit delimiter
            default:
                if first & 0x1F == 5 { key = true }
                var length = UInt32(nal.count).bigEndian
                sample.append(Data(bytes: &length, count: 4))
                sample.append(nal)
            }
        }
        if videoFormat == nil, let sps, let pps {
            videoFormat = Self.makeVideoFormat(sps: sps, pps: pps)
            firstSPS = sps
        }
        guard videoFormat != nil, !sample.isEmpty else { return }
        // A section encoded at a different size (often an ad) can't share this track. Skip it.
        if let firstSPS, let sps, sps != firstSPS { return }
        // Decode times must keep increasing.
        if let last = lastVideoDTS, dts <= last { return }
        if !seenKeyframe {
            guard key else { return }
            seenKeyframe = true
        }

        lastVideoDTS = dts
        let frame = VideoFrame(data: sample, pts: pts, dts: dts, key: key, duration: 0)
        if var held = heldVideo {
            let gap = dts - held.dts
            held.duration = gap > 0 && gap < 90_000 ? gap : lastVideoDuration
            lastVideoDuration = held.duration
            videoQueue.append(held)
        }
        heldVideo = frame
    }

    func handleAudio(_ payload: Data, pts rawPTS: Int64?) {
        if started && audioInput == nil { return }  // no audio track in the file
        var t: Int64
        if audioLeftover.isEmpty, let rawPTS {
            t = audioTime.adjust(rawPTS, step: 1024 * 90_000 / sampleRate)
        } else if let next = nextAudioPTS {
            t = next
        } else if lastAudioEnd == nil {
            t = 0  // the very first audio has no timestamp: start at zero
        } else {
            return
        }

        let buffer = audioLeftover + payload
        audioLeftover = Data()
        var i = 0
        let bytes = [UInt8](buffer)
        let n = bytes.count

        while i + 7 <= n {
            guard bytes[i] == 0xFF, (bytes[i + 1] & 0xF0) == 0xF0 else {
                i += 1
                continue
            }
            let headerLength = (bytes[i + 1] & 0x01) == 1 ? 7 : 9
            let frameLength = (Int(bytes[i + 3] & 0x03) << 11) | (Int(bytes[i + 4]) << 3) | (Int(bytes[i + 5]) >> 5)
            guard frameLength > headerLength else {
                i += 1
                continue
            }
            if i + frameLength > n { break }

            if audioFormat == nil {
                let objectType = Int(bytes[i + 2] >> 6) + 1
                let rateIndex = Int((bytes[i + 2] >> 2) & 0x0F)
                let channels = Int(((bytes[i + 2] & 0x01) << 2) | (bytes[i + 3] >> 6))
                let rates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
                guard rateIndex < rates.count, channels > 0 else {
                    i += frameLength
                    continue
                }
                sampleRate = Int64(rates[rateIndex])
                audioFormat = Self.makeAudioFormat(objectType: objectType, sampleRate: rates[rateIndex], channels: channels)
            }

            let step = 1024 * 90_000 / sampleRate
            // Drop audio that would overlap what's already queued.
            if let end = lastAudioEnd, t < end {
                t += step
                i += frameLength
                continue
            }
            audioQueue.append(AudioFrame(data: Data(bytes[(i + headerLength)..<(i + frameLength)]), pts: t))
            lastAudioEnd = t + step
            t += step
            i += frameLength
        }
        if i < n { audioLeftover = Data(bytes[i..<n]) }
        nextAudioPTS = t
    }

    /// Packed audio (an audio-only rendition as raw AAC). The start time is in an ID3 tag.
    func handlePackedAudio(_ data: Data) {
        let bytes = [UInt8](data)
        var pts: Int64?
        var start = 0
        if bytes.count > 10, bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 {  // "ID3"
            let size = (Int(bytes[6] & 0x7F) << 21) | (Int(bytes[7] & 0x7F) << 14) | (Int(bytes[8] & 0x7F) << 7) | Int(bytes[9] & 0x7F)
            let tagEnd = min(10 + size + ((bytes[5] & 0x10) != 0 ? 10 : 0), bytes.count)
            pts = Self.transportTimestamp(in: bytes, from: 10, to: tagEnd)
            start = tagEnd
        }
        audioLeftover = Data()
        handleAudio(Data(bytes[start...]), pts: pts)
    }

    /// Moves the last held video frame into the queue. Call after the last segment.
    func endOfStream() {
        if var held = heldVideo {
            held.duration = lastVideoDuration
            videoQueue.append(held)
            heldVideo = nil
        }
    }

    // MARK: Writing

    func start() throws {
        guard videoFormat != nil || audioFormat != nil else {
            throw DownloadFailure("No video or audio Veil can read was found in this stream.")
        }
        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)

        if let videoFormat {
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                videoInput = input
            }
        }
        if let audioFormat {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }
        guard writer.startWriting() else {
            throw writer.error ?? DownloadFailure("Couldn't start writing the MP4 file.")
        }

        let firstVideo = (videoQueue.first?.dts).map { [$0] } ?? (heldVideo.map { [$0.dts] } ?? [])
        let firstAudio = audioQueue.first.map { [$0.pts] } ?? []
        base = (firstVideo + firstAudio).min() ?? 0
        writer.startSession(atSourceTime: .zero)
        self.writer = writer
        started = true

        if videoInput == nil { videoQueue.removeAll(); heldVideo = nil }
        if audioInput == nil { audioQueue.removeAll() }
    }

    func finishVideo() {
        guard let videoInput, !videoDone else { return }
        videoDone = true
        videoInput.markAsFinished()
    }

    func finishAudio() {
        guard let audioInput, !audioDone else { return }
        audioDone = true
        audioInput.markAsFinished()
    }

    /// Writes the earliest queued packet whose track is ready for more data.
    func appendNext() throws -> Step {
        guard let writer else { return .empty }
        if writer.status == .failed {
            throw writer.error ?? DownloadFailure("Writing the MP4 file failed.")
        }

        let video = videoActive ? videoQueue.first : nil
        let audio = audioActive ? audioQueue.first : nil
        if video == nil && audio == nil { return .empty }

        let videoFirst: Bool
        switch (video, audio) {
        case let (v?, a?): videoFirst = v.dts <= a.pts
        case (.some, nil): videoFirst = true
        default: videoFirst = false
        }

        let order: [Bool] = videoFirst ? [true, false] : [false, true]
        for isVideo in order {
            if isVideo, let frame = video, let input = videoInput, input.isReadyForMoreMediaData {
                videoQueue.removeFirst()
                if let buffer = makeVideoSample(frame), !input.append(buffer) {
                    throw writer.error ?? DownloadFailure("Couldn't write a video frame.")
                }
                return .appended
            }
            if !isVideo, let frame = audio, let input = audioInput, input.isReadyForMoreMediaData {
                audioQueue.removeFirst()
                if let buffer = makeAudioSample(frame), !input.append(buffer) {
                    throw writer.error ?? DownloadFailure("Couldn't write an audio frame.")
                }
                return .appended
            }
        }
        return .waiting
    }

    func finish() async throws {
        guard let writer else { throw DownloadFailure("Nothing was written.") }
        finishVideo()
        finishAudio()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            writer.finishWriting { done.resume() }
        }
        guard writer.status == .completed else {
            throw writer.error ?? DownloadFailure("Couldn't finish the MP4 file.")
        }
    }

    // MARK: Sample Buffers

    private func makeVideoSample(_ frame: VideoFrame) -> CMSampleBuffer? {
        guard let format = videoFormat else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: frame.duration, timescale: 90_000),
            presentationTimeStamp: CMTime(value: frame.pts - base, timescale: 90_000),
            decodeTimeStamp: CMTime(value: frame.dts - base, timescale: 90_000)
        )
        guard let sample = Self.makeSample(frame.data, format: format, timing: &timing) else { return nil }
        if !frame.key, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            let yes: CFBoolean = kCFBooleanTrue
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                Unmanaged.passUnretained(yes).toOpaque()
            )
        }
        return sample
    }

    private func makeAudioSample(_ frame: AudioFrame) -> CMSampleBuffer? {
        guard let format = audioFormat else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1024, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: CMTime(value: frame.pts - base, timescale: 90_000),
            decodeTimeStamp: .invalid
        )
        return Self.makeSample(frame.data, format: format, timing: &timing)
    }

    private static func makeSample(_ data: Data, format: CMFormatDescription, timing: inout CMSampleTimingInfo) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        ) == noErr, let block else { return nil }

        let copied = data.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)
        }
        guard copied == noErr else { return nil }

        var sample: CMSampleBuffer?
        var size = data.count
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample
        ) == noErr else { return nil }
        return sample
    }

    private static func makeVideoFormat(sps: Data, pps: Data) -> CMVideoFormatDescription? {
        var format: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { spsRaw -> OSStatus in
            pps.withUnsafeBytes { ppsRaw -> OSStatus in
                guard let s = spsRaw.bindMemory(to: UInt8.self).baseAddress,
                      let p = ppsRaw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                let pointers: [UnsafePointer<UInt8>] = [s, p]
                let sizes: [Int] = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &format
                )
            }
        }
        return status == noErr ? format : nil
    }

    private static func makeAudioFormat(objectType: Int, sampleRate: Int, channels: Int) -> CMAudioFormatDescription? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: AudioFormatFlags(objectType),
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 0,
            mReserved: 0
        )
        // AudioSpecificConfig: object type (5 bits), rate index (4), channels (4), 3 zero bits.
        let rates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
        let rateIndex = rates.firstIndex(of: sampleRate) ?? 4
        let config = UInt16(objectType << 11) | UInt16(rateIndex << 7) | UInt16(channels << 3)
        let cookie = esds(audioSpecificConfig: [UInt8(config >> 8), UInt8(config & 0xFF)])

        var format: CMAudioFormatDescription?
        let status = cookie.withUnsafeBytes { raw -> OSStatus in
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                magicCookieSize: cookie.count, magicCookie: raw.baseAddress,
                extensions: nil, formatDescriptionOut: &format
            )
        }
        return status == noErr ? format : nil
    }

    /// The ES descriptor CoreMedia expects as the AAC magic cookie.
    private static func esds(audioSpecificConfig asc: [UInt8]) -> Data {
        func descriptor(_ tag: UInt8, _ body: [UInt8]) -> [UInt8] {
            [tag, UInt8(body.count)] + body
        }
        let decoderSpecific = descriptor(0x05, asc)
        let decoderConfig = descriptor(0x04, [
            0x40,                    // object type: MPEG-4 audio
            0x15,                    // stream type: audio
            0x00, 0x00, 0x00,        // buffer size
            0x00, 0x00, 0x00, 0x00,  // max bitrate
            0x00, 0x00, 0x00, 0x00,  // average bitrate
        ] + decoderSpecific)
        let slConfig = descriptor(0x06, [0x02])
        let es = descriptor(0x03, [0x00, 0x00, 0x00] + decoderConfig + slConfig)
        return Data(es)
    }

    // MARK: Parsing Helpers

    /// Splits Annex B H.264 data on its 00 00 01 start codes.
    static func nalUnits(in data: Data) -> [Data] {
        let bytes = [UInt8](data)
        let n = bytes.count
        var starts: [(code: Int, nal: Int)] = []
        var i = 0
        while i + 2 < n {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                starts.append((i, i + 3))
                i += 3
            } else {
                i += 1
            }
        }
        var units: [Data] = []
        for (k, s) in starts.enumerated() {
            var end = k + 1 < starts.count ? starts[k + 1].code : n
            while end > s.nal && bytes[end - 1] == 0 { end -= 1 }
            if end > s.nal { units.append(Data(bytes[s.nal..<end])) }
        }
        return units
    }

    /// Finds Apple's transport stream timestamp in an ID3 PRIV frame.
    private static func transportTimestamp(in bytes: [UInt8], from start: Int, to end: Int) -> Int64? {
        let owner = Array("com.apple.streaming.transportStreamTimestamp".utf8)
        var i = start
        while i + 10 <= end {
            let id = String(bytes: bytes[i..<(i + 4)], encoding: .ascii) ?? ""
            let size = (Int(bytes[i + 4]) << 24) | (Int(bytes[i + 5]) << 16) | (Int(bytes[i + 6]) << 8) | Int(bytes[i + 7])
            let body = i + 10
            guard size > 0, body + size <= end else { return nil }
            if id == "PRIV", size >= owner.count + 1 + 8, Array(bytes[body..<(body + owner.count)]) == owner {
                let t = body + owner.count + 1
                var value: Int64 = 0
                for b in bytes[t..<(t + 8)] { value = (value << 8) | Int64(b) }
                return value & 0x1_FFFF_FFFF
            }
            i = body + size
        }
        return nil
    }
}
