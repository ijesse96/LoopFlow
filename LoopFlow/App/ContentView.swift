import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var vm = ProjectViewModel()
    @FocusState private var keyboardFocused: Bool

    var body: some View {
        Group {
            if vm.isInStudio {
                studioContent
            } else {
                SessionLibraryView(vm: vm)
            }
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
    }

    private var studioContent: some View {
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
        let scrubDisabled = vm.recording.phase != .idle
        return VStack(spacing: 10) {
            HStack(spacing: 12) {
                bottomBarButton(
                    title: vm.recording.phase == .idle ? "Record" : "Stop",
                    fill: vm.recording.phase == .idle ? AppTheme.record : AppTheme.surfaceElevated,
                    foreground: vm.recording.phase == .idle ? .white : AppTheme.textPrimary
                ) {
                    vm.toggleRecord()
                }
                bottomBarButton(title: "Keep + Next", fill: AppTheme.surfaceElevated, foreground: AppTheme.textPrimary) {
                    vm.handleControllerAction(.keepTakeAndNext)
                }
            }
            HStack(spacing: 12) {
                bottomBarButton(title: "Keep Take", fill: AppTheme.accent, foreground: .black) {
                    vm.handleControllerAction(.keepTake)
                }
                bottomBarButton(
                    title: "Lead In",
                    fill: AppTheme.surfaceElevated,
                    foreground: AppTheme.textPrimary,
                    disabled: scrubDisabled
                ) {
                    vm.handleControllerAction(.leadIn)
                }
            }
            HStack(spacing: 12) {
                HoldRepeatIconButton(
                    systemName: "chevron.backward",
                    fill: AppTheme.surfaceElevated,
                    foreground: AppTheme.textPrimary,
                    disabled: scrubDisabled
                ) {
                    vm.nudgePlayhead(byBars: -1)
                }
                bottomBarIconButton(
                    systemName: vm.audio.isPlaying && vm.recording.phase == .idle ? "pause.fill" : "play.fill",
                    fill: AppTheme.surfaceElevated,
                    foreground: AppTheme.transport
                ) {
                    vm.togglePlay()
                }
                HoldRepeatIconButton(
                    systemName: "chevron.forward",
                    fill: AppTheme.surfaceElevated,
                    foreground: AppTheme.textPrimary,
                    disabled: scrubDisabled
                ) {
                    vm.nudgePlayhead(byBars: 1)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(AppTheme.surface)
    }

    private func bottomBarButton(
        title: String,
        fill: Color,
        foreground: Color,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(fill)
                .foregroundStyle(foreground)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .opacity(disabled ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func bottomBarIconButton(
        systemName: String,
        fill: Color,
        foreground: Color,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(fill)
                .foregroundStyle(foreground)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .opacity(disabled ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

/// Icon button: one tap via Button; hold-repeat starts only after a short delay.
private struct HoldRepeatIconButton: View {
    let systemName: String
    let fill: Color
    let foreground: Color
    var disabled: Bool = false
    let action: () -> Void

    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(fill)
                .foregroundStyle(foreground)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .opacity(disabled ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !disabled else { return }
                    guard repeatTask == nil else { return }
                    // Delay before repeat so a normal tap is only the Button action.
                    repeatTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        while !Task.isCancelled {
                            action()
                            try? await Task.sleep(nanoseconds: 180_000_000)
                        }
                    }
                }
                .onEnded { _ in
                    repeatTask?.cancel()
                    repeatTask = nil
                }
        )
    }
}
