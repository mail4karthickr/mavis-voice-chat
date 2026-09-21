# MarvisVoice's pinned MLXAudio dependency

Upstream: https://github.com/Blaizzy/mlx-audio-swift

Base revision: `3e978558404df4ad1bbb0a5634a03df2b0f9dfa5`.
This local source snapshot is the dependency used by both `project.yml` and the
checked-in Xcode project. Keep the upstream license and this file when updating.
The ignored `vendor/` and Xcode's package checkout are not build inputs.

Local changes:

1. `Mimi.resetState()` resets the downsampler and upsampler as well as the
   encoder, decoder, and attention caches. Reference recordings otherwise inherit
   convolution history from earlier phrases. `MimiResetTests` covers both paths.
2. `MarvisTTSModel` caches evaluated preset reference tokens, masks, and transcript
   per model instance/voice. Target text is still tokenized separately each time.
   Custom reference audio remains uncached. `prepare(voice:)` warms the selected
   preset; callers must serialize preparation and generation.
3. Sampling uses temperature `0.9`, top-k `50`, and no top-p filter, matching the
   [MLX Python reference](https://github.com/Blaizzy/mlx-audio/blob/main/mlx_audio/tts/models/sesame/sesame.py).
   The generic `SpeechGenerationModel` parameter overrides remain unsupported by
   this upstream Marvis implementation; app calls use its dedicated streaming API.

Build the app with Xcode in **Release** for realistic inference performance.
Plain `swift test` does not build the required Metal shader bundle.
