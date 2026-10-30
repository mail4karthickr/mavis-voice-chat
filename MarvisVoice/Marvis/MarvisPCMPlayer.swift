import AVFoundation

@MainActor
final class MarvisPCMPlayer {
    /// What happened during the most recent utterance. Kept until the next one starts.
    struct Report {
        var session = ""
        var buffers = 0
        /// Times a buffer arrived after the player had already run out of audio.
        var underruns = 0
        /// Times another component changed the audio session or route mid-utterance.
        var configurationChanges = 0
    }

    private var engine = AVAudioEngine()
    private var node = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private var queuedSamples = 0
    private var generation = UUID()
    private var configurationObserver: (any NSObjectProtocol)?
    var onDrained: (() -> Void)?
    private var finished = false
    private(set) var report = Report()

    init() {}

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
            // Build a fresh graph for each utterance. A reused engine can keep the output
            // format from before another component (such as microphone capture) changed
            // the audio session, which plays later replies through a mismatched conversion.
            engine = AVAudioEngine()
            node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: created)
            try engine.start()
            node.play()
            report = Report(session: Self.describe(session))
            let token = generation
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.report.configurationChanges += 1
                }
            }
        }
        guard let format,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else {
            throw MarvisError.message("Could not allocate an audio buffer.")
        }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        if report.buffers > 0 && queuedSamples == 0 { report.underruns += 1 }
        report.buffers += 1
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
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        node.stop()
        engine.stop()
        format = nil
        queuedSamples = 0
        finished = false
        onDrained = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func describe(_ session: AVAudioSession) -> String {
        let outputs = session.currentRoute.outputs.map(\.portName).joined(separator: " + ")
        let category = session.category.rawValue.replacingOccurrences(of: "AVAudioSessionCategory", with: "")
        let mode = session.mode.rawValue.replacingOccurrences(of: "AVAudioSessionMode", with: "")
        return "\(category)/\(mode), \(Int(session.sampleRate)) Hz, \(Int(session.ioBufferDuration * 1000)) ms buffer → \(outputs.isEmpty ? "no output" : outputs)"
    }
}
