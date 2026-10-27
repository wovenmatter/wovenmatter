// Keep AppKit separate from Testing: the Xcode 27 beta SwiftPM runner does not
// ship the _Testing_AppKit cross-import module.
import AppKit
import Foundation

func computerFixturePNG() throws -> Data {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 16,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileReadCorruptFile) }
    return png
}
func computerFixtureImageSize(_ data: Data) throws -> (Int, Int) {
    guard let bitmap = NSBitmapImageRep(data: data) else { throw CocoaError(.fileReadCorruptFile) }
    return (bitmap.pixelsWide, bitmap.pixelsHigh)
}
