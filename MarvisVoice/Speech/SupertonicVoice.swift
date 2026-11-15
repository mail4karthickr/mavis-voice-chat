import CoreML
import FluidAudio
import Foundation

/// Supertonic 3 through FluidAudio: its download, loading and synthesis.
actor SupertonicVoice: PiecewiseVoice {
    /// A build of the model's heaviest stage, which runs eight times for every piece
    /// of speech. The other three stages and the voice styles are the same files in
    /// every version.
    ///
    /// FluidAudio also publishes a variable-length 4-bit build, the smallest at 107 MB.
    /// It is left out: on a Mac it produced noise instead of speech.
    enum Version: String, Sendable, CaseIterable {
        /// 6-bit weights. The smallest that speaks.
        case int6
        /// 8-bit weights.
        case int8
        /// 4-bit weights in three fixed-length copies, the form the Neural Engine can
        /// run. FluidAudio's default, and the fastest.
        case int4
        /// The weights as converted, without quantization.
        case fp16 = "FP16"

        /// Approximate download size, with the shared stages and the ten voice styles.
        var megabytes: Double {
            switch self {
            case .int6: 123
            case .int8: 139
            case .int4: 172
            case .fp16: 202
            }
        }

        fileprivate var estimator: Supertonic3VectorEstimator {
            switch self {
            case .int6: .dynamic(.int6)
            case .int8: .dynamic(.int8)
            case .int4: .aneBucketed(.int4)
            case .fp16: .fp16Dynamic
            }
        }

        /// The name FluidAudio's downloader has for the same build. Kept beside
        /// `estimator` so that the files fetched and the model loaded always agree.
        fileprivate var download: String? {
            switch self {
            case .int6: "dyn-int6"
            case .int8: "dyn-int8"
            case .int4: "ane-int4"
            case .fp16: nil
            }
        }

        /// Only the fixed-length build can use the Neural Engine. The others are kept
        /// on the CPU: left to choose, Core ML stopped the process with the 8-bit
        /// build on a Mac, and ran the unquantized one three times slower.
        fileprivate var computeUnits: MLComputeUnits {
            self == .int4 ? .cpuAndNeuralEngine : .cpuOnly
        }
    }

    static let sampleRate = Supertonic3Constants.sampleRate
    /// The most characters FluidAudio gives the model in one piece. It cuts longer text itself.
    static let pieceLength = Supertonic3Constants.maxChunkLengthLatin

    /// Where FluidAudio keeps the models and voice styles of every version.
    static var directory: URL {
        let root = (try? TtsCacheDirectory.ensure()) ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent("Models").appendingPathComponent(Repo.supertonic3.folderName)
    }

    /// The model bundles and voice styles a version loads, including those it shares with the others.
    static func files(_ version: Version) -> [URL] {
        ModelNames.Supertonic3.requiredFiles(veVariant: version.download)
            .union(Supertonic3Voice.allCases.map(\.fileName))
            .map { directory.appendingPathComponent($0) }
    }

    static func isDownloaded(_ version: Version) -> Bool {
        files(version).allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Fetches what a version is missing, and all ten voice styles. `progress` receives 0 through 1.
    static func download(_ version: Version, progress: @escaping @MainActor @Sendable (Double) -> Void) async throws {
        try await Supertonic3ResourceDownloader.ensureModels(veVariant: version.download) { update in
            // FluidAudio counts the download as the first half of its progress and keeps
            // the second half for a compile step that this download does not have.
            // The voice styles that follow are 3 MB against the models' 100 or more.
            Task { @MainActor in progress(min(1, update.fractionCompleted * 2) * 0.98) }
        }
        for voice in Supertonic3Voice.allCases {
            try await Supertonic3ResourceDownloader.downloadVoiceStyle(voice)
        }
    }

    private let manager: Supertonic3Manager
    private var styles: [String: Supertonic3VoiceStyle] = [:]

    init(version: Version) {
        manager = Supertonic3Manager(computeUnits: version.computeUnits, vectorEstimator: version.estimator)
    }

    /// Loads the models from disk, downloading any that are missing.
    func load() async throws {
        try await manager.initialize()
    }

    /// Speaks one piece of English text with the named voice, such as "F1".
    func synthesize(_ text: String, voice: String) async throws -> [Float] {
        if styles[voice] == nil {
            guard let known = Supertonic3Voice(name: voice) else {
                throw SpeechError.message("Supertonic has no voice named \(voice).")
            }
            styles[voice] = try Supertonic3VoiceStyle.load(from: Self.directory.appendingPathComponent(known.fileName))
        }
        guard let style = styles[voice] else { return [] }
        return try await manager.synthesize(text: text, language: "en", style: style).samples
    }
}
