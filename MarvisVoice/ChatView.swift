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
                        if chat.replyVoice == .marvis && !chat.voiceReady { setupCard }
                        ForEach(chat.messages) { message in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(message.isUser ? "YOU" : "MARVIS")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .tracking(2).foregroundStyle(message.isUser ? .secondary : mint)
                                if message.text.isEmpty {
                                    ProgressView().tint(mint)
                                } else {
                                    Text(message.text)
                                        .font(.system(size: 18)).lineSpacing(5)
                                        .textSelection(.enabled)
                                }
                            }
                            .padding(20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(message.isUser ? Color.white.opacity(0.06) : mint.opacity(0.055), in: RoundedRectangle(cornerRadius: 22))
                        }
                        if !chat.liveTranscript.isEmpty {
                            Text(chat.liveTranscript).font(.title3).foregroundStyle(mint).padding(.horizontal, 8)
                        }
                        if let note = chat.contextNotice { notice(note, icon: "arrow.trianglehead.clockwise") }
                        if let error = chat.error { notice(error, icon: "exclamationmark.circle") }
                        Color.clear.frame(height: 1).id("bottom")
                    }.padding(24)
                }
                .onChange(of: chat.messages.last?.text) { _, _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
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
                Text("marvis").font(.system(size: 27, weight: .semibold, design: .rounded))
            }
            Spacer()
            Button { confirmClear = true } label: { Image(systemName: "square.and.pencil").frame(width: 44, height: 44) }
                .accessibilityLabel("New conversation")
            Button { settings = true } label: { Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44) }
                .accessibilityLabel("Voice settings")
        }
        .foregroundStyle(.white).padding(.horizontal, 24).padding(.top, 10)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 7) {
                Circle().fill(mint).frame(width: 5, height: 5)
                Text("A LITTLE SPACE TO THINK OUT LOUD")
                    .font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1.5)
            }.foregroundStyle(mint)
            Text("Your thoughts.\nA voice back.")
                .font(.system(size: 43, weight: .medium, design: .serif)).tracking(-1.5)
            Text("Tap the microphone once and talk naturally. Marvis replies when you pause, then listens again. Your conversation stays on your iPhone.")
                .font(.system(size: 16)).foregroundStyle(.secondary).lineSpacing(5)
            HStack(spacing: 5) {
                ForEach(0..<37) { index in
                    Capsule().fill(mint.opacity(index % 4 == 0 ? 0.9 : 0.35))
                        .frame(width: 3, height: CGFloat(12 + ((index * 17 + 7) % 45)))
                }
            }.frame(maxWidth: .infinity).frame(height: 85).accessibilityHidden(true)
        }.padding(.vertical, 28)
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label("Meet your on-device voice", systemImage: "arrow.down.circle")
                .font(.headline)
            Text("Download Marvis and its audio codec once over Wi-Fi. Keep the app open during setup. Afterward, voice generation works offline while the downloaded files remain on your iPhone.")
                .font(.subheadline).foregroundStyle(.secondary)
            Button(action: chat.prepareVoice) {
                HStack {
                    if chat.phase == .preparing { ProgressView().tint(.black) }
                    Text(chat.phase == .preparing ? "Downloading / loading…" : "Prepare Marvis voice")
                        .fontWeight(.semibold)
                }.frame(maxWidth: .infinity).padding(12)
            }
            .buttonStyle(.plain).foregroundStyle(.black)
            .background(mint, in: Capsule()).disabled(chat.isBusy)
            Text("You can turn off spoken replies in settings to start with text.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 22))
    }

    private var controls: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                TextField("Or type a thought…", text: $chat.draft, axis: .vertical)
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
                    Text("Tap the microphone to start a hands-free conversation. Pause after speaking to send your words automatically. Replies begin speaking as they arrive, and listening resumes after playback.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Toggle("Speak replies", isOn: $chat.readAloud)
                    Picker("Spoken voice", selection: $chat.replyVoice) {
                        Text("iPhone · clear reading").tag(ReplyVoice.system)
                        Text("Marvis · expressive").tag(ReplyVoice.marvis)
                    }
                    if chat.replyVoice == .marvis {
                        Picker("English voice", selection: $chat.voiceB) {
                            Text("Conversational A").tag(false)
                            Text("Conversational B").tag(true)
                        }
                        Text("Marvis uses longer phrases for smoother speech. Its generated voice can occasionally repeat or change words. Choose iPhone for closer reading of the reply.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("Reads the reply with an installed English voice. No Marvis model download is needed.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }.disabled(chat.isBusy)
                Section("Runs on your iPhone") {
                    Label("Apple Foundation Models · replies", systemImage: "apple.intelligence")
                    Label("Apple Speech · English transcription", systemImage: "mic")
                    Label(chat.replyVoice == .marvis ? "Marvis 250M · 8-bit voice model" : "iPhone voice · spoken replies", systemImage: "waveform")
                    Text("Microphone audio and conversations are processed locally. Conversations live in memory and clear when the app closes. The optional Marvis voice needs an initial download and loads its cached files after relaunch. Replies can still contain mistakes; check important details.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Link("MLX Audio · original project", destination: URL(string: "https://github.com/Blaizzy/mlx-audio")!)
                    Link("MLX Audio Swift · iPhone implementation", destination: URL(string: "https://github.com/Blaizzy/mlx-audio-swift")!)
                    Link("Marvis model and license", destination: URL(string: "https://huggingface.co/Marvis-AI/marvis-tts-250m-v0.2-MLX-8bit")!)
                }
            }
            .tint(mint).navigationTitle("Make it yours")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { settings = false } } }
        }
    }
}
