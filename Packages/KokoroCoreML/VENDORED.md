# Local snapshot of kokoro-coreml

Upstream: https://github.com/mattmireles/kokoro-coreml (Apache-2.0, see `LICENSE`)

Revision: `b23caa862f0585c2c65187d0fc97e0f8311041dc`.

The source files are unchanged. Only two targets are kept, at their upstream paths:

- `swift-tts/Sources/KokoroTTS`
- `swift/Sources/KokoroPipeline`

`Package.swift` is rewritten to expose just the `KokoroTTS` product. Upstream's manifest
also declares a binary target named `NemoTextProcessing` for its `KokoroG2P` library,
which the app does not use. FluidAudio declares a target with the same name, and Swift
packages in one app may not share a target name, so the two could not be added together
from their repositories.

The folder is named `KokoroCoreML`, not `kokoro-coreml` like the repository. An Xcode
that had used the repository as a remote package would not load a local folder of that
name: its builds failed with "Missing package product 'KokoroTTS'" while `xcodebuild`
succeeded, and closing the project and resetting the package caches did not help.

To update, copy the two folders from a newer upstream revision, keep the MisakiSwift pin
in `Package.swift` in step with upstream's, and change the revision above.
