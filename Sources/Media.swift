import AVFoundation

/// 音檔處理全用 AVFoundation：ffmpeg 是 GPL，不能跟 app 一起散布
enum Media {
    /// 在背景執行緒同步等 AVFoundation 的 async API（呼叫端都在背景佇列）
    static func wait<T>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<T, Error>?
        Task.detached {
            do { result = .success(try await work()) } catch { result = .failure(error) }
            sem.signal()
        }
        sem.wait()
        return try result!.get()
    }

    /// 第一條音軌的聲道數，以及 metadata 的 comment（MeetRec 標記放這裡）
    static func info(_ url: URL) throws -> (channels: Int, comment: String?) {
        try wait {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw MediaError.noAudio }
            let desc = try await track.load(.formatDescriptions).first
            let channels = desc.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame }.map(Int.init) ?? 1
            let meta = try await asset.load(.metadata)
            let comment = try await AVMetadataItem.metadataItems(from: meta, filteredByIdentifier: .iTunesMetadataUserComment).first?.load(.stringValue)
            return (channels, comment)
        }
    }

    /// 解碼成 16 kHz float，每個聲道一個陣列（最多兩聲道）
    static func decode16k(_ url: URL) throws -> [[Float]] {
        try wait {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw MediaError.noAudio }
            let desc = try await track.load(.formatDescriptions).first
            let source = desc.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame }.map(Int.init) ?? 1
            let channels = min(max(source, 1), 2)
            let seconds = try await asset.load(.duration).seconds
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
                AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: channels,
            ])
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? MediaError.decode }
            var out = [[Float]](repeating: [], count: channels)
            // 一次預留整段的空間：每段都 reserveCapacity 會反覆搬整個陣列，23 分鐘的錄音要多花半分鐘
            for c in 0..<channels { out[c].reserveCapacity(Int(seconds * 16000) + 16000) }
            while let sample = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
                var length = 0
                var pointer: UnsafeMutablePointer<CChar>?
                CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
                guard let pointer else { continue }
                let f = UnsafeRawPointer(pointer).assumingMemoryBound(to: Float.self)
                let frames = length / 4 / channels
                for c in 0..<channels {
                    for i in 0..<frames { out[c].append(f[i * channels + c]) }
                }
            }
            if reader.status == .failed { throw reader.error ?? MediaError.decode }
            return out
        }
    }

    /// 16 kHz 單聲道 16-bit wav（whisper.cpp、sherpa-onnx 都吃這個）
    static func writeWav(_ samples: [Float], to url: URL) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = 16000 * 60
        for start in stride(from: 0, to: samples.count, by: chunk) {
            let n = min(chunk, samples.count - start)
            let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
            buf.frameLength = AVAudioFrameCount(n)
            samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress! + start, count: n) }
            try file.write(from: buf)
        }
    }

    /// 不重新編碼、只換容器（ADTS .aac → .m4a），順便寫 comment
    static func remux(_ src: URL, to dst: URL, comment: String) throws {
        try export(src, to: dst, preset: AVAssetExportPresetPassthrough, comment: comment)
    }

    /// 轉成 AAC m4a（匯入影片或其他格式）
    static func convertToM4A(_ src: URL, to dst: URL) throws {
        try export(src, to: dst, preset: AVAssetExportPresetAppleM4A, comment: nil)
    }

    private static func export(_ src: URL, to dst: URL, preset: String, comment: String?) throws {
        try? FileManager.default.removeItem(at: dst)
        try wait {
            let asset = AVURLAsset(url: src)
            guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else { throw MediaError.noAudio }
            guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { throw MediaError.unsupported }
            if let comment {
                let item = AVMutableMetadataItem()
                item.identifier = .iTunesMetadataUserComment
                item.value = comment as NSString
                session.metadata = [item]
            }
            try await session.export(to: dst, as: .m4a)
        }
    }
}

enum MediaError: Error, CustomStringConvertible {
    case noAudio, decode, unsupported
    var description: String {
        switch self {
        case .noAudio: return "檔案裡沒有聲音"
        case .decode: return "讀不了這個音檔"
        case .unsupported: return "不支援這個格式"
        }
    }
}
