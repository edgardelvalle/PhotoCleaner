import SwiftUI
import UIKit

/// Counts and timings from the current or last scan, plus saved MetricKit reports.
/// Everything shown here stays on the device unless you copy or share it.
struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model
    @State private var reports: [URL] = []
    @State private var copied = false

    var body: some View {
        let stats = model.scanStats
        let p = stats.photos
        List {
            Section("Scan") {
                row("Status", stats.outcome.rawValue)
                if let startedAt = stats.startedAt {
                    row("Started", startedAt.formatted(date: .omitted, time: .standard))
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    row("Duration", seconds(stats.elapsed(now: context.date)))
                }
                row("Speed", stats.photosPerSecond.map { String(format: "%.1f photos/s", $0) } ?? "–")
                if let remaining = model.scanTimeRemaining {
                    row("Time left", seconds(remaining))
                }
            }

            Section {
                row("Photos in library", stats.libraryCount)
                row("From cache", stats.cacheHits)
                row("To analyze", stats.toAnalyze)
                row("Analyzed on device", p.analyzedLocal)
                row("Downloaded from iCloud", p.analyzedDownloaded)
                row("Screenshots (metadata only)", p.metadataOnly)
                row("Needed iCloud", stats.neededICloud)
                row("Only a tiny preview on device", p.tinyPreviews)
                row("iCloud downloads failed", p.downloadFailed)
                row("Skipped on cellular", stats.skippedForCellular)
            } header: {
                Text("Photos")
            } footer: {
                Text("“Needed iCloud” photos are checked in a second pass after everything already on the phone. With Optimize iPhone Storage on, that pass is usually most of a first scan.")
            }

            Section {
                row("Read library", seconds(stats.readLibrary))
                row("Load cache", "\(seconds(stats.loadCache)) · \(stats.cacheRowsLoaded) rows")
                row("On-device pass", seconds(stats.localPass))
                row("iCloud pass", seconds(stats.iCloudPass))
                row("Prune cache", seconds(stats.prune))
                row("Image load, device", timing(p.localImageLoad))
                row("Image load, iCloud", timing(p.iCloudImageLoad))
                row("Vision", timing(p.vision))
                row("List rebuilds", timing(stats.rebuilds))
                row("Cache saves", timing(stats.cacheSaves))
            } header: {
                Text("Time")
            } footer: {
                Text("Per-photo times are averages, with the slowest in brackets. Several photos are processed at once, so they add up to more than the pass time.")
            }

            if !stats.errors.isEmpty {
                Section("Errors") {
                    ForEach(Array(stats.errors.enumerated()), id: \.offset) { _, message in
                        Text(message).font(.footnote)
                    }
                }
            }

            Section {
                Button(copied ? "Copied" : "Copy scan report") {
                    UIPasteboard.general.string = stats.report()
                    copied = true
                }
                ShareLink("Share scan report", item: stats.report())
            }

            Section {
                if reports.isEmpty {
                    Text("None yet. iOS delivers these at most once a day, and crash or hang reports on the next launch.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(reports, id: \.self) { url in
                        ShareLink(item: url) {
                            Label(url.deletingPathExtension().lastPathComponent, systemImage: "doc.text")
                                .font(.footnote)
                        }
                    }
                }
            } header: {
                Text("System reports (MetricKit)")
            } footer: {
                Text("Launch time, hangs, crashes, energy and memory reports that iOS collects for this app. They stay on this phone unless you share one.")
            }

            Section {
                Text("Detailed logs go to the system log under “\(Log.subsystem)”. Connect the phone to a Mac and open Console.app, or run from Xcode, to read them.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .monospacedDigit()
        .onAppear { reports = MetricsReporter.shared.savedReports() }
        .onChange(of: stats.outcome) { copied = false }
    }

    private func row(_ title: String, _ value: Int) -> some View {
        row(title, value.formatted())
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title, value: value)
    }

    private func seconds(_ value: TimeInterval?) -> String {
        guard let value else { return "–" }
        if value >= 120 { return Duration.seconds(value).formatted(.time(pattern: .hourMinuteSecond)) }
        return String(format: "%.1f s", value)
    }

    private func timing(_ timing: Timing) -> String {
        guard let mean = timing.mean else { return "–" }
        return String(format: "%.0f ms (%.0f) × %d", mean * 1000, timing.max * 1000, timing.count)
    }
}
