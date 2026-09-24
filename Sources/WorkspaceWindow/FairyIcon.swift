import AppKit

// FairyStack's fairy as a menu-bar template: an orb, two upright wings and two sparkles.
public enum FairyIcon {
    public static func menuBar() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            for (x, sign) in [(5.6, 1.0), (12.4, -1.0)] { wing(center: NSPoint(x: x, y: 11.9), degrees: 30 * sign).fill() }
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: NSRect(x: 9 - 4.2, y: 5 - 4.2, width: 8.4, height: 8.4)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSBezierPath(ovalIn: NSRect(x: 9 - 3.2, y: 5 - 3.2, width: 6.4, height: 6.4)).fill()
            sparkle(NSPoint(x: 1.9, y: 4.2), 1.7).fill(); sparkle(NSPoint(x: 16.1, y: 4.2), 1.7).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "FairyStack Companion"
        return image
    }
    private static func wing(center: NSPoint, degrees: CGFloat) -> NSBezierPath {
        let length: CGFloat = 10.4, width: CGFloat = 2.3, steps = 40
        let side = (0...steps).map { i -> (CGFloat, CGFloat) in
            let t = CGFloat(i) / CGFloat(steps)
            return (width * pow(sin(.pi * t), 0.75) * (1.2 - 0.45 * t), -length / 2 + length * t)
        }
        let a = degrees * .pi / 180
        let point = { (x: CGFloat, y: CGFloat) in NSPoint(x: center.x + x * cos(a) - y * sin(a), y: center.y + x * sin(a) + y * cos(a)) }
        let path = NSBezierPath()
        path.move(to: point(side[0].0, side[0].1))
        side.dropFirst().forEach { path.line(to: point($0.0, $0.1)) }
        side.reversed().forEach { path.line(to: point(-$0.0, $0.1)) }
        path.close(); return path
    }
    private static func sparkle(_ c: NSPoint, _ r: CGFloat) -> NSBezierPath {
        let k = r * 0.28, path = NSBezierPath()
        let points = [(0, r), (k, k), (r, 0), (k, -k), (0, -r), (-k, -k), (-r, 0), (-k, k)]
        path.move(to: NSPoint(x: c.x + points[0].0, y: c.y + points[0].1))
        points.dropFirst().forEach { path.line(to: NSPoint(x: c.x + $0.0, y: c.y + $0.1)) }
        path.close(); return path
    }
}
