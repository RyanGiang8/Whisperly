// Renders the Whisperly app icon: black/graphite rounded square
// with five clean white bars. Run: swift scripts/make_icon.swift
import AppKit

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let iconsetURL = URL(fileURLWithPath: "AppIcon.iconset")
try? FileManager.default.removeItem(at: iconsetURL)
try! FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

// Waveform silhouette (relative heights).
let bars: [CGFloat] = [0.32, 0.62, 1.0, 0.62, 0.32]

func render(_ pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .calibratedRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s = CGFloat(pixels)
    // macOS icon grid: content square ~82% of canvas, centered.
    let inset = s * 0.09
    let square = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = square.width * 0.225
    let path = NSBezierPath(roundedRect: square, xRadius: radius, yRadius: radius)

    let gradient = NSGradient(colors: [
        NSColor(calibratedWhite: 0.22, alpha: 1),
        NSColor(calibratedWhite: 0.07, alpha: 1)
    ])!
    gradient.draw(in: path, angle: -90)

    // Waveform bars.
    let waveWidth = square.width * 0.44
    let maxBarHeight = square.height * 0.46
    let barWidth = waveWidth / (CGFloat(bars.count) * 1.9)
    let gap = (waveWidth - barWidth * CGFloat(bars.count)) / CGFloat(bars.count - 1)
    var x = square.midX - waveWidth / 2

    for h in bars {
        let barH = max(barWidth, h * maxBarHeight)
        let y = square.midY - barH / 2
        let color = NSColor(calibratedWhite: 0.97, alpha: 1)
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: barWidth, height: barH),
                     xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        x += barWidth + gap
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for size in sizes {
    let rep = render(size)
    let png = rep.representation(using: .png, properties: [:])!
    if size <= 512 {
        try! png.write(to: iconsetURL.appendingPathComponent("icon_\(size)x\(size).png"))
    }
    if size >= 32 {
        try! png.write(to: iconsetURL.appendingPathComponent("icon_\(size / 2)x\(size / 2)@2x.png"))
    }
}
print("iconset written")
