// Renders icon.svg at every size the app icon set lists, with AppKit's own SVG
// support, on a transparent sRGB canvas.
//   swift script/app-icon/png.swift ICON.svg APPICONSET
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let image = NSImage(contentsOf: URL(fileURLWithPath: args[1])) else {
    FileHandle.standardError.write("usage: png.swift ICON.svg APPICONSET\n".data(using: .utf8)!)
    exit(64)
}
let set = URL(fileURLWithPath: args[2])

func png(_ pixels: Int) -> Data {
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try png(size).write(to: set.appendingPathComponent("AppIcon-\(size).png"))
    try png(size * 2).write(to: set.appendingPathComponent("AppIcon-\(size)@2x.png"))
}
