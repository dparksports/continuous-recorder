# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Known limitations

- **Never compiled.** There is no Swift toolchain on the machine where this was
  written. CI (`.github/workflows/ci.yml`) is the first real compile gate; expect
  small fixes on the first macOS build. See `RecorderApp/Docs/MAC-HANDOFF.md`.
- **Video and tamper-evidence are not wired into the UI.** `HourlyVideoRecorder`
  and `TamperChain` are complete and self-contained; integration is ~20 lines and
  documented in the README.
- No app icon, no launch artwork, no upload/sync, no file-browsing UI.

## [0.1.1] - 2026-11-08

First release that compiles. v0.1.0 was tagged before CI had ever run against this tree;
it does not build and is superseded.

### Fixed

- Compile errors surfaced by the first macOS CI run: `Section(String)` has no `footer:`
  overload; an exclusive-access violation read and wrote the same optional in one
  expression; `CIImageRepresentationOption` has no compression-quality member, so motion
  snapshots now render through `UIImage.jpegData`.
- CI piped `xcodebuild` through `tail`, which discarded every diagnostic and left only
  "Command SwiftCompile failed". It now runs `-quiet` and keeps the output.
- `gh release create` takes assets positionally — `--attach` does not exist, and the release
  script failed after the tag had already been pushed. Adds `--resume` for that case.

### Verified

- 61 unit tests pass on the iOS simulator (Xcode 16.4).
- Static checks job green on Ubuntu.

## [0.1.0] - 2026-11-07

### Added

- **Continuous audio recorder**: `AVAudioEngine` tap with gapless segment rotation
  (`SegmentedRecorder`, `SegmentWriter`), 5-minute segments by default, AAC 48 kbps
  mono via `.record` category and the `audio` background mode.
- **Session resilience**: interruption handling (calls, Siri), input route changes
  (headset, USB mic), media-services reset, engine restart outside the recorder lock.
- **Coverage accounting**: append-only `chain`-independent manifest (`segments.jsonl`,
  `gaps.jsonl`) plus `CoverageSummary`, so `audioSeconds + gapSeconds` can be checked
  against wall clock and silent drops surface as *unexplained*.
- **Power governor**: stop at a configurable battery floor, downgrade to speech-grade
  AAC in Low Power Mode or `.serious` thermal state, stop below a free-space floor.
- **Energy model**: device capacity table, `PowerMeter` that derives observed watts
  from battery-level movement, per-session runtime projection.
- **Hourly video recorder** (`HourlyVideoRecorder`): `AVCaptureVideoDataOutput` into a
  rotating `AVAssetWriter`, HEVC 1080p15 default, per-segment dropped-frame counting,
  thermal frame-rate ladder.
- **Display governor** (`DisplayGovernor`): brightness 0, idle-timer override, save and
  restore, with the platform limits documented rather than papered over.
- **Tamper evidence** (`TamperChain`, `SecureEnclaveSigner`): SHA-256 hash chain, one
  signed link per closed file, non-exportable ECDSA P-256 key, canonical payload
  encoding specified for cross-language verification, plus `ChainVerifier`.
- **Kiosk mode**: `KioskController` (Guided Access session request, brightness floor,
  idle-timer override, restore on exit), `RadioMonitor` (detects a network path and records
  anomalies — it cannot disable radios), `TelemetryFormat` / `TelemetryWatermark` (drifting
  top-edge stamp with timestamp, battery and charging state), `WatermarkComposer` (optional
  burn-in, applied before the hash so the chain covers the stamped bytes), and
  `UIRequiresFullScreen` to block Slide Over.
- **Motion events**: `MotionMonitor` (10 Hz device motion), `MotionClassifier` (two-threshold
  hysteresis over acceleration, rotation and gravity; bump versus re-aim), `SnapshotGate` /
  `MotionSnapshotStore` (one 1280 px JPEG per second while moving, carrying the video PTS),
  `MotionEventRecorder` (event JSON containing every frame hash, signed as one chain link).
- **Authenticated Mac sharing**: recordings moved out of `Documents` into `Library/Recordings`
  (with a migration for earlier sessions), so File Sharing no longer exposes them at all.
  `EvidenceShareController` opens a time-boxed window of hard links under `Documents/Share`
  only after `LAContext` confirms the device owner (Face ID / Touch ID, passcode fallback),
  closes it on expiry, backgrounding or device lock, purges stale windows at launch, and logs
  every open and close to `share-access.jsonl`. `SharePlan` is pure and testable.
- **Sound-triggered escalation**: `AudioTriggerAnalyzer` (dBFS per audio buffer against a
  tracked noise floor: +12 dB held 150 ms to open, +6 dB held 5 s to close, floor frozen
  while open) and `SoundTriggerCoordinator` (dormant 1 fps ↔ full 15 fps, thermally capped).
  `SegmentedRecorder` now publishes true RMS in dBFS from the existing tap.
- **Tests**: 61 unit tests covering energy arithmetic, coverage accounting, power
  policy, chain verification (including the truncation case the chain cannot catch), kiosk
  policy / watermark formatting, the motion classifier and snapshot gate, share planning and
  session expiry, and the sound trigger's adaptive floor and hysteresis.
- **Tooling**: `Tools/runtime_estimate.py` (audio and video power/storage model),
  `Tools/sanity_check.py` (brace/string-aware structural lint, plist validation),
  `scripts/local_ci.py`, `scripts/release.py`.
- **Docs**: runtime model and calibration, display/platform limits, threat model and
  chain specification, Mac hand-off and on-device verification checklist.
- **Infographics**: `assets/runtime-budget.svg|png`, `assets/tamper-chain.svg|png`.

### Notes

- Licence: Apache-2.0.
- The numbers in the docs are model output, not measurements of any particular device;
  the app measures the real figure while it runs.
