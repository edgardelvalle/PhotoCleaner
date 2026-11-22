import SwiftUI

@main
struct PhotoCleanerApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch model.authorization {
            case .authorized, .limited:
                MainView()
            case .notDetermined:
                OnboardingView()
            default:
                PermissionDeniedView()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refreshAuthorization() }
        }
    }
}

struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.selectedSection) {
            Tab("Overview", systemImage: "sparkles", value: AppSection.overview) {
                NavigationStack { DashboardView() }
            }
            TabSection("Clean up") {
                Tab("Duplicates", systemImage: "square.on.square", value: AppSection.duplicates) {
                    NavigationStack { DuplicatesView() }
                }
                Tab("Screenshots", systemImage: "camera.viewfinder", value: AppSection.screenshots) {
                    NavigationStack { ScreenshotsView() }
                }
                Tab("One-offs", systemImage: "doc.text.viewfinder", value: AppSection.oneOffs) {
                    NavigationStack { OneOffsView() }
                }
            }
            Tab("To Delete", systemImage: "trash", value: AppSection.cleanup) {
                NavigationStack { CleanupAlbumView() }
            }
            .badge(model.cleanupAssets.count)
        }
        .tabViewStyle(.sidebarAdaptable)
        .sheet(isPresented: $model.showTray) {
            TrayView()
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
