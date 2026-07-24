import SwiftUI

struct ExportView: View {
    @ObservedObject var vm: ProjectViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Export") {
                    ForEach(ExportKind.allCases) { kind in
                        Button {
                            Task { await vm.export(kind) }
                        } label: {
                            HStack {
                                Text(kind.displayName)
                                    .foregroundStyle(AppTheme.textPrimary)
                                Spacer()
                                Image(systemName: "square.and.arrow.up")
                                    .foregroundStyle(AppTheme.accent)
                            }
                        }
                    }
                }

                if let message = vm.exportMessage {
                    Section {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }
            }
            .navigationTitle("Export")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppTheme.background)
            .overlay {
                if vm.isBusy {
                    ProgressView("Exporting…")
                        .padding()
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
