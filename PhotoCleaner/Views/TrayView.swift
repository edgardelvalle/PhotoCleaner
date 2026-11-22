import SwiftUI

/// Everything marked for deletion, with the two ways to act on it.
struct TrayView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if model.tray.isEmpty {
                    ContentUnavailableView(
                        "Nothing marked",
                        systemImage: "tray",
                        description: Text("Photos you mark for deletion collect here.")
                    )
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Tap a photo to unmark it.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            MarkableGrid(ids: model.tray.orderedIDs)
                        }
                        .padding()
                    }
                    .safeAreaInset(edge: .bottom) { actions }
                }
            }
            .navigationTitle("Marked (\(model.tray.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if !model.tray.isEmpty {
                    ToolbarItem(placement: .secondaryAction) {
                        Button("Unmark all", role: .destructive) { model.tray.clear() }
                    }
                }
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Text("About \(model.bytes(model.tray.orderedIDs).bytesText)")
                .font(.headline)

            Button {
                Task {
                    if await model.moveTrayToCleanupAlbum() { dismiss() }
                }
            } label: {
                Label("Move to “\(CleanupAlbum.title)”", systemImage: "folder.badge.minus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button(role: .destructive) {
                Task {
                    if await model.deleteTrayNow() { dismiss() }
                }
            } label: {
                Label("Delete now", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Text(model.preferences.hideSoftDeleted
                 ? "Moving keeps photos safe (and hidden) until you empty the album. Deleted photos stay in Recently Deleted for 30 days."
                 : "Moving keeps photos safe until you empty the album. Deleted photos stay in Recently Deleted for 30 days.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .disabled(model.isWorking)
        .overlay { if model.isWorking { ProgressView() } }
    }
}
