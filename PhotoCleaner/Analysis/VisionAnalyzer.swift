import Foundation
import Vision
import CoreML

struct VisionSignals: Sendable {
    var featurePrint: Data?
    var aestheticsScore: Double?
    var isUtility = false
    var hasDocument = false
    var textCharacterCount = 0
    var hasReceiptWords = false
}

/// Runs Apple's on-device Vision requests on a small thumbnail.
/// Each request runs on its own so one failure doesn't lose the others.
enum VisionAnalyzer {
    static let documentConfidence: Float = 0.8
    /// Changing this invalidates every cached feature print: bump `AssetAnalyzer.version` too.
    static let featurePrintRevision = VNGenerateImageFeaturePrintRequestRevision2

    static func analyze(_ image: CGImage, orientation: CGImagePropertyOrientation) -> VisionSignals {
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
        var signals = VisionSignals()

        let featurePrint = VNGenerateImageFeaturePrintRequest()
        // Pinned so prints made after an SDK update can still be compared with cached ones.
        featurePrint.revision = featurePrintRevision
        prepare(featurePrint)
        if (try? handler.perform([featurePrint])) != nil, let observation = featurePrint.results?.first {
            signals.featurePrint = try? NSKeyedArchiver.archivedData(withRootObject: observation, requiringSecureCoding: true)
        }

        let aesthetics = VNCalculateImageAestheticsScoresRequest()
        prepare(aesthetics)
        if (try? handler.perform([aesthetics])) != nil, let observation = aesthetics.results?.first {
            signals.aestheticsScore = Double(observation.overallScore)
            signals.isUtility = observation.isUtility
        }

        let document = VNDetectDocumentSegmentationRequest()
        prepare(document)
        if (try? handler.perform([document])) != nil, let observation = document.results?.first,
           observation.confidence >= documentConfidence {
            signals.hasDocument = true
        }

        // OCR is the slowest step, so only run it on likely throwaways.
        if signals.isUtility || signals.hasDocument {
            let text = VNRecognizeTextRequest()
            text.recognitionLevel = .fast
            text.usesLanguageCorrection = false
            prepare(text)
            if (try? handler.perform([text])) != nil, let observations = text.results {
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                signals.textCharacterCount = lines.reduce(0) { $0 + $1.count }
                signals.hasReceiptWords = ReceiptWords.matches(lines)
            }
        }
        return signals
    }

    static func decodeFeaturePrint(_ data: Data) -> VNFeaturePrintObservation? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data)
    }

    static func distance(_ a: VNFeaturePrintObservation, _ b: VNFeaturePrintObservation) -> Float? {
        var distance: Float = 0
        do {
            try a.computeDistance(&distance, to: b)
            return distance
        } catch {
            return nil
        }
    }

    /// Some Vision models fail on the Simulator's Neural Engine path; force the CPU there.
    private static func prepare(_ request: VNRequest) {
        #if targetEnvironment(simulator)
        let cpu = MLComputeDevice.allComputeDevices.first { device in
            if case .cpu = device { return true }
            return false
        }
        if let cpu {
            try? request.setComputeDevice(cpu, for: .main)
        }
        #endif
    }
}
