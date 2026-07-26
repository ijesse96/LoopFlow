import SwiftUI

struct SessionLibraryView: View {
    @ObservedObject var vm: ProjectViewModel
    @State private var sessionPendingDelete: ProjectSummary?

    var body: some View {
        NavigationStack {
            Group {
                if vm.sessionSummaries.isEmpty {
                    emptyState
                } else {
                    sessionList
                }
            }
            .navigationTitle("Sessions")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        vm.startNewProject()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .foregroundStyle(AppTheme.accent)
                    .accessibilityLabel("New Session")
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppTheme.background.ignoresSafeArea())
            .onAppear { vm.refreshSessionSummaries() }
            .confirmationDialog(
                "Delete this session? Audio files will be removed from this device.",
                isPresented: Binding(
                    get: { sessionPendingDelete != nil },
                    set: { if !$0 { sessionPendingDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let session = sessionPendingDelete {
                        vm.deleteProject(id: session.id)
                    }
                    sessionPendingDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    sessionPendingDelete = nil
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "music.note.list")
                .font(.system(size: 44))
                .foregroundStyle(AppTheme.textSecondary)
            Text("No sessions yet")
                .font(.title3.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)
            Text("Create a session to start recording loops.")
                .font(.subheadline)
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                vm.startNewProject()
            } label: {
                Text("New Session")
                    .font(.headline)
                    .frame(maxWidth: 220)
                    .padding(.vertical, 12)
                    .background(AppTheme.accent)
                    .foregroundStyle(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sessionList: some View {
        List {
            ForEach(vm.sessionSummaries) { session in
                Button {
                    vm.openProject(id: session.id)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.name.isEmpty ? "Untitled Session" : session.name)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(AppTheme.textPrimary)
                            Text("\(Int(session.bpm)) bpm · \(session.updatedAt.formatted(.relative(presentation: .named)))")
                                .font(.caption)
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(AppTheme.surface)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        sessionPendingDelete = session
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
    }
}
