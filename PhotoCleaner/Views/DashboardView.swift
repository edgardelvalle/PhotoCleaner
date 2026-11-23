import SwiftUI
import UIKit

struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var showSettings = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                scanCard
                savingsHeader

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 16)], spacing: 16) {
                    CategoryCard(
                        title: "Duplicates",
                        systemImage: "square.on.square",
                        count: model.duplicateExtraCount,
                        detail: groupsText,
                        bytes: model.duplicateSavings
                    ) { model.selectedSection = .duplicates }

                    CategoryCard(
                        title: "Screenshots",
                        systemImage: "camera.viewfinder",
                        count: model.results.screenshotIDs.count,
                        detail: "Oldest first",
                        bytes: model.screenshotSavings
                    ) { model.selectedSection = .screenshots }

                    CategoryCard(
                        title: "One-offs",
                        systemImage: "doc.text.viewfinder",
                        count: model.results.oneOffs.count,
                        detail: "Receipts, notes, parking spots",
                        bytes: model.oneOffSavings
                    ) { model.selectedSection = .oneOffs }
                }

                if !model.cleanupAssets.isEmpty { cleanupCard }
                if model.authorization == .limited { limitedAccessCard }

                if model.preferences.lifetimeFreedBytes > 0 {
                    Text("You’ve freed about \(model.preferences.lifetimeFreedBytes.bytesText) so far.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Photo Cleaner")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
            }
            ToolbarItem(placement: .primaryAction) { TrayButton() }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    private var groupsText: String {
        let count = model.results.duplicateGroups.count
        return count == 1 ? "In 1 group" : "In \(count) groups"
    }

    private var savingsHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("You could free up")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("about \(model.totalSavings.bytesText)")
                .font(.system(.largeTitle, design: .rounded).bold())
                .contentTransition(.numericText())
            Text("Space is an estimate. Deleted photos stay in Recently Deleted for 30 days before the space comes back.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var scanCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch model.scanState {
            case .idle:
                Text("Not scanned yet").font(.headline)
                Button("Scan my library") { model.startScan() }
                    .buttonStyle(.borderedProminent)
            case .preparing, .scanning:
                HStack {
                    Text("Scanning").font(.headline)
                    Spacer()
                    Button("Stop") { model.cancelScan() }
                }
                ScanProgressView()
                Text("You can start cleaning while this runs. Keep the app open for the first scan; the screen stays on until it’s done.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .finished(let date):
                HStack {
                    Label("Up to date", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Scan again") { model.startScan() }
                }
                Text("Last scan \(date, style: .relative) ago")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if model.skippedForCellular > 0 {
                    Text("\(model.skippedForCellular) iCloud photos were skipped on cellular. They’ll be checked on Wi-Fi.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .card()
    }

    private var cleanupCard: some View {
        Button {
            model.selectedSection = .cleanup
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Label("Waiting in “\(CleanupAlbum.title)”", systemImage: "trash")
                    .font(.headline)
                Text("\(model.cleanupAssets.count) photos, about \(model.cleanupBytes.bytesText). Empty the album to free the space.")
                    .foregroundStyle(.secondary)
                if model.staleCleanupCount > 0 {
                    Text("\(model.staleCleanupCount) have been waiting for over 30 days.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
            .card()
        }
        .buttonStyle(.plain)
    }

    private var limitedAccessCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Limited access", systemImage: "photo.badge.exclamationmark")
                .font(.headline)
            Text("Photo Cleaner can only see the photos you picked, so it may miss duplicates and screenshots.")
                .foregroundStyle(.secondary)
            Button("Change in Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
        }
        .card()
    }
}

struct CategoryCard: View {
    let title: String
    let systemImage: String
    let count: Int
    let detail: String
    let bytes: Int64
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: systemImage)
                        .font(.title2)
                        .foregroundStyle(.tint)
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                Text(title).font(.headline)
                HStack(alignment: .firstTextBaseline) {
                    Text(count.formatted())
                        .font(.system(.title, design: .rounded).bold())
                        .contentTransition(.numericText())
                    Text("photos").foregroundStyle(.secondary)
                    Spacer()
                    Text(bytes.bytesText).foregroundStyle(.secondary)
                }
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            .card()
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}
