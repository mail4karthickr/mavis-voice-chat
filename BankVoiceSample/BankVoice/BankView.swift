import SwiftUI

struct BankView: View {
    @Bindable var bank: BankController
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var composerFocused: Bool
    @State private var showingSettings = false
    @State private var showingDiagnostics = false
    @State private var confirmingReset = false

    private var ink: Color { colorScheme == .dark ? Color(red: 0.91, green: 0.94, blue: 0.94) : Color(red: 0.10, green: 0.19, blue: 0.24) }
    private var teal: Color { colorScheme == .dark ? Color(red: 0.45, green: 0.84, blue: 0.73) : Color(red: 0.05, green: 0.39, blue: 0.34) }
    private var canvas: Color { colorScheme == .dark ? Color(red: 0.055, green: 0.085, blue: 0.10) : Color(red: 0.97, green: 0.96, blue: 0.93) }
    private var surface: Color { colorScheme == .dark ? Color(red: 0.10, green: 0.14, blue: 0.16) : .white }
    private var muted: Color { ink.opacity(0.70) }
    private var canSendDraft: Bool { bank.canSend && !bank.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if let issue = bank.modelIssue, bank.mode == .foundation { modelNotice(issue) }
                        if !bank.voiceReady && bank.readAloud { voiceSetup }
                        if bank.messages.isEmpty { welcome }
                        ForEach(bank.messages) { message in
                            messageBubble(message)
                        }
                        if !bank.liveTranscript.isEmpty { transcript }
                        if let error = bank.error { errorNotice(error) }
                        if bank.metrics.firstAudioSeconds != nil || bank.metrics.firstTextSeconds != nil {
                            latestTiming
                        }
                        Color.clear.frame(height: 1).id("conversation-bottom")
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 16)
                    .padding(.bottom, 20)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: bank.messages.last?.text) { _, _ in
                    scroll.scrollTo("conversation-bottom", anchor: .bottom)
                }
                .onChange(of: bank.messages.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) { scroll.scrollTo("conversation-bottom", anchor: .bottom) }
                }
                .onChange(of: bank.liveTranscript) { _, _ in
                    scroll.scrollTo("conversation-bottom", anchor: .bottom)
                }
                .onChange(of: bank.error) { _, _ in
                    scroll.scrollTo("conversation-bottom", anchor: .bottom)
                }
            }
            composer
        }
        .foregroundStyle(ink)
        .background(canvas)
        .tint(teal)
        .sheet(isPresented: $showingSettings) { settingsSheet }
        .sheet(isPresented: $showingDiagnostics) { diagnosticsSheet }
        .confirmationDialog("Clear this demo conversation?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Clear conversation", role: .destructive) { bank.reset() }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(teal)
                .frame(width: 42, height: 42)
                .background(teal.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Bank Voice").font(.title3.weight(.semibold))
                Text("Demo • synthetic data")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(muted)
            }
            Spacer(minLength: 2)
            Button { confirmingReset = true } label: {
                Image(systemName: "square.and.pencil").frame(width: 40, height: 44)
            }
            .accessibilityLabel("Clear conversation")
            .disabled(bank.messages.isEmpty && !bank.isBusy && !bank.conversationActive)
            Button { showingSettings = true } label: {
                Image(systemName: "slider.horizontal.3").frame(width: 40, height: 44)
            }
            .accessibilityLabel("Conversation settings")
            .accessibilityIdentifier("bank.settings")
        }
        .padding(.horizontal, 22)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(canvas)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                Text("A little clarity.\nA conversation away.")
                    .font(.system(.largeTitle, design: .serif, weight: .medium))
                    .tracking(-0.8)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Ask about your balance, recent spending, card or payment status.")
                    .font(.body)
                    .foregroundStyle(muted)
                    .lineSpacing(3)
                Label("Mock API · 2-second delay", systemImage: "clock")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(teal)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(teal.opacity(0.08), in: Capsule())
            }
            .padding(.top, 10)
            LazyVGrid(columns: dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(BankScenario.allCases) { scenario in
                    Button {
                        composerFocused = false
                        bank.ask(scenario)
                    } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            Image(systemName: scenario.symbol)
                                .font(.system(size: 19, weight: .medium))
                                .foregroundStyle(teal)
                                .frame(height: 24)
                                .accessibilityHidden(true)
                            Text(scenario.title).font(.subheadline.weight(.semibold))
                            Text(scenario.query)
                                .font(.caption)
                                .foregroundStyle(muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(16)
                        .background(surface, in: RoundedRectangle(cornerRadius: 20))
                    }
                    .buttonStyle(.plain)
                    .disabled(!bank.canSend || bank.conversationActive)
                    .accessibilityLabel(scenario.query)
                    .accessibilityHint("Sends a sample question to the mock bank API")
                    .accessibilityIdentifier("bank.scenario.\(scenario.id)")
                }
            }
        }
    }

    private func messageBubble(_ message: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(message.isUser ? "You" : "Bank assistant", systemImage: message.isUser ? "person.crop.circle" : "waveform")
                .font(.caption.weight(.semibold))
                .foregroundStyle(message.isUser ? muted : teal)
            if message.text.isEmpty {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text(bank.phase.rawValue).font(.subheadline).foregroundStyle(muted)
                }
                .accessibilityElement(children: .combine)
            } else {
                Text(message.text)
                    .font(.body)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(message.isUser ? ink.opacity(0.055) : surface, in: RoundedRectangle(cornerRadius: 22))
        .padding(.leading, message.isUser ? 22 : 0)
        .padding(.trailing, message.isUser ? 0 : 12)
    }

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Listening", systemImage: "mic.fill").font(.caption.weight(.semibold))
            Text(bank.liveTranscript).font(.body).lineSpacing(3)
        }
        .foregroundStyle(teal)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(teal.opacity(0.07), in: RoundedRectangle(cornerRadius: 20))
    }

    private var voiceSetup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Give your assistant a voice", systemImage: "waveform.badge.plus")
                .font(.headline)
            Text("Prepare Marvis once to hear replies as they arrive. The first setup downloads the voice model; keep this app open.")
                .font(.subheadline)
                .foregroundStyle(muted)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: bank.prepareVoice) {
                HStack(spacing: 9) {
                    if bank.phase == .preparing { ProgressView().tint(canvas) }
                    Text(bank.phase == .preparing ? "Preparing voice…" : "Prepare Marvis")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .foregroundStyle(canvas)
                .background(teal, in: RoundedRectangle(cornerRadius: 13))
            }
            .buttonStyle(.plain)
            .disabled(bank.isBusy)
            Button("Try text replies first") { bank.readAloud = false }
                .font(.subheadline.weight(.medium))
                .disabled(bank.isBusy)
                .accessibilityIdentifier("bank.textOnly")
        }
        .padding(18)
        .background(surface, in: RoundedRectangle(cornerRadius: 22))
    }

    private func modelNotice(_ issue: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Apple Intelligence unavailable", systemImage: "apple.intelligence")
                .font(.subheadline.weight(.semibold))
            Text(issue).font(.subheadline).foregroundStyle(muted)
            HStack {
                Button("Use direct wording") { bank.mode = .direct }
                Spacer()
                Button("Check again", action: bank.refreshAvailability)
            }
            .font(.caption.weight(.semibold))
            .disabled(bank.isBusy)
        }
        .padding(18)
        .background(teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
    }

    private func errorNotice(_ message: String) -> some View {
        Label {
            Text(message).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.circle")
        }
        .font(.subheadline)
        .foregroundStyle(ink)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityLabel("Error: \(message)")
    }

    private var latestTiming: some View {
        Button { showingDiagnostics = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "stopwatch")
                if let seconds = bank.metrics.firstAudioSeconds {
                    Text("First audio in \(seconds, specifier: "%.2f")s")
                } else if let seconds = bank.metrics.firstTextSeconds {
                    Text("First text in \(seconds, specifier: "%.2f")s")
                }
                Spacer(minLength: 4)
                Text("Details")
                Image(systemName: "chevron.right").font(.caption2)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(teal)
            .padding(.horizontal, 5)
            .padding(.vertical, 6)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows timing measurements and the latest mock API response")
        .accessibilityIdentifier("bank.latestTiming")
    }

    private var composer: some View {
        VStack(spacing: 12) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Ask your bank…", text: $bank.draft, axis: .vertical)
                    .lineLimit(1...4)
                    .submitLabel(.send)
                    .focused($composerFocused)
                    .onSubmit(sendDraft)
                    .disabled(bank.isBusy || bank.conversationActive)
                    .padding(.vertical, 10)
                    .accessibilityLabel("Your question")
                Button(action: sendDraft) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(canvas)
                        .frame(width: 42, height: 42)
                        .background(teal, in: Circle())
                        .opacity(canSendDraft ? 1 : 0.35)
                }
                .disabled(!canSendDraft)
                .accessibilityLabel("Send question")
            }
            .padding(8)
            .padding(.leading, 8)
            .background(surface, in: RoundedRectangle(cornerRadius: 23))

            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Circle().fill(bank.phase == .listening ? teal : muted.opacity(0.5)).frame(width: 6, height: 6)
                        Text(bank.phase.rawValue).font(.subheadline.weight(.medium))
                    }
                    Text(bank.phase == .listening ? "Pause to send · tap to stop" : bank.conversationActive ? "Conversation on · tap to stop" : "Tap once to talk hands-free")
                        .font(.caption)
                        .foregroundStyle(muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button {
                    composerFocused = false
                    if bank.isBusy || bank.conversationActive { bank.stop() }
                    else { bank.microphoneTapped() }
                } label: {
                    Image(systemName: bank.isBusy || bank.conversationActive ? "stop.fill" : "mic.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(canvas)
                        .frame(width: 58, height: 58)
                        .background(teal, in: Circle())
                }
                .disabled(!bank.isBusy && !bank.conversationActive && !bank.canSend)
                .opacity(!bank.isBusy && !bank.conversationActive && !bank.canSend ? 0.35 : 1)
                .accessibilityLabel(bank.isBusy || bank.conversationActive ? "Stop conversation" : "Start hands-free conversation")
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background(canvas)
        .overlay(alignment: .top) { Rectangle().fill(ink.opacity(0.07)).frame(height: 1) }
    }

    private func sendDraft() {
        guard canSendDraft else { return }
        composerFocused = false
        bank.sendDraft()
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Wording", selection: $bank.mode) {
                        ForEach(BankReplyMode.allCases) { mode in Text(mode.label).tag(mode) }
                    }
                    .accessibilityIdentifier("bank.modePicker")
                    Toggle("Speak replies with Marvis", isOn: $bank.readAloud)
                } header: {
                    Text("Reply experience")
                } footer: {
                    Text("Foundation Models turns the mock JSON into conversational wording on your iPhone. Direct wording reads a prepared answer from the same data, so you can compare the delay.")
                }
                .disabled(bank.isBusy || bank.conversationActive)
                Section("Hands-free conversation") {
                    Text("Tap the microphone once. When you pause, your question sends automatically. After the reply finishes speaking, the microphone listens again. Tap Stop to end.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Section("This sample") {
                    Label("Synthetic banking data", systemImage: "building.columns")
                    Label("Mock API waits 2 seconds per request", systemImage: "clock")
                    Text("No bank account is connected. The sample cannot transfer money, change a card or make a payment.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section {
                    NavigationLink("Timing & API response") { diagnosticsContent.navigationTitle("Diagnostics") }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingSettings = false }
                        .accessibilityIdentifier("bank.settingsDone")
                }
            }
        }
        .tint(teal)
    }

    private var diagnosticsSheet: some View {
        NavigationStack {
            diagnosticsContent
                .navigationTitle("Diagnostics")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingDiagnostics = false } } }
        }
        .tint(teal)
    }

    private var diagnosticsContent: some View {
        Form {
            Section {
                metric("API response", seconds: bank.metrics.apiSeconds)
                metric("First spoken text", seconds: bank.metrics.firstTextSeconds)
                metric("First audio queued", seconds: bank.metrics.firstAudioSeconds)
                metric("Text complete", seconds: bank.metrics.textCompleteSeconds)
                metric("Reply complete", seconds: bank.metrics.totalSeconds)
            } header: {
                Text("Latest request")
            } footer: {
                Text("Times start when you send the question and include the mock API delay. First audio measures when audio is queued for playback, rather than when sound reaches your ears. A dash means that event has not occurred.")
            }
            Section("Mock endpoint") {
                Text(bank.latestEndpoint.isEmpty ? "Send a question to see its endpoint." : bank.latestEndpoint)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .accessibilityIdentifier("bank.latestEndpoint")
            }
            Section("JSON response") {
                if bank.latestJSON.isEmpty {
                    Text("The latest mock API response appears here.")
                        .foregroundStyle(.secondary)
                } else {
                    Text(bank.latestJSON)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("bank.responseJSON")
                }
            }
        }
    }

    private func metric(_ label: String, seconds: Double?) -> some View {
        LabeledContent(label) {
            if let seconds {
                Text("\(seconds, specifier: "%.2f") s").monospacedDigit()
            } else {
                Text("—").accessibilityLabel("Not measured")
            }
        }
    }
}
