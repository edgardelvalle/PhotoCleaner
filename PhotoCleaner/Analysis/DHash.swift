import Foundation

/// A 64-bit difference hash ("dHash").
///
/// The image is shrunk to a 9x8 grayscale grid and each bit records whether a pixel is
/// brighter than its right-hand neighbour. Exact copies, re-saved and resized versions of
/// the same picture end up with the same (or nearly the same) hash.
enum DHash {
    static let gridWidth = 9
    static let gridHeight = 8

    /// Builds the hash from a 9x8 grayscale grid, row by row (72 values).
    static func hash(grayscale pixels: [UInt8]) -> UInt64? {
        guard pixels.count == gridWidth * gridHeight else { return nil }
        var hash: UInt64 = 0
        for row in 0..<gridHeight {
            for column in 0..<(gridWidth - 1) {
                let left = pixels[row * gridWidth + column]
                let right = pixels[row * gridWidth + column + 1]
                hash <<= 1
                if left > right { hash |= 1 }
            }
        }
        return hash
    }

    /// Number of differing bits between two hashes (0 = identical, 64 = opposite).
    static func distance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    /// Flat images (all black, all white, a solid colour) produce all-zero or all-one hashes
    /// that would match every other flat image, so they are ignored for grouping.
    static func isInformative(_ hash: UInt64) -> Bool {
        hash != 0 && hash != UInt64.max
    }
}
