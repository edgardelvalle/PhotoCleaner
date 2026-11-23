import Foundation
import MetricKit

/// Receives Apple's MetricKit reports and keeps them on the device.
///
/// iOS collects these itself: daily metric reports (launch time, hang rate, CPU, memory,
/// disk writes, energy) and diagnostic reports (crashes, hangs, CPU and disk-write
/// exceptions, with call stacks). They are delivered at most once a day, or on the next
/// launch for diagnostics. Each one is saved as JSON in Application Support/Diagnostics so
/// it can be shared from the Diagnostics screen. Nothing is uploaded.
///
/// On a device run from Xcode, Debug > Simulate MetricKit Payloads delivers a sample report
/// right away. The Simulator never delivers any.
final class MetricsReporter: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = MetricsReporter()

    /// Older reports beyond this many are deleted.
    static let maxReports = 30

    let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Diagnostics", isDirectory: true)
    }()

    private var started = false

    func start() {
        guard !started else { return }
        started = true
        MXMetricManager.shared.add(self)
        Log.metrics.info("MetricKit subscriber registered")
        // Reports delivered while the app wasn't subscribed yet.
        let pastDiagnostics = MXMetricManager.shared.pastDiagnosticPayloads
        if !pastDiagnostics.isEmpty { didReceive(pastDiagnostics) }
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            let launches = payload.applicationLaunchMetrics?.histogrammedTimeToFirstDraw.totalBucketCount ?? 0
            let hangTime = payload.applicationResponsivenessMetrics.map { "\($0.histogrammedApplicationHangTime.totalBucketCount)" } ?? "–"
            let range = "\(payload.timeStampBegin.formatted()) to \(payload.timeStampEnd.formatted())"
            Log.metrics.notice("Metric report \(range, privacy: .public): \(launches) launches, \(hangTime, privacy: .public) hang samples")
            save(payload.jsonRepresentation(), kind: "metrics", date: payload.timeStampEnd)
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let crashes = payload.crashDiagnostics?.count ?? 0
            let hangs = payload.hangDiagnostics?.count ?? 0
            let cpu = payload.cpuExceptionDiagnostics?.count ?? 0
            let disk = payload.diskWriteExceptionDiagnostics?.count ?? 0
            Log.metrics.notice("Diagnostic report: \(crashes) crashes, \(hangs) hangs, \(cpu) CPU exceptions, \(disk) disk-write exceptions")
            for hang in payload.hangDiagnostics ?? [] {
                Log.metrics.notice("Hang of \(hang.hangDuration.description, privacy: .public)")
            }
            save(payload.jsonRepresentation(), kind: "diagnostics", date: payload.timeStampEnd)
        }
    }

    /// Saved reports, newest first.
    func savedReports() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        )) ?? []
        return urls.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func save(_ json: Data, kind: String, date: Date) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd'T'HHmmss"
            let name = "\(formatter.string(from: date))-\(kind)-\(UUID().uuidString.prefix(4)).json"
            try json.write(to: directory.appendingPathComponent(name), options: .atomic)
            for old in savedReports().dropFirst(Self.maxReports) {
                try? FileManager.default.removeItem(at: old)
            }
        } catch {
            Log.metrics.error("Couldn't save \(kind, privacy: .public) report: \(error.localizedDescription, privacy: .public)")
        }
    }
}
