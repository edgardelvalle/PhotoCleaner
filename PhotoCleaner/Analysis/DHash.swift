import Foundation

/// A 64-bit difference hash ("dHash").
///
/// The image is shrunk to a 9x8 grayscale grid and each bit records whether a pixel is
/// brighter than its right-hand neighbour. Exact copies, re-saved and resized versions of
/// the same picture end up with the same (or nearly the same) hash.
enum DHash {
    static let gridWidth = 9
    static let gridHeight = 8
    /// Grids with less brightness range than this (dark, foggy or plain photos) produce
    /// hashes made of noise that match unrelated photos, so they get no hash at all.
    static let minimumContrast: UInt8 = 16

    /// Builds the hash from a 9x8 grayscale grid, row by row (72 values).
    /// Returns nil for the wrong size or a low-contrast grid.
    static func hash(grayscale pixels: [UInt8]) -> UInt64? {
        guard pixels.count == gridWidth * gridHeight,
              let darkest = pixels.min(), let brightest = pixels.max(),
              brightest - darkest >= minimumContrast
        else { return nil }
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

    /// Hashes with very few or very many set bits come from nearly uniform gradients
    /// (skies, walls, plain backgrounds) and match too easily to trust.
    static func isStrong(_ hash: UInt64) -> Bool {
        (8...56).contains(hash.nonzeroBitCount)
    }
}
