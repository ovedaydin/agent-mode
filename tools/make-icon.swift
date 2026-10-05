// Renders the app icon (Resources/AppIcon.icns) and assets/icon.png from the Agent Mode cup mark.
// Run: mkdir -p /tmp/mi && cp tools/make-icon.swift /tmp/mi/main.swift && swiftc -o /tmp/mi/run /tmp/mi/main.swift Sources/CupMark.swift && /tmp/mi/run
import AppKit

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

func render(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(size) / 1024
    // macOS icon grid: 824pt rounded square on a 1024 canvas, with a soft shadow.
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.shadowBlurRadius = 24 * s
    shadow.set()
    color(0x0E1220).setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(0x232B4A), ending: color(0x0E1220))!.draw(in: path, angle: -90)
    CupMark.draw(in: tile.insetBy(dx: 130 * s, dy: 130 * s), style: .awake,
                 cup: color(0xF4EEE4), eyes: color(0x5CE1FF), steam: color(0x5CE1FF))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! render(size: base * scale).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()
try! render(size: 512).representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("assets/icon.png"))
print("Wrote Resources/AppIcon.icns and assets/icon.png")
