import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// One writer per source. Files keep their original meeting offset even if a source starts late.
final class TrackWriter {
    static let rate = 16_000.0
    private let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
    private let folder: URL
    private let track: Track
    private var converter: AVAudioConverter?
    private var file: AVAudioFile?
    private var firstPTS: Double?
    private var lastPTS: Double?
    private var timelineBase: Double = 0
    private var written: Int64 = 0

    init(folder: URL, track: Track) { self.folder = folder; self.track = track }

    func append(_ sample: CMSampleBuffer, startHost: Double) throws -> Float {
        guard CMSampleBufferDataIsReady(sample), sample.numSamples > 0,
              let description = sample.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let inputFormat = AVAudioFormat(streamDescription: asbd) else { return 0 }
        let count = AVAudioFrameCount(sample.numSamples)
        guard let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: count) else {
            throw NoteError("無法配置錄音緩衝區。")
        }
        input.frameLength = count
        let copied = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(count), into: input.mutableAudioBufferList)
        guard copied == noErr else { throw NoteError("讀取\(track.title)時出錯（\(copied)）。") }
        if converter?.inputFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: format)
            converter?.primeMethod = .none
        }
        let capacity = AVAudioFrameCount(ceil(Double(count) * Self.rate / inputFormat.sampleRate)) + 64
        guard let converter, let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw NoteError("無法轉換\(track.title)的音訊格式。")
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return input
        }
        guard status != .error else { throw error ?? NoteError("音訊轉換失敗。") }
        guard output.frameLength > 0, let samples = output.floatChannelData?[0] else { return 0 }

        let arrival = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let rawPTS = sample.presentationTimeStamp.seconds
        let pts = rawPTS.isFinite ? rawPTS : arrival
        if file == nil {
            let clock = abs(pts - arrival) < 10 ? pts : arrival
            let offset = max(0, clock - startHost)
            try String(offset).write(to: folder.appendingPathComponent(track.rawValue + ".offset"), atomically: true, encoding: .utf8)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Self.rate, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
            ]
            file = try AVAudioFile(forWriting: folder.appendingPathComponent(track.rawValue + ".caf"),
                                   settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            firstPTS = pts
        }
        // A route change can restart a device's sample clock.
        if let previous = lastPTS, pts < previous - 0.1 {
            firstPTS = pts
            timelineBase = Double(written) / Self.rate
        }
        lastPTS = pts
        let elapsed = timelineBase + max(0, pts - (firstPTS ?? pts))
        let gap = Int64((elapsed * Self.rate).rounded()) - written
        if gap > Int64(Self.rate * 0.06) { try writeSilence(gap) }
        try file?.write(from: output)
        written += Int64(output.frameLength)
        var peak: Float = 0
        for index in 0..<Int(output.frameLength) { peak = max(peak, abs(samples[index])) }
        return peak
    }

    private func writeSilence(_ count: Int64) throws {
        let capacity: AVAudioFrameCount = 8192
        guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw NoteError("無法保持音軌同步。")
        }
        silence.floatChannelData?[0].initialize(repeating: 0, count: Int(capacity))
        var remaining = count
        while remaining > 0 {
            silence.frameLength = AVAudioFrameCount(min(Int64(capacity), remaining))
            try file?.write(from: silence)
            remaining -= Int64(silence.frameLength)
            written += Int64(silence.frameLength)
        }
    }
}

// Recorder lifetime is serialized by Notebook. All sample, level and writer state lives on queue.
final class MeetingRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "meetingnotes.audio", qos: .userInitiated)
    private var stream: SCStream?
    private var writers: [Track: TrackWriter] = [:]
    private let levels: @Sendable (Track, Float) -> Void
    private let failure: @Sendable (String) -> Void
    private var startHost: Double = 0
    private var microphoneOn = true
    private var failed = false
    private var lastLevel: [Track: Double] = [:]
    private var peaks: [Track: Float] = [:]

    init(folder: URL, levels: @escaping @Sendable (Track, Float) -> Void, failure: @escaping @Sendable (String) -> Void) {
        self.levels = levels
        self.failure = failure
        for track in [Track.microphone, .meeting] { writers[track] = TrackWriter(folder: folder, track: track) }
    }

    func start(source: MeetingSource) async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw NoteError("請在「系統設定 → 隱私權與安全性 → 麥克風」允許 Meeting Notes，再試一次。")
        }
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) }
        catch { throw NoteError("請允許 Meeting Notes 存取「螢幕與系統音訊錄製」，如系統提示請重開 App。\n" + error.localizedDescription) }
        let apps = content.applications.filter { source.includes($0.bundleIdentifier) }
        guard let display = content.displays.first, !apps.isEmpty else {
            throw NoteError("找不到正在執行的 \(source.title)。請先打開會議程式，或選擇實際開會的瀏覽器。")
        }
        let filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 1)
        config.capturesAudio = true
        config.captureMicrophone = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 1
        let capture = SCStream(filter: filter, configuration: config, delegate: self)
        try capture.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try capture.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        stream = capture
        queue.sync { startHost = CMClockGetTime(CMClockGetHostTimeClock()).seconds }
        try await capture.startCapture()
    }

    func setMicrophone(_ enabled: Bool) {
        queue.async { self.microphoneOn = enabled }
    }

    func stop() async {
        if let stream { try? await stream.stopCapture() }
        // Drain callbacks and close files before the transcriber reads them.
        await withCheckedContinuation { continuation in
            queue.async {
                self.failed = true
                self.writers.removeAll()
                continuation.resume()
            }
        }
        stream = nil
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { self.fail(error.localizedDescription) }
    }
    private func fail(_ message: String) {
        guard !failed else { return }
        failed = true
        failure(message)
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !failed else { return }
        let track: Track
        switch type {
        case .audio: track = .meeting
        case .microphone: track = .microphone
        default: return
        }
        do {
            let level = track == .microphone && !microphoneOn ? 0 : try writers[track]?.append(sampleBuffer, startHost: startHost) ?? 0
            let now = ProcessInfo.processInfo.systemUptime
            peaks[track] = max(peaks[track] ?? 0, level)
            if now - (lastLevel[track] ?? 0) > 0.15 {
                lastLevel[track] = now
                levels(track, peaks[track] ?? 0)
                peaks[track] = 0
            }
        } catch { fail(error.localizedDescription) }
    }
}
