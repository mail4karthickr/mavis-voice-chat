import AVFoundation

@MainActor
final class MarvisPCMPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private var queuedSamples = 0
    private var generation = UUID()
    var onDrained: (() -> Void)?
    private var finished = false

    init() { engine.attach(node) }

    func enqueue(_ samples: [Float], sampleRate: Int) async throws {
        guard !samples.isEmpty else { return }
        // Backpressure prevents an entire long reply accumulating in RAM.
        while queuedSamples > sampleRate * 3 {
            try await Task.sleep(for: .milliseconds(40))
        }
        try Task.checkCancellation()
        if format == nil {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true)
            guard let created = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1) else {
                throw MarvisError.message("Could not configure audio playback.")
            }
            format = created
            engine.connect(node, to: engine.mainMixerNode, format: created)
            try engine.start()
            node.play()
        }
        guard let format,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else {
            throw MarvisError.message("Could not allocate an audio buffer.")
        }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        queuedSamples += samples.count
        let token = generation
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.queuedSamples -= samples.count
                self.checkDrain()
            }
        }
    }

    func finish() {
        finished = true
        checkDrain()
    }

    private func checkDrain() {
        if finished && queuedSamples == 0 {
            let callback = onDrained
            stop()
            callback?()
        }
    }

    func stop() {
        generation = UUID()
        node.stop()
        engine.stop()
        engine.disconnectNodeOutput(node)
        format = nil
        queuedSamples = 0
        finished = false
        onDrained = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
