import XCTest
@testable import MarvisVoice

final class ModelStoreTests: XCTestCase {
    /// Needs a network connection: fetches Kokoro's 9 MB pronunciation data from Hugging Face.
    func testAssetDownloadReportsProgressAndItsSizeOnDisk() async throws {
        let asset = ModelAsset(repo: "beshkenadze/kitten-tts-g2p", megabytes: 9)
        let progress = Progress()
        do {
            try await asset.download { progress.fractions.append($0) }
        } catch let error as URLError {
            throw XCTSkip("Hugging Face is unreachable: \(error.localizedDescription)")
        }
        XCTAssertTrue(asset.isDownloaded)
        XCTAssertGreaterThan(asset.bytesOnDisk, 9_000_000)
        let fractions = await progress.fractions
        XCTAssertEqual(fractions, fractions.sorted(), "Progress must never move backwards")
        XCTAssertEqual(fractions.last, 1)
    }

    @MainActor
    func testTheSystemVoiceNeedsNoDownload() {
        let store = ModelStore()
        XCTAssertTrue(store.isDownloaded(.system))
        XCTAssertEqual(store.state(of: .system), .downloaded(bytes: 0))
    }

    @MainActor
    private final class Progress {
        var fractions: [Double] = []
    }
}
