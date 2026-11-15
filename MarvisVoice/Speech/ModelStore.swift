import Foundation
import HuggingFace
import KokoroTTS
import MLXAudioCore
import Observation

/// One download an engine needs before it can speak, from a Hugging Face repository.
struct ModelAsset: Sendable {
    enum Kind: Sendable {
        /// A snapshot stored where mlx-audio-swift looks for it. `files` are the only files
        /// to fetch; nil fetches what mlx-audio-swift loads from a model repository by
        /// default: weights, configuration, and voice files.
        case mlxAudio(files: [String]? = nil)
        /// The Core ML bundle that the KokoroTTS package downloads and verifies itself.
        case kokoroCoreML
        /// The 8-bit Kokoro stages, their pronunciation data and these voices, which
        /// FluidAudio downloads into two of its folders.
        case kokoroInt8(voices: [String])
        /// One version of the Supertonic models, and the voice styles, that FluidAudio
        /// downloads. Every version is kept in the same folder and shares files there.
        case supertonic(SupertonicVoice.Version)
    }

    let repo: String
    var kind = Kind.mlxAudio()
    /// Approximate download size. Weights the progress across an engine's assets.
    let megabytes: Double

    var directory: URL {
        switch kind {
        case .mlxAudio:
            HubCache.default.cacheDirectory
                .appendingPathComponent("mlx-audio")
                .appendingPathComponent(repo.replacingOccurrences(of: "/", with: "_"))
        case .kokoroCoreML:
            KokoroHostedModels.defaultCacheDirectory
        case .kokoroInt8:
            KokoroInt8Voice.directory
        case .supertonic:
            SupertonicVoice.directory
        }
    }

    var isDownloaded: Bool {
        let manager = FileManager.default
        switch kind {
        case .mlxAudio(let files?):
            return files.allSatisfy { manager.fileExists(atPath: directory.appendingPathComponent($0).path) }
        case .mlxAudio:
            // Mirrors what mlx-audio-swift checks before it decides to download.
            let contents = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            return contents.contains { $0.pathExtension == "safetensors" && Self.size(of: $0) > 0 }
        case .kokoroCoreML:
            // The package writes this marker only after every file has passed its hash check.
            return manager.fileExists(atPath: directory.appendingPathComponent(".kokoro-hosted-version").path)
        case .kokoroInt8(let voices):
            return KokoroInt8Voice.files(voices: voices).allSatisfy { manager.fileExists(atPath: $0.path) }
        case .supertonic(let version):
            return SupertonicVoice.isDownloaded(version)
        }
    }

    /// What the asset needs on disk. For a Supertonic version that includes the files
    /// it shares with the other versions, so that the sizes can be compared.
    var bytesOnDisk: Int64 {
        switch kind {
        case .mlxAudio, .kokoroCoreML:
            Self.bytes(at: directory)
        case .kokoroInt8(let voices):
            KokoroInt8Voice.files(voices: voices).reduce(0) { $0 + Self.bytes(at: $1) }
        case .supertonic(let version):
            SupertonicVoice.files(version).reduce(0) { $0 + Self.bytes(at: $1) }
        }
    }

    /// Fetches the asset unless it is already complete. `progress` receives 0 through 1.
    func download(progress: @escaping @MainActor @Sendable (Double) -> Void) async throws {
        guard let repoID = Repo.ID(rawValue: repo) else {
            throw SpeechError.message("Invalid model repository: \(repo)")
        }
        let client = HubClient(cache: .default)
        let report: @MainActor @Sendable (Progress) -> Void = { progress($0.fractionCompleted) }
        switch kind {
        case .mlxAudio(let files?):
            guard !isDownloaded else { return }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            _ = try await client.downloadSnapshot(
                of: repoID, kind: .model, to: directory, revision: "main", matching: files, progressHandler: report
            )
        case .mlxAudio:
            _ = try await ModelUtils.resolveOrDownloadModel(
                client: client, cache: .default, repoID: repoID, requiredExtension: "safetensors", progressHandler: report
            )
        case .kokoroCoreML:
            _ = try await KokoroResourceProvider.huggingFace(cacheDirectory: directory) { update in
                Task { @MainActor in progress(update.fraction) }
            }
        case .kokoroInt8(let voices):
            try await KokoroInt8Voice.download(voices: voices, progress: progress)
        case .supertonic(let version):
            try await SupertonicVoice.download(version, progress: progress)
        }
    }

    /// The size of a file, or of everything in a folder.
    private static func bytes(at url: URL) -> Int64 {
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
              let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return size(of: url)
        }
        return files.reduce(Int64(0)) { total, file in total + ((file as? URL).map(size) ?? 0) }
    }

    private static func size(of file: URL) -> Int64 {
        Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }
}

/// Which speech models are on this iPhone, and the downloads that put them there.
@MainActor @Observable
final class ModelStore {
    enum State: Equatable {
        case notDownloaded
        case downloading(fraction: Double)
        case downloaded(bytes: Int64)
    }

    private var states: [Speaker.Engine: State] = [:]
    /// Why the most recent download of an engine failed.
    private(set) var failures: [Speaker.Engine: String] = [:]
    @ObservationIgnored private var downloads: [Speaker.Engine: Task<Void, Never>] = [:]

    init() {
        for engine in Speaker.Engine.allCases { states[engine] = Self.stateOnDisk(engine) }
    }

    func state(of engine: Speaker.Engine) -> State {
        states[engine] ?? .notDownloaded
    }

    /// True for the iPhone voice, which has nothing to download.
    func isDownloaded(_ engine: Speaker.Engine) -> Bool {
        if case .downloaded = state(of: engine) { true } else { false }
    }

    func download(_ engine: Speaker.Engine) {
        guard downloads[engine] == nil, !isDownloaded(engine) else { return }
        failures[engine] = nil
        states[engine] = .downloading(fraction: 0)
        downloads[engine] = Task {
            defer { downloads[engine] = nil }
            do {
                let assets = engine.assets
                let total = assets.reduce(0) { $0 + $1.megabytes }
                var finished = 0.0
                for asset in assets {
                    let before = finished
                    try await asset.download { fraction in
                        // Updates hop to the main actor one at a time and can arrive late.
                        let overall = (before + fraction * asset.megabytes) / total
                        guard case .downloading(let current) = self.states[engine], overall > current else { return }
                        self.states[engine] = .downloading(fraction: overall)
                    }
                    finished += asset.megabytes
                    states[engine] = .downloading(fraction: finished / total)
                }
                states[engine] = Self.stateOnDisk(engine)
                if !isDownloaded(engine) {
                    failures[engine] = "The download finished, but some model files are missing. Try again."
                }
            } catch {
                states[engine] = .notDownloaded
                failures[engine] = error.localizedDescription
            }
        }
    }

    private static func stateOnDisk(_ engine: Speaker.Engine) -> State {
        let assets = engine.assets
        guard assets.allSatisfy(\.isDownloaded) else { return .notDownloaded }
        return .downloaded(bytes: assets.reduce(0) { $0 + $1.bytesOnDisk })
    }
}
