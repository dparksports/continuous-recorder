# Running this on the Mac

The code was written on Windows, where there is no Swift toolchain. It has been checked
for structural integrity (`python Tools/sanity_check.py`) and the pure-logic parts have
tests, but **it has never been compiled**. Expect to fix a handful of small things on the
first build — the "When it does not compile" section at the bottom lists the likely spots.

## What you need

- macOS with **Xcode 16 or newer** (`sudo xcodebuild -license accept` once)
- An Apple ID added in Xcode ▸ Settings ▸ Accounts (a free one can install on your own
  iPad; a paid account is only needed for >7-day profiles)
- **iPad on iPadOS 17+**, with Developer Mode on (Settings ▸ Privacy & Security ▸
  Developer Mode, then reboot)
- XcodeGen: `brew install xcodegen` — optional, see Path B

## Path A — generate the project (2 minutes)

```bash
cd RecorderApp
xcodegen generate
open RecorderApp.xcodeproj
```

Then in Xcode:

1. Select the **RecorderApp** target ▸ *Signing & Capabilities*.
2. Team: your Apple ID. If Xcode complains about the bundle identifier, change
   `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml` to `com.<yourname>.recorderapp` and
   re-run `xcodegen generate`.
3. Plug in the iPad, pick it as the destination, press ⌘R.
4. On first launch: allow the microphone **and the camera**. Tap **Start recording**.

The `audio` background mode and the microphone usage string are already in
`Sources/Resources/Info.plist`, so locking the screen does not stop capture.

## Path B — no XcodeGen

1. Xcode ▸ File ▸ New ▸ Project ▸ iOS ▸ App. Name it `RecorderApp`, Interface **SwiftUI**,
   Language **Swift**.
2. Delete the generated `RecorderAppApp.swift` and `ContentView.swift`.
3. Drag the `Sources` folder into the project navigator (Create groups, not folder
   references; copy items if needed).
4. Select the target ▸ *Info*, and merge in the keys from
   `Sources/Resources/Info.plist` — the two that matter are
   **`UIBackgroundModes` = `audio`** and **`NSMicrophoneUsageDescription`**.
5. Build and run.

## First-run verification, in this order

Do not trust it until you have done these five things on the device:

1. **Start, wait 15 s, stop.** The app should show one segment, coverage ≈ 100.000%,
   and a file in Files ▸ On My iPad ▸ Continuous Recorder ▸ Recordings. Play it back —
   if the file has no audio, the tap format and the file format disagree; check the
   console for `formatMismatch`.
2. **Start, lock the screen, wait 10 minutes, unlock.** Segment count should have gone
   up by ~2 (5-minute segments) and coverage should still be ≈ 100%. If capture stopped
   at lock, see the `.record` fallback below.
3. **Interruption test.** While recording, call the iPad from a phone, or trigger Siri.
   The app should log a gap, write nothing during the call, and resume on its own. Check
   that the gap appears under *Capture integrity* and that coverage reflects it honestly.
4. **Rotation test.** Set segment length to 1 minute, record 10 minutes, stop. You should
   have 10 contiguous files, each ~1 minute, and total audio ≈ total wall time.
5. **Battery test.** Follow the calibration section of `Docs/RUNTIME-ESTIMATE.md` for one
   hour. The app's *Measured draw* should agree with your manual calculation within ~20%.
6. **Video rotation** (once `HourlyVideoRecorder` is wired in). Set `segmentDuration` to
   120 s, record 10 minutes. You should get 5 playable `.mp4` files, each starting on a
   keyframe, with `droppedFrames` near zero. Watch the thermal state — sustained capture on
   a warm desk should park at *Fair*, not climb to *Serious*.
7. **Chain verification.** Record two segments, then verify:

   ```swift
   let links = TamperChain(directory: dir, signer: signer).links()
   print(ChainVerifier.verify(links: links,
                              publicKeyX963: signer.publicKeyX963,
                              directory: dir).problems)
   ```

   Then the two tests that matter more than the happy path: flip one byte in an `.mp4` and
   re-run (expect *file content changed*), and delete the middle link and re-run (expect
   *previous hash does not match*). If both pass, the chain is doing its job.

Run the unit tests with ⌘U — 34 of them. They cover the energy arithmetic, coverage
accounting, the power-governor policy and the hash chain, including the case the chain
*cannot* catch (truncation). None of them touch audio hardware, the camera or the Secure
Enclave, so they also pass in CI and on the simulator, where `SoftwareSigner` stands in for
the real key.

## When it does not compile

Ordered by how likely they are, with the fix:

| Symptom | Cause and fix |
|---|---|
| `AVAudioFile` init throws `-50` (paramErr) at runtime | The AAC encoder refused the client format. It wants the file sample rate to equal the client sample rate; both currently come from `inputNode.outputFormat(forBus: 0)`. Print both and align them. |
| Recording stops when the screen locks | Two different causes. Audio: some iPadOS versions do not keep a `.record`-only session alive in the background — in `AudioSessionController.configure()`, switch to `.playAndRecord` with `options: []` and keep the same background mode. Video: this is not a bug, it is the platform. Locking suspends camera capture; see `Docs/POWER-AND-DISPLAY.md`. |
| `hour-00001.mp4` is unplayable / zero bytes | The writer was never finished. `finishWriting` only runs on `stop()` or rotation; a process kill leaves an unfinalised container. Shorter `segmentDuration` is the mitigation. |
| `SecureEnclaveSigner` returns nil on the simulator | Expected: there is no Secure Enclave there. Use `SoftwareSigner` in tests; links signed that way are flagged by the verifier on purpose. |
| `SecKeyCreateRandomKey` fails with `-25293` (auth failed) | No device passcode set, or the device has not been unlocked since boot. SE keys require both. |
| `MainActor.assumeIsolated` errors on an older SDK | Replace with `DispatchQueue.main.async { ... }` inside the closure; the closure already runs on the main queue. |
| `@Published` `didSet` warnings | Harmless in Swift 5 language mode; do not switch the project to Swift 6 mode until the concurrency annotations are audited. |
| `xcodegen: command not found` | Use Path B. Do not hand-edit a `.pbxproj`. |

If the build succeeds but the microphone indicator never appears, the session activation
failed before the engine started — check `Log.session` output for the thrown error.

## What is deliberately not here

- **No app icon and no launch storyboard artwork.** Xcode's default is fine for testing;
  an App Store submission needs both.
- **Video and tamper-evidence are not wired into the UI.** `HourlyVideoRecorder` and
  `TamperChain` are complete and self-contained, but nothing calls them yet — the README
  shows the ~20 lines of integration. Keeping that seam explicit means the audio path, which
  is the one that runs for days, stays reviewable.
- **No file-listing UI.** Recordings are reachable through the Files app via Document
  Sharing, which is enough for retrieval and keeps the code small.
- **No upload/sync.** If this becomes a real product, upload is where the power budget
  goes to die; batch it over Wi-Fi while charging.
- **No encryption at rest.** For a device that records continuously, enable Data
  Protection (`.completeUntilFirstUserAuthentication` is already the default) and consider
  encrypted segments if the audio is sensitive.
