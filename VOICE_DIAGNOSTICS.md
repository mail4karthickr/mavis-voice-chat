# Expressive voice investigation — 18 September 2026

Device: iPhone 17 Pro. Model: `Marvis-AI/marvis-tts-250m-v0.2-MLX-8bit`.

## Verified findings

- Debug compiled the speech model and codec without optimization. At 32
  codebooks, measured synthesis took longer than the audio it produced. With an
  80 ms playback queue this causes gaps; changing playback sample rate is not a
  valid fix. The app already uses the correct 24,000 Hz rate.
- `Mimi.resetState()` omitted the streaming downsampler and upsampler. Two
  deterministic tests reproduced prior-audio contamination against the original
  package. The downsampler is used when encoding each Marvis voice reference.
- Preset recordings were loaded and encoded again for every text fragment. The
  app now prepares and caches evaluated reference tokens for each voice.
- The Swift port used temperature 0.9 / top-p 0.8. The official MLX Python
  implementation uses temperature 0.9 / top-k 50. The local package now matches
  that sampling distribution. Generic generation-parameter overrides are ignored
  upstream; the app uses the dedicated Marvis API.

## Device baseline

Exact supplied text: “The red balloon is next to the blue chair. Please put it on
the table.” Times exclude loading model weights, but include reference encoding.
These are individual diagnostic runs, not averages; generated audio is stochastic.

| Original package | Synthesis time | Audio duration | Time / audio duration | First PCM |
| --- | ---: | ---: | ---: | ---: |
| Debug, 32 codebooks | 5.337 s | 3.840 s | 1.390 | 0.301 s |
| Release, 32 codebooks | 2.844 s | 3.920 s | 0.726 | 0.237 s |
| Debug, 16 codebooks | 5.254 s | 6.720 s | 0.782 | 0.264 s |
| Release, 16 codebooks | 1.756 s | 3.840 s | 0.457 | 0.206 s |

Below 1.0 means synthesis is faster than playback. Debug/full-detail required
approximately 1.175 seconds of extra startup buffering to avoid gaps in this
sample. Release/full-detail required none in this isolated measurement.

On-device transcription matched all supplied words in both full-detail runs.
The Debug/16-codebook run inserted “I blew” and “yeah”; its word edit distance was
3. This is evidence against blindly reducing detail for speed, not an estimated
error rate. Full 32-codebook output is retained.

## Validation and reproduction

The corrected Release app passed all 48 device tests, including both previously
failing codec tests. Full-detail synthesis produced 4.160 seconds of audio in
3.053 seconds (ratio 0.734); on-device transcription matched all 15 supplied words.
The real-model streaming test queued non-silent expressive PCM at 0.619 seconds;
text generation completed at 1.498 seconds. These timings start at the text-model
request after voice preparation, and measure queued PCM rather than speaker
output or the microphone's end-of-speech delay.

A follow-up run checked full-detail synthesis twice on the same model instance.
Both recordings transcribed exactly. Reusing the cached reference reduced first
PCM from 0.234 to 0.091 seconds in that run; sustained synthesis ratios were
0.730 and 0.691 respectively. See `ExpressiveCachedReference.xcresult`.

The diagnostic 16-codebook configuration also produced badly mismatched speech
in a corrected-build run. That setting is not used by the app. The automated
diagnostic records its waveform and transcription instead of asserting that
every tested configuration has correct pronunciation.

- Normal Xcode Run now uses Release without the debugger. Tests retain their
  Debug default; pass `-configuration Release ENABLE_TESTABILITY=YES` for device
  performance tests.
- `ExpressiveVoiceTests` measures actual PCM production, saves WAV attachments,
  and transcribes the generated waveform with on-device speech recognition.
  Transcription scores are diagnostics, not assertions of universal clarity.
- `MimiResetTests` verifies isolation between recordings and utterances.
- `StreamingLatencyTests` checks both voices against real Foundation Models
  streaming and the playback queue, with no artificial model delay.
- The maintained dependency is `Packages/mlx-audio-swift`, based on upstream
  revision `3e978558404df4ad1bbb0a5634a03df2b0f9dfa5`. See its
  [patch notes](Packages/mlx-audio-swift/MARVIS_PATCHES.md).

## Primary sources checked

- [Marvis MLX model card](https://huggingface.co/Marvis-AI/marvis-tts-250m-v0.2-MLX-8bit)
- [Official Marvis inference setup](https://github.com/Marvis-Labs/marvis-tts/blob/main/inference.py)
- [MLX Python sampling and streaming implementation](https://github.com/Blaizzy/mlx-audio/blob/main/mlx_audio/tts/models/sesame/sesame.py)
- [MLX's note on running outside the debugger](https://github.com/ml-explore/mlx-swift-examples/blob/main/Applications/LLMEval/README.md#performance)

Word accuracy in one recording does not establish subjective voice quality or
guarantee faithful speech for every reply. Speech onset also includes transcription
and text-model latency; it is different from the PCM-generation time above.
