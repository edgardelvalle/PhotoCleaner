import SwiftUI

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
    @State private var index = 0
    @State private var history: [(index: Int, decision: Decision)] = []
    @State private var drag: CGSize = .zero
    @State private var isAnimating = false
    @State private var markedCount = 0

    enum Decision { case keep, delete }

    private let swipeDistance: CGFloat = 120
    private var current: SwipeItem? { index < items.count ? items[index] : nil }
    private var next: SwipeItem? { index + 1 < items.count ? items[index + 1] : nil }

    var body: some View {
        VStack(spacing: 16) {
            if current != nil {
                VStack(spacing: 4) {
                    ProgressView(value: Double(index), total: Double(max(items.count, 1)))
                    Text("\(index + 1) of \(items.count)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            ZStack {
                if let next, let asset = model.asset(next.id) {
                    card(AssetImage(asset: asset, side: 1200, contentMode: .fit), reason: nil)
                        .scaleEffect(0.94)
                        .opacity(0.4)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                if let current, let asset = model.asset(current.id) {
                    card(AssetImage(asset: asset, side: 1200, contentMode: .fit), reason: current.reason)
                        .overlay(alignment: .top) { stamp }
                        .offset(x: drag.width, y: drag.height * 0.2)
                        .rotationEffect(.degrees(Double(drag.width / 25)))
                        .gesture(dragGesture)
                        .id(current.id)
                        .accessibilityElement()
                        .accessibilityLabel(current.reason ?? "Photo")
                        .accessibilityActions {
                            Button("Delete") { decide(.delete) }
                            Button("Keep") { decide(.keep) }
                        }
                } else if current == nil {
                    finishedView
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
        .onDisappear {
            Task { await model.refreshResults() }
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
        HStack(spacing: 12) {
            Button(role: .destructive) { decide(.delete) } label: {
                Label("Delete", systemImage: "trash")
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity)
            }
            .tint(.red)
            .keyboardShortcut(.leftArrow, modifiers: [])

            Button { undo() } label: {
                // Icon-only so it never wraps; the Label still gives VoiceOver "Undo".
                Label("Undo", systemImage: "arrow.uturn.backward")
                    .labelStyle(.iconOnly)
            }
            .fixedSize()
            .help("Undo")
            .disabled(history.isEmpty)
            .keyboardShortcut("z", modifiers: .command)

            Button { decide(.keep) } label: {
                Label("Keep", systemImage: "checkmark")
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity)
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
            drag = .zero
            index += 1
            isAnimating = false
        }
    }

    private func undo() {
        guard !isAnimating, let last = history.popLast() else { return }
        let id = items[last.index].id
        switch last.decision {
        case .delete:
            model.tray.remove([id])
            markedCount -= 1
        case .keep:
            model.unkeep(id)
        }
        withAnimation(.spring) { index = last.index }
    }
}
