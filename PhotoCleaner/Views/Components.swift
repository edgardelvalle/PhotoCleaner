import SwiftUI
import UIKit
import Photos

/// Loads and shows a photo sized to the space it gets on screen, at most `side` points.
/// A small cached version shows first and is replaced by a sharp one.
struct AssetImage: View {
    let asset: PHAsset
    var side: CGFloat = 200
    var contentMode: ContentMode = .fill

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var layoutSide: CGFloat = 0
    @State private var loadedID: String?

    var body: some View {
        ZStack {
            // Only draw an image loaded for this asset: when a view is reused for another photo,
            // the old image would otherwise show until the new request starts.
            if let image, loadedID == asset.localIdentifier {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if contentMode == .fill {
                Rectangle().fill(.quaternary)
            } else {
                // Fills the offered space while loading, so the first request has the right size.
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onGeometryChange(for: CGFloat.self) { max($0.size.width, $0.size.height) } action: { newSide in
            // Only grow: a fitted image can lay out smaller than its placeholder did.
            if newSide > layoutSide { layoutSide = newSide }
        }
        .task(id: RequestKey(id: asset.localIdentifier, pixels: pixelSide)) {
            if loadedID != asset.localIdentifier {
                image = nil
                loadedID = asset.localIdentifier
            }
            guard pixelSide > 0 else { return }
            let mode: PHImageContentMode = contentMode == .fill ? .aspectFill : .aspectFit
            for await next in ImageLoader.displayImages(for: asset, pixelSide: pixelSide, contentMode: mode) {
                // When re-requesting at a larger size, keep the current image over a blurry stand-in.
                if next.isDegraded && image != nil { continue }
                image = next.image
            }
        }
        .accessibilityHidden(true)
    }

    /// Pixels to request: the laid-out size (capped at `side`), rounded up to a cache bucket.
    private var pixelSide: CGFloat {
        guard layoutSide > 0 else { return 0 }
        return ImageLoader.bucketed(min(layoutSide, side) * displayScale)
    }

    private struct RequestKey: Equatable {
        let id: String
        let pixels: CGFloat
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
                .overlay { AssetImage(asset: asset, side: 300, contentMode: contentMode) } // MarkableGrid.tileCap
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
/// Thumbnails for the next rows are prepared ahead of scrolling.
struct MarkableGrid: View {
    let ids: [String]
    var caption: ((String) -> String?)?

    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.displayScale) private var displayScale
    @State private var width: CGFloat = 0
    @State private var prefetchedUpTo = 0

    private static let spacing: CGFloat = 6
    private static let prefetchAhead = 60
    private static let tileCap: CGFloat = 300

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimumTile), spacing: Self.spacing)], spacing: Self.spacing) {
            ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                if let asset = model.asset(id) {
                    SelectableTile(asset: asset, isOn: model.tray.contains(id), caption: caption?(id)) {
                        model.tray.toggle(id)
                    }
                    .onAppear { prefetch(after: index) }
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onChange(of: ids) { prefetchedUpTo = 0 }
        .onDisappear {
            ImageLoader.stopPrefetching()
            prefetchedUpTo = 0
        }
    }

    private var minimumTile: CGFloat { sizeClass == .compact ? 100 : 160 }

    /// The pixel size each tile requests, computed the way the adaptive grid lays out
    /// columns, so prefetched thumbnails match the tiles' own requests.
    private var tilePixels: CGFloat {
        guard width > 0 else { return 0 }
        let columns = max(1, floor((width + Self.spacing) / (minimumTile + Self.spacing)))
        let tile = (width - Self.spacing * (columns - 1)) / columns
        return ImageLoader.bucketed(min(tile, Self.tileCap) * displayScale)
    }

    private func prefetch(after index: Int) {
        let pixels = tilePixels
        guard pixels > 0 else { return }
        let start = max(index + 1, prefetchedUpTo)
        let end = min(ids.count, index + 1 + Self.prefetchAhead)
        guard start < end else { return }
        prefetchedUpTo = end
        ImageLoader.prefetch(ids[start..<end].compactMap { model.asset($0) }, pixelSide: pixels)
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
                Text("Looked at \(done.formatted()) of \(total.formatted()) photos\(remainingText)")
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

extension ScanProgressView {
    private var remainingText: String {
        guard let seconds = model.scanTimeRemaining, seconds >= 60 else { return "" }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .short
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        guard let text = formatter.string(from: seconds) else { return "" }
        return " · about \(text) left"
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
