import Foundation

struct NoteError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum MeetingSource: String, CaseIterable, Codable, Identifiable {
    case zoom, teams, chrome, safari, tencent
    var id: Self { self }
    var title: String {
        switch self {
        case .zoom: return "Zoom"
        case .teams: return "Microsoft Teams"
        case .chrome: return "Google Chrome（含 Meet）"
        case .safari: return "Safari（含 Meet）"
        case .tencent: return "騰訊會議 / VooV"
        }
    }
    var isBrowser: Bool { self == .chrome || self == .safari }
    func includes(_ identifier: String) -> Bool {
        let ids: [String]
        switch self {
        case .zoom: ids = ["us.zoom.xos"]
        case .teams: ids = ["com.microsoft.teams", "com.microsoft.teams2"]
        case .chrome: ids = ["com.google.Chrome"]
        case .safari: ids = ["com.apple.Safari"]
        case .tencent: ids = ["com.tencent.meeting", "com.tencent.tencentmeeting", "com.tencent.voovmeeting"]
        }
        let candidate = identifier.lowercased()
        return ids.contains { candidate == $0.lowercased() || candidate.hasPrefix($0.lowercased() + ".") }
    }
}

enum MeetingLanguage: String, CaseIterable, Codable, Identifiable {
    case auto, en, zh, yue
    var id: Self { self }
    var title: String {
        switch self {
        case .auto: return "自動辨識"
        case .en: return "English"
        case .zh: return "普通話"
        case .yue: return "廣東話"
        }
    }
    var locale: Locale {
        switch self {
        case .auto: return .current
        case .en: return Locale(identifier: "en-US")
        case .zh: return Locale(identifier: "zh-CN")
        case .yue: return Locale(identifier: "yue-HK")
        }
    }
}

enum Track: String, Codable {
    case microphone, meeting, imported
    var title: String {
        switch self {
        case .microphone: return "我的麥克風"
        case .meeting: return "會議音訊"
        case .imported: return "錄音"
        }
    }
}

struct Segment: Codable, Identifiable, Equatable {
    let id: UUID
    let start: Double
    let track: Track
    let text: String
    init(_ start: Double, _ track: Track, _ text: String) {
        self.id = UUID()
        self.start = max(0, start)
        self.track = track
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

func timestamp(_ seconds: Double) -> String {
    let value = max(0, Int(seconds.isFinite ? seconds : 0))
    if value >= 3600 { return String(format: "%d:%02d:%02d", value/3600, value/60%60, value%60) }
    return String(format: "%02d:%02d", value/60, value%60)
}

struct Meeting: Codable, Identifiable {
    let id: UUID
    var title: String
    let created: Date
    let source: String
    var language: MeetingLanguage
    var duration: Double = 0
    var state: State = .unfinished
    var summary = ""
    var summaryEngine = ""
    var transcriptEngine = ""
    var notice = ""
    var segments: [Segment] = []
    enum State: String, Codable { case unfinished, audioReady, transcribed, complete }

    var markdown: String {
        let lines = segments.map { "[\(timestamp($0.start))] \($0.track.title)　\($0.text)" }
        return [
            "# " + title,
            created.formatted(date: .abbreviated, time: .shortened) + " · " + source,
            "## 會議摘要", summary.isEmpty ? "尚未整理" : summary,
            summaryEngine, "## 逐字稿", lines.joined(separator: "\n\n")
        ].filter { !$0.isEmpty }.joined(separator: "\n\n") + "\n"
    }
}

struct AudioInput {
    let url: URL
    let track: Track
    let offset: Double
}

struct MeetingStore {
    let root: URL
    let files = FileManager.default

    static var standard: Self {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return Self(root: support.appendingPathComponent("MeetingNotesLocal/Meetings", isDirectory: true))
    }
    func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func save(_ note: Meeting) throws {
        let dir = folder(note.id)
        try files.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(note).write(to: dir.appendingPathComponent("meeting.json"), options: .atomic)
    }
    func load() -> [Meeting] {
        let dirs = (try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { dir -> Meeting? in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("meeting.json")) else { return nil }
            return try? JSONDecoder().decode(Meeting.self, from: data)
        }.sorted { $0.created > $1.created }
    }
    func inputs(_ id: UUID) -> [AudioInput] {
        let dir = folder(id)
        let urls = (try? files.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return urls.compactMap { url -> AudioInput? in
            guard let track = Track(rawValue: url.deletingPathExtension().lastPathComponent),
                  !["offset", "json"].contains(url.pathExtension) else { return nil }
            let clock = dir.appendingPathComponent(track.rawValue + ".offset")
            let offset = (try? String(contentsOf: clock, encoding: .utf8)).flatMap(Double.init) ?? 0
            return AudioInput(url: url, track: track, offset: offset)
        }.sorted { $0.track.rawValue < $1.track.rawValue }
    }
}
