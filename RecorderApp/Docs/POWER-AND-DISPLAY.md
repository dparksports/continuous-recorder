# Display, brightness and the limits of "turn the screen off"

## The short answer

| What you want | Possible? | What actually happens |
|---|---|---|
| Drive brightness to 0% | **Yes** | `UIScreen.main.brightness = 0`. Backlight parks at minimum. Saves ~0.2 W versus 25%, ~0.85 W versus 60%. |
| Truly power the panel down | **No public API** | The only thing that turns the panel off is locking the device. |
| Lock the device and keep recording audio | **Yes** | `UIBackgroundModes = audio` + an active `.record` session keeps the process alive. The panel really is off. This is the 118-hour case. |
| Lock the device and keep recording video | **No** | Locking suspends `AVCaptureSession`. There is no camera background mode in `UIBackgroundModes` — the list is audio, location, voip, fetch, remote-notification, processing, bluetooth-central, bluetooth-peripheral, external-accessory, nearby-interaction. No camera. |

So the honest split is: **audio can run with the screen genuinely off; video cannot.** A
video recorder has to stay frontmost, which means the panel stays lit at whatever minimum
brightness you can push it to.

If the requirement is "24/7 video with no display", the iPad is the wrong device for the
capture end. A PoE IP camera writes continuously with no panel at all; the iPad is much
better used as the thing that ingests, chains and verifies those streams. That is a
hardware decision, not a code decision — but it is the one that actually solves it.

## What each brightness level costs

11-inch iPad Air, from `Tools/runtime_estimate.py --mode video`:

| Brightness | Panel draw | + rest of the video pipeline | Total |
|---|---|---|---|
| 0% | 0.35 W | 1.25 W | 1.60 W → **16.3 h** |
| 25% | 0.55 W | 1.25 W | 1.80 W → **14.5 h** |
| 60% | 1.20 W | 1.25 W | 2.45 W → **~10.6 h** |

Dropping from 25% to 0% is worth about **1.8 hours** on a full charge. Real, but nothing
compared to the decision you made when you chose video over audio: 16.3 hours instead of
118.

## The three operating modes worth supporting

**Mode A — audio only, screen locked.** The panel is off, the radio can be off, and the
device runs for days. Use this whenever video is not strictly required. It is the mode the
existing app already implements, and the one that hits 118 h (11") / 150 h (13").

**Mode B — video, foreground, dimmed.** Brightness 0, no preview layer, black UI, 15 fps,
HEVC. `DisplayGovernor` does the dimming and the idle-timer override; `HourlyVideoRecorder`
never attaches a preview layer, because the compositor is the second-largest display cost
after the backlight. ~16 hours on an 11-inch.

**Mode C — video, mains power.** For a fixed on-prem installation this is the only mode
that matters. At ~1.6 W the charger is irrelevant (any 5 W supply is 3× oversized); the
constraints become **heat** and **disk**, not battery. See "Thermal" below.

Mode B and Mode C are the same code path. The difference is whether a cable is attached.

## How to dim properly

`DisplayGovernor` (already in `Sources/Core/`) does three things, and each one matters:

1. **`UIScreen.main.brightness = 0`.** Global while the app is active, so the previous
   value is saved and restored — leaving a shared iPad at 0% is a support ticket.
2. **`UIApplication.shared.isIdleTimerDisabled = true`.** Auto-lock would stop the camera.
   This is mandatory for Mode B and is why Low Power Mode is incompatible with it: Low
   Power Mode shortens the auto-lock timer to 30 seconds.
3. **Restore on resign-active.** iOS usually restores the user's brightness when the app
   backgrounds, but "usually" is not a guarantee, and a stuck-at-zero screen is not a
   failure mode you want to discover in the field.

Two more things you cannot do from code and should do in the field:

- **Guided Access** (Settings ▸ Accessibility ▸ Guided Access, triple-click to start) locks
  the app on screen and blocks the home gesture. Without it, an accidental swipe ends the
  recording.
- **Supervised single-app mode** via MDM if this is a real deployment. It also stops the
  user from deleting the recordings through Files.

## Thermal is the real ceiling for video

Continuous camera capture plus encoding is a sustained load, and an iPad in a closed box
will get hot. Two consequences:

- **The encoder starts dropping frames** before you notice anything on screen. The app
  counts them per segment (`droppedFrames`), and a non-zero count on a healthy device means
  the pipeline is underfed — check the disk, not the camera.
- **Charging stops when the device is hot.** "iPad needs to cool down" on a Mode C
  installation means the battery is now draining even though it is plugged in. Ventilate,
  do not enclose, and keep it out of direct sun.

`HourlyVideoRecorder.applyThermalPolicy(_:)` drops 15 fps → 10 fps at `.serious` and
5 fps at `.critical`. For surveillance footage that is nearly free: motion stays legible,
the ISP and encoder load fall by a third, and the device stops cooking itself.

## Storage: hourly files are what makes upload mandatory

One file per hour, 24/7:

| Profile | Per hour | Per day | 100 GB holds |
|---|---|---|---|
| 1080p15 HEVC 4 Mbps | 1.80 GB | 43.2 GB | **2.3 days** |
| 1080p30 HEVC 6 Mbps | 2.70 GB | 64.8 GB | 1.5 days |
| 1080p30 H.264 8 Mbps | 3.60 GB | 86.4 GB | 1.2 days |
| 4K30 HEVC 12 Mbps | 5.40 GB | 129.6 GB | 0.8 days |

Compare audio at 48 kbps: **0.52 GB/day**, 193 days in the same space. Video is ~83× the
storage for ~7× the power. On a 128 GB iPad you have roughly 100 GB of usable space, which
is two days of footage — so the hourly upload is not a nice-to-have, it is the retention
strategy. Which is also what makes the tamper story work: see
[TAMPER-EVIDENCE.md](TAMPER-EVIDENCE.md).

### Why hourly, and the price of it

An `AVAssetWriter` only produces a playable file when `finishWriting` completes — the `moov`
atom is written at the end. An hour-long file is therefore an hour of exposure: pull the
power at minute 59 and that hour is unreadable, no matter how good the hash chain is.

Three options, pick deliberately:

| Segment length | Loss on power cut | Files/day | Verdict |
|---|---|---|---|
| 60 min | up to 60 min | 24 | what was asked for; acceptable on mains + UPS |
| 10 min | up to 10 min | 144 | **recommended default**; roll up to hourly off-device |
| 60 s | up to 60 s | 1440 | only if the evidence value justifies the file count |

`settings.segmentDuration` is the knob. If you need hourly deliverables *and* bounded loss,
record 10-minute chunks and concatenate them off-device:

```bash
# lossless remux, no re-encode
printf "file '%s'\n" hour-*.mp4 > list.txt
ffmpeg -f concat -safe 0 -i list.txt -c copy hourly-rollup.mp4
```

then chain-hash the rollup as well as the chunks.
