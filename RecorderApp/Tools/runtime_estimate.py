#!/usr/bin/env python3
"""Runtime and storage model for continuous recording on iPad / iPhone.

This is a *model*, not a measurement. It exists so the numbers in the docs are
reproducible and so you can swap in your own measured watts.

The model is anchored on Apple's own published figures: an 11-inch iPad Air has a
28.93 Wh battery and Apple quotes "up to 10 hours of surfing the web on Wi-Fi",
i.e. roughly 2.9 W for a screen-on, radio-on workload. Audio-only recording with
the screen locked is an order of magnitude cheaper than that. Video is not: the
ISP, the encoder and the panel together land at 1.5–3 W, so video runs in hours
where audio ran in days.

Usage:
    python runtime_estimate.py                       # audio, default report
    python runtime_estimate.py --mode video --markdown
    python runtime_estimate.py --measured-watts 0.31
    python runtime_estimate.py --wh 36.59 --bitrate-kbps 128 --channels 2
"""

from __future__ import annotations

import argparse

# --- Devices -----------------------------------------------------------------
# Source: Apple tech specs. Battery figures are design capacity in watt-hours.
DEVICES = {
    "iPad Air 11\" (M2/M3)": 28.93,
    "iPad Air 13\" (M2/M3)": 36.59,
    "iPad Air 10.9\" (4th/5th gen)": 28.60,
    "iPad Pro 11\" (M4)": 31.29,
    "iPad Pro 13\" (M4)": 38.99,
    "iPhone 15 / 16 (approx.)": 13.00,
}

# --- Power components (watts) -------------------------------------------------
# (low, typical, high). Screen off, no charging, nothing else running.
COMPONENTS = {
    "SoC idle + OS background": (0.09, 0.13, 0.20),
    "Microphone + ADC + audio subsystem": (0.02, 0.04, 0.07),
    "AAC encode (hardware codec) + file I/O": (0.02, 0.05, 0.10),
    "Wi-Fi associated, idle traffic": (0.05, 0.10, 0.25),
    "Screen on, 25% brightness (11\" LCD)": (0.35, 0.55, 0.80),
    "Screen on, 60% brightness (11\" LCD)": (0.90, 1.20, 1.60),

    # Video-only paths. Camera + ISP dominates: the sensor runs continuously and the
    # pipeline holds buffers no matter what the encoder does.
    "Camera sensor + ISP (1080p)": (0.50, 0.90, 1.40),
    "Camera sensor + ISP (4K)": (0.90, 1.50, 2.30),
    "HEVC encode (1080p15)": (0.08, 0.18, 0.32),
    "HEVC encode (1080p30)": (0.14, 0.35, 0.60),
    "HEVC encode (4K30)": (0.30, 0.60, 1.00),
    "Display lit at 0% backlight": (0.15, 0.35, 0.60),
    "Storage I/O (video bitrate)": (0.02, 0.04, 0.08),
}

AUDIO_SCENARIOS = [
    ("Screen locked, airplane mode, AAC 48 kbps mono",
     ["SoC idle + OS background", "Microphone + ADC + audio subsystem",
      "AAC encode (hardware codec) + file I/O"], "reference case"),
    ("Screen locked, Wi-Fi on, AAC 48 kbps mono",
     ["SoC idle + OS background", "Microphone + ADC + audio subsystem",
      "AAC encode (hardware codec) + file I/O", "Wi-Fi associated, idle traffic"],
     "realistic unattended"),
    ("Screen locked, Wi-Fi on, AAC 96 kbps/ch",
     ["SoC idle + OS background", "Microphone + ADC + audio subsystem",
      "AAC encode (hardware codec) + file I/O", "Wi-Fi associated, idle traffic"],
     "balanced profile"),
    ("Screen on 25%, Wi-Fi on",
     ["SoC idle + OS background", "Microphone + ADC + audio subsystem",
      "AAC encode (hardware codec) + file I/O", "Wi-Fi associated, idle traffic",
      "Screen on, 25% brightness (11\" LCD)"], "app left visible"),
    ("Screen on 60%, Wi-Fi on",
     ["SoC idle + OS background", "Microphone + ADC + audio subsystem",
      "AAC encode (hardware codec) + file I/O", "Wi-Fi associated, idle traffic",
      "Screen on, 60% brightness (11\" LCD)"], "worst realistic case"),
]

VIDEO_SCENARIOS = [
    ("1080p15 HEVC 4 Mbps, brightness 0 (recommended)",
     ["SoC idle + OS background", "Camera sensor + ISP (1080p)", "HEVC encode (1080p15)",
      "Display lit at 0% backlight", "Storage I/O (video bitrate)"], "surveillance default"),
    ("1080p30 HEVC 6 Mbps, brightness 0",
     ["SoC idle + OS background", "Camera sensor + ISP (1080p)", "HEVC encode (1080p30)",
      "Display lit at 0% backlight", "Storage I/O (video bitrate)"], "smoother motion"),
    ("1080p15 HEVC, brightness 25%",
     ["SoC idle + OS background", "Camera sensor + ISP (1080p)", "HEVC encode (1080p15)",
      "Screen on, 25% brightness (11\" LCD)", "Storage I/O (video bitrate)"], "panel left readable"),
    ("4K30 HEVC 12 Mbps, brightness 0",
     ["SoC idle + OS background", "Camera sensor + ISP (4K)", "HEVC encode (4K30)",
      "Display lit at 0% backlight", "Storage I/O (video bitrate)"], "highest quality"),
]

RESERVE = 0.10          # keep 10% so the device shuts down cleanly
AGING = 0.12            # a 1-year-old battery delivers ~88% of design capacity
REAL_WORLD_PENALTY = 1.35   # background sync, notifications, thermal, model error


def scenario_watts(keys: list[str]) -> tuple[float, float, float]:
    lo = sum(COMPONENTS[k][0] for k in keys)
    mid = sum(COMPONENTS[k][1] for k in keys)
    hi = sum(COMPONENTS[k][2] for k in keys)
    return lo, mid, hi


def usable_wh(wh: float, reserve: float = RESERVE) -> float:
    return wh * (1.0 - reserve)


def hours(wh: float, watts: float) -> float:
    return wh / watts if watts > 0 else float("inf")


def streaming_mb_per_hour(kbps: int, channels: int) -> float:
    return kbps * channels * 3600 / 8 / 1_000_000 * 1_000  # kbit -> MB


def pcm_mb_per_hour(sample_rate: float, channels: int, bits: int = 16) -> float:
    return sample_rate * channels * (bits / 8) * 3600 / 1_000_000


def fmt_hours(h: float) -> str:
    days = h / 24
    if days >= 2:
        return f"{h:,.0f} h ({days:.1f} d)"
    return f"{h:,.1f} h"


def storage_section() -> list[str]:
    out = ["Audio storage (48 kHz mono, 24/7):"]
    out.append(f"  AAC 48 kbps mono  : {streaming_mb_per_hour(48, 1):6.1f} MB/h  "
               f"{streaming_mb_per_hour(48, 1) * 24 / 1000:5.2f} GB/day")
    out.append(f"  AAC 96 kbps mono  : {streaming_mb_per_hour(96, 1):6.1f} MB/h  "
               f"{streaming_mb_per_hour(96, 1) * 24 / 1000:5.2f} GB/day")
    out.append(f"  AAC 128 kbps x2   : {streaming_mb_per_hour(128, 2):6.1f} MB/h  "
               f"{streaming_mb_per_hour(128, 2) * 24 / 1000:5.2f} GB/day")
    out.append(f"  ALAC 16-bit mono  : {pcm_mb_per_hour(48000, 1) * 0.55:6.0f} MB/h  "
               f"{pcm_mb_per_hour(48000, 1) * 0.55 * 24 / 1000:5.1f} GB/day")
    out.append(f"  PCM 16-bit mono   : {pcm_mb_per_hour(48000, 1):6.0f} MB/h  "
               f"{pcm_mb_per_hour(48000, 1) * 24 / 1000:5.1f} GB/day")
    out.append("")
    out.append("Video storage (one file per hour, 24/7) — 100 GB of free space holds:")
    for label, kbps in (("1080p15 HEVC 4 Mbps ", 4000), ("1080p30 HEVC 6 Mbps ", 6000),
                        ("1080p30 H.264 8 Mbps", 8000), ("4K30 HEVC 12 Mbps  ", 12000)):
        gb_per_hour = kbps * 3600 / 8 / 1_000_000
        out.append(f"  {label}: {gb_per_hour:5.2f} GB/h  {gb_per_hour * 24:6.1f} GB/day  "
                   f"{100 / (gb_per_hour * 24):4.1f} days")
    return out


def report(wh: float, device_name: str, kbps: int, channels: int, markdown: bool,
           measured_watts: float | None, mode: str) -> str:
    out: list[str] = []
    usable = usable_wh(wh)
    aged = usable * (1 - AGING)
    out.append(f"Device: {device_name} — {wh:.2f} Wh design, {usable:.2f} Wh usable (10% reserve)")
    out.append(f"Aged battery (12 months): {aged:.2f} Wh usable")
    out.append(f"Mode: {mode}")
    out.append("")

    scenarios = VIDEO_SCENARIOS if mode == "video" else AUDIO_SCENARIOS
    if markdown:
        out.append("| Scenario | Typical draw | Hours @ design capacity | Planning figure (−35% real world) |")
        out.append("|---|---|---|---|")
    for name, keys, _note in scenarios:
        lo, mid, hi = scenario_watts(keys)
        h_mid = hours(usable, mid)
        planning = hours(aged, mid * REAL_WORLD_PENALTY)
        line = f"{name} | {mid:.2f} W ({lo:.2f}–{hi:.2f}) | {fmt_hours(h_mid)} | {fmt_hours(planning)}"
        out.append(f"| {line} |" if markdown else f"  {line}")
    out.append("")

    if measured_watts:
        out.append(f"With your measured {measured_watts:.2f} W:")
        out.append(f"  design capacity : {fmt_hours(hours(usable, measured_watts))}")
        out.append(f"  aged +30% margin: {fmt_hours(hours(aged, measured_watts * 1.30))}")
        out.append("")

    if mode == "audio":
        out.append(f"At {kbps} kbps × {channels} ch: "
                   f"{streaming_mb_per_hour(kbps, channels):.1f} MB/h, "
                   f"{streaming_mb_per_hour(kbps, channels) * 24 / 1000:.2f} GB/day")
        out.append(f"  128 GB iPad → ~{100_000 / (streaming_mb_per_hour(kbps, channels) * 24):.0f} days of continuous audio")
        out.append("")

    out.extend(storage_section())
    out.append("")

    out.append("Hours from watts (usable capacity, 10% reserve):")
    for w in (0.15, 0.20, 0.25, 0.30, 0.50, 0.75, 1.00, 1.50, 2.00, 2.50, 3.00):
        out.append(f"  {w:4.2f} W -> {fmt_hours(hours(usable, w))}")
    return "\n".join(out)


def main() -> None:
    p = argparse.ArgumentParser(description="Continuous-recording runtime model")
    p.add_argument("--device", default='iPad Air 11" (M2/M3)', choices=list(DEVICES))
    p.add_argument("--wh", type=float, default=None, help="override battery watt-hours")
    p.add_argument("--mode", choices=["audio", "video"], default="audio")
    p.add_argument("--bitrate-kbps", type=int, default=48)
    p.add_argument("--channels", type=int, default=1)
    p.add_argument("--measured-watts", type=float, default=None)
    p.add_argument("--markdown", action="store_true")
    args = p.parse_args()

    wh = args.wh if args.wh is not None else DEVICES[args.device]
    print(report(wh, args.device, args.bitrate_kbps, args.channels, args.markdown,
                 args.measured_watts, args.mode))


if __name__ == "__main__":
    main()
