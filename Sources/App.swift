import AppKit
import SwiftUI

@main struct MeetingNotesApp: App {
    @StateObject private var book = Notebook()
    @NSApplicationDelegateAdaptor(NotesDelegate.self) private var delegate
    var body: some Scene {
        Window("Meeting Notes", id: "notebook") {
            NotebookView(book: book)
                .onAppear { delegate.book = book }
        }
        .defaultSize(width: 920, height: 625)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新增會議") { book.newMeeting() }.keyboardShortcut("n").disabled(book.busy)
                Button("匯入錄音…") { book.importAudio() }.keyboardShortcut("o").disabled(book.busy)
            }
        }
        MenuBarExtra("Meeting Notes", systemImage: book.phase == .recording ? "record.circle.fill" : "waveform") {
            MenuControls(book: book)
        }
    }
}

@MainActor final class NotesDelegate: NSObject, NSApplicationDelegate {
    weak var book: Notebook?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let book, book.busy else { return .terminateNow }
        if book.phase == .waiting { book.cancelWaiting(); return .terminateNow }
        let dialog = NSAlert()
        if book.phase == .recording {
            dialog.messageText = "要先保存這次錄音嗎？"
            dialog.informativeText = "保存後可在下次打開時轉錄。"
            dialog.addButton(withTitle: "繼續錄音")
            dialog.addButton(withTitle: "保存並結束")
            guard dialog.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
            Task { await book.finish(process: false); sender.reply(toApplicationShouldTerminate: true) }
            return .terminateLater
        }
        dialog.messageText = "Meeting Notes 正在處理音訊"
        dialog.informativeText = "可以讓這項工作完成後再結束 App。"
        dialog.addButton(withTitle: "留在 App")
        dialog.addButton(withTitle: "完成後結束")
        guard dialog.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        Task {
            while book.busy {
                if book.phase == .recording { await book.finish(process: false); break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

private struct MenuControls: View {
    @ObservedObject var book: Notebook
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("打開會議筆記") { openWindow(id: "notebook"); NSApp.activate(ignoringOtherApps: true) }
        if book.phase == .recording {
            Button("停止並整理") { Task { await book.finish() } }
        }
        if book.phase == .waiting { Button("取消自動開始") { book.cancelWaiting() } }
        Divider()
        Button("結束 Meeting Notes") { NSApp.terminate(nil) }
    }
}

private let green = Color(red: 0.17, green: 0.43, blue: 0.35)

private struct NotebookView: View {
    @ObservedObject var book: Notebook
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 14) {
                Label("會議筆記", systemImage: "waveform").font(.title2.weight(.semibold)).padding(.top, 15)
                Button { book.newMeeting() } label: {
                    Label("新增會議", systemImage: "plus").frame(maxWidth: .infinity)
                }.controlSize(.large).disabled(book.busy)
                Text("最近會議").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 8)
                if book.meetings.isEmpty {
                    Text("還沒有會議記錄").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(book.meetings) { note in
                                Button { book.selected = note.id } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(note.title).font(.body.weight(.medium)).lineLimit(1)
                                        Text(note.created.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }.padding(9).frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                        .background(note.id == book.selected ? green.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 7))
                                }.buttonStyle(.plain).disabled(book.busy && book.selected != note.id)
                            }
                        }
                    }
                }
                Divider()
                Button { book.importAudio() } label: { Label("匯入錄音…", systemImage: "square.and.arrow.down") }
                    .buttonStyle(.plain).disabled(book.busy).padding(.bottom, 10)
            }
            .padding(.horizontal, 16)
            .navigationSplitViewColumnWidth(min: 176, ideal: 212, max: 260)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if book.phase == .waiting {
                        Text("等待會議").font(.largeTitle.bold())
                        Text(book.status).font(.headline)
                        Text("只等這一次。程式開始使用麥克風時會開始錄音，測試麥克風也可能觸發。").foregroundStyle(.secondary)
                        HStack {
                            Button("立即開始") { book.cancelWaiting(); book.start() }.buttonStyle(.borderedProminent)
                            Button("取消等待") { book.cancelWaiting() }
                        }.controlSize(.large)
                    } else if book.phase == .recording { RecordingView(book: book) }
                    else if let note = book.selection { DetailView(book: book, note: note).id(note.id) }
                    else { SetupView(book: book) }
                    if book.busy && book.phase != .recording && book.phase != .waiting {
                        HStack(spacing: 10) { ProgressView().controlSize(.small); Text(book.status).font(.callout) }
                            .padding(.vertical, 8).accessibilityElement(children: .combine)
                    }
                }.padding(34).frame(maxWidth: 830, alignment: .leading).frame(maxWidth: .infinity, alignment: .topLeading)
            }.background(scheme == .dark ? Color(nsColor: .windowBackgroundColor) : Color(red: 0.978, green: 0.977, blue: 0.957))
        }
        .tint(green)
        .frame(minWidth: 740, minHeight: 475)
        .alert("會議筆記", isPresented: Binding(get: { book.alert != nil }, set: { if !$0 { book.alert = nil } })) {
            Button("知道了") { book.alert = nil }
        } message: { Text(book.alert ?? "") }
    }
}

private struct SetupView: View {
    @ObservedObject var book: Notebook
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("錄製會議").font(.system(size: 32, weight: .semibold))
            TextField("會議名稱（選填）", text: $book.title)
                .textFieldStyle(.roundedBorder).controlSize(.large)
            Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 16) {
                GridRow {
                    Text("會議程式")
                    Picker("會議程式", selection: $book.source) { ForEach(MeetingSource.allCases) { Text($0.title).tag($0) } }.labelsHidden()
                }
                GridRow {
                    Text("會議語言")
                    Picker("會議語言", selection: $book.language) { ForEach(MeetingLanguage.allCases) { Text($0.title).tag($0) } }.labelsHidden()
                }
            }.controlSize(.large)
            if book.source.isBrowser { Text("會收錄所選瀏覽器正在播放的聲音。開會時可先將其他有聲音的分頁靜音。").font(.callout).foregroundStyle(.secondary) }
            Toggle("快速轉錄（優先使用較小的 Whisper 模型）", isOn: $book.quick).toggleStyle(.checkbox).font(.callout)
            Divider()
            VStack(alignment: .leading, spacing: 9) {
                Text("開始前，請先取得與會者同意。").font(.body.weight(.medium))
                Text("錄音只存在這台 Mac。按下停止後，會自動產生逐字稿及摘要。").font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button { book.start() } label: { Label("開始錄音", systemImage: "record.circle").padding(.horizontal, 7) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: [.command])
                if !book.source.isBrowser {
                    Button("等會議開始時自動錄音") { book.armForCall() }
                        .help("這次會議程式啟用麥克風時，自動開始錄音")
                }
            }.controlSize(.large)
        }.disabled(book.busy).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RecordingView: View {
    @ObservedObject var book: Notebook
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { timeline in
            VStack(alignment: .leading, spacing: 20) {
                HStack { Circle().fill(.red).frame(width: 9,height: 9); Text("錄音中").font(.headline) }
                Text(book.selection?.title ?? "會議").font(.largeTitle.bold())
                Text(timestamp(timeline.date.timeIntervalSince(book.started)))
                    .font(.system(size: 40, weight: .medium, design: .monospaced)).monospacedDigit()
                ForEach([Track.meeting, .microphone], id: \.self) { track in
                    let item = book.levels[track]
                    let fresh = item.map { timeline.date.timeIntervalSince($0.0) < 0.8 } ?? false
                    let peak = fresh ? Double(item?.1 ?? 0) : 0
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(track.title)
                            Spacer()
                            Text(peak > 0.002 ? "收到聲音" : "安靜")
                                .foregroundStyle(.secondary).font(.caption)
                        }
                        ProgressView(value: min(1, sqrt(peak))).progressViewStyle(.linear)
                    }
                }
                Toggle("錄下我的麥克風", isOn: $book.microphoneOn).toggleStyle(.switch)
                Text("這個開關獨立於會議程式的靜音鍵。").font(.callout).foregroundStyle(.secondary)
                Button { Task { await book.finish() } } label: { Label("停止並整理", systemImage: "stop.fill") }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
    }
}

private final class DetailOptions: ObservableObject {
    @Published var tab = 0
    @Published var language: MeetingLanguage = .auto
}

private struct DetailView: View {
    @ObservedObject var book: Notebook
    let note: Meeting
    @StateObject private var options = DetailOptions()
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text(note.title).font(.system(size: 30, weight: .semibold)).textSelection(.enabled)
            Text([note.source, note.created.formatted(date: .abbreviated, time: .shortened), timestamp(note.duration)]
                .joined(separator: "  ·  ")).foregroundStyle(.secondary).font(.callout)
            if !note.notice.isEmpty { Text(note.notice).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            if note.state == .complete || note.state == .transcribed {
                Picker("檢視", selection: $options.tab) { Text("會議摘要").tag(0); Text("逐字稿").tag(1) }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 270)
                if options.tab == 0 {
                    if !note.summaryEngine.isEmpty { Text(note.summaryEngine).font(.caption.weight(.medium)).foregroundStyle(.secondary) }
                    Text(note.summary.isEmpty ? "等待整理摘要。" : note.summary).lineSpacing(4).textSelection(.enabled)
                } else if note.segments.isEmpty { Text("沒有辨識到發言。").foregroundStyle(.secondary) }
                else {
                    Text(note.transcriptEngine).font(.caption).foregroundStyle(.secondary)
                    LazyVStack(alignment: .leading, spacing: 13) {
                        ForEach(note.segments) { segment in
                            VStack(alignment: .leading, spacing: 3) {
                                Button { book.togglePlayback(note, at: segment) } label: {
                                    Label(timestamp(segment.start) + "   " + segment.track.title,
                                          systemImage: book.playingSegment == segment.id ? "stop.circle.fill" : "play.circle")
                                }.buttonStyle(.plain).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    .help("從這裡播放這條音軌，再按一下可停止").disabled(book.busy)
                                Text(segment.text).textSelection(.enabled)
                            }
                        }
                    }
                }
                Divider()
                HStack {
                    Button("匯出 Markdown…") { book.export(note) }
                    Button("重新整理摘要") { book.summarizeAgain(note) }
                    Menu("重新轉錄") { ForEach(MeetingLanguage.allCases) { language in
                        Button(language.title) { book.retry(note, language: language) }
                    } }
                }.disabled(book.busy)
            } else if !book.busy {
                Text("已保存音檔，可繼續轉錄。").foregroundStyle(.secondary)
            }
            if !book.busy {
                if note.state != .complete {
                    HStack {
                        Picker("語言", selection: $options.language) { ForEach(MeetingLanguage.allCases) { Text($0.title).tag($0) } }
                            .frame(maxWidth: 210)
                        Button("從錄音轉錄") { book.retry(note, language: options.language) }
                    }
                }
                Button { book.reveal(note) } label: { Label("在 Finder 查看音檔", systemImage: "folder") }
                    .buttonStyle(.link)
            }
        }.onAppear { options.language = note.language }
    }
}
