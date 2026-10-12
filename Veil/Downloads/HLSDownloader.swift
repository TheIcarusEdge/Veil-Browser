import AVFoundation
import CommonCrypto
import Foundation

/// Picks the cookies a request to `url` would carry, the way a browser does.
enum CookieHeader {
    static func fields(for url: URL, from cookies: [HTTPCookie]) -> [String: String] {
        guard let host = url.host?.lowercased() else { return [:] }
        let path = url.path.isEmpty ? "/" : url.path
        let secure = url.scheme?.lowercased() == "https"
        let now = Date()
        let matching = cookies.filter { cookie in
            var domain = cookie.domain.lowercased()
            if domain.hasPrefix(".") { domain.removeFirst() }
            let domainOK = host == domain || host.hasSuffix("." + domain)
            let pathOK = cookie.path.isEmpty || path.hasPrefix(cookie.path)
            let secureOK = !cookie.isSecure || secure
            let fresh = cookie.expiresDate.map { $0 > now } ?? true
            return domainOK && pathOK && secureOK && fresh
        }
        return HTTPCookie.requestHeaderFields(with: matching)
    }
}

/// Downloads an HLS stream (.m3u8) and saves it as one MP4.
///
/// Veil fetches the playlist and every segment itself, with the page's cookies attached to
/// each request, so streams behind a login (like a course site) work. TS segments are
/// rewrapped into MP4 without re-encoding. fMP4 segments are joined, then tidied into a
/// regular MP4. AES-128 encryption is supported. DRM is not.
final class HLSDownloader {
    typealias Progress = (_ fraction: Double, _ finishing: Bool) -> Void

    private let source: URL
    private let headers: [String: String]
    private let cookies: [HTTPCookie]
    private let workDir: URL
    private let progress: Progress
    private let session: URLSession

    init(source: URL, headers: [String: String], cookies: [HTTPCookie], workDir: URL, progress: @escaping Progress) {
        self.source = source
        self.headers = headers
        self.cookies = cookies
        self.workDir = workDir
        self.progress = progress

        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpMaximumConnectionsPerHost = 4
        config.timeoutIntervalForRequest = 60
        session = URLSession(configuration: config)
    }

    deinit {
        session.invalidateAndCancel()
    }

    /// Returns the finished MP4 inside `workDir`.
    func run() async throws -> URL {
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let firstText = try await text(at: source)
        var mainURL = source
        var mainText = firstText
        var audioURL: URL?

        if HLSParser.isMaster(firstText) {
            let master = try HLSParser.parseMaster(firstText, base: source)
            guard let variant = master.bestVariant() else {
                throw DownloadFailure("This stream lists no video Veil can save.")
            }
            mainURL = variant.url
            mainText = try await text(at: mainURL)
            audioURL = master.audioRendition(for: variant)?.url
        }

        let main = try HLSParser.parseMedia(mainText, base: mainURL)
        guard main.isComplete else {
            throw DownloadFailure("This is a live stream. Veil can only save streams that have ended.")
        }
        guard !main.segments.isEmpty else { throw DownloadFailure("This stream has no video segments.") }

        var audio: HLSMediaPlaylist?
        if let audioURL {
            let audioText = try await text(at: audioURL)
            audio = try HLSParser.parseMedia(audioText, base: audioURL)
            if audio?.segments.isEmpty ?? true { audio = nil }
        }

        let mainFetcher = try await SegmentFetcher(playlist: main, downloader: self)
        var audioFetcher: SegmentFetcher?
        if let audio { audioFetcher = try await SegmentFetcher(playlist: audio, downloader: self) }
        defer {
            mainFetcher.cancelAll()
            audioFetcher?.cancelAll()
        }

        if main.initSegment != nil {
            return try await saveFragmented(main: mainFetcher, audio: audioFetcher)
        }
        let first = try await mainFetcher.segment(0)
        if Self.looksLikeTS(first) {
            return try await remuxTS(main: mainFetcher, audio: audioFetcher, firstSegment: first)
        }
        if Self.looksLikeMP4(first) {
            return try await saveFragmented(main: mainFetcher, audio: audioFetcher, firstSegment: first)
        }
        if Self.looksLikePackedAudio(first) {
            return try await remuxTS(main: mainFetcher, audio: nil, firstSegment: first, mainIsPackedAudio: true)
        }
        throw DownloadFailure("This stream uses a format Veil can't read yet.")
    }

    // MARK: TS Streams

    private func remuxTS(
        main: SegmentFetcher,
        audio: SegmentFetcher?,
        firstSegment: Data,
        mainIsPackedAudio: Bool = false
    ) async throws -> URL {
        let output = workDir.appendingPathComponent("stream.mp4")
        let mux = TSRemuxer(output: output)

        let mainDemux = TSDemuxer()
        mainDemux.onVideo = { mux.handleVideo($0, pts: $1, dts: $2) }
        if audio == nil { mainDemux.onAudio = { mux.handleAudio($0, pts: $1) } }
        let audioDemux = TSDemuxer()
        audioDemux.onAudio = { mux.handleAudio($0, pts: $1) }

        let mainCount = main.count
        let audioCount = audio?.count ?? 0
        var mi = 0
        var ai = 0
        var cached: Data? = firstSegment

        func report() {
            let total = Double(mainCount + audioCount)
            progress(total > 0 ? Double(mi + ai) / total : 0, false)
        }

        func pullMain() async throws {
            let data: Data
            if let c = cached {
                data = c
                cached = nil
            } else {
                data = try await main.segment(mi)
            }
            if mainIsPackedAudio {
                mux.handlePackedAudio(data)
            } else {
                if mi > 0, main.playlist.segments[mi].discontinuity, audio == nil { mux.markDiscontinuity() }
                mainDemux.feed(data)
                if mainDemux.unsupportedVideo && !mainDemux.foundVideo {
                    throw DownloadFailure("This stream uses HEVC video in a format Veil can't convert yet.")
                }
            }
            mi += 1
            if mi == mainCount {
                mainDemux.flush()
                mux.endOfStream()
            }
            report()
        }

        func pullAudio() async throws {
            guard let audio else { return }
            let data = try await audio.segment(ai)
            if Self.looksLikeTS(data) { audioDemux.feed(data) } else { mux.handlePackedAudio(data) }
            ai += 1
            if ai == audioCount { audioDemux.flush() }
            report()
        }

        // Read until the video and audio formats are known.
        var primed = 0
        repeat {
            if mi < mainCount { try await pullMain() }
            if audio != nil, ai < audioCount { try await pullAudio() }
            primed += 1
            let needVideo = !mainIsPackedAudio && mainDemux.foundVideo && mux.videoFormat == nil
            let needAudio = (audio != nil || mainDemux.foundAudio || mainIsPackedAudio) && mux.audioFormat == nil
            if !needVideo && !needAudio { break }
        } while primed < 4 && (mi < mainCount || ai < audioCount)

        try mux.start()

        var stalls = 0
        loop: while true {
            try Task.checkCancellation()

            while mux.videoActive && !mux.hasVideoQueued && mi < mainCount { try await pullMain() }
            if audio != nil {
                while mux.audioActive && !mux.hasAudioQueued && ai < audioCount { try await pullAudio() }
            } else {
                while mux.audioActive && !mux.hasAudioQueued && mi < mainCount && mux.queuedCount < 1500 {
                    try await pullMain()
                }
            }
            if mux.videoActive && !mux.hasVideoQueued && mi >= mainCount { mux.finishVideo() }
            let audioExhausted = audio != nil ? ai >= audioCount : mi >= mainCount
            if mux.audioActive && !mux.hasAudioQueued && audioExhausted { mux.finishAudio() }

            switch try mux.appendNext() {
            case .appended:
                stalls = 0
            case .empty:
                if !mux.videoActive && !mux.audioActive { break loop }
            case .waiting:
                stalls += 1
                if stalls > 4000 {
                    // One track stopped early and the writer is waiting on it. Close it and carry on.
                    if !mux.hasAudioQueued { mux.finishAudio() } else if !mux.hasVideoQueued { mux.finishVideo() }
                    else { throw DownloadFailure("Building the MP4 stalled.") }
                    stalls = 0
                }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
        }

        progress(1, true)
        try await mux.finish()
        return output
    }

    // MARK: fMP4 Streams

    private func saveFragmented(main: SegmentFetcher, audio: SegmentFetcher?, firstSegment: Data? = nil) async throws -> URL {
        let total = Double(main.count + (audio?.count ?? 0))
        var done = 0.0

        func join(_ fetcher: SegmentFetcher, into file: URL, first: Data?) async throws {
            FileManager.default.createFile(atPath: file.path, contents: nil)
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            if let initSegment = fetcher.playlist.initSegment {
                handle.write(try await data(at: initSegment.url, range: initSegment.range))
            }
            for i in 0..<fetcher.count {
                try Task.checkCancellation()
                if i == 0, let first {
                    handle.write(first)
                } else {
                    handle.write(try await fetcher.segment(i))
                }
                done += 1
                progress(done / total, false)
            }
        }

        let videoFile = workDir.appendingPathComponent("video.mp4")
        try await join(main, into: videoFile, first: firstSegment)
        var audioFile: URL?
        if let audio {
            let file = workDir.appendingPathComponent("audio.mp4")
            try await join(audio, into: file, first: nil)
            audioFile = file
        }

        progress(1, true)
        let output = workDir.appendingPathComponent("stream.mp4")
        do {
            try await Self.combine(video: videoFile, audio: audioFile, into: output)
            return output
        } catch {
            // The joined file still plays, so keep it when there is no separate audio.
            if audioFile == nil { return videoFile }
            throw error
        }
    }

    /// Joins separate video and audio files (or tidies a single fragmented file) into a regular MP4.
    private static func combine(video: URL, audio: URL?, into output: URL) async throws {
        let videoAsset = AVURLAsset(url: video)
        let composition = AVMutableComposition()
        let duration = try await videoAsset.load(.duration)
        let range = CMTimeRange(start: .zero, duration: duration)

        if let track = try await videoAsset.loadTracks(withMediaType: .video).first,
           let comp = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try comp.insertTimeRange(range, of: track, at: .zero)
            comp.preferredTransform = try await track.load(.preferredTransform)
        }
        let audioAsset = audio.map { AVURLAsset(url: $0) } ?? videoAsset
        if let track = try await audioAsset.loadTracks(withMediaType: .audio).first,
           let comp = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let audioDuration = try await audioAsset.load(.duration)
            try comp.insertTimeRange(CMTimeRange(start: .zero, duration: min(duration, audioDuration)), of: track, at: .zero)
        }

        for preset in [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality] {
            try? FileManager.default.removeItem(at: output)
            guard let export = AVAssetExportSession(asset: composition, presetName: preset) else { continue }
            export.outputURL = output
            export.outputFileType = .mp4
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                export.exportAsynchronously { done.resume() }
            }
            if export.status == .completed { return }
        }
        throw DownloadFailure("Couldn't combine the stream's video and audio.")
    }

    // MARK: Network

    func text(at url: URL) async throws -> String {
        let data = try await data(at: url, range: nil)
        guard let text = String(data: data, encoding: .utf8), text.contains("#EXTM3U") else {
            throw DownloadFailure("The stream's playlist couldn't be read. The link may have expired. Reload the page and try again.")
        }
        return text
    }

    func data(at url: URL, range: ByteRange?) async throws -> Data {
        var request = URLRequest(url: url)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        for (key, value) in CookieHeader.fields(for: url, from: cookies) { request.setValue(value, forHTTPHeaderField: key) }
        if let range { request.setValue(range.httpHeader, forHTTPHeaderField: "Range") }

        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { return data }
                switch http.statusCode {
                case 200..<300:
                    return data
                case 401, 403:
                    throw DownloadFailure("The site refused access (error \(http.statusCode)). Play the video in Veil first, then try again.")
                case 404, 410:
                    throw DownloadFailure("Part of the stream is missing (error \(http.statusCode)). The link may have expired. Reload the page and try again.")
                case 500...:
                    if attempt < 2 { break }
                    throw DownloadFailure("The site had a server error (\(http.statusCode)).")
                default:
                    throw DownloadFailure("The site returned error \(http.statusCode).")
                }
            } catch let failure as DownloadFailure {
                throw failure
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if attempt >= 2 || Task.isCancelled { throw error }
            }
            attempt += 1
            try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
        }
    }

    // MARK: Format Checks

    static func looksLikeTS(_ data: Data) -> Bool {
        data.count >= 189 && data[data.startIndex] == 0x47 && data[data.startIndex + 188] == 0x47
    }

    static func looksLikeMP4(_ data: Data) -> Bool {
        guard data.count >= 8 else { return false }
        let type = String(data: data[(data.startIndex + 4)..<(data.startIndex + 8)], encoding: .ascii) ?? ""
        return ["ftyp", "styp", "moof", "sidx", "moov"].contains(type)
    }

    static func looksLikePackedAudio(_ data: Data) -> Bool {
        guard data.count >= 3 else { return false }
        let b = [UInt8](data.prefix(3))
        return (b[0] == 0x49 && b[1] == 0x44 && b[2] == 0x33) || (b[0] == 0xFF && (b[1] & 0xF0) == 0xF0)
    }

    /// Turns any error into a message that says what went wrong, with codes for troubleshooting.
    static func describe(_ error: Error) -> String {
        if let failure = error as? DownloadFailure { return failure.message }
        let ns = error as NSError
        var text = ns.localizedDescription
        if let reason = ns.localizedFailureReason, !text.contains(reason) { text += " " + reason }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += " [\(underlying.domain) \(underlying.code)]"
        }
        return text + " (\(ns.domain) \(ns.code))"
    }
}

// MARK: - Segment Fetcher

/// Downloads segments a few at a time ahead of where the writer is, and decrypts them.
final class SegmentFetcher {
    let playlist: HLSMediaPlaylist
    private unowned let downloader: HLSDownloader
    private var keys: [URL: Data] = [:]
    private var tasks: [Int: Task<Data, Error>] = [:]
    private let lookahead = 4

    var count: Int { playlist.segments.count }

    init(playlist: HLSMediaPlaylist, downloader: HLSDownloader) async throws {
        self.playlist = playlist
        self.downloader = downloader
        // Fetch encryption keys up front. Most streams use one key for every segment.
        for uri in Set(playlist.segments.compactMap { $0.key?.uri }) {
            let key = try await downloader.data(at: uri, range: nil)
            guard key.count == 16 else { throw DownloadFailure("The stream's encryption key couldn't be read.") }
            keys[uri] = key
        }
    }

    func segment(_ index: Int) async throws -> Data {
        for j in index..<min(index + lookahead, count) where tasks[j] == nil {
            let segment = playlist.segments[j]
            let key = segment.key.flatMap { k in keys[k.uri].map { (k, $0) } }
            let downloader = self.downloader
            tasks[j] = Task {
                let raw = try await downloader.data(at: segment.url, range: segment.range)
                guard let pair = key else { return raw }
                let iv = pair.0.iv ?? SegmentFetcher.sequenceIV(segment.sequence)
                return try SegmentFetcher.decrypt(raw, key: pair.1, iv: iv)
            }
        }
        guard let task = tasks[index] else { throw DownloadFailure("A stream segment was skipped.") }
        defer { tasks[index] = nil }
        return try await task.value
    }

    func cancelAll() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
    }

    static func sequenceIV(_ sequence: Int) -> Data {
        var iv = Data(count: 8)
        var big = UInt64(sequence).bigEndian
        iv.append(Data(bytes: &big, count: 8))
        return iv
    }

    static func decrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
        var output = Data(count: data.count + kCCBlockSizeAES128)
        let capacity = output.count
        var moved = 0
        let status = output.withUnsafeMutableBytes { outRaw in
            data.withUnsafeBytes { inRaw in
                key.withUnsafeBytes { keyRaw in
                    iv.withUnsafeBytes { ivRaw in
                        CCCrypt(
                            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            keyRaw.baseAddress, key.count, ivRaw.baseAddress,
                            inRaw.baseAddress, data.count,
                            outRaw.baseAddress, capacity, &moved
                        )
                    }
                }
            }
        }
        guard status == CCCryptorStatus(kCCSuccess) else {
            throw DownloadFailure("A stream segment couldn't be decrypted.")
        }
        output.count = moved
        return output
    }
}
