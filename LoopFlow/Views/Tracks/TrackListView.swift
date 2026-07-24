import SwiftUI

struct TrackHeaderView: View {
    @Binding var track: Track
    var isSelected: Bool = false
    var isRecordingHere: Bool = false
    /// True when I is on but output isn't headphones/BT.
    var monitorBlockedByRoute: Bool = false
    /// Show live mic meter (recording this track or I armed).
    var showInputMeter: Bool = false
    var inputLevel: Float = 0
    var onSelect: (() -> Void)?
    var onToggleInputMonitor: ((Bool) -> Void)?
    @State private var showEffects = false

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(isRecordingHere ? AppTheme.record : (isSelected ? AppTheme.accent : Color.clear))
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: iconName)
                            .font(.caption)
                            .foregroundStyle(AppTheme.accent)
                            .frame(width: 14)

                        Text(track.name)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.textPrimary)
                            .lineLimit(1)

                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect?() }

                    if track.type == .vocal || track.type == .audio {
                        muteSoloButton(
                            "I",
                            active: track.inputMonitorEnabled,
                            activeColor: monitorBlockedByRoute && track.inputMonitorEnabled
                                ? Color.orange
                                : AppTheme.accent
                        ) {
                            onToggleInputMonitor?(!track.inputMonitorEnabled)
                        }
                    }
                    muteSoloButton("M", active: track.isMuted, activeColor: AppTheme.accent) {
                        track.isMuted.toggle()
                    }
                    muteSoloButton("S", active: track.isSoloed, activeColor: Color.yellow) {
                        track.isSoloed.toggle()
                    }
                }

                HStack(spacing: 6) {
                    Button {
                        showEffects = true
                    } label: {
                        Text("+ Fx")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(AppTheme.surfaceElevated)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    .buttonStyle(.borderless)

                    Slider(value: $track.volume, in: 0...1)
                        .tint(AppTheme.accent)
                }

                if showInputMeter {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(AppTheme.surfaceElevated)
                            Capsule()
                                .fill(isRecordingHere ? AppTheme.record : AppTheme.accent)
                                .frame(width: max(2, geo.size.width * CGFloat(min(1, max(0, inputLevel)))))
                        }
                    }
                    .frame(height: 5)
                } else {
                    HStack(spacing: 4) {
                        Text("L")
                            .font(.system(size: 8))
                            .foregroundStyle(AppTheme.textSecondary)
                        Slider(value: $track.pan, in: -1...1)
                            .tint(AppTheme.textSecondary)
                        Text("R")
                            .font(.system(size: 8))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(isSelected ? AppTheme.accent.opacity(0.12) : AppTheme.surface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppTheme.border)
                .frame(height: 1)
        }
        .sheet(isPresented: $showEffects) {
            NavigationStack {
                EffectsSlotView(trackName: track.name, slots: track.effectSlots)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showEffects = false }
                        }
                    }
            }
            .preferredColorScheme(.dark)
        }
    }

    private func muteSoloButton(
        _ title: String,
        active: Bool,
        activeColor: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
                .background(active ? activeColor.opacity(0.35) : AppTheme.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(AppTheme.textPrimary)
    }

    private var iconName: String {
        switch track.type {
        case .instrumental: return "waveform"
        case .vocal: return "mic.fill"
        case .audio: return "square.stack.3d.up"
        }
    }
}

struct EffectsSlotView: View {
    let trackName: String
    let slots: [EffectSlotState]

    var body: some View {
        List {
            Section {
                Text("Built-in DSP and AUv3 plugins will plug into these slots in a later release.")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.textSecondary)
            }
            Section("Inserts") {
                ForEach(Array(slots.enumerated()), id: \.element.id) { index, slot in
                    HStack {
                        Text("Slot \(index + 1)")
                        Spacer()
                        Text(slot.typeName)
                            .foregroundStyle(AppTheme.textSecondary)
                        Text(slot.bypass ? "Bypassed" : "Active")
                            .font(.caption)
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }
            }
            Section("Planned") {
                Text("Reverb")
                Text("Delay")
                Text("Compressor")
                Text("EQ")
                Text("Noise Gate")
            }
        }
        .navigationTitle("\(trackName) FX")
        .scrollContentBackground(.hidden)
        .background(AppTheme.background)
    }
}
