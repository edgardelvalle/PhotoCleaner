import SwiftUI
import UIKit

struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 64))
                    .foregroundStyle(.tint)
                    .padding(.top, 48)

                VStack(spacing: 8) {
                    Text("Tidy up your photos")
                        .font(.largeTitle.bold())
                    Text("Find duplicates, old screenshots and throwaway shots, then clear them out in a few taps.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)

                VStack(alignment: .leading, spacing: 20) {
                    FeatureRow(
                        systemImage: "lock.shield",
                        title: "Stays on your device",
                        text: "Photos are looked at on this device only. Nothing is uploaded, and there’s no account."
                    )
                    FeatureRow(
                        systemImage: "hand.raised",
                        title: "You decide",
                        text: "Photo Cleaner only suggests. Nothing is deleted until you say so."
                    )
                    FeatureRow(
                        systemImage: "arrow.uturn.backward.circle",
                        title: "Two safety nets",
                        text: "Photos first wait in a “\(CleanupAlbum.title)” album, then in Recently Deleted for 30 days."
                    )
                }

                Button {
                    Task { await model.requestAccess() }
                } label: {
                    Text("Continue").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Text("iOS will ask for access to your photos. Full access works best; with limited access, Photo Cleaner only sees the photos you pick.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(32)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
    }
}

struct FeatureRow: View {
    let systemImage: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary)
            }
        }
    }
}

struct PermissionDeniedView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        ContentUnavailableView {
            Label("Photo access is off", systemImage: "photo.badge.exclamationmark")
        } description: {
            Text("Photo Cleaner needs access to your photos to find things to clean up. Everything stays on this device.")
        } actions: {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
