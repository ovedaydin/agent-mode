import AppKit

/// Pixel-art menu bar icons: a robot coffee mug, awake (steaming, eyes open) or asleep.
enum MenuIcon {
    static let awake = make([
        "....#...#.......",
        ".....#...#......",
        "....#...#.......",
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
    ])

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
