import SwiftUI

private let mint = Color(red: 0.55, green: 0.96, blue: 0.78)

struct ChatView: View {
    @Bindable var chat: ChatController
    @State private var settings = false
    @State private var confirmClear = false

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if chat.messages.isEmpty { welcome }
                        if let issue = chat.modelIssue {
                            notice(issue, icon: "apple.intelligence")
                            Button("Check again") { chat.refreshAvailability() }.tint(mint)
                        }
                        ForEach(chat.messages) { message in messageCard(message) }
                        if !chat.liveTranscript.isEmpty {
                            Text(chat.liveTranscript).font(.title3).foregroundStyle(mint).padding(.horizontal, 8)
                        }
                        if let error = chat.error { notice(error, icon: "exclamationmark.circle") }
                        Color.clear.frame(height: 1).id("bottom")
                    }.padding(24)
                }
                .onChange(of: chat.messages.last?.text) { _, _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: chat.messages.last?.report) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: chat.liveTranscript) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
            controls
        }
        .background(Color(red: 0.035, green: 0.055, blue: 0.065))
        .sheet(isPresented: $settings) { settingsSheet }
        .confirmationDialog("Clear this conversation?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear conversation", role: .destructive) { chat.newConversation() }
        }
    }

    private var header: some View {
        HStack {
            HStack(spacing: 9) {
                Image(systemName: "waveform").foregroundStyle(mint)
                Text("expressive voices").font(.system(size: 24, weight: .semibold, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            Spacer()
            Button { confirmClear = true } label: { Image(systemName: "square.and.pencil").frame(width: 44, height: 44) }
                .accessibilityLabel("New conversation")
            Button { settings = true } label: { Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44) }
                .accessibilityLabel("Voice settings")
        }
        .foregroundStyle(.white).padding(.horizontal, 24).padding(.top, 10)
    }

    private func messageCard(_ message: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            label(message.isUser ? "YOU" : "ASSISTANT", color: message.isUser ? .secondary : mint)
            if message.text.isEmpty {
                ProgressView().tint(mint)
            } else {
                Text(message.text)
                    .font(.system(size: 18)).lineSpacing(5)
                    .textSelection(.enabled)
            }
            if let report = message.report {
                label("DIAGNOSTICS", color: .secondary).padding(.top, 6)
                Text(report).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(message.isUser ? Color.white.opacity(0.06) : mint.opacity(0.055), in: RoundedRectangle(cornerRadius: 22))
    }

    private func label(_ text: String, color: Color) -> some View {
        Text(text).font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(2).foregroundStyle(color)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 7) {
                Circle().fill(mint).frame(width: 5, height: 5)
                Text("ASK · THINK · SPEAK")
                    .font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1.5)
            }.foregroundStyle(mint)
            Text("Your question.\nA voice back.")
                .font(.system(size: 43, weight: .medium, design: .serif)).tracking(-1.5)
            Text("Tap the microphone and ask anything. Apple’s on-device model answers, and the voice you choose in settings speaks the reply while it is still being written. Then it listens again.")
                .font(.system(size: 16)).foregroundStyle(.secondary).lineSpacing(5)
            HStack(spacing: 5) {
                ForEach(0..<37) { index in
                    Capsule().fill(mint.opacity(index % 4 == 0 ? 0.9 : 0.35))
                        .frame(width: 3, height: CGFloat(12 + ((index * 17 + 7) % 45)))
                }
            }.frame(maxWidth: .infinity).frame(height: 85).accessibilityHidden(true)
        }.padding(.vertical, 28)
    }

    private var controls: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                TextField("Or type a question…", text: $chat.draft, axis: .vertical)
                    .lineLimit(1...4).submitLabel(.send).onSubmit { chat.sendDraft() }
                    .disabled(chat.isBusy)
                Button(action: chat.sendDraft) {
                    Image(systemName: "arrow.up").fontWeight(.semibold)
                        .frame(width: 38, height: 38).background(.white.opacity(0.08), in: Circle())
                }
                .disabled(!chat.canTalk || chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send message")
            }.padding(12).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 22))
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(chat.phase.rawValue).font(.subheadline.weight(.medium))
                    Text(chat.phase == .listening ? "Pause to send · tap to end" : chat.conversationActive ? "CONVERSATION ON · TAP TO END" : "ON-DEVICE · PRIVATE BY DESIGN")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .tracking(1).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button(action: chat.microphoneTapped) {
                    Image(systemName: chat.conversationActive || chat.isBusy ? "stop.fill" : "mic.fill")
                        .font(.system(size: 23, weight: .medium)).foregroundStyle(.black)
                        .frame(width: 68, height: 68)
                        .background(chat.phase == .listening ? Color.white : mint, in: Circle())
                }
                .disabled(!chat.isBusy && !chat.canTalk)
                .opacity(!chat.isBusy && !chat.canTalk ? 0.4 : 1)
                .accessibilityLabel(chat.conversationActive ? "End voice conversation" : chat.isBusy ? "Stop" : "Start voice conversation")
            }
        }.padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 18)
    }

    private func notice(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon).font(.subheadline).foregroundStyle(.secondary)
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section("Voice") {
                    Toggle("Speak replies", isOn: $chat.readAloud).disabled(chat.isBusy)
                    Picker("Engine", selection: $chat.engine) {
                        ForEach(chat.availableEngines) { Text($0.rawValue).tag($0) }
                    }.disabled(chat.isBusy)
                    if chat.engine.voices.count > 1 {
                        Picker("Voice", selection: $chat.voice) {
                            ForEach(chat.engine.voices) { Text($0.name).tag($0) }
                        }.disabled(chat.isBusy)
                    }
                    if chat.phase == .speaking {
                        Button("Stop", systemImage: "stop.fill") { chat.stop() }
                    } else {
                        Button("Play a sample", systemImage: "play.fill") { chat.playSample() }.disabled(chat.isBusy)
                    }
                    Text("Replies are spoken while Apple’s on-device model is still writing them. The iPhone voice needs no download. Downloaded models appear here as engines.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Voice models") {
                    ForEach(Speaker.Engine.allCases.filter { !$0.assets.isEmpty }) { modelRow($0) }
                    Text("Each model downloads once from Hugging Face and stays on your iPhone. Use Wi-Fi and keep the app open until it finishes. Versions of one model share some files; each size is what that version needs on its own.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Runs on your iPhone") {
                    Label("Apple Foundation Models · answers", systemImage: "apple.intelligence")
                    Label("Apple Speech · English transcription", systemImage: "mic")
                    Label("\(chat.engine.rawValue) · \(describe(chat.engine))", systemImage: "waveform")
                    Text("Microphone audio, answers and speech are processed locally. Conversations live in memory and clear when the app closes.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Link("MLX Audio · original project", destination: URL(string: "https://github.com/Blaizzy/mlx-audio")!)
                    Link("MLX Audio Swift · iPhone implementation", destination: URL(string: "https://github.com/Blaizzy/mlx-audio-swift")!)
                    ForEach(modelLinks, id: \.repo) { model in
                        Link("\(model.name) model and license", destination: URL(string: "https://huggingface.co/\(model.repo)")!)
                    }
                }
            }
            .tint(mint).navigationTitle("Voices")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { settings = false } } }
        }
    }

    /// One downloadable model: a download button, then progress as a percentage, then its size on disk.
    private func modelRow(_ engine: Speaker.Engine) -> some View {
        let state = chat.models.state(of: engine)
        let megabytes = engine.assets.reduce(0) { $0 + $1.megabytes }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(engine.rawValue)
                    Text(state == .notDownloaded ? "\(describe(engine)) · \(size(Int64(megabytes * 1_000_000)))" : describe(engine))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                switch state {
                case .notDownloaded:
                    Button("Download") { chat.models.download(engine) }
                        .buttonStyle(.bordered).fixedSize()
                case .downloading(let fraction):
                    Text("\(Int(fraction * 100))%").monospacedDigit().foregroundStyle(.secondary)
                case .downloaded(let bytes):
                    Label(size(bytes), systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                }
            }
            if case .downloading(let fraction) = state { ProgressView(value: fraction) }
            if let failure = chat.models.failures[engine] {
                Text(failure).font(.footnote).foregroundStyle(.red)
            }
        }
        // Otherwise the row's divider starts under the size label on the right.
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
    }

    private func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func describe(_ engine: Speaker.Engine) -> String {
        switch engine {
        case .system: "installed voice, no download"
        case .marvis: "expressive, conversational"
        case .kokoro: "clear reading, on the GPU"
        case .kokoroCoreML: "clear reading, on the Neural Engine"
        case .kokoroInt8: "clear reading, 8-bit, on the Neural Engine"
        case .supertonic(.int6): "expressive, 6-bit, on the CPU"
        case .supertonic(.int8): "expressive, 8-bit, on the CPU"
        case .supertonic(.int4): "expressive, 4-bit, on the Neural Engine"
        case .supertonic(.fp16): "expressive, full precision, on the CPU"
        }
    }

    /// One link for each model repository. Versions that come from the same one share
    /// its link, under the name they have in common.
    private var modelLinks: [(name: String, repo: String)] {
        var links: [(name: String, repo: String)] = []
        for engine in Speaker.Engine.allCases {
            guard let repo = engine.assets.first?.repo else { continue }
            if let shared = links.firstIndex(where: { $0.repo == repo }) {
                links[shared].name = engine.rawValue.components(separatedBy: " · ")[0]
            } else {
                links.append((engine.rawValue, repo))
            }
        }
        return links
    }
}
