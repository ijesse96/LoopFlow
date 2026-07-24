import SwiftUI

struct ControllerMappingView: View {
    @ObservedObject var vm: ProjectViewModel

    var body: some View {
        List {
            if vm.controller.isAssigning, let action = vm.controller.assigningAction {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Press any key…")
                            .font(.headline)
                        Text("Assigning: \(action.displayName)")
                            .foregroundStyle(AppTheme.textSecondary)
                        Button("Cancel") {
                            vm.controller.cancelAssign()
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("Actions") {
                ForEach(vm.controller.mappings) { mapping in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mapping.action.displayName)
                            Text(mapping.keyLabel ?? "Unassigned")
                                .font(.caption)
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                        Spacer()
                        Button("Assign") {
                            vm.controller.beginAssign(action: mapping.action)
                        }
                        .buttonStyle(.bordered)
                        .tint(AppTheme.accent)

                        if mapping.isAssigned {
                            Button("Clear") {
                                vm.controller.clearMapping(action: mapping.action)
                                vm.syncMappingsFromController()
                            }
                            .font(.caption)
                            .foregroundStyle(AppTheme.textSecondary)
                        }
                    }
                }
            }

            Section {
                Button("Reset to Defaults") {
                    vm.controller.resetDefaults()
                    vm.syncMappingsFromController()
                }
            }
        }
        .navigationTitle("Controller Mapping")
        .onChange(of: vm.controller.isAssigning) { _, assigning in
            if !assigning {
                vm.syncMappingsFromController()
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppTheme.background)
    }
}
