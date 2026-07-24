import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var vm = ProjectViewModel()
    @FocusState private var keyboardFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    TopToolbarView(vm: vm)
                    Divider().background(AppTheme.border)
                    ArrangeView(vm: vm)
                        .frame(maxHeight: .infinity)
                    statusBar
                    bottomTransportBar
                }
            }
        }
        .focusable()
        .focused($keyboardFocused)
        .onAppear { keyboardFocused = true }
        .onKeyPress(phases: .down) { press in
            let chars = press.characters
            if chars == UIKeyCommand.inputLeftArrow {
                vm.controller.handleSwiftUIKey("leftArrow")
            } else if chars == UIKeyCommand.inputRightArrow {
                vm.controller.handleSwiftUIKey("rightArrow")
            } else if chars == UIKeyCommand.inputEscape {
                vm.controller.handleSwiftUIKey("escape")
            } else {
                vm.controller.handleSwiftUIKey(String(chars))
            }
            if !vm.controller.isAssigning {
                vm.syncMappingsFromController()
            }
            return .handled
        }
        .fileImporter(
            isPresented: $vm.showImporter,
            allowedContentTypes: vm.importTypes,
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                vm.importInstrumental(url: url)
            }
        }
        .sheet(isPresented: $vm.showSettings) {
            SettingsView(vm: vm)
        }
        .sheet(isPresented: $vm.showExport) {
            ExportView(vm: vm)
        }
        .sheet(isPresented: $vm.showSetupSheet) {
            ProjectSetupView(vm: vm)
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var statusBar: some View {
        VStack(spacing: 6) {
            if vm.recording.phase != .idle || vm.project.tracks.contains(where: \.inputMonitorEnabled) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(AppTheme.surfaceElevated)
                        Capsule()
                            .fill(vm.recording.phase == .loopRecording ? AppTheme.record : AppTheme.accent)
                            .frame(width: max(3, geo.size.width * CGFloat(min(1, max(0, vm.audio.inputLevel)))))
                    }
                }
                .frame(height: 6)
            }
            HStack {
                Text(vm.recording.statusMessage.isEmpty ? "Ready" : vm.recording.statusMessage)
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                Spacer()
                if let name = vm.project.selectedTrack?.name {
                    Text(name)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AppTheme.accent)
                }
                if vm.recording.phase == .loopRecording {
                    Text("Take \(vm.recording.currentTakeNumber)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.accent)
                }
                let region = vm.project.currentRegion
                Text("Bars \(region.startBar)–\(region.endBar - 1)")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(AppTheme.surface)
    }

    private var bottomTransportBar: some View {
        HStack(spacing: 12) {
            Button {
                vm.handleControllerAction(.keepTake)
            } label: {
                Text("Keep Take")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(AppTheme.accent)
                    .foregroundStyle(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)

            Button {
                vm.handleControllerAction(.keepTakeAndNext)
            } label: {
                Text("Keep + Next")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(AppTheme.surfaceElevated)
                    .foregroundStyle(AppTheme.textPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(AppTheme.surface)
    }
}
