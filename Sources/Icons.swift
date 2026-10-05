import AppKit

/// Menu bar icons: the Agent Mode cup, awake (steaming, eyes open) or asleep (outline, eyes closed).
/// Template images, so macOS colors them for light and dark menu bars.
enum MenuIcon {
    static var awake: NSImage { awakeFrames[0] }

    /// Steam frames, alternated while agents are working.
    static let awakeFrames = [make(.awake, phase: 0), make(.awake, phase: 1)]

    static let asleep = make(.asleep, phase: 0)

    private static func make(_ style: CupMark.Style, phase: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            CupMark.draw(in: rect, style: style, cup: .black, eyes: .black, steam: .black, template: true, steamPhase: phase)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Agent Mode"
        return image
    }
}
