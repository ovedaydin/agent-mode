// Renders the app icon (Resources/AppIcon.icns) and assets/icon.png from pixel art.
// Run: swift tools/make-icon.swift
import AppKit

let art = [
    "........T....T..........",
    ".......t....t...........",
    "........T....T..........",
    ".........t....t.........",
    "........T....T..........",
    "........................",
    "...WWWWWWWWWWWWWWS......",
    "...WOOOOOOOOOOOOOS......",
    "...WWWWWWWWWWWWWWSWWWW..",
    "...WWKKKKKKKKKKKWS..WS..",
    "...WWKKCCKKKKCCKWS..WS..",
    "...WWKKCCKKKKCCKWS..WS..",
    "...WWKKCCKKKKCCKWS..WS..",
    "...WWKKKKKKKKKKKWS..WS..",
    "...WWWWWWWWWWWWWWSWWWS..",
    "...WWWWWWWWWWWWWWS......",
    "...WWWWWWWWWWWWWWS......",
    "...WWWWWWWWWWWWWWS......",
    "....WWWWWWWWWWWWS.......",
    "..PPPPPPPPPPPPPPPPPP....",
]

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

// Warm cream, clay and ink.
let palette: [Character: NSColor] = [
    "W": color(0xF5F1E8),        // mug
    "S": color(0xE2D9C8),        // mug shading
    "O": color(0x8A5A3C),        // coffee
    "K": color(0x1F1E1D),        // robot visor
    "C": color(0xD97757),        // eyes
    "T": color(0xD97757),        // steam
    "t": color(0xE9A58C),        // steam, lighter
    "P": color(0x4A4743),        // saucer
]

func render(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(size) / 1024

    // macOS icon grid: 824pt rounded square centered on a 1024 canvas.
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x000000, 0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.shadowBlurRadius = 24 * s
    shadow.set()
    color(0x1F1E1D).setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(0x2E2C29), ending: color(0x1A1918))!.draw(in: path, angle: -90)

    // Pixel art, centered on the tile.
    let cols = art[0].count, rows = art.count
    let px = (624 * s / CGFloat(cols)).rounded(.down).clamped(min: 1)
    let originX = (CGFloat(size) - px * CGFloat(cols)) / 2
    let originY = (CGFloat(size) - px * CGFloat(rows)) / 2 + 12 * s
    func cell(_ x: Int, _ y: Int) -> NSRect {
        NSRect(x: originX + CGFloat(x) * px, y: originY + CGFloat(rows - 1 - y) * px, width: px, height: px)
    }

    for (y, row) in art.enumerated() {
        for (x, ch) in row.enumerated() {
            guard let fill = palette[ch] else { continue }
            fill.setFill()
            cell(x, y).fill(using: .sourceOver)
        }
    }


    // Eyes again, with a soft glow over the visor.
    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = color(0xD97757, 0.9)
    glow.shadowBlurRadius = 28 * s
    glow.set()
    for (y, row) in art.enumerated() {
        for (x, ch) in row.enumerated() where ch == "C" {
            palette[ch]!.setFill()
            cell(x, y).fill()
        }
    }
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

extension CGFloat {
    func clamped(min lower: CGFloat) -> CGFloat { Swift.max(self, lower) }
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! render(size: base * scale).representation(using: .png, properties: [:])!
            .write(to: iconset.appendingPathComponent(name))
    }
}

try! fm.createDirectory(at: root.appendingPathComponent("Resources"), withIntermediateDirectories: true)
try! fm.createDirectory(at: root.appendingPathComponent("assets"), withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()
try! render(size: 512).representation(using: .png, properties: [:])!
    .write(to: root.appendingPathComponent("assets/icon.png"))
print("Wrote Resources/AppIcon.icns and assets/icon.png")
