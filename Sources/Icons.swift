import AppKit

/// Pixel-art menu bar icons: a robot coffee mug, awake (steaming, eyes open) or asleep.
enum MenuIcon {
    static var awake: NSImage { awakeFrames[0] }

    /// Steam frames, alternated while agents are working.
    static let awakeFrames = [steamA, steamB].map { make($0 + mugAwake) }

    private static let steamA = [
        "....#...#.......",
        ".....#...#......",
        "....#...#.......",
    ]
    private static let steamB = [
        ".....#...#......",
        "....#...#.......",
        ".....#...#......",
    ]

    private static let mugAwake = [
        "................",
        "................",
        ".###########....",
        ".###########....",
        ".##############.",
        ".##..###..##..#.",
        ".##..###..##..#.",
        ".###########..#.",
        ".####...#######.",
        ".###########....",
        ".###########....",
        "..#########.....",
        "................",
    ]

    static let asleep = make([
        "..........####..",
        "............#...",
        "...........#....",
        "..........####..",
        "................",
        ".###########....",
        ".#.........#....",
        ".#.........####.",
        ".#.........#..#.",
        ".#.##...##.#..#.",
        ".#.........#..#.",
        ".#.........####.",
        ".#.........#....",
        ".###########....",
        "..#########.....",
        "................",
    ])

    private static func make(_ rows: [String]) -> NSImage {
        let size = NSSize(width: rows[0].count, height: rows.count)
        let image = NSImage(size: size, flipped: true) { _ in
            NSColor.black.setFill()
            for (y, row) in rows.enumerated() {
                for (x, char) in row.enumerated() where char == "#" {
                    NSRect(x: x, y: y, width: 1, height: 1).fill()
                }
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Agent Mode"
        return image
    }
}
