import AppKit

/// The Agent Mode mark: a flat cup with two "agent" eyes and two lines of steam, drawn on a 100×100 grid.
/// Used for the menu bar icons and (via tools/make-icon.swift) the app icon.
enum CupMark {
    enum Style {
        case awake   // solid cup, eyes open, steam
        case asleep  // outline cup, eyes closed, no steam
    }

    /// Draws the mark into `rect` (square) in the current graphics context.
    /// `cup` fills the body; `eyes` is used for the eyes (and cut-outs on a template); `steam` colors the steam.
    /// `steamPhase` (0 or 1) nudges the steam for the menu bar's "working" animation.
    static func draw(in rect: NSRect, style: Style, cup: NSColor, eyes: NSColor, steam: NSColor, template: Bool = false, steamPhase: Int = 0) {
        let s = rect.width / 100
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: rect.minX + x * s, y: rect.maxY - y * s) }  // y down

        // Body: flat top, straight sides, rounded bottom.
        let body = NSBezierPath()
        body.move(to: p(16, 36))
        body.line(to: p(68, 36))
        body.line(to: p(68, 62))
        body.appendArc(withCenter: p(46, 62), radius: 22 * s, startAngle: 0, endAngle: -90, clockwise: true)
        body.line(to: p(38, 84))
        body.appendArc(withCenter: p(38, 62), radius: 22 * s, startAngle: -90, endAngle: 180, clockwise: true)
        body.close()

        // Handle: a half ring on the right.
        let handle = NSBezierPath()
        handle.appendArc(withCenter: p(68, 55), radius: 11 * s, startAngle: 90, endAngle: -90, clockwise: true)
        handle.lineWidth = 7 * s
        handle.lineCapStyle = .round

        cup.setStroke()
        handle.stroke()

        switch style {
        case .awake:
            cup.setFill()
            body.fill()
            // Eyes: on a template image they're cut out of the body.
            let eyePaths = [NSBezierPath(ovalIn: NSRect(x: p(30.5, 0).x, y: p(0, 61.5).y, width: 11 * s, height: 11 * s)),
                            NSBezierPath(ovalIn: NSRect(x: p(49.5, 0).x, y: p(0, 61.5).y, width: 11 * s, height: 11 * s))]
            if template {
                NSGraphicsContext.current?.compositingOperation = .clear
                eyePaths.forEach { $0.fill() }
                NSGraphicsContext.current?.compositingOperation = .sourceOver
            } else {
                eyes.setFill()
                eyePaths.forEach { $0.fill() }
            }
            // Steam: two short rounded strokes above the cup.
            steam.setStroke()
            for (n, x) in [34.0, 52.0].enumerated() {
                let lift: CGFloat = steamPhase == 0 ? 0 : (n == 0 ? 3 : -3)  // the two lines bob in turn
                let line = NSBezierPath()
                line.move(to: p(x, 26 - lift))
                line.line(to: p(x, 14 - lift))
                line.lineWidth = 6.5 * s
                line.lineCapStyle = .round
                line.stroke()
            }
        case .asleep:
            body.lineWidth = 6.5 * s
            cup.setStroke()
            body.stroke()
            for x in [33.0, 51.0] {  // closed eyes
                let line = NSBezierPath()
                line.move(to: p(x, 56))
                line.line(to: p(x + 8, 56))
                line.lineWidth = 5.5 * s
                line.lineCapStyle = .round
                eyes.setStroke()
                line.stroke()
            }
        }
    }
}
