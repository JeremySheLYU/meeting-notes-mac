import AppKit
import AVFoundation
import CoreAudio
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class Notebook: ObservableObject {
    enum Phase { case idle, waiting, starting, recording, stopping, processing }
    @Published private(set) var meetings: [Meeting]
    @Published var selected: UUID? { didSet { if oldValue != selected { stopPlayback() } } }
    @Published var title = ""
    @Published var source = MeetingSource(rawValue: UserDefaults.standard.string(forKey: "source") ?? "") ?? .zoom {
        didSet { UserDefaults.standard.set(source.rawValue, forKey: "source") }
    }
    @Published var language = MeetingLanguage(rawValue: UserDefaults.standard.string(forKey: "language") ?? "") ?? .auto {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "language") }
    }
    @Published var quick = UserDefaults.standard.bool(forKey: "quick") {
        didSet { UserDefaults.standard.set(quick, forKey: "quick") }
    }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var status = ""
    @Published var alert: String?
    @Published var microphoneOn = true { didSet { recorder?.setMicrophone(microphoneOn) } }
    @Published private(set) var levels: [Track: (Date, Float)] = [:]
    @Published private(set) var playingSegment: UUID?
    private var player: AVAudioPlayer?
    private var playbackEnd: Task<Void, Never>?
    private(set) var started = Date()
    let store: MeetingStore
    private var recorder: MeetingRecorder?
    private var watchTask: Task<Void, Never>?
    private var currentID: UUID?
    private var startupFault: String?
    private var activity: NSObjectProtocol?

    init(store: MeetingStore = .standard) {
        self.store = store
        self.meetings = store.load()
    }
    var selection: Meeting? { meetings.first { $0.id == selected } }
    var busy: Bool { phase != .idle }
    private func keepAwake() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "錄製或整理這次會議")
    }
    private func idle() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        phase = .idle
        currentID = nil
        status = ""
    }
    func newMeeting() {
        guard !busy else { return }
        selected = nil
        title = ""
    }
    private func makeNote(source: String, fallback: String) -> Meeting {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return Meeting(id: UUID(), title: name.isEmpty ? fallback : name, created: Date(), source: source, language: language)
    }
    private func commit(_ note: Meeting) throws {
        try store.save(note)
        meetings.removeAll { $0.id == note.id }
        meetings.append(note)
        meetings.sort { $0.created > $1.created }
    }
    func armForCall() {
        guard !busy, !source.isBrowser else { return }
        let target = source
        stopPlayback()
        phase = .waiting
        status = "等待 " + target.title + " 啟用麥克風"
        watchTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let detected = try await Task.detached(priority: .utility) {
                        try AudioHardwareSystem.shared.processes.contains { process in
                            guard let identifier = try? process.bundleID, target.includes(identifier) else { return false }
                            return (try? process.isRunningInput) == true
                        }
                    }.value
                    guard !Task.isCancelled, let self, self.phase == .waiting else { return }
                    if detected {
                        self.watchTask = nil
                        self.idle()
                        self.start()
                        return
                    }
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled, let self else { return }
                self.cancelWaiting()
                self.alert = "無法偵測會議程式的麥克風狀態，請按「開始錄音」。\n" + error.localizedDescription
            }
        }
    }
    func cancelWaiting() {
        guard phase == .waiting else { return }
        watchTask?.cancel()
        watchTask = nil
        idle()
    }
    func start() {
        guard !busy else { return }
        stopPlayback()
        let selectedSource = source
        let note = makeNote(source: source.title, fallback: source.title + " 會議")
        do { try store.save(note) } catch { alert = error.localizedDescription; return }
        phase = .starting
        status = "正在連接麥克風與\(selectedSource.title)…"
        currentID = note.id
        startupFault = nil
        levels = [:]
        microphoneOn = true
        let capture = MeetingRecorder(folder: store.folder(note.id)) { [weak self] track, level in
            Task { @MainActor in
                if self?.currentID == note.id { self?.levels[track] = (Date(), level) }
            }
        } failure: { [weak self] message in
            Task { @MainActor in
                guard let self, self.currentID == note.id else { return }
                if self.phase == .starting { self.startupFault = message }
                else if self.phase == .recording { await self.finish(reason: message) }
            }
        }
        recorder = capture
        Task {
            do {
                try await capture.start(source: selectedSource)
                try commit(note)
                selected = note.id
                started = Date()
                phase = .recording
                keepAwake()
                if let startupFault { await finish(reason: startupFault) }
            } catch {
                await capture.stop()
                recorder = nil
                if store.inputs(note.id).isEmpty { try? FileManager.default.removeItem(at: store.folder(note.id)) }
                else { meetings = store.load(); selected = note.id }
                idle()
                alert = error.localizedDescription
            }
        }
    }
    func finish(reason: String? = nil, process: Bool = true) async {
        guard phase == .recording, let id = currentID, var note = meetings.first(where: { $0.id == id }) else { return }
        phase = .stopping
        status = "正在保存錄音…"
        note.duration = Date().timeIntervalSince(started)
        await recorder?.stop()
        recorder = nil
        levels = [:]
        note.state = .audioReady
        if let reason { note.notice = "錄音曾中斷。已保留中斷前的音訊。\n" + reason }
        do { try commit(note) } catch { idle(); alert = error.localizedDescription; return }
        if process { await processNote(note, language: note.language) } else { idle() }
    }
    func importAudio() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.wav, .aiff, .mp3, .mpeg4Audio, .audio]
        panel.allowsMultipleSelection = false
        panel.prompt = "匯入錄音"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        beginImport(url)
    }
    func beginImport(_ url: URL) {
        guard !busy else { return }
        stopPlayback()
        var note = makeNote(source: "匯入錄音", fallback: url.deletingPathExtension().lastPathComponent)
        note.state = .audioReady
        phase = .processing
        status = "正在匯入錄音…"
        let dir = store.folder(note.id)
        Task {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let destination = dir.appendingPathComponent("imported").appendingPathExtension(url.pathExtension)
                try await Task.detached { try FileManager.default.copyItem(at: url, to: destination) }.value
                try commit(note)
                selected = note.id
                await processNote(note, language: note.language)
            } catch {
                if !FileManager.default.fileExists(atPath: dir.appendingPathComponent("meeting.json").path) {
                    try? FileManager.default.removeItem(at: dir)
                }
                idle()
                alert = error.localizedDescription
            }
        }
    }
    func retry(_ note: Meeting, language: MeetingLanguage) {
        guard !busy else { return }
        phase = .processing
        Task { await processNote(note, language: language) }
    }
    private func processNote(_ original: Meeting, language: MeetingLanguage) async {
        stopPlayback()
        phase = .processing
        currentID = original.id
        keepAwake()
        status = "檢查錄音…"
        var note = original
        let inputs = store.inputs(note.id)
        let fast = quick
        do {
            let report: @Sendable (String) -> Void = { [weak self] progress in
                Task { @MainActor in if self?.currentID == original.id { self?.status = progress } }
            }
            let transcription = try await Task.detached(priority: .userInitiated) {
                try await Transcriber.run(inputs, language: language, quick: fast, status: report)
            }.value
            note.language = language
            note.segments = transcription.segments
            note.transcriptEngine = transcription.engine
            note.duration = max(note.duration, transcription.duration)
            var silent = transcription.silentTracks
            if !inputs.contains(where: { $0.track == .imported }) {
                for track in [Track.meeting, .microphone] where !inputs.contains(where: { $0.track == track }) { silent.append(track.title) }
            }
            let warnings = [original.notice.hasPrefix("錄音曾中斷") ? String(original.notice.components(separatedBy: "\n未收到").first ?? "") : "",
                            silent.isEmpty ? "" : "未收到可辨識的聲音：" + silent.joined(separator: "、")]
            note.notice = warnings.filter { !$0.isEmpty }.joined(separator: "\n")
            note.state = .transcribed
            note.summary = ""
            note.summaryEngine = ""
            try commit(note)
            try await saveSummary(note)
        } catch { alert = error.localizedDescription }
        idle()
    }
    private func saveSummary(_ original: Meeting) async throws {
        status = "正在整理會議摘要…"
        let summary = await Task.detached(priority: .userInitiated) { await Summarizer.run(original.segments) }.value
        var note = original
        note.summary = summary.text
        note.summaryEngine = summary.engine
        note.state = .complete
        try commit(note)
    }
    func summarizeAgain(_ note: Meeting) {
        guard !busy else { return }
        phase = .processing
        currentID = note.id
        keepAwake()
        Task {
            do { try await saveSummary(note) } catch { alert = error.localizedDescription }
            idle()
        }
    }
    func export(_ note: Meeting) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = note.title.replacingOccurrences(of: "/", with: "-") + ".md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try note.markdown.write(to: url, atomically: true, encoding: .utf8) } catch { alert = error.localizedDescription }
    }
    func reveal(_ note: Meeting) {
        NSWorkspace.shared.activateFileViewerSelecting([store.folder(note.id)])
    }
    func togglePlayback(_ note: Meeting, at segment: Segment) {
        let wasPlaying = playingSegment == segment.id
        stopPlayback()
        guard !wasPlaying, !busy, let input = store.inputs(note.id).first(where: { $0.track == segment.track }) else { return }
        do {
            let audio = try AVAudioPlayer(contentsOf: input.url)
            audio.currentTime = min(audio.duration, max(0, segment.start - input.offset))
            guard audio.play() else { throw NoteError("未能播放這段錄音。") }
            player = audio
            playingSegment = segment.id
            let remaining = max(0, audio.duration - audio.currentTime)
            playbackEnd = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                if !Task.isCancelled { self?.stopPlayback() }
            }
        } catch { alert = error.localizedDescription }
    }
    private func stopPlayback() {
        playbackEnd?.cancel()
        playbackEnd = nil
        player?.stop()
        player = nil
        if playingSegment != nil { playingSegment = nil }
    }
}
