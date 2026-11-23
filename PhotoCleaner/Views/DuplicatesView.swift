import SwiftUI

struct DuplicatesView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmDeleteAll = false

    var body: some View {
        Group {
            if model.results.duplicateGroups.isEmpty {
                CategoryEmptyView(
                    title: "No duplicates",
                    systemImage: "square.on.square",
                    message: "No copies or near-identical shots were found."
                )
            } else {
                List {
                    let copyIDs = model.oneTapCopyIDs
                    if !copyIDs.isEmpty {
                        Section {
                            Button {
                                model.markAllExactCopies()
                            } label: {
                                Label(
                                    "Mark \(copyIDs.count) extra copies (\(model.bytes(copyIDs).bytesText))",
                                    systemImage: "wand.and.stars"
                                )
                            }
                        } footer: {
                            Text("Only exact copies, keeping one of each. Favorites are never marked. Similar shots need a look, so open each group below. Nothing is deleted yet.")
                        }
                    }

                    let deletableIDs = model.deletableDuplicateIDs
                    if !deletableIDs.isEmpty {
                        Section {
                            Button(role: .destructive) {
                                confirmDeleteAll = true
                            } label: {
                                Label(
                                    "Delete all \(deletableIDs.count) extras (\(model.bytes(deletableIDs).bytesText))",
                                    systemImage: "trash"
                                )
                            }
                            .disabled(model.isWorking)
                        } footer: {
                            Text("Deletes every photo in every group except the one marked Best, including similar shots you haven't reviewed. Favorites and photos you kept are skipped. Photos stay in Recently Deleted for 30 days.")
                        }
                    }

                    Section {
                        ForEach(model.results.duplicateGroups) { group in
                            NavigationLink(value: group) {
                                DuplicateGroupRow(group: group)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Duplicates")
        .confirmationDialog(
            "Delete all duplicate extras?",
            isPresented: $confirmDeleteAll,
            titleVisibility: .visible
        ) {
            let ids = model.deletableDuplicateIDs
            Button("Delete \(ids.count) photos", role: .destructive) {
                Task { await model.deleteAllDuplicateExtras() }
            }
        } message: {
            Text("The best photo in each group is kept. Similar shots are included, so open a group first if you want to choose yourself. Deleted photos stay in Recently Deleted for 30 days.")
        }
        .navigationDestination(for: DuplicateGroup.self) { group in
            GroupDetailView(group: group)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { TrayButton() }
        }
    }
}

struct DuplicateGroupRow: View {
    let group: DuplicateGroup
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: -16) {
                ForEach(group.memberIDs.prefix(4), id: \.self) { id in
                    if let asset = model.asset(id) {
                        AssetImage(asset: asset, side: 64)
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.background, lineWidth: 2))
                    }
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(group.title).font(.headline)
                Text("\(group.date.formatted(date: .abbreviated, time: .omitted)) · about \(group.estimatedSavings.bytesText)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            let marked = group.memberIDs.filter { model.tray.contains($0) }.count
            if marked > 0 {
                Label("\(marked)", systemImage: "trash")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }
}

struct GroupDetailView: View {
    let group: DuplicateGroup

    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(explanation)
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: sizeClass == .compact ? 150 : 280), spacing: 12)], spacing: 12) {
                    ForEach(group.memberIDs, id: \.self) { id in
                        if let asset = model.asset(id) {
                            SelectableTile(
                                asset: asset,
                                isOn: model.tray.contains(id),
                                badge: id == group.keeperID ? "Best" : nil,
                                caption: asset.creationDate?.formatted(date: .omitted, time: .standard),
                                contentMode: .fit
                            ) {
                                model.tray.toggle(id)
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle(group.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Keep best") { model.markExtras(of: group) }
                    .keyboardShortcut(.return, modifiers: .command)
            }
            ToolbarItem(placement: .primaryAction) { TrayButton() }
        }
    }

    private var explanation: String {
        let kind = group.kind == .exactCopies
            ? "These look like copies of the same photo."
            : "These were taken moments apart and look alike."
        return "\(kind) The one marked Best is suggested to keep (\(group.keeperReason.rawValue.lowercased())). Keep best never marks favorites. Tap photos to mark or unmark them. Touch and hold to see one larger."
    }
}
