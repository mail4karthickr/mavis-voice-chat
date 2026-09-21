#!/usr/bin/env python3
"""Check real Swift callback isolation without a device or microphone access.

Run: python3 scripts/check-speech-callback-isolation.py
Requires Xcode with the iPhoneOS SDK. Non-Sendable Objective-C callbacks can
silently inherit MainActor and trap when Speech or AVAudioEngine calls them.
Inspecting Swift's emitted SIL checks the compiled behavior, not source spelling.
"""

from pathlib import Path
import re
import subprocess
import tempfile


def verify_callbacks(sil: str) -> None:
    callbacks = {
        "speech authorization": "(SFSpeechRecognizerAuthorizationStatus,",
        "recognition result": "(@guaranteed Optional<SFSpeechRecognitionResult>,",
        "audio tap": "(@guaranteed AVAudioPCMBuffer, @guaranteed AVAudioTime,",
    }
    functions = re.findall(
        r"^// (closure[^\n]*SpeechCapture[^\n]*)\n"
        r"// Isolation: ([^\n]+)\n"
        r"(sil [^\n]+)\n(.*?)^\} // end sil function",
        sil,
        re.MULTILINE | re.DOTALL,
    )
    for name, signature in callbacks.items():
        matches = [function for function in functions if signature in function[2]]
        if len(matches) != 1:
            raise RuntimeError(f"Expected one {name} callback, found {len(matches)}")
        _, isolation, _, body = matches[0]
        if isolation != "nonisolated" or "swift_task_reportUnexpectedExecutor" in body:
            raise RuntimeError(f"{name} callback can trap off MainActor: {isolation}")
        print(f"PASS: {name} callback can run off MainActor")


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    sdk = subprocess.check_output(
        ["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], text=True
    ).strip()
    with tempfile.TemporaryDirectory(prefix="marvis-speech-isolation-") as directory:
        output = Path(directory) / "SpeechCapture.sil"
        subprocess.run(
            [
                "xcrun", "swiftc", "-emit-sil", "-whole-module-optimization",
                "-swift-version", "6", "-warnings-as-errors",
                "-target", "arm64-apple-ios26.0", "-sdk", sdk,
                "-module-cache-path", str(Path(directory) / "modules"),
                "-module-name", "SpeechCaptureVerification",
                str(root / "MarvisVoice/SpeechCapture.swift"),
                str(root / "MarvisVoice/Conversation.swift"),
                "-o", str(output),
            ],
            check=True,
        )
        verify_callbacks(output.read_text())


if __name__ == "__main__":
    main()
