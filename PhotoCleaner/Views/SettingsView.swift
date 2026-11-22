import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmReset = false

    var body: some View {
        @Bindable var preferences = model.preferences
        NavigationStack {
            Form {
                Section {
                    Toggle("Hide photos I move to “\(CleanupAlbum.title)”", isOn: $preferences.hideSoftDeleted)
                } footer: {
                    Text("Hidden photos leave your main library and go to the Hidden album in Photos, which is locked with Face ID or Touch ID. Restoring a photo un-hides it.")
                }

                Section {
                    Slider(value: $preferences.similarityThreshold, in: 0.2...0.5, step: 0.05) {
                        Text("Similar photo strictness")
                    } minimumValueLabel: {
                        Text("Strict")
                    } maximumValueLabel: {
                        Text("Loose")
                    } onEditingChanged: { editing in
                        if !editing { Task { await model.refreshResults() } }
                    }
                } header: {
                    Text("Similar shots")
                } footer: {
                    Text("Looser finds more similar shots but may group photos that are only alike.")
                }

                Section("Review") {
                    Button("Show photos I chose to keep again (\(model.preferences.keptIDs.count))") {
                        Task { await model.forgetKeptPhotos() }
                    }
                    .disabled(model.preferences.keptIDs.isEmpty)
                }

                Section {
                    Button("Scan everything again", role: .destructive) { confirmReset = true }
                } footer: {
                    Text("Clears what Photo Cleaner learned about your photos and starts over. Use this if results look wrong.")
                }

                Section("Privacy") {
                    Text("Everything happens on this device. Photo Cleaner has no account, no analytics, no ads and no network code.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Scan everything again?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Scan again", role: .destructive) {
                    Task { await model.resetAndRescan() }
                }
            } message: {
                Text("This can take a while on a large library.")
            }
        }
    }
}
