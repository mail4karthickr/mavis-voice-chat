import MLX
import MLXAudioCodecs
import MLXNN
import XCTest

final class MimiResetTests: XCTestCase {
    func testResetDiscardsPreviousReferenceDownsamplingHistory() throws {
        let codec = makeTinyCodec()
        let convolution = codec.downsample.conv.conv.conv
        try convolution.update(
            parameters: ModuleParameters.unflattened([
                "weight": MLXArray.ones(convolution.weight.shape)
            ]),
            verify: .all
        )
        let silence = MLXArray.zeros([1, 8, 4])
        let firstReference = codec.downsample.step(silence).asArray(Float.self)
        let previousReference = codec.downsample.step(MLXArray.ones([1, 8, 4]))
        XCTAssertTrue(previousReference.asArray(Float.self).contains(where: { $0 > 0 }))

        codec.resetState()

        let newReference = codec.downsample.step(silence).asArray(Float.self)
        XCTAssertFalse(firstReference.isEmpty)
        XCTAssertEqual(newReference, firstReference,
                       "A new reference must not retain samples from the previous voice prompt.")
    }

    func testResetDiscardsPreviousAudioUpsamplingHistory() throws {
        let codec = makeTinyCodec()
        let convolution = codec.upsample.convtr.convtr.convtr
        try convolution.update(
            parameters: ModuleParameters.unflattened([
                "weight": MLXArray.ones(convolution.weight.shape)
            ]),
            verify: .all
        )
        let silence = MLXArray.zeros([1, 8, 2])
        let firstAudio = codec.upsample.step(silence).asArray(Float.self)
        let previousAudio = codec.upsample.step(MLXArray.ones([1, 8, 2]))
        XCTAssertTrue(previousAudio.asArray(Float.self).contains(where: { $0 > 0 }))

        codec.resetState()

        let newAudio = codec.upsample.step(silence).asArray(Float.self)
        XCTAssertFalse(firstAudio.isEmpty)
        XCTAssertEqual(newAudio, firstAudio,
                       "A new utterance must not retain convolution overlap from the previous audio.")
    }

    /// Exercise the complete codec's reset contract without model downloads or
    /// allocating the production model; only the resamplers run in these tests.
    private func makeTinyCodec() -> Mimi {
        let seanet = SeanetConfig(
            dimension: 8, channels: 1, causal: true, nfilters: 4,
            nresidualLayers: 1, ratios: [2], ksize: 3, residualKsize: 3,
            lastKsize: 3, dilationBase: 2, padMode: .constant,
            trueSkip: true, compress: 2
        )
        let transformer = TransformerConfig(
            dModel: 8, numHeads: 2, numLayers: 1, causal: true,
            normFirst: true, biasFF: false, biasAttn: false, layerScale: 0.01,
            positionalEmbedding: "rope", useConvBlock: false, crossAttention: false,
            convKernelSize: 3, useConvBias: true, gating: false, norm: "layer_norm",
            context: 8, maxPeriod: 10_000, maxSeqLen: 64, kvRepeat: 1,
            dimFeedforward: 16, convLayout: true
        )
        return Mimi(cfg: MimiConfig(
            channels: 1, sampleRate: 16_000, frameRate: 4_000, renormalize: true,
            seanet: seanet, transformer: transformer,
            quantizerNQ: 2, quantizerBins: 8, quantizerDim: 4
        ))
    }
}
