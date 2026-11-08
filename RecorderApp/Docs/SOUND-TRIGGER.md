# Sound-triggered recording, and what to sample

## The short answer on sampling

| Question | Answer | Why |
|---|---|---|
| Capture sample rate | **48 kHz**, mono | It is what the hardware already delivers. Resampling to 16 kHz would burn CPU to save nothing: the cost is the microphone and the encoder, not the rate. |
| Bit depth for capture | 32-bit float inside the engine, 16-bit on disk (AAC) | Float at the tap avoids clipping in the RMS maths; AAC handles the rest. |
| Analysis rate | **One RMS per audio buffer — 4096 frames ≈ 85 ms, so ~12 decisions/second** | The samples are already in registers for the level meter. This is free. |
| Analysis window | The whole buffer | 85 ms is comfortably longer than a 20–30 ms speech frame; for energy gating a longer window is steadier and produces fewer false edges. |
| What is compared | **dBFS**, `20·log10(rms)` | Linear RMS differs by microphone and gain setting; dBFS does not. |
| 16 kHz + 20 ms frames? | Only if you add a real VAD | That is the input for FFT features and ML speech detection. `AudioTriggerAnalyzer` is an energy gate, not a speech detector — say so and stop. |

One thing that would quietly ruin all of this: `AVAudioSession.setVoiceProcessingEnabled(true)`.
It applies its own gain and noise suppression, so a level calibrated today means something
different tomorrow. Leave it off, which is the default.

## Why the threshold is relative, not absolute

`level > -40 dBFS` is the obvious design and it fails immediately in the real world: a fridge,
a fan, a road, or a projector puts the room at -35 and the recorder never goes dormant. It
then spends its battery recording a fridge.

So the trigger compares against a **tracked noise floor**:

- The floor starts at the first sample and is clamped to −80…−20 dBFS.
- It **tracks downward immediately** — a room that got quieter is believed at once.
- It **rises slowly**, with a 200-second time constant, so a passing event does not become
  the new normal.
- It is **frozen while an event is open**, so a two-minute alarm cannot teach the analyser
  that loud *is* the room.

| Constant | Default | Meaning |
|---|---|---|
| `openMarginDB` | +12 dB above floor | "Noticeably louder than the room" — a door, a voice, glass |
| `closeMarginDB` | +6 dB above floor | Lower than the open margin, so the state cannot flicker at the boundary |
| `openHoldSeconds` | 0.15 s | Two buffers. A single bang does not open an event |
| `closeHoldSeconds` | 5 s | A pause between sentences is not the end of a conversation |

`AudioTriggerAnalyzer` is pure and time-injected, so all of that is unit-tested with numbers
rather than ears — including the case that matters: a room sitting at −34 dBFS, above any
sensible fixed threshold, still goes dormant, and a door 15 dB above *that* still opens.

## What "full recording" switches

`SoundTriggerCoordinator` listens to the audio tap and calls
`HourlyVideoRecorder.setFramesPerSecond`:

- **Dormant:** 1 fps, one frame per second, audio still recording at full quality.
- **Triggered:** 15 fps, then back to 1 fps after the close hold.

The thermal policy sets a *cap* rather than a rate, so a hot device in a quiet room is not
dragged back to 10 fps a second after the trigger dropped it to 1.

## The part that should change how you budget this

**Dormant at 1 fps is not cheap.** The camera sensor and ISP cost is dominated by being
*open*, not by how many frames it produces. Dropping 15 fps → 1 fps removes the encode cost
and some of the pipeline, and that is all:

| Mode | Draw | 11" iPad Air |
|---|---|---|
| Full 1080p15 HEVC | 1.60 W | **16.3 h** |
| Dormant 1 fps, sound-triggered | 1.09 W | **23.9 h** |
| Audio only, camera closed | 0.22 W | **118 h** |

So the dormant mode you asked for buys about **32%**, not 15×. If the goal is "runs for days
and wakes up when something happens", the camera has to be **closed** while dormant, not
slowed — and the price is 0.5–1.5 s of camera startup on trigger, during which you have audio
but no picture.

Both are defensible:

- **1 fps dormant** (what this implements): no startup gap, and you already have a picture of
  the second before the event. Costs ~4× the audio-only power.
- **Camera closed** (a configuration change): days of runtime, and the first second of video
  is lost. The audio — which is what triggered it — is never lost, so you keep the *reason*
  even when you lose the first frames.

The estimator carries the dormant row: `--mode video`.

## Pre-roll

The sound that wakes the recorder arrives *before* the trigger decision (that is what the
0.15 s hold and the 12 dB margin are buying). Three ways to keep it:

1. **Audio** — already continuous, so the trigger instant is in the audio file regardless.
2. **Frames at 1 fps** — you have a frame per second of pre-trigger context for free.
3. **A rolling buffer** — keep the last N decoded frames in memory (a 5-second 1080p ring is
   ~50 MB at 4:2:0) and write them when the trigger fires. Not implemented; it is the honest
   way to get true pre-roll at full frame rate, and it costs memory, not power.

## Failure modes worth knowing

- **The app triggering itself.** Any sound the app makes — an alert, a shutter, a beep — goes
  straight into its own microphone. There are none in this codebase; keep it that way, or
  gate triggers for 1 s after playback.
- **Rain, HVAC, traffic, a ticking clock.** All continuous. The floor tracker absorbs
  continuous noise by design; what it cannot absorb is intermittent noise at the same level
  as the events you care about. That is a threshold-tuning problem, and the log tells you:
  every event records `peakLevelDB` and the `noiseFloorDB` it was judged against.
- **Speech from a TV in the next room** will trigger it. It is an energy gate, not a speech
  detector; if that matters, that is the 16 kHz + VAD path.
- **A quiet event** — glass breaking on carpet, a door easing shut — may not clear 12 dB.
  Lower the margin to 8 and accept more false positives, which is why it is a parameter.

## Verifying it

1. Quiet room for 10 minutes: no triggers, and the reported floor should sit near the real
   ambient level (watch `noiseFloorDB`).
2. Clap twice. The trigger should open within ~0.2 s, video should jump to 15 fps, and it
   should close about 5 s after the last clap.
3. Play a continuous tone for two minutes: it should open once and stay open, not oscillate,
   and the floor must not drift up while open.
4. Put the device near a fan. It should stay dormant — if it does not, the floor is not
   tracking and that is the bug to chase first.
5. Stop the session mid-trigger: `reset()` should close the event rather than leave it open.
