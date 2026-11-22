import CoreGraphics

extension DHash {
    /// Draws the image into a 9x8 grayscale bitmap and hashes it.
    static func compute(_ image: CGImage) -> UInt64? {
        var pixels = [UInt8](repeating: 0, count: gridWidth * gridHeight)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: gridWidth,
                height: gridHeight,
                bitsPerComponent: 8,
                bytesPerRow: gridWidth,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: gridWidth, height: gridHeight))
            return true
        }
        return drawn ? hash(grayscale: pixels) : nil
    }
}
