import SwiftUI

struct ProjectSetupView: View {
    @ObservedObject var vm: ProjectViewModel
    @Environment(\.dismiss) private var dismiss

    private var hasInstrumental: Bool {
        vm.project.instrumentalTrack?.audioRelativePath != nil
    }

    private var sourceStartLabel: String {
        guard let clip = vm.instrumentalClip else { return "—" }
        return String(format: "%.2fs", clip.sourceStartSeconds)
    }

    private var sourceEndLabel: String {
        guard let clip = vm.instrumentalClip else { return "—" }
        return String(format: "%.2fs", clip.sourceEndSeconds)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Instrumental") {
                    if hasInstrumental {
                        Label("Beat imported", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Import Instrumental…") {
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                vm.showImporter = true
                            }
                        }
                    }
                }

                Section("Tempo") {
                    Stepper(value: $vm.project.bpm, in: 40...240, step: 1) {
                        Text("BPM: \(Int(vm.project.bpm))")
                    }
                }

                if hasInstrumental {
                    Section {
                        Button {
                            vm.alignInstrumentalToFirstSound()
                        } label: {
                            Label("Find First Sound", systemImage: "waveform")
                        }

                        HStack {
                            Text("In-point")
                            Spacer()
                            Text(sourceStartLabel)
                                .foregroundStyle(AppTheme.textSecondary)
                                .monospacedDigit()
                        }
                        HStack(spacing: 12) {
                            Button("-1 beat") {
                                vm.nudgeInstrumentalSourceStart(deltaSeconds: -vm.project.secondsPerBeat)
                            }
                            Button("-10 ms") {
                                vm.nudgeInstrumentalSourceStart(deltaSeconds: -0.01)
                            }
                            Spacer()
                            Button("+10 ms") {
                                vm.nudgeInstrumentalSourceStart(deltaSeconds: 0.01)
                            }
                            Button("+1 beat") {
                                vm.nudgeInstrumentalSourceStart(deltaSeconds: vm.project.secondsPerBeat)
                            }
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)

                        HStack {
                            Text("Out-point")
                            Spacer()
                            Text(sourceEndLabel)
                                .foregroundStyle(AppTheme.textSecondary)
                                .monospacedDigit()
                        }
                        HStack(spacing: 12) {
                            Button("-1 beat") {
                                vm.nudgeInstrumentalSourceEnd(deltaSeconds: -vm.project.secondsPerBeat)
                            }
                            Button("-10 ms") {
                                vm.nudgeInstrumentalSourceEnd(deltaSeconds: -0.01)
                            }
                            Spacer()
                            Button("+10 ms") {
                                vm.nudgeInstrumentalSourceEnd(deltaSeconds: 0.01)
                            }
                            Button("+1 beat") {
                                vm.nudgeInstrumentalSourceEnd(deltaSeconds: vm.project.secondsPerBeat)
                            }
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)

                        Button("Reset to Full File") {
                            vm.resetInstrumentalClipBounds()
                        }
                        .foregroundStyle(.orange)
                    } header: {
                        Text("Align")
                    } footer: {
                        Text("Skips silence before the beat so bar 1 matches the audible start. Nudge if the auto threshold is slightly early or late.")
                    }
                }

                Section("Recording Length") {
                    Picker("Region", selection: $vm.project.regionLength) {
                        ForEach(RegionLength.allCases) { length in
                            Text(length.displayName).tag(length)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: vm.project.regionLength) { _, length in
                        vm.applyRegionPreset(length)
                    }
                }

                Section {
                    Text("When you record, LoopFlow loops only the active region and creates a new take every pass. Accept with your Bluetooth controller to advance.")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
            .navigationTitle("Project Setup")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        vm.applyAudioFromProject()
                        vm.autosave()
                        dismiss()
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
