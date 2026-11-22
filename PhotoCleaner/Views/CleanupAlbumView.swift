import SwiftUI
import Photos

/// The soft-delete album: restore photos, or empty it to delete them for real.
struct CleanupAlbumView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var selection: Set<String> = []
    @State private var confirmEmpty = false

    var body: some View {
        Group {
            if model.cleanupAssets.isEmpty {
                ContentUnavailableView(
                    "Nothing waiting",
                    systemImage: "trash.slash",
                    description: Text("Photos you move to “\(CleanupAlbum.title)” wait here until you empty the album. You can also see the album in the Photos app.")
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("\(model.cleanupAssets.count) photos, about \(model.cleanupBytes.bytesText)")
                            .font(.headline)
                        Text("Tap photos to select them for restoring. Emptying the album deletes everything in it; iOS asks you to confirm, and photos stay in Recently Deleted for 30 more days.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if model.staleCleanupCount > 0 {
                            Label("\(model.staleCleanupCount) photos have waited here for over 30 days.", systemImage: "clock")
                                .font(.callout)
                                .foregroundStyle(.orange)
                        }

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: sizeClass == .compact ? 100 : 160), spacing: 6)], spacing: 6) {
                            ForEach(model.cleanupAssets, id: \.localIdentifier) { asset in
                                let id = asset.localIdentifier
                                SelectableTile(asset: asset, isOn: selection.contains(id), style: .select) {
                                    if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
                                }
                            }
                        }
                    }
                    .padding()
                }
                .safeAreaInset(edge: .bottom) { actions }
            }
        }
        .navigationTitle("To Delete")
        .toolbar { ToolbarItem(placement: .primaryAction) { TrayButton() } }
        .confirmationDialog(
            "Delete \(model.cleanupAssets.count) photos?",
            isPresented: $confirmEmpty,
            titleVisibility: .visible
        ) {
            Button("Delete \(model.cleanupAssets.count) photos", role: .destructive) {
                Task { await model.emptyCleanupAlbum() }
            }
        } message: {
            Text("iOS will ask you to confirm. They stay in Recently Deleted for 30 days.")
        }
        .onChange(of: model.cleanupAssets.map(\.localIdentifier)) { _, ids in
            selection.formIntersection(ids)
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button {
                let assets = selection.isEmpty
                    ? model.cleanupAssets
                    : model.cleanupAssets.filter { selection.contains($0.localIdentifier) }
                Task {
                    await model.restore(assets)
                    selection = []
                }
            } label: {
                Label(selection.isEmpty ? "Restore all" : "Restore \(selection.count)", systemImage: "arrow.uturn.backward")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button(role: .destructive) {
                confirmEmpty = true
            } label: {
                Label("Empty album", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .controlSize(.large)
        .padding()
        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .disabled(model.isWorking)
    }
}
