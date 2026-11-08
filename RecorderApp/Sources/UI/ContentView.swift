import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: RecorderViewModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Form {
                recorderSection
                coverageSection
                powerSection
                settingsSection
            }
            .navigationTitle("Continuous Recorder")
            .onChange(of: scenePhase) { _, phase in
                model.setUIActive(phase == .active)
            }
        }
    }

    // MARK: - Sections

    private var recorderSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.elapsedText)
                    .font(.system(size: 46, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                LevelBar(level: model.level)

                HStack(spacing: 8) {
                    Circle()
                        .fill(model.isCapturing ? Color.red : Color.secondary.opacity(0.4))
                        .frame(width: 8, height: 8)
                    Text(model.statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let error = model.lastError {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityLabel(error)
                    }
                }
            }
            .padding(.vertical, 4)

            Button {
                model.toggle()
            } label: {
                Label(
                    model.isRecording ? "Stop recording" : "Start recording",
                    systemImage: model.isRecording ? "stop.circle.fill" : "record.circle"
                )
                .font(.headline)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isRecording ? .red : .accentColor)
            .controlSize(.large)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        } header: {
            Text("Recorder")
        }
    }

    private var coverageSection: some View {
        Section("Capture integrity") {
            LabeledContent("Coverage", value: model.coverageText)
            LabeledContent("Audio", value: RecorderViewModel.hms(model.audioSeconds))
            LabeledContent("Segments written", value: "\(model.segmentCount)")
            LabeledContent("Gaps", value: "\(model.coverage.gapCount)")
            if model.coverage.gapCount > 0 {
                LabeledContent("Longest gap", value: String(format: "%.2f s", model.coverage.largestGapSeconds))
            }
            LabeledContent("On disk", value: RecorderViewModel.bytesText(model.bytesOnDisk))
            LabeledContent("Free space", value: model.freeBytes.map(RecorderViewModel.bytesText) ?? "—")
            if let days = model.storageDays {
                LabeledContent("Headroom at this rate", value: String(format: "%.0f days", days))
            }
            if let segment = model.lastSegment {
                LabeledContent("Last file", value: segment.fileName)
            }
        }
    }

    private var powerSection: some View {
        Section("Power") {
            LabeledContent("Battery", value: batteryText)
            LabeledContent("Measured draw", value: model.observedWattsText)
            LabeledContent("Projected remaining", value: model.projectedText)
            LabeledContent("Thermal", value: model.thermal.displayName)
            LabeledContent("Low power mode", value: model.lowPowerMode ? "On" : "Off")
            LabeledContent("Assumed capacity", value: model.capacityText)
        }
    }

    private var settingsSection: some View {
        Section("Settings") {
            Picker("Format", selection: $model.preset) {
                ForEach(RecordingProfile.Preset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }

            Picker("Segment length", selection: $model.segmentMinutes) {
                Text("1 minute").tag(1)
                Text("5 minutes").tag(5)
                Text("10 minutes").tag(10)
                Text("30 minutes").tag(30)
            }

            Stepper(
                "Auto-stop at \(model.autoStopBatteryPercent)%",
                value: $model.autoStopBatteryPercent,
                in: 5...50,
                step: 5
            )

            Picker("Battery model", selection: $model.deviceID) {
                ForEach(EnergyModel.devices) { device in
                    Text(device.name).tag(device.id)
                }
            }
        } footer: {
            Text("Settings apply from the next segment. Files land in Files ▸ On My iPad ▸ Continuous Recorder ▸ Recordings.")
        }
    }

    private var batteryText: String {
        guard let fraction = model.batteryFraction else { return "—" }
        let percent = Int((fraction * 100).rounded())
        return model.batteryCharging ? "\(percent)% (charging)" : "\(percent)%"
    }
}

struct LevelBar: View {
    let level: Float

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(2, geometry.size.width * CGFloat(min(1, max(0, level)))))
            }
        }
        .frame(height: 8)
        .animation(.linear(duration: 0.2), value: level)
    }
}

#Preview {
    ContentView()
        .environmentObject(RecorderViewModel())
}
