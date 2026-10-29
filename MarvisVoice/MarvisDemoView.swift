import FoundationModels
import SwiftUI

private let mint = Color(red: 0.55, green: 0.96, blue: 0.78)

/// Exercises the two `Marvis` entry points: a streamed Foundation Models reply and a complete string.
struct MarvisDemoView: View {
    let marvis: Marvis
    @State private var text = ""
    @State private var error: String?
    @State private var preparing = false
    @State private var operation: Task<Void, Never>?

    private let question = "In three short sentences, why do cats purr?"
    private let passage = """
        Good morning! Here is your update. It looks like a bright day ahead, \
        with a gentle breeze in the afternoon. Don't forget your sunglasses.
        """

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if case .unavailable = SystemLanguageModel.default.availability {
                    Label("Apple Foundation Models is unavailable on this device, so only “Speak text” works.",
                          systemImage: "apple.intelligence")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if !marvis.isPrepared {
                    demoButton(preparing ? "Loading Marvis…" : "Prepare Marvis (optional)",
                               icon: "arrow.down.circle", action: prepare)
                        .disabled(preparing || marvis.isSpeaking)
                }
                demoButton("Ask Foundation Model (stream)", icon: "apple.intelligence", action: askModel)
                Text("“\(question)”").font(.footnote).foregroundStyle(.secondary)
                demoButton("Speak text", icon: "text.quote", action: speakText)
                if marvis.isSpeaking {
                    demoButton("Stop", icon: "stop.fill") {
                        operation?.cancel()
                        marvis.stop()
                    }
                }
                if !text.isEmpty {
                    Text(text).font(.system(size: 18)).lineSpacing(5)
                        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                        .background(mint.opacity(0.055), in: RoundedRectangle(cornerRadius: 22))
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(.secondary)
                }
            }.padding(24)
        }
        .foregroundStyle(.white)
        .background(Color(red: 0.035, green: 0.055, blue: 0.065))
        .navigationTitle("Marvis demo")
        .onDisappear {
            operation?.cancel()
            marvis.stop()
        }
    }

    private func demoButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).fontWeight(.semibold)
                .frame(maxWidth: .infinity).padding(14)
        }
        .buttonStyle(.plain).foregroundStyle(.black)
        .background(mint, in: Capsule())
        .disabled(preparing)
    }

    private func prepare() {
        run {
            preparing = true
            defer { preparing = false }
            try await marvis.prepare()
        }
    }

    private func askModel() {
        run {
            text = ""
            let session = LanguageModelSession(instructions: "Answer in plain spoken English without markdown or lists.")
            try await marvis.speak(session.streamResponse(to: question)) { _ in /*text = $0*/ }
        }
    }

    private func speakText() {
        run {
            text = passage
            try await marvis.speak(passage)
        }
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        operation?.cancel()
        error = nil
        operation = Task {
            do {
                try await work()
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
