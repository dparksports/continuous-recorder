# Kiosk mode: one app, a dark screen, quiet radios, a visible stamp

Four requirements, four different answers. Three of them are deployment configuration, not
code — which is the part worth knowing before writing any of it.

| Requirement | Can the app do it? | What actually does it |
|---|---|---|
| Only this app runs | **Partly** | `UIAccessibility.requestGuidedAccessSession(enabled: true)` on a normal device (user can still exit with the passcode); MDM Autonomous Single App Mode on a supervised device (no escape) |
| Zero brightness | **Yes** | `UIScreen.main.brightness = 0` — but see the contradiction below |
| All radios off | **No** | Airplane Mode, set by a human or enforced by MDM; the app can only *observe* the result |
| Timestamp / battery / charging stamp | **Yes** | `TelemetryWatermark` on screen, `WatermarkComposer` into the file |

## 1. Only this app

`KioskController.enter()` calls `UIAccessibility.requestGuidedAccessSession(enabled: true)`,
which puts the device into Guided Access without the triple-click. Requirements and limits,
all of which are real:

- Guided Access must be **enabled in Settings ▸ Accessibility ▸ Guided Access** first. If it
  is off, the call completes with `false` and the app sets an error explaining it. There is
  no way to turn the setting on from code.
- The app must be frontmost when the call is made.
- Exiting still needs the passcode, so an operator can always get out. That is a feature for
  maintenance and a hole for an attacker — whether it matters depends on who holds the
  device.
- A notification or Control Center swipe is blocked while the session is active. Without it,
  a banner slides over your watermark, which is exactly the moment you least want one.

For a device you do not hand out, use **Supervised + MDM Autonomous Single App Mode**
(`com.apple.app.lock`). That removes the triple-click escape entirely and is the only tier
that deserves the word "kiosk". `UIRequiresFullScreen` is set in `Info.plist` so Slide Over
and Split View are unavailable — without it, an iPad can put another app beside yours.

`KioskStatus` reports which of these is actually true, and `KioskPolicy` turns it into a
short list of what is wrong. No self-assessment: it reads the real brightness, the real idle
timer, the real radio state.

## 2. Zero brightness versus a visible watermark

These two cannot both be true, and it is worth saying plainly: at brightness 0 the stamp is
invisible, and a watermark nobody can read is decoration.

| Setting | Panel draw | 11" runtime (video 1080p15) | Watermark readable? |
|---|---|---|---|
| 0.00 (`DimLevel.dark`) | ~0.35 W | ~16.3 h | No |
| 0.04 (`DimLevel.watermark`) | ~0.37 W | ~16.1 h | Yes, in a dim room |
| 0.25 | 0.55 W | ~14.5 h | Yes, in daylight |

The difference between 0 and 0.04 is about **two-tenths of a watt** — roughly 12 minutes of
runtime. Give up the twelve minutes. `DimLevel.dark` exists for the case where the device is
in a dark cupboard and the watermark is only needed in the recording, not on the glass.

And the constraint from the previous round still applies: with video running, the panel
cannot be off at all — locking the device suspends `AVCaptureSession`, and there is no camera
background mode. The best available is "lit but nearly black".

## 3. Radios

There is no public API to disable Wi-Fi, Bluetooth or cellular. Every "turn off radios"
answer you will find for iOS is either a Settings instruction or a private framework. What
this app does instead:

- `RadioMonitor` watches `NWPathMonitor` and publishes whether a network path exists and
  over which interface.
- `KioskPolicy` reports it as an issue when a path is up during a session.
- `KioskController.radioAnomaly` records the moment a path appears mid-session. On a kiosk
  that is not a convenience, it is an event.

Be precise about the semantics: `NWPathMonitor` reports **connectivity, not emission**.
Wi-Fi that is switched on but unassociated still scans, still radiates, and still reports no
path. So "silent" in the UI means "no route to anywhere", which is the useful operational
signal and not the same thing as RF silence.

For actual silence you need the human step, and it composes with kiosk mode nicely because
kiosk mode is what stops anyone undoing it:

1. Airplane Mode on, then enable Wi-Fi/Bluetooth only if you have a documented reason.
2. No SIM in a cellular iPad.
3. Unpair Bluetooth accessories — a paired Pencil or keyboard will re-establish links.
4. On a supervised device, use restrictions to remove Control Center and the ability to
   change these settings, so the state cannot drift.

**The timestamp consequence.** Airplane Mode means no NTP. The stamp is the device's own
clock, which drifts — seconds per day is normal, more on a cold or old device. If the
watermark is evidence rather than decoration, sync the clock before going offline, or have
the collector compare `recordedAt` against `monotonicMilliseconds` per link: a clock that
jumps relative to monotonic uptime is detectable after the fact, which is better than
trusting it in the moment.

## 4. The watermark

Three ways to do it, and they are not equivalent:

| Approach | Cost | What it proves |
|---|---|---|
| Screen overlay only (`TelemetryWatermark`) | Free | Nothing about the file — the stamp is not in the recording |
| Burned into the file (`WatermarkComposer`) | A full re-encode per segment | A human watching the file sees when it was made and on what power |
| Metadata only (chain payload) | Free | Machine-verifiable, tamper-evident, but invisible to a viewer |

The app supports all three, and the ordering matters: **`finishWriting` → burn → SHA-256 →
chain link.** Hashing before the burn would sign bytes that no longer exist on disk, and the
verifier would report every file as tampered.

`WatermarkComposer` uses `AVVideoCompositionCoreAnimationTool`, which renders a `CATextLayer`
at export time. That is a re-encode at close to real time on the same silicon, so budget
**+40% to +100% energy per recorded hour** and measure it rather than trusting the estimate.
On mains, do it. On battery, prefer the metadata route and burn nothing.

Two details that look cosmetic and are not:

- **The stamp drifts** by a few points every twenty minutes (`TelemetryFormat.drift`). A
  permanently lit element on a panel that runs for weeks is a bad idea, and a *live*
  watermark moves while a spliced frame's does not.
- **Text, not icons.** `CHARGING` survives downscaling and re-encoding; a bolt glyph does
  not.

## 5. What kiosk mode costs

Nothing on top of the recorder itself — the kiosk controls are configuration and monitoring.
The budget stays what it was:

| Configuration | Draw | 11" iPad Air |
|---|---|---|
| Audio only, screen locked | ~0.22 W | ~118 h |
| Video 1080p15, brightness 0.04 | ~1.62 W | ~16 h |
| Video 1080p15 + burned watermark | ~1.6 W while recording, ~3 W during export | ~9–12 h |
| Any of the above on mains + UPS | — | thermally limited, not energy limited |

## 6. Deployment checklist

- [ ] Supervised device, MDM profile, single-app mode (or Guided Access enabled + passcode held by ops)
- [ ] `UIRequiresFullScreen` is in `Info.plist` — no Split View next to the recorder
- [ ] Airplane Mode on, no SIM, Bluetooth accessories unpaired
- [ ] Brightness floor set by the app (`DimLevel.watermark`), not by hand
- [ ] Mains power with a small UPS; an outage is the cheapest way to lose the current hour
- [ ] Clock synced before going offline; drift budget written down
- [ ] Ventilation — sealed box plus continuous video equals thermal shutdown in hours
- [ ] Passcode on the device and on Guided Access, held by someone accountable
- [ ] `UIFileSharingEnabled` removed from `Info.plist` in production (`Docs/TAMPER-EVIDENCE.md`)

## 7. Verifying it on the device

1. Start recording, call `enter()`. The screen should dim within a frame or two and the stamp
   should appear top-centre with the correct time and battery.
2. Triple-click the side button. If Guided Access is active, nothing happens; if it is not,
   `KioskStatus` should be reporting "Guided Access is not active".
3. Turn Wi-Fi on in Settings (you will have to leave the app). `radioAnomaly` should be
   stamped with the time it came up.
4. Unplug power. The stamp should switch from `CHARGING` to `ON BATTERY` within a second,
   without a restart.
5. Stop, then burn one segment and verify the text is at the **top**, not the bottom. Layer
   space in `AVVideoCompositionCoreAnimationTool` is bottom-left origin, so if it lands
   upside-down the fix is the single `y:` line in `WatermarkComposer`.
