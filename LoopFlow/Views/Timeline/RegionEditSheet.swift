import SwiftUI

struct RegionEditSheet: View {
    @ObservedObject var vm: ProjectViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
                    editButton("Move", systemImage: "arrow.left.and.right") {
                        vm.recording.statusMessage = "Drag the clip to move"
                    }
                    editButton("Find First Sound", systemImage: "waveform") {
                        vm.alignInstrumentalToFirstSound()
                    }
                    editButton("Trim Start", systemImage: "arrow.right.to.line") {
                        vm.nudgeTrimStart()
                    }
                    editButton("Trim End", systemImage: "arrow.left.to.line") {
                        vm.nudgeTrimEnd()
                    }
                    editButton("Split at Playhead", systemImage: "scissors") {
                        vm.splitSelectedClipAtPlayhead()
                    }
                    editButton("Copy", systemImage: "doc.on.doc") {
                        vm.copySelectedClip()
                    }
                    editButton("Cut", systemImage: "scissors.badge.ellipsis") {
                        vm.cutSelectedClip()
                    }
                    editButton("Paste", systemImage: "doc.on.clipboard") {
                        vm.pasteClipboard()
                    }
                    editButton("Duplicate", systemImage: "plus.square.on.square") {
                        vm.duplicateSelectedClip()
                    }
                    editButton("Delete", systemImage: "trash", destructive: true) {
                        vm.deleteSelectedClip()
                        dismiss()
                    }
                    editButton(
                        vm.selectedClip?.isMuted == true ? "Unmute" : "Mute",
                        systemImage: "speaker.slash"
                    ) {
                        vm.toggleMuteSelectedClip()
                    }
                    editButton(
                        vm.selectedClip?.isLooping == true ? "Unloop" : "Loop",
                        systemImage: "repeat"
                    ) {
                        vm.toggleLoopSelectedClip()
                    }
                }
                .padding()

                Toggle(isOn: Binding(
                    get: { vm.project.snapEnabled },
                    set: { _ in vm.toggleSnap() }
                )) {
                    Label("Snap to Grid", systemImage: "magnet")
                }
                .padding(.horizontal)

                HStack {
                    Button("Undo") { vm.performUndo() }
                        .disabled(!vm.editHistory.canUndo)
                    Spacer()
                    Button("Redo") { vm.performRedo() }
                        .disabled(!vm.editHistory.canRedo)
                }
                .padding()
            }
            .navigationTitle("Edit Region")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .background(AppTheme.background)
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }

    private func editButton(
        _ title: String,
        systemImage: String,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.title3)
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(destructive ? Color.red : AppTheme.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(AppTheme.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}
