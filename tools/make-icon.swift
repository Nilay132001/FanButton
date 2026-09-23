import AppKit

// Draws the app icon (white fan on a blue rounded square) into an .iconset folder for iconutil.
let iconset = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

func draw(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let size = CGFloat(pixels)
    // Apple's icon grid: the tile fills about 80% of the canvas.
    let tile = NSRect(x: size * 0.1, y: size * 0.1, width: size * 0.8, height: size * 0.8)
    let shape = NSBezierPath(roundedRect: tile, xRadius: size * 0.18, yRadius: size * 0.18)
    NSGradient(starting: NSColor(red: 0.20, green: 0.62, blue: 1.0, alpha: 1),
               ending: NSColor(red: 0.05, green: 0.28, blue: 0.75, alpha: 1))!.draw(in: shape, angle: -90)
    let config = NSImage.SymbolConfiguration(pointSize: size * 0.42, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    let fan = NSImage(systemSymbolName: "fanblades.fill", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
    fan.draw(in: NSRect(x: (size - fan.size.width) / 2, y: (size - fan.size.height) / 2,
                        width: fan.size.width, height: fan.size.height))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    try draw(points).write(to: URL(fileURLWithPath: "\(iconset)/icon_\(points)x\(points).png"))
    try draw(points * 2).write(to: URL(fileURLWithPath: "\(iconset)/icon_\(points)x\(points)@2x.png"))
}
