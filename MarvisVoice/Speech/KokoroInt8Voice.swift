import FluidAudio
import Foundation

/// Kokoro with 8-bit weights, through FluidAudio: its download, loading and synthesis.
/// The model is split into seven Core ML stages, most of which run on the Neural Engine.
struct KokoroInt8Voice: PiecewiseVoice {
    static let sampleRate = KokoroAneConstants.sampleRate
    /// The most characters given to the model in one piece. Its memory grows with the
    /// length of what it speaks: on a Mac the app held 640 MB after an 11-second piece
    /// of this length, and 1.2 GB after a 28-second sentence spoken whole.
    static let pieceLength = 220

    /// Where FluidAudio keeps every model it downloads.
    private static var models: URL {
        let root = (try? TtsCacheDirectory.ensure()) ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent(KokoroAneResourceDownloader.modelsSubdirectory)
    }

    /// The folder of the stages and voices.
    static var directory: URL { models.appendingPathComponent(Repo.kokoroAne.folderName) }

    /// The stages and voices, then the English pronunciation models and word list,
    /// which FluidAudio keeps in a folder of their own.
    static func files(voices: [String]) -> [URL] {
        let pronunciation = models.appendingPathComponent(Repo.kokoro.folderName)
        return ModelNames.KokoroAne.requiredModels.union(voices.map { "\($0).bin" })
            .map { directory.appendingPathComponent($0) }
            + ModelNames.G2P.requiredModels.union([LexiconAssetCache.englishFileName(british: false)])
            .map { pronunciation.appendingPathComponent($0) }
    }

    /// Fetches whatever is missing. FluidAudio would otherwise fetch a voice when it is
    /// first used. `progress` receives 0 through 1.
    static func download(voices: [String], progress: @escaping @MainActor @Sendable (Double) -> Void) async throws {
        let stages = try await KokoroAneResourceDownloader.ensureModels { update in
            // FluidAudio counts the download as the first half of its progress and keeps
            // the second half for a compile step that this download does not have.
            // The stages are 82 MB. The pronunciation data that follows is 12 MB, and
            // the voices a few more.
            Task { @MainActor in progress(min(1, update.fractionCompleted * 2) * 0.8) }
        }
        try await KokoroAneResourceDownloader.ensureG2PAssets()
        // Without its word list FluidAudio still speaks, with poorer pronunciation, so
        // it reports a failed fetch as nil instead of an error.
        guard await KokoroAneResourceDownloader.ensureEnglishLexicon() != nil else {
            throw SpeechError.message("Kokoro’s pronunciation data could not be downloaded. Try again.")
        }
        await progress(0.92)
        for voice in voices {
            try await KokoroAneResourceDownloader.ensureVoicePack(voice, repoDirectory: stages)
        }
    }

    private let manager = KokoroAneManager()

    /// Loads the models from disk, downloading any that are missing.
    func load() async throws {
        try await manager.initialize()
    }

    /// Speaks one piece of English text with the named voice, such as "af_heart".
    func synthesize(_ text: String, voice: String) async throws -> [Float] {
        try await manager.synthesizeDetailed(text: text, voice: voice).samples
    }
}
