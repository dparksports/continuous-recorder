import SwiftUI

/// The stamp that sits at the top of the screen in kiosk mode.
///
/// Small, monospaced and high-contrast on purpose: it has to survive being read through a
/// camera, from across a room, on a dimmed panel. It drifts a few points every twenty
/// minutes so a multi-week session does not leave one row of pixels lit forever — and so a
/// frozen frame is obvious, because a live watermark moves and a splice does not.
struct TelemetryWatermark: View {
    let date: Date
    let battery: Double?
    let charging: Bool

    var body: some View {
        Text(TelemetryFormat.line(date: date, battery: battery, charging: charging))
            .font(.system(size: 15, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
            .offset(TelemetryFormat.drift(at: date))
            .accessibilityHidden(true)
    }
}

/// Ticks once a second on its own, so the surrounding recorder UI is not re-rendered at the
/// same rate. `TimelineView` also stops updating when the view leaves the screen, which is
/// the behaviour you want on a device you are trying not to waste power on.
struct LiveTelemetryWatermark: View {
    let battery: Double?
    let charging: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            TelemetryWatermark(date: context.date, battery: battery, charging: charging)
        }
    }
}

extension View {
    /// Pins the watermark to the top edge, inside the safe area.
    func kioskWatermark(battery: Double?, charging: Bool) -> some View {
        overlay(alignment: .top) {
            LiveTelemetryWatermark(battery: battery, charging: charging)
                .padding(.top, 8)
                .allowsHitTesting(false)
        }
    }
}

/// Shown in the settings sheet, never over the recording surface — a red banner in the
/// footage would be worse than the problem it reports.
struct KioskIssuesView: View {
    let status: KioskStatus

    var body: some View {
        if status.isCompliant {
            Label("Kiosk checks pass", systemImage: "checkmark.seal")
                .font(.footnote)
                .foregroundStyle(.green)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Label("\(status.issues.count) kiosk issue(s)", systemImage: "exclamationmark.triangle")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.orange)
                ForEach(status.issues, id: \.self) { issue in
                    Text("• \(issue)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
