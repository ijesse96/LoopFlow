import SwiftUI

struct TopToolbarView: View {
    @ObservedObject var vm: ProjectViewModel

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                menuButton
                TextField("Project", text: $vm.project.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 140)
                    .onChange(of: vm.project.name) { _, _ in vm.autosave() }

                Spacer(minLength: 0)

                Button {
                    vm.save()
                } label: {
                    Label("Save", systemImage: "icloud.and.arrow.up")
                        .labelStyle(.iconOnly)
                }
                .foregroundStyle(AppTheme.textPrimary)

                Button {
                    vm.showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .foregroundStyle(AppTheme.textPrimary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    tempoGroup
                    transportGroup
                    Text(vm.timeDisplay)
                        .font(.system(.caption, design: .monospaced).weight(.medium))
                        .foregroundStyle(AppTheme.textPrimary)
                        .frame(minWidth: 64)
                    utilityGroup
                }
                .padding(.horizontal, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(AppTheme.surface)
    }

    private var menuButton: some View {
        Menu {
            Button("Import / Replace Instrumental…") { vm.showImporter = true }
            Button("Clear Instrumental", role: .destructive) { vm.clearInstrumental() }
            Button("Project Setup…") { vm.showSetupSheet = true }
            Button("Export…") { vm.showExport = true }
            Divider()
            Button("New Project", role: .destructive) { vm.startNewProject() }
            Divider()
            Button("Settings") { vm.showSettings = true }
        } label: {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(AppTheme.textPrimary)
        }
    }

    private var tempoGroup: some View {
        HStack(spacing: 8) {
            Button {
                vm.project.metronomeEnabled.toggle()
                vm.applyAudioFromProject()
                vm.autosave()
            } label: {
                Image(systemName: "metronome")
                    .foregroundStyle(vm.project.metronomeEnabled ? AppTheme.accent : AppTheme.textSecondary)
            }

            HStack(spacing: 4) {
                TextField(
                    "BPM",
                    value: $vm.project.bpm,
                    format: .number.precision(.fractionLength(0))
                )
                .keyboardType(.decimalPad)
                .frame(width: 36)
                .multilineTextAlignment(.trailing)
                .onChange(of: vm.project.bpm) { _, _ in
                    vm.applyAudioFromProject()
                    vm.autosave()
                }
                Text("bpm")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(AppTheme.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Text(vm.project.timeSignature.displayString)
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
                .onTapGesture {
                    // Cycle common signatures
                    if vm.project.timeSignature.beatsPerBar == 4 {
                        vm.project.timeSignature = TimeSignature(beatsPerBar: 3, beatUnit: 4)
                    } else {
                        vm.project.timeSignature = .fourFour
                    }
                    vm.applyAudioFromProject()
                    vm.autosave()
                }

            Menu {
                ForEach(MusicalKey.allCases) { key in
                    Button(key.rawValue) {
                        vm.project.musicalKey = key
                        vm.autosave()
                    }
                }
            } label: {
                Text(vm.project.musicalKey.rawValue)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(AppTheme.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(AppTheme.textPrimary)
            }
        }
    }

    private var transportGroup: some View {
        HStack(spacing: 14) {
            Button {
                vm.togglePlay()
            } label: {
                Image(systemName: vm.audio.isPlaying && vm.recording.phase == .idle ? "pause.fill" : "play.fill")
                    .foregroundStyle(AppTheme.transport)
            }

            Button {
                vm.returnToBeginning()
            } label: {
                Image(systemName: "backward.end.fill")
                    .foregroundStyle(AppTheme.transport)
            }

            Button {
                vm.toggleRecord()
            } label: {
                Image(systemName: vm.recording.phase == .idle ? "circle.fill" : "stop.circle.fill")
                    .foregroundStyle(AppTheme.record)
                    .font(.title3)
            }

            Button {
                vm.setLoopEnabled(!vm.project.loopEnabled)
            } label: {
                Image(systemName: "repeat")
                    .foregroundStyle(vm.project.loopEnabled ? AppTheme.accent : AppTheme.textSecondary)
            }
        }
    }

    private var utilityGroup: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                Slider(value: $vm.project.masterVolume, in: 0...1)
                    .frame(width: 80)
                    .onChange(of: vm.project.masterVolume) { _, v in
                        vm.audio.setMasterVolume(v)
                        vm.autosave()
                    }
            }

            Button { vm.performUndo() } label: {
                Image(systemName: "arrow.uturn.backward")
                    .foregroundStyle(vm.editHistory.canUndo ? AppTheme.textPrimary : AppTheme.textSecondary)
            }
            .disabled(!vm.editHistory.canUndo)

            Button { vm.performRedo() } label: {
                Image(systemName: "arrow.uturn.forward")
                    .foregroundStyle(vm.editHistory.canRedo ? AppTheme.textPrimary : AppTheme.textSecondary)
            }
            .disabled(!vm.editHistory.canRedo)

            Button {
                vm.project.snapEnabled.toggle()
                vm.autosave()
            } label: {
                Image(systemName: "magnet")
                    .foregroundStyle(vm.project.snapEnabled ? AppTheme.accent : AppTheme.textSecondary)
            }

            Button { vm.zoomOut() } label: {
                Image(systemName: "minus.magnifyingglass")
                    .foregroundStyle(AppTheme.textSecondary)
            }
            Button { vm.zoomIn() } label: {
                Image(systemName: "plus.magnifyingglass")
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
    }
}
