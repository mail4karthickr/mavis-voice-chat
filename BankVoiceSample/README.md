# Bank Voice

A separate iPhone sample that turns mocked banking JSON into streamed speech:

```text
Typed question or on-device speech recognition
  → choose a mock banking endpoint
  → wait 2 seconds asynchronously
  → decode the JSON and format its facts
  → Apple Foundation Models streams conversational wording
  → complete short sentences stream into Marvis
  → play PCM as it arrives
```

The bundle identifier is `com.karthick.bankvoice`. This folder contains its own
Xcode project, application sources, tests, and patched MLXAudio snapshot. It does
not link to or modify the existing Marvis app. All account details and transactions
are fictional; the API is an in-process mock and makes no banking network calls.

## Try it

1. Open `BankVoice.xcodeproj`, select the **BankVoice** scheme and a supported
   iPhone, and run. Normal Run uses **Release** without the debugger for realistic
   speech performance. Set your signing team if using another developer account.
2. Tap **Prepare Marvis**. The first use downloads the Marvis model and Mimi codec
   if absent; later preparations load the cached files. Keep the app foregrounded
   during setup. Choose **Try text replies first** to test the JSON/wording flow
   without loading the voice.
3. Tap one of the four sample questions, type a supported question, or start the
   microphone. In voice mode, pausing submits the question, and listening resumes
   after the answer finishes. Stop cancels the API wait, generation, and playback.
4. Open **Conversation settings** to compare **Foundation Models** with **Direct
   wording**. Both modes use the same JSON and two-second API delay. Direct mode
   speaks deterministically formatted facts and skips the wording model.
5. Open the timing card or **Timing & API response** to inspect the endpoint,
   returned JSON, and measured timings.

Screenshots from the passing UI test: [conversation](screenshots/conversation.png)
and [API diagnostics](screenshots/diagnostics.png). These show Direct wording with
audio disabled; their timings are not speech measurements.

Foundation Models requires iOS 26 or later, an Apple Intelligence capable device,
Apple Intelligence enabled, and downloaded model assets. Direct wording can be
used when Foundation Models is unavailable. Marvis requires a physical device
with Metal; microphone use asks for microphone and on-device speech permissions.

## Mock endpoints

| Example question | Endpoint | Response |
| --- | --- | --- |
| How much money is available in my account? | `/mock/v1/accounts/demo-savings/balance` | Available and current INR balances, account suffix, snapshot date |
| What are my three most recent transactions? | `/mock/v1/accounts/demo-savings/transactions` | Two debits and one salary credit, with dates and merchants |
| Is my card active, and how much credit is available? | `/mock/v1/cards/demo-credit-card` | Card status, total credit limit, available credit |
| Did my payment to Asha go through? | `/mock/v1/payments/DEMO-PAY-20260917-01` | An existing payment's completion status, beneficiary, amount and date |

`MockBankAPI.fetch` uses a cancellable `Task.sleep(for: .seconds(2))` by default.
It encodes the fixture and decodes it into typed response models before deriving
the spoken facts. Money uses integer minor units, account suffixes use separate
digits, and dates are formatted in a fixed English locale. Unsupported queries
and action requests return a clear message instead of inventing an API result.

To connect a real backend later, replace this mock boundary with your HTTP
client and retain typed decoding. No credentials or live banking endpoint are
needed for this sample.

## Streaming and measurement

The Foundation Models session prewarms its fixed prompt prefix while the API sleeps.
Every turn uses a new session and sends a compact JSON projection containing the
decoded, formatted facts and question, outside the fixed instructions. Raw minor
units remain in diagnostics and are not mixed with formatted currency in the
model's input. The model uses greedy generation and is told to retain
all amounts, currencies, dates, statuses, and qualifications.

Marvis uses 32 codebooks, cached voice reference tokens, and 80 ms audio chunks.
The copied MLXAudio snapshot includes the codec reset and sampling fixes described
in `Packages/mlx-audio-swift/MARVIS_PATCHES.md`.

The pipeline consumes partial text, releasing complete short sentences so amounts
and account suffixes stay together; it does not wait for the complete rewrite.
A very short rewrite may nevertheless finish before the first audio is ready.
The diagnostic reports that behavior honestly.

All displayed timing milestones start when the API request is sent:

- API response: includes the simulated two-second wait.
- First spoken text: first nonempty wording-model snapshot, or the direct text.
- First audio queued: first non-silent PCM scheduled for playback, not a hardware
  measurement of sound reaching the speaker.
- Text complete: the wording stream ended.
- Reply complete: the audio queue drained, or the text-only response finished.

Model preparation and microphone end-of-speech detection are outside those
measurements. Wording instructions do not guarantee factual accuracy; the sample
provides original JSON and Direct wording for comparison. No generated wording
can execute banking operations.

### Measured on the connected iPhone

A Release device test on iPhone 17 Pro, with downloaded models and Marvis prepared,
ran the complete balance request through Foundation Models and Marvis:

| Milestone | Time from request |
| --- | --- |
| Mock API response | 2.02 s |
| First Foundation Models text | 2.49 s |
| First non-silent audio queued | 3.14 s |
| Text generation complete | 3.14 s |
| Spoken reply finished | 18.95 s |

This is one measured run, not a latency guarantee. The short balance answer's
text finished almost simultaneously with the first audio; sentence synthesis
was already running while text streamed. Longer answers can overlap more.
These numbers exclude initial model loading and the pause used to detect the
end of a spoken question. The result bundle is
`.build/BankVoiceCleanWordingTests.xcresult` when available locally.

## Build and test

The checked-in Xcode project is ready to open. To regenerate it, run
`xcodegen generate --spec project.yml` inside this directory.

```sh
xcodebuild -project BankVoice.xcodeproj -scheme BankVoice \
  -configuration Release -destination 'platform=iOS,id=YOUR_DEVICE_ID' \
  -derivedDataPath .build/device ENABLE_TESTABILITY=YES test
```

Tests cover all four mock endpoints and their exact values, a real two-second
delay, cancellation, stale-response isolation, model wording fidelity, incremental
streaming, the full JSON-to-Marvis device pipeline, and the user interface. UI
tests retain conversation and JSON diagnostic screenshots. Real model tests need
available Apple Intelligence assets; the Marvis integration test also needs its
voice models downloaded or cached.

Device verification completed with 22 unit/integration tests and one UI test
passing across the final targeted runs. This includes real Foundation Models
wording for all four endpoints plus a pending-payment case, and real Marvis
playback for the balance flow. Results are in the local
`.build/BankVoiceCleanWordingTests.xcresult`,
`.build/BankVoiceEndpointTests.xcresult`, and the UI portion of
`.build/BankVoiceFinalTests.xcresult` (its earlier wording-test failure was fixed
and verified in the subsequent runs).

Use Xcode rather than plain `swift test` to build the required Metal shaders.
