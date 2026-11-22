import SwiftUI
import UIKit
import Photos

/// Loads and shows a photo at about `side` points.
struct AssetImage: View {
    let asset: PHAsset
    var side: CGFloat = 200
    var contentMode: ContentMode = .fill

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if contentMode == .fill {
                Rectangle().fill(.quaternary)
            } else {
                ProgressView()
            }
        }
        .task(id: asset.localIdentifier) {
            image = await ImageLoader.image(for: asset, side: side * displayScale, manager: ImageLoader.thumbnails)
        }
        .accessibilityHidden(true)
    }
}

/// A square grid tile that toggles when tapped. Long-press shows a large preview.
struct SelectableTile: View {
    enum Style { case markForDeletion, select }

    let asset: PHAsset
    let isOn: Bool
    var style: Style = .markForDeletion
    var badge: String?
    var caption: String?
    var contentMode: ContentMode = .fill
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { AssetImage(asset: asset, side: 300, contentMode: contentMode) }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    if isOn {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(tint, lineWidth: 4)
                            .background(tint.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .overlay(alignment: .topLeading) {
                    if let badge {
                        Text(badge)
                            .font(.caption.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.green, in: Capsule())
                            .foregroundStyle(.white)
                            .padding(6)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if isOn {
                        Image(systemName: style == .markForDeletion ? "trash.circle.fill" : "checkmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, tint)
                            .padding(6)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if let caption {
                        Text(caption)
                            .font(.caption2)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(6)
                    }
                }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(action: action) {
                Label(isOn ? offLabel : onLabel, systemImage: isOn ? "arrow.uturn.backward" : "trash")
            }
        } preview: {
            AssetImage(asset: asset, side: 900, contentMode: .fit)
                .frame(minWidth: 300, minHeight: 300)
        }
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var tint: Color { style == .markForDeletion ? .red : .accentColor }
    private var onLabel: String { style == .markForDeletion ? "Mark for deletion" : "Select" }
    private var offLabel: String { style == .markForDeletion ? "Unmark" : "Deselect" }

    private var accessibilityText: String {
        var parts = ["Photo"]
        if let date = asset.creationDate { parts.append(date.formatted(date: .abbreviated, time: .shortened)) }
        if let badge { parts.append(badge) }
        if let caption { parts.append(caption) }
        return parts.joined(separator: ", ")
    }
}

/// An adaptive grid of photo ids that toggles each one in the Marked tray.
struct MarkableGrid: View {
    let ids: [String]
    var caption: ((String) -> String?)?

    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: sizeClass == .compact ? 100 : 160), spacing: 6)], spacing: 6) {
            ForEach(ids, id: \.self) { id in
                if let asset = model.asset(id) {
                    SelectableTile(asset: asset, isOn: model.tray.contains(id), caption: caption?(id)) {
                        model.tray.toggle(id)
                    }
                }
            }
        }
    }
}

/// Toolbar button that opens the Marked tray and shows how many photos are in it.
struct TrayButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.showTray = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: model.tray.isEmpty ? "tray" : "tray.full.fill")
                if !model.tray.isEmpty {
                    Text("\(model.tray.count)").monospacedDigit()
                }
            }
        }
        .accessibilityLabel("Marked photos, \(model.tray.count)")
        .keyboardShortcut("t", modifiers: .command)
    }
}

/// Shown when a category is empty, or still being scanned.
struct CategoryEmptyView: View {
    let title: String
    let systemImage: String
    let message: String

    @Environment(AppModel.self) private var model

    var body: some View {
        if model.isScanning {
            ContentUnavailableView {
                Label("Still looking", systemImage: "magnifyingglass")
            } description: {
                Text("Results appear here as the scan finds them.")
            } actions: {
                ScanProgressView()
            }
        } else {
            ContentUnavailableView(title, systemImage: systemImage, description: Text(message))
        }
    }
}

struct ScanProgressView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.scanState {
        case .scanning(let done, let total):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                Text("Looked at \(done.formatted()) of \(total.formatted()) photos")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .preparing:
            HStack {
                ProgressView()
                Text("Reading your library…").foregroundStyle(.secondary)
            }
        default:
            EmptyView()
        }
    }
}

struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}
