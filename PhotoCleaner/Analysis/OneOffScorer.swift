import Foundation

/// Everything the one-off ("throwaway shot") rule looks at for a single photo.
struct OneOffSignals: Sendable {
    var isUtility = false
    var hasDocument = false
    var textCharacterCount = 0
    var hasReceiptWords = false
    var aestheticsScore: Double?
    var ageInDays = 0
    var isFavorite = false
    var isInUserAlbum = false
    var isInDuplicateGroup = false
    var isScreenshot = false
}

struct OneOffVerdict: Sendable, Equatable {
    let score: Int
    let reason: String
}

/// Scores how likely a photo is a throwaway shot (receipt, whiteboard, parking spot...).
/// Cheap built-in signals are added up; no model is trained.
enum OneOffScorer {
    static let minimumScore = 2
    /// Very recent photos are skipped: that parking spot photo may still be needed.
    static let minimumAgeInDays = 3

    static func evaluate(_ s: OneOffSignals) -> OneOffVerdict? {
        if s.isFavorite || s.isInUserAlbum || s.isInDuplicateGroup || s.isScreenshot { return nil }
        if s.ageInDays < minimumAgeInDays { return nil }

        var score = 0
        if s.isUtility { score += 2 }
        if s.hasDocument { score += 2 }
        if s.hasReceiptWords { score += 2 }
        if s.textCharacterCount >= 40 { score += 1 }
        if let aesthetics = s.aestheticsScore, aesthetics < -0.2 { score += 1 }
        guard score >= minimumScore else { return nil }
        return OneOffVerdict(score: score, reason: reason(for: s))
    }

    static func reason(for s: OneOffSignals) -> String {
        if s.hasReceiptWords { return "Looks like a receipt" }
        if s.hasDocument && s.textCharacterCount >= 40 { return "Looks like a document or whiteboard" }
        if s.hasDocument { return "Looks like a photo of a page" }
        if s.textCharacterCount >= 40 { return "Mostly text, like a sign or a note" }
        return "Looks like a quick reference photo"
    }
}

/// Detects receipt vocabulary in recognised text.
enum ReceiptWords {
    static let strongWords = ["subtotal", "receipt", "recibo", "ticket"]
    static let words = ["total", "tax", "change", "cash", "visa", "mastercard", "amount", "balance", "iva", "propina"]

    static func matches(_ lines: [String]) -> Bool {
        let text = lines.joined(separator: " ").lowercased()
        if strongWords.contains(where: { text.contains($0) }) { return true }
        return words.filter { text.contains($0) }.count >= 2
    }
}
