import SwiftUI
import Photos

struct SwipeItem: Hashable {
    let id: String
    let reason: String?
}

/// One photo at a time: swipe left (or press D / ←) to mark for deletion,
/// right (or K / →) to keep. ⌘Z undoes.
struct SwipeReviewView: View {
    let title: String
    let items: [SwipeItem]

    @Environment(AppModel.self) private var model
    /// The photos being reviewed, fixed when the review opens. The category lists keep
    /// rebuilding while the review is open (marking, keeping, a scan finishing), and following
    /// them would shift `index` onto a different photo mid-review. New finds go at the end.
    @State private var queue: [SwipeItem]
    @State private var index = 0
    @State private var history: [(index: Int, decision: Decision)] = []
    @State private var drag: CGSize = .zero
    @State private var isAnimating = false
    @State private var markedCount = 0

    enum Decision { case keep, delete }

    private let swipeDistance: CGFloat = 120

    init(title: String, items: [SwipeItem]) {
        self.title = title
        self.items = items
        _queue = State(initialValue: items)
    }

    private var current: SwipeItem? { index < queue.count ? queue[index] : nil }
    /// The top card and the one under it, bottom first.
    private var visibleCards: [SwipeItem] {
        Array(queue[min(index, queue.count)..<min(index + 2, queue.count)].reversed())
    }

    var body: some View {
        VStack(spacing: 16) {
            if current != nil {
                VStack(spacing: 4) {
                    ProgressView(value: Double(index), total: Double(max(queue.count, 1)))
                    Text("\(index + 1) of \(queue.count)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            ZStack {
                if current == nil {
                    finishedView
                }
                // Keyed by photo, so the card underneath becomes the top card as the same view,
                // with its image already loaded, instead of a fresh view loading from scratch.
                ForEach(visibleCards, id: \.id) { item in
                    if let asset = model.asset(item.id) {
                        cardView(item, asset: asset, isTop: item.id == current?.id)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if current != nil { controls }
        }
        .padding()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { TrayButton() }
        }
        .onChange(of: items) { _, latest in
            let known = Set(queue.map(\.id))
            queue.append(contentsOf: latest.filter { !known.contains($0.id) })
        }
        .onDisappear {
            Task { await model.refreshResults() }
        }
    }

    @ViewBuilder
    private func cardView(_ item: SwipeItem, asset: PHAsset, isTop: Bool) -> some View {
        card(AssetImage(asset: asset, side: 1200, contentMode: .fit), reason: item.reason)
            .overlay(alignment: .top) { if isTop { stamp } }
            .scaleEffect(isTop ? 1 : 0.94)
            .opacity(isTop ? 1 : 0.4)
            .offset(x: isTop ? drag.width : 0, y: isTop ? drag.height * 0.2 : 0)
            .rotationEffect(.degrees(isTop ? Double(drag.width / 25) : 0))
            .gesture(dragGesture)
            .allowsHitTesting(isTop)
            .zIndex(isTop ? 1 : 0)
            // A decided card is already off screen when it leaves; an undone one flies back in
            // from where it left. Neither needs a fade.
            .transition(.identity)
            .accessibilityElement()
            .accessibilityLabel(item.reason ?? "Photo")
            .accessibilityHidden(!isTop)
            .accessibilityActions {
                Button("Delete") { decide(.delete) }
                Button("Keep") { decide(.keep) }
            }
    }

    private func card(_ image: AssetImage, reason: String?) -> some View {
        image
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(alignment: .bottomLeading) {
                if let reason {
                    Text(reason)
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding()
                }
            }
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
    }

    private var stamp: some View {
        let progress = min(1, abs(drag.width) / swipeDistance)
        let deleting = drag.width < 0
        return Text(deleting ? "DELETE" : "KEEP")
            .font(.title.bold())
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .foregroundStyle(deleting ? Color.red : Color.green)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(deleting ? Color.red : Color.green, lineWidth: 3))
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .rotationEffect(.degrees(deleting ? 12 : -12))
            .padding(.top, 32)
            .opacity(drag == .zero ? 0 : progress)
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard !isAnimating else { return }
                drag = value.translation
            }
            .onEnded { value in
                if value.translation.width < -swipeDistance {
                    decide(.delete)
                } else if value.translation.width > swipeDistance {
                    decide(.keep)
                } else {
                    withAnimation(.spring) { drag = .zero }
                }
            }
    }

    private var controls: some View {
        HStack(spacing: 20) {
            Button(role: .destructive) { decide(.delete) } label: {
                Label("Delete", systemImage: "trash").frame(minWidth: 90)
            }
            .tint(.red)
            .keyboardShortcut(.leftArrow, modifiers: [])

            Button { undo() } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .disabled(history.isEmpty)
            .keyboardShortcut("z", modifiers: .command)

            Button { decide(.keep) } label: {
                Label("Keep", systemImage: "checkmark").frame(minWidth: 90)
            }
            .tint(.green)
            .keyboardShortcut(.rightArrow, modifiers: [])
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .background {
            // Extra hardware keyboard shortcuts: D or Delete to discard, K to keep.
            Group {
                Button("") { decide(.delete) }.keyboardShortcut("d", modifiers: [])
                Button("") { decide(.delete) }.keyboardShortcut(.delete, modifiers: [])
                Button("") { decide(.keep) }.keyboardShortcut("k", modifiers: [])
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    private var finishedView: some View {
        ContentUnavailableView {
            Label("All done", systemImage: "checkmark.circle")
        } description: {
            Text(markedCount == 0
                 ? "You kept everything."
                 : "You marked \(markedCount) photos. Review them in the Marked tray when you’re ready.")
        } actions: {
            if markedCount > 0 {
                Button("Open Marked tray") { model.showTray = true }
                    .buttonStyle(.borderedProminent)
            }
            if !history.isEmpty {
                Button("Undo last") { undo() }
            }
        }
    }

    private func decide(_ decision: Decision) {
        guard let current, !isAnimating else { return }
        switch decision {
        case .delete:
            model.tray.add([current.id])
            markedCount += 1
        case .keep:
            model.keep(current.id)
        }
        history.append((index, decision))
        isAnimating = true
        withAnimation(.easeIn(duration: 0.18)) {
            drag = CGSize(width: decision == .delete ? -900 : 900, height: drag.height)
        } completion: {
            // The card underneath grows into place; the decided card is already off screen.
            withAnimation(.easeOut(duration: 0.2)) {
                drag = .zero
                index += 1
            }
            isAnimating = false
        }
    }

    private func undo() {
        guard !isAnimating, let last = history.popLast() else { return }
        let id = queue[last.index].id
        switch last.decision {
        case .delete:
            model.tray.remove([id])
            markedCount -= 1
        case .keep:
            model.unkeep(id)
        }
        // Bring the card back from the side it left on: insert it off screen, then let it spring in.
        withAnimation(.spring) {
            drag = CGSize(width: last.decision == .delete ? -900 : 900, height: 0)
            index = last.index
        }
        DispatchQueue.main.async {
            withAnimation(.spring) { drag = .zero }
        }
    }
}
