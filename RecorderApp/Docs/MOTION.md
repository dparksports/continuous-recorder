# Motion: turning a bump into evidence

The IMU answers a question the camera cannot: **did someone touch the box?** A recorder that
only sees the scene has no way to distinguish "nothing happened for six hours" from "someone
turned it to face the wall at 14:32 and turned it back at 14:35".

## What happens when the device moves

1. `MotionMonitor` samples device motion at 10 Hz and reduces each `CMDeviceMotion` to three
   numbers: acceleration with gravity removed, angular velocity, and the gravity direction.
2. `MotionClassifier` runs a two-threshold hysteresis state machine over those samples. When
   it enters "moving", it emits `.began`.
3. `.began` **arms `SnapshotGate`**. From that moment the video pipeline offers one frame per
   second to `MotionSnapshotStore`, which writes a 1280 px JPEG and hashes it.
4. When the samples have been quiet for three seconds, the classifier emits `.ended` with the
   episode summary. The gate closes and the gate's snapshot list is written to `event.json`.
5. That JSON — which contains the SHA-256 of every frame — is signed into the chain as a
   single link.

## The stills, honestly

You asked for a frame a second while it is not stationary, and that is what it does. But in
full video mode the frames are **not** what proves movement — the video already does, and the
motion event's `startedAt`/`endedAt` point into it. What the stills are actually worth:

- **A timeline you can scrub** without decoding 1.8 GB of HEVC.
- **A fallback** when an hour file is lost to a power cut, which is the one failure mode where
  an unfinalised `AVAssetWriter` file is worth nothing at all.
- **An alert payload**: `event.json` plus two or three JPEGs is something you can send to a
  phone. A 1.8 GB segment is not.
- **Presentation time per frame.** Each `MotionSnapshot` records the video PTS it came from,
  so a reviewer can seek the exact frame instead of guessing from wall clock.

If the device is running audio-only, motion events are more valuable still: they are the only
record that anything happened at all.

## Bump versus re-aim

The classifier tracks the angle between the current gravity vector and the one captured at
session start:

- **Gravity unchanged, acceleration spiked** → somebody knocked the table. `reaimed == false`.
- **Gravity moved more than 5°** → the device is pointing somewhere else. `reaimed == true`.

A re-aim is the interesting one, because it changes what the camera is looking at. Treat
`reaimed` as the alert condition, not "movement happened" — a passing lorry will produce
movement all day.

Two honest limits:

- **Gravity cannot see yaw.** Spinning a device that lies flat does not change the gravity
  vector. The rotation *rate* still trips the classifier during the turn, so the event is
  recorded — but the final `reaimed` flag will be false. Detecting that reliably needs a
  magnetometer, and a magnetic reference next to steel furniture is worse than no reference.
- **The reference drifts.** `calibrate` is taken at session start; over days the device may be
  nudged 1° at a time and never trip the threshold. If that matters, re-check against the
  previous event rather than the session start.

## Thresholds

| Constant | Default | What it means |
|---|---|---|
| `movingAcceleration` | 0.06 g | A firm tap is ~0.2 g, a pickup ~0.4 g, walking ~0.3–1 g |
| `movingRotation` | 0.20 rad/s | ~11°/s — slower than a deliberate turn |
| `settleAcceleration` / `settleRotation` | 0.03 g / 0.10 rad/s | Must fall **below** these, not just below the start threshold |
| `settleDelay` | 3 s | Quiet time before the episode closes |
| `reaimDegrees` | 5° | Gravity change that counts as re-aiming |

Two thresholds rather than one on purpose: with a single threshold the state chatters on every
vibration, and a system that chatters is a system whose alerts get ignored. The cost is a
little latency at both ends, which for this purpose is free.

**Tuning.** Run it for a quiet day and look at `peakAcceleration` across events. If clean
events sit at 0.02–0.05 g, the site has a vibration source — a compressor, a projector fan, a
truck route — and either the threshold goes up or the device needs isolation mounts. Do not
"fix" it by disabling motion events; that is how the one real event gets missed.

## Cost

| Item | Draw | Note |
|---|---|---|
| Device motion at 10 Hz | tens of mW | Small next to the 1.6 W video pipeline; not free on an audio-only battery session, hence `stop()` |
| JPEG at 1 Hz while moving | ~5–10 ms per frame | Encoded off the capture queue, so it cannot stutter the video |
| Per event | 90–140 KB per still | Five minutes of movement ≈ 30–40 MB |

`maximumSnapshotsPerEvent` defaults to 600 (ten minutes) so a permanently vibrating mount
cannot fill the disk. Reaching the cap does not end the event; it just stops the stills.

## Limits worth knowing

- **CoreMotion stops delivering when the device is still.** An event whose samples simply stop
  would stay open forever and keep the gate armed. `MotionClassifier.flush(at:)` closes it
  from the sampling path, and `stop()` flushes on shutdown.
- **No motion while suspended.** Video already requires the app to be frontmost, so this adds
  no new constraint — but it does mean a locked device records neither video nor motion.
- **The IMU is not a seal.** These events say the device moved; they cannot say who moved it
  or whether the lens was covered while it happened. Pair with a physical seal and, if the
  threat model includes it, a second camera pointed at this one.

## Verifying on device

1. Start video, then pick the device up and set it down. `event.json` should appear under
   `Recordings/<day>/<session>/video/motion/<uuid>/`, with `reaimed: false` and a handful of
   frames.
2. Turn it 30° and leave it. The next event should have `reaimed: true` and
   `peakTiltDegrees` around 30.
3. Leave it alone for ten minutes. No new events, no new frames — if you get a steady drip,
   the site vibrates and the thresholds need the tuning pass above.
4. Open a frame and check it is recognisable at 1280 px. If faces are mush, raise
   `MotionSnapshotStore.targetWidth` before raising quality; resolution reads better than
   bitrate at this size.
5. Confirm the chain: `ChainVerifier.verify` should show one extra link per event, and
   `event.json` should contain a `sha256` for each frame it lists.
