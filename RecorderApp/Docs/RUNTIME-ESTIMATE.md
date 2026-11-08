# Runtime estimate: continuous recording on an iPad Air

All figures below come from `Tools/runtime_estimate.py`, which you can re-run and edit.
Nothing here is a measurement of *your* device — it is a model with a stated shape, and
the app measures the real number for you while it runs (see "Calibrating" at the bottom).

## What is being modelled

A single-process app that holds the microphone open continuously, writes compressed audio
to local flash, and does nothing else: no network traffic of its own, no playback, screen
off (locked). Energy comes from four things:

| Component | Draw (low / typical / high) |
|---|---|
| SoC idle + OS background activity | 0.09 / 0.13 / 0.20 W |
| Microphone + ADC + audio subsystem | 0.02 / 0.04 / 0.07 W |
| AAC encode (hardware codec) + file I/O | 0.02 / 0.05 / 0.10 W |
| Wi-Fi associated but idle | 0.05 / 0.10 / 0.25 W |
| Screen on, 25% brightness | 0.35 / 0.55 / 0.80 W |
| Screen on, 60% brightness | 0.90 / 1.20 / 1.60 W |

Sanity anchor: Apple rates the 11-inch iPad Air at "up to 10 hours of surfing the web on
Wi-Fi" on a 28.93 Wh battery, i.e. roughly **2.9 W** for a screen-on, radio-on workload.
Screen-off audio capture is about an order of magnitude below that, which is why the
answers below are measured in days rather than hours.

Battery capacity: **28.93 Wh** (11-inch) and **36.59 Wh** (13-inch), per Apple's tech
specs. Usable energy assumes a 10% reserve so the OS can shut down cleanly instead of
yanking power mid-write.

## Answer

**iPad Air 11-inch, from 100% to the 10% reserve:**

| How it is used | Typical draw | Hours | With a 1-year-old battery and 35% real-world margin |
|---|---|---|---|
| Locked, airplane mode, AAC 48 kbps mono | 0.22 W | **118 h** (4.9 days) | 77 h (3.2 days) |
| Locked, Wi-Fi on, AAC 48 kbps mono | 0.32 W | **81 h** (3.4 days) | 53 h (2.2 days) |
| Locked, Wi-Fi on, AAC 96 kbps/ch | 0.32 W | 81 h (3.4 days) | 53 h (2.2 days) |
| Screen left on at 25%, Wi-Fi on | 0.87 W | 30 h | 20 h |
| Screen left on at 60%, Wi-Fi on | 1.52 W | 17 h | 11 h |

**iPad Air 13-inch (36.59 Wh) is about 26% longer:** 150 h / 103 h / 103 h / 38 h / 22 h
for the same five rows.

Planning numbers, if you want one line each:

- **11-inch, locked and unattended: plan on ~2–3 days per charge** (measured models say
  3.4; older batteries, background sync and warm rooms eat the difference).
- **13-inch, locked and unattended: plan on ~3–4 days per charge.**
- **If the screen stays on, divide by roughly four.**

Two things dominate, in this order:

1. **The screen.** Leaving it visible at moderate brightness costs 0.9–1.6 W, which is
   four to seven times the entire recording workload. Lock the screen; that single habit
   is worth ~60 hours.
2. **The radio.** Wi-Fi associated but idle costs about as much as the microphone, the
   encoder and the SoC combined. Airplane mode is a 30% runtime win.

Bitrate is almost irrelevant to runtime and completely relevant to storage. Encoding
48 kbps costs essentially the same as 128 kbps on the audio DSP.

## Storage, which is the real ceiling

Continuous 48 kHz mono, one device, 24/7:

| Format | Per hour | Per day | Days in 100 GB free |
|---|---|---|---|
| AAC 48 kbps mono (speech) | 21.6 MB | 0.52 GB | **193 days** |
| AAC 96 kbps mono (balanced) | 43.2 MB | 1.04 GB | 96 days |
| AAC 128 kbps stereo (high) | 115 MB | 2.76 GB | 36 days |
| ALAC 16-bit mono (lossless) | 190 MB | 4.6 GB | 22 days |
| PCM 16-bit mono (WAV) | 346 MB | 8.3 GB | 12 days |

So: **battery is measured in days, storage in weeks.** A 128 GB iPad recording speech-grade
AAC never has to delete anything for months; the same iPad recording WAV runs out in under
two weeks. Choose lossless only if the audio is evidence, not just audio.

Second-order point on storage: at 48 kbps the app writes a 5-minute file every 5 minutes,
which is 288 writes a day. Writing 8,640 one-second files a day would multiply metadata
overhead for no capture benefit — the segment length is the knob for *crash safety*, not
for "recording every second".

## Calibrating against your own hardware

The app displays a **Measured draw** once it has watched the battery fall by at least 2
percentage points over at least 10 minutes (battery percentage only moves in 1% steps, so
faster readings are noise). Once it has a number it uses that instead of the model.

Manual cross-check, 1 hour:

1. Charge to 100%, unplug, note the time.
2. Start recording, lock the screen, put it in airplane mode, leave it alone for 1 hour.
3. Note the battery percentage. `watts ≈ 28.93 × Δfraction / 1 h` (or 36.59 for the 13-inch).
4. Feed it back in: `python Tools/runtime_estimate.py --measured-watts 0.29`.

Expect **0.2–0.4 W** if you did it right. If you measure more than 0.6 W, something else is
running: screen wake-ups from notifications, a case with a keyboard attached, Wi-Fi
scanning, or the app being foregrounded by the system.

## Running 24/7 instead of on battery

For an always-on recorder the battery is not the constraint, the charger is:

- Average draw ~0.3 W, so any 5 W charger keeps up with enormous margin. Charging speed is
  not the issue; **heat and calendar ageing** are.
- Continuous charging at 100% in a warm enclosure is the fastest way to destroy a lithium
  battery. Use the iPadOS charging limit (80%) if your model has it, or a smart plug that
  charges 6 hours a day, and keep the device out of direct sun.
- An 18-month-old battery at 80% health is an 18% runtime loss on every row above — the
  model's "1-year-old battery" column is deliberately not the best case.
- Thermal throttling is handled: the governor downgrades to speech-grade AAC when the
  device reports `.serious` thermal state, and stops entirely at `.critical`.
