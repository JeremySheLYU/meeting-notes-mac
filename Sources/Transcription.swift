import AVFoundation
import CryptoKit
import Foundation
import Speech

struct AudioActivity {
    let duration: Double
    let ranges: [ClosedRange<Double>]

    init(file url: URL) throws {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let rate = format.sampleRate
        guard rate > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 0.1)) else {
            throw NoteError("無法讀取音訊格式。")
        }
        var intervals: [ClosedRange<Double>] = []
        while file.framePosition < file.length {
            let start = Double(file.framePosition) / rate
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
            var active = false
            for channel in 0..<Int(format.channelCount) {
                var sum: Double = 0
                let count = Int(buffer.frameLength)
                for index in stride(from: 0, to: count, by: 4) {
                    let value = Double(channels[channel][index])
                    sum += value * value
                }
                if sum / Double(max(1, (count + 3) / 4)) > 0.0000008 { active = true; break }
            }
            if active {
                let end = Double(file.framePosition) / rate
                if let previous = intervals.last, start - previous.upperBound < 0.45 {
                    intervals[intervals.count - 1] = previous.lowerBound...end
                } else { intervals.append(start...end) }
            }
        }
        duration = Double(file.framePosition) / rate
        ranges = intervals
    }

    func containsSound(from start: Double, to end: Double) -> Bool {
        let lower = max(0, start - 0.2), upper = max(lower, end + 0.2)
        return ranges.contains { $0.lowerBound <= upper && $0.upperBound >= lower }
    }
}

struct Transcription {
    var segments: [Segment] = []
    var duration: Double = 0
    var engine = ""
    var silentTracks: [String] = []
}

private enum LocalWhisper {
    // Official model hashes also exclude partially downloaded checkpoints.
    static let hashes = [
        "tiny": "65147644a518d12f04e32d6f3b26facc3f8dd46e5390956a9424a650c0ce22b9",
        "base": "ed3a0b6b1c0edf879ad9b11b1af5a0e6ab5db9205f891f668f8b0e6c6326e34e",
        "small": "9ecf779972d90ba49c06d968637d720dd632c55bbf19d441fb42bf17a411e794",
        "medium": "345ae4da62f9b3d59415adc60127b97c714f32e89e936602e85993674d08dcb1",
        "large-v3": "e5b1a55b89c1367dacf97e3e19bfd829a01529dbfdeefa8caeb59b3f1b81dadb",
        "large-v3-turbo": "aff26ae408abcba5fbf8813c21e62b0941638c5f6eebfb145be0c9839262a19a"
    ]
    struct Installation {
        let executable: URL
        let model: URL
        let name: String
    }
    static func installation(quick: Bool, language: MeetingLanguage) throws -> Installation? {
        let files = FileManager.default
        let paths = ["/opt/homebrew/bin/whisper", "/usr/local/bin/whisper"]
        guard let executable = paths.first(where: files.isExecutableFile(atPath:)) else { return nil }
        let cache = ProcessInfo.processInfo.environment["XDG_CACHE_HOME"].map { URL(fileURLWithPath: $0) }
            ?? files.homeDirectoryForCurrentUser.appendingPathComponent(".cache")
        let folder = cache.appendingPathComponent("whisper")
        var choices = quick ? ["tiny","base","small","large-v3-turbo","medium","large-v3"]
                            : ["small","medium","large-v3-turbo","base","large-v3","tiny"]
        if language == .yue { choices = ["large-v3-turbo", "large-v3"] }
        for name in choices {
            let url = folder.appendingPathComponent(name + ".pt")
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            var digest = SHA256()
            do {
                while let data = try handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty { digest.update(data: data) }
                try handle.close()
            } catch { try? handle.close(); continue }
            let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
            if hash == hashes[name] { return Installation(executable: URL(fileURLWithPath: executable), model: url, name: name) }
        }
        return nil
    }

    struct Output: Decodable {
        struct Item: Decodable { let start: Double; let end: Double; let text: String }
        let segments: [Item]
    }
    static func run(_ inputs: [AudioInput], using install: Installation, language: MeetingLanguage) throws -> [[Output.Item]] {
        let files = FileManager.default
        let temporary = files.temporaryDirectory.appendingPathComponent("meetingnotes-" + UUID().uuidString)
        try files.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: temporary) }
        let logURL = temporary.appendingPathComponent("engine.log")
        try Data().write(to: logURL)
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        let job = Process()
        job.executableURL = install.executable
        job.currentDirectoryURL = temporary
        var arguments = inputs.map { $0.url.path }
        arguments += ["--model", install.model.path, "--device", "cpu", "--fp16", "False", "--threads", "4",
                      "--task", "transcribe", "--condition_on_previous_text", "False", "--verbose", "False",
                      "--output_format", "json", "--output_dir", temporary.path]
        if language != .auto { arguments += ["--language", language.rawValue] }
        job.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        env["MPLCONFIGDIR"] = temporary.path
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        job.environment = env
        job.standardOutput = log
        job.standardError = log
        try job.run()
        job.waitUntilExit()
        func failure() -> NoteError {
            let tail = ((try? String(contentsOf: logURL, encoding: .utf8)) ?? "").suffix(380)
            return NoteError("Whisper 未能完成轉錄。請確認本機可執行 whisper 和 ffmpeg，再重試。\n\(tail)")
        }
        guard job.terminationStatus == 0 else { throw failure() }
        return try inputs.map { input in
            let name = input.url.deletingPathExtension().lastPathComponent + ".json"
            guard let data = try? Data(contentsOf: temporary.appendingPathComponent(name)),
                  let result = try? JSONDecoder().decode(Output.self, from: data) else { throw failure() }
            return result.segments
        }
    }
}

enum Transcriber {
    static func run(_ inputs: [AudioInput], language: MeetingLanguage, quick: Bool,
                    status: @escaping @Sendable (String) -> Void) async throws -> Transcription {
        guard !inputs.isEmpty else { throw NoteError("這次沒有音檔。請檢查音訊權限及會議來源。") }
        var result = Transcription()
        var audible: [(AudioInput, AudioActivity)] = []
        for input in inputs {
            let scan = try AudioActivity(file: input.url)
            result.duration = max(result.duration, input.offset + scan.duration)
            if scan.ranges.isEmpty { result.silentTracks.append(input.track.title) }
            else { audible.append((input, scan)) }
        }
        guard !audible.isEmpty else { return result }
        status("準備本機語音模型…")
        if let install = try LocalWhisper.installation(quick: quick, language: language) {
            result.engine = "Whisper · " + install.name
            status("正在本機轉錄 · Whisper \(install.name)")
            let outputs = try LocalWhisper.run(audible.map { $0.0 }, using: install, language: language)
            for ((input, scan), items) in zip(audible, outputs) {
                for item in items where scan.containsSound(from: item.start, to: item.end) {
                    let segment = Segment(input.offset + item.start, input.track, item.text)
                    if !segment.text.isEmpty { result.segments.append(segment) }
                }
            }
        } else {
            guard language != .auto else {
                throw NoteError("此 Mac 沒有可用的本機 Whisper 模型。請在下方選擇會議語言再重試，改用 Apple 離線轉錄。")
            }
            guard SpeechTranscriber.isAvailable, let locale = await SpeechTranscriber.supportedLocale(equivalentTo: language.locale) else {
                throw NoteError("這台 Mac 的 Apple 語音模型未支援所選語言。可改用其他語言，或安裝支援該語言的本機 Whisper 模型。")
            }
            result.engine = "Apple Speech"
            for (input, scan) in audible {
                let module = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
                if let installation = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                    status("正在下載 Apple 的\(language.title)語音模型…")
                    try await installation.downloadAndInstall()
                }
                status("正在本機轉錄 · " + input.track.title)
                let file = try AVAudioFile(forReading: input.url)
                let analyzer = SpeechAnalyzer(modules: [module])
                async let collected: [Segment] = collect(module, input: input, activity: scan)
                do {
                    if let last = try await analyzer.analyzeSequence(from: file) { try await analyzer.finalizeAndFinish(through: last) }
                    else { await analyzer.cancelAndFinishNow() }
                    result.segments += try await collected
                } catch { await analyzer.cancelAndFinishNow(); throw error }
            }
        }
        result.segments.sort { $0.start < $1.start }
        return result
    }
    private static func collect(_ module: SpeechTranscriber, input: AudioInput, activity: AudioActivity) async throws -> [Segment] {
        var segments: [Segment] = []
        for try await part in module.results {
            let start = part.range.start.seconds, end = part.range.end.seconds
            guard activity.containsSound(from: start, to: end) else { continue }
            let s = Segment(start + input.offset, input.track, String(part.text.characters))
            if !s.text.isEmpty { segments.append(s) }
        }
        return segments
    }
}
