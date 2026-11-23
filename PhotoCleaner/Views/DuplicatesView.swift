import SwiftUI

struct DuplicatesView: View {
    @Environment(AppModel.self) private var model

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
    @State private var confirmMarkAll = false

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
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Mark all \(group.memberIDs.count) for deletion", systemImage: "trash", role: .destructive) {
                        confirmMarkAll = true
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
            ToolbarItem(placement: .primaryAction) { TrayButton() }
        }
        .confirmationDialog(
            "Mark all \(group.memberIDs.count) photos for deletion?",
            isPresented: $confirmMarkAll,
            titleVisibility: .visible
        ) {
            Button("Mark all \(group.memberIDs.count), including Best", role: .destructive) {
                model.markAll(of: group)
            }
        } message: {
            Text(markAllMessage)
        }
    }

    private var markAllMessage: String {
        let protected = model.favoriteOrKeptCount(in: group)
        let warning = switch protected {
        case 0: ""
        case 1: "This includes 1 favorite or kept photo. "
        default: "This includes \(protected) favorites or kept photos. "
        }
        return "None of these will be kept, including the one marked Best. \(warning)Nothing is deleted yet. You can unmark them in the tray, and photos moved to To Delete can be restored."
    }

    private var explanation: String {
        let kind = group.kind == .exactCopies
            ? "These look like copies of the same photo."
            : "These were taken moments apart and look alike."
        return "\(kind) The one marked Best is suggested to keep (\(group.keeperReason.rawValue.lowercased())). Keep best never marks favorites. To remove the whole group, choose Mark all from the menu. Tap photos to mark or unmark them. Touch and hold to see one larger."
    }
}
