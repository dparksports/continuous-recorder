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
- **Tests**: 22 unit tests covering energy arithmetic, coverage accounting, power
  policy and chain verification (including the truncation case the chain cannot catch).
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
