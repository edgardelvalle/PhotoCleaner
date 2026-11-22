import SwiftUI

struct ScreenshotsView: View {
    @Environment(AppModel.self) private var model
    @State private var olderThanMonth = false

    private var ids: [String] {
        guard olderThanMonth else { return model.results.screenshotIDs }
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        return model.results.screenshotIDs.filter { (model.creationDate($0) ?? .distantFuture) < cutoff }
    }

    var body: some View {
        Group {
            if model.results.screenshotIDs.isEmpty {
                CategoryEmptyView(title: "No screenshots", systemImage: "camera.viewfinder", message: "Your library has no screenshots to clean up.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Picker("Show", selection: $olderThanMonth) {
                            Text("All").tag(false)
                            Text("Older than 30 days").tag(true)
                        }
                        .pickerStyle(.segmented)

                        ReviewActions(
                            summary: "\(ids.count) screenshots, about \(model.bytes(ids).bytesText). Oldest first.",
                            reviewTitle: "Screenshots",
                            items: ids.map { SwipeItem(id: $0, reason: nil) }
                        )

                        MarkableGrid(ids: ids)
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("Screenshots")
        .toolbar { ToolbarItem(placement: .primaryAction) { TrayButton() } }
    }
}

struct OneOffsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let candidates = model.results.oneOffs
        let reasons = Dictionary(candidates.map { ($0.id, $0.reason) }, uniquingKeysWith: { first, _ in first })
        Group {
            if candidates.isEmpty {
                CategoryEmptyView(
                    title: "No one-offs found",
                    systemImage: "doc.text.viewfinder",
                    message: "Nothing looks like a receipt, note or quick reference shot."
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Photos that look like they were taken once for a quick reason, like receipts, whiteboards or where you parked. Favorites and photos in albums are never suggested.")
                            .foregroundStyle(.secondary)

                        ReviewActions(
                            summary: "\(candidates.count) photos, about \(model.oneOffSavings.bytesText). Oldest first.",
                            reviewTitle: "One-offs",
                            items: candidates.map { SwipeItem(id: $0.id, reason: $0.reason) }
                        )

                        MarkableGrid(ids: candidates.map(\.id)) { reasons[$0] }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("One-offs")
        .toolbar { ToolbarItem(placement: .primaryAction) { TrayButton() } }
    }
}

/// "Review one by one" and "Mark all" buttons above a category grid.
struct ReviewActions: View {
    let summary: String
    let reviewTitle: String
    let items: [SwipeItem]

    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(summary).font(.headline)
            HStack {
                NavigationLink {
                    SwipeReviewView(title: reviewTitle, items: items)
                } label: {
                    Label("Review one by one", systemImage: "rectangle.stack")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    model.tray.add(items.map(\.id))
                } label: {
                    Label("Mark all", systemImage: "checkmark.circle")
                }
                .buttonStyle(.bordered)
            }
            .disabled(items.isEmpty)
            Text("Or tap photos below to mark them.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
