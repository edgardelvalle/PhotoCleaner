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

/// Reviews duplicate groups one after another. The decision buttons sit at the bottom, and
/// choosing one moves straight on to the next group that has nothing marked yet, so the whole
/// list can be cleared without going back to it.
struct GroupDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dismiss) private var dismiss

    @State private var currentID: String
    @State private var fallback: DuplicateGroup
    @State private var confirmMarkAll = false
    @State private var showInfo = false
    @State private var isAdvancing = false
    @State private var decisions = 0

    init(group: DuplicateGroup) {
        _currentID = State(initialValue: group.id)
        _fallback = State(initialValue: group)
    }

    /// The group on screen. Falls back to the last one shown if the list was rebuilt without it.
    private var group: DuplicateGroup {
        model.results.duplicateGroups.first { $0.id == currentID } ?? fallback
    }

    private var position: (index: Int, count: Int)? {
        let groups = model.results.duplicateGroups
        guard let index = groups.firstIndex(where: { $0.id == currentID }) else { return nil }
        return (index + 1, groups.count)
    }

    private var anyMarked: Bool { group.memberIDs.contains { model.tray.contains($0) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                hint(for: group)

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
        .id(group.id)
        .transition(.push(from: .trailing))
        .safeAreaInset(edge: .bottom) { actionBar(for: group) }
        .navigationTitle(position.map { "\($0.index) of \($0.count)" } ?? group.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { TrayButton() }
        }
        // Reviewing is a focused flow; hiding the tab bar keeps its buttons away from the decisions.
        .toolbar(.hidden, for: .tabBar)
        .sensoryFeedback(.success, trigger: decisions)
    }

    // MARK: Pieces

    private func hint(for group: DuplicateGroup) -> some View {
        HStack(spacing: 6) {
            Text("\(group.kind == .exactCopies ? "Copies" : "Similar shots") · Best: \(group.keeperReason.rawValue.lowercased())")
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            Button {
                showInfo = true
            } label: {
                Image(systemName: "info.circle")
            }
            .accessibilityLabel("How this works")
            .popover(isPresented: $showInfo) {
                Text(explanation(for: group))
                    .font(.callout)
                    .padding()
                    .frame(idealWidth: 320)
                    .fixedSize(horizontal: false, vertical: true)
                    .presentationCompactAdaptation(.popover)
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    private func actionBar(for group: DuplicateGroup) -> some View {
        VStack(spacing: 16) {
            Button {
                model.markExtras(of: group)
                advance(after: group)
            } label: {
                Label("Keep best", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .keyboardShortcut(.return, modifiers: .command)

            // Keep the destructive button well apart from the others to avoid mis-taps.
            HStack(spacing: 24) {
                Button(role: .destructive) {
                    confirmMarkAll = true
                } label: {
                    Label("Delete all", systemImage: "trash")
                        .frame(maxWidth: .infinity, minHeight: 28)
                }
                .tint(.red)
                // Attached here, not to the screen, so iOS anchors the bubble to this button.
                .confirmationDialog(
                    "Mark all \(group.memberIDs.count) photos for deletion?",
                    isPresented: $confirmMarkAll,
                    titleVisibility: .visible
                ) {
                    Button("Mark all \(group.memberIDs.count), including Best", role: .destructive) {
                        model.markAll(of: group)
                        advance(after: group)
                    }
                } message: {
                    Text(markAllMessage(for: group))
                }

                Button {
                    advance(after: group, decided: false)
                } label: {
                    // Moving on without marking keeps the whole group. After marking photos
                    // by hand, it moves on and keeps the rest.
                    Label(anyMarked ? "Next" : "Keep all", systemImage: anyMarked ? "arrow.right" : "square.on.square")
                        .frame(maxWidth: .infinity, minHeight: 28)
                }
                .keyboardShortcut(.rightArrow, modifiers: .command)
            }
            .buttonStyle(.bordered)
        }
        .disabled(isAdvancing)
        .padding(.horizontal)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .background(.bar)
    }

    // MARK: Flow

    /// Shows the next group with nothing marked yet, or goes back to the list when there are none.
    /// Waits a moment after a decision so the marks are visible before the screen changes.
    private func advance(after group: DuplicateGroup, decided: Bool = true) {
        if decided { decisions += 1 }
        isAdvancing = true
        Task {
            if decided { try? await Task.sleep(for: .milliseconds(350)) }
            defer { isAdvancing = false }
            guard let next = model.results.duplicateGroups.nextUndecided(after: group.id, isMarked: model.tray.contains) else {
                dismiss()
                return
            }
            withAnimation(.snappy) {
                fallback = next
                currentID = next.id
            }
        }
    }

    private func markAllMessage(for group: DuplicateGroup) -> String {
        let protected = model.favoriteOrKeptCount(in: group)
        let warning = switch protected {
        case 0: ""
        case 1: "This includes 1 favorite or kept photo. "
        default: "This includes \(protected) favorites or kept photos. "
        }
        return "None of these will be kept, including the one marked Best. \(warning)Nothing is deleted yet. You can unmark them in the tray, and photos moved to To Delete can be restored."
    }

    private func explanation(for group: DuplicateGroup) -> String {
        let kind = group.kind == .exactCopies
            ? "These look like copies of the same photo."
            : "These were taken moments apart and look alike."
        return "\(kind) The one marked Best is suggested to keep. Keep best marks the others, but never favorites or photos you kept. Delete all marks the whole group after asking, and Keep all moves on without marking any. Tap photos to mark or unmark them, then tap Next. Touch and hold to see one larger. Marked photos wait in the tray, so nothing is deleted yet."
    }
}
