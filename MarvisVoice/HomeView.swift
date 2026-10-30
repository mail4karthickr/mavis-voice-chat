import SwiftUI

private let mint = Color(red: 0.55, green: 0.96, blue: 0.78)

/// Entry point to both screens. They share one `Marvis` instance, so the voice model loads once.
struct HomeView: View {
    let chat: ChatController
    let marvis: Marvis

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 9) {
                    Image(systemName: "waveform").foregroundStyle(mint)
                    Text("marvis").font(.system(size: 27, weight: .semibold, design: .rounded))
                }.padding(.bottom, 12)
                NavigationLink {
                    ChatView(chat: chat)
                        .toolbarBackground(.hidden, for: .navigationBar)
                        .onDisappear { chat.stop() }
                } label: {
                    card("Voice chat", detail: "Ask by voice. The backend’s JSON is summarized on-device and read by Marvis.", icon: "mic.fill")
                }
                NavigationLink {
                    MarvisDemoView(marvis: marvis)
                } label: {
                    card("Marvis demo", detail: "Speak a streamed Foundation Models reply or a fixed text.", icon: "play.fill")
                }
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(red: 0.035, green: 0.055, blue: 0.065))
        }
        .tint(mint)
    }

    private func card(_ title: String, detail: String, icon: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon).font(.title2).foregroundStyle(.black)
                .frame(width: 52, height: 52).background(mint, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").foregroundStyle(.secondary)
        }
        .foregroundStyle(.white)
        .padding(20)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 22))
    }
}
