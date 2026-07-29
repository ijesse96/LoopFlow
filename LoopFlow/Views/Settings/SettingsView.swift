import SwiftUI

struct SettingsView: View {
    @ObservedObject var vm: ProjectViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmNewSession = false

    var body: some View {
        NavigationStack {
            List {
                Section("Session") {
                    Stepper(value: $vm.project.bpm, in: 40...240, step: 1) {
                        Text("BPM: \(Int(vm.project.bpm))")
                    }
                    .onChange(of: vm.project.bpm) { _, _ in
                        vm.applyAudioFromProject()
                        vm.autosave()
                    }

                    Picker("Region Length", selection: $vm.project.regionLength) {
                        ForEach(RegionLength.allCases) { length in
                            Text(length.displayName).tag(length)
                        }
                    }
                    .onChange(of: vm.project.regionLength) { _, length in
                        vm.applyRegionPreset(length)
                    }

                    Toggle("Snap to Grid", isOn: Binding(
                        get: { vm.project.snapEnabled },
                        set: { _ in vm.toggleSnap() }
                    ))

                    Toggle("Count-in", isOn: $vm.project.countInEnabled)
                        .onChange(of: vm.project.countInEnabled) { _, _ in vm.autosave() }
                    Text("Used when starting from stop. Skipped if already playing.")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.textSecondary)

                    Toggle("Metronome", isOn: Binding(
                        get: { vm.project.metronomeEnabled },
                        set: { vm.setMetronomeEnabled($0) }
                    ))

                    Toggle("Loop Region", isOn: Binding(
                        get: { vm.project.loopEnabled },
                        set: { vm.setLoopEnabled($0) }
                    ))
                }

                Section("Recording") {
                    Stepper(value: $vm.recordingLatencyOffsetMs, in: -80...80, step: 5) {
                        Text("Latency offset: \(vm.recordingLatencyOffsetMs) ms")
                    }
                    Text("If kept takes play late, increase this. If early, decrease. Applies on Keep. Leave at 0 when auto-align feels tight.")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.textSecondary)
                }

                Section("Instrumental") {
                    Button("Import / Replace Instrumental…") {
                        dismiss()
                        vm.showImporter = true
                    }
                    Button("Clear Instrumental", role: .destructive) {
                        vm.clearInstrumental()
                        dismiss()
                    }
                }

                Section {
                    Button("New Session", role: .destructive) {
                        confirmNewSession = true
                    }
                }

                Section {
                    NavigationLink("Controller Mapping") {
                        ControllerMappingView(vm: vm)
                    }
                }

                Section("About") {
                    Text("LoopFlow V1")
                        .foregroundStyle(AppTheme.textSecondary)
                    Text("Effects DSP and AUv3 hosting come in a later release.")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppTheme.background)
            .confirmationDialog(
                "Start a new session? Current work is already saved.",
                isPresented: $confirmNewSession,
                titleVisibility: .visible
            ) {
                Button("New Session", role: .destructive) {
                    dismiss()
                    vm.startNewProject()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        .preferredColorScheme(.dark)
    }
}
