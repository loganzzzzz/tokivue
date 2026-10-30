import AppKit

@MainActor
enum QuotaRingIcon {
    static let size = NSSize(width: 17, height: 17)

    static func make(remainingPercent: Double?) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            draw(remainingPercent: remainingPercent, in: rect, cutoutColor: nil)
            return true
        }
        image.isTemplate = true
        return image
    }

    static func previewPNG(remainingPercent: Double, scale: Int = 16) -> Data? {
        let pixelWidth = Int(size.width) * scale
        let pixelHeight = Int(size.height) * scale
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }
        bitmap.size = size

        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        draw(
            remainingPercent: remainingPercent,
            in: NSRect(origin: .zero, size: size),
            cutoutColor: .white
        )
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        return bitmap.representation(using: .png, properties: [:])
    }

    private static func draw(
        remainingPercent: Double?,
        in rect: NSRect,
        cutoutColor: NSColor?
    ) {
        let lineWidth: CGFloat = 2.15
        let radius = (min(rect.width, rect.height) - lineWidth) / 2 - 0.55
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let ringRect = NSRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )

        let track = NSBezierPath(ovalIn: ringRect)
        track.lineWidth = lineWidth
        NSColor.black.withAlphaComponent(0.24).setStroke()
        track.stroke()

        if let remainingPercent {
            let fraction = CGFloat(min(100, max(0, remainingPercent)) / 100)
            if fraction >= 0.999 {
                NSColor.black.setStroke()
                track.stroke()
            } else if fraction > 0 {
                let progress = NSBezierPath()
                progress.lineWidth = lineWidth
                progress.lineCapStyle = .round
                progress.appendArc(
                    withCenter: center,
                    radius: radius,
                    startAngle: 90,
                    endAngle: 90 - (360 * fraction),
                    clockwise: true
                )
                NSColor.black.setStroke()
                progress.stroke()
            }
        }

        drawCodexMark(
            center: center,
            scale: min(rect.width, rect.height) / 17,
            cutoutColor: cutoutColor
        )
    }

    private static func drawCodexMark(
        center: NSPoint,
        scale: CGFloat,
        cutoutColor: NSColor?
    ) {
        let lobeRadius = 2.05 * scale
        let orbitRadius = 2.25 * scale
        NSColor.black.setFill()

        let core = NSBezierPath(
            ovalIn: NSRect(
                x: center.x - 2.65 * scale,
                y: center.y - 2.65 * scale,
                width: 5.3 * scale,
                height: 5.3 * scale
            )
        )
        core.fill()

        for index in 0..<7 {
            let angle = CGFloat.pi / 2 + (CGFloat(index) * 2 * .pi / 7)
            let lobeCenter = NSPoint(
                x: center.x + cos(angle) * orbitRadius,
                y: center.y + sin(angle) * orbitRadius
            )
            let lobe = NSBezierPath(
                ovalIn: NSRect(
                    x: lobeCenter.x - lobeRadius,
                    y: lobeCenter.y - lobeRadius,
                    width: lobeRadius * 2,
                    height: lobeRadius * 2
                )
            )
            lobe.fill()
        }

        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        if let cutoutColor {
            context.setBlendMode(.normal)
            context.setStrokeColor(cutoutColor.cgColor)
        } else {
            context.setBlendMode(.clear)
        }
        context.setLineWidth(0.72 * scale)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        context.move(to: CGPoint(x: center.x - 1.65 * scale, y: center.y + 1.7 * scale))
        context.addLine(to: CGPoint(x: center.x - 0.35 * scale, y: center.y))
        context.addLine(to: CGPoint(x: center.x - 1.65 * scale, y: center.y - 1.7 * scale))
        context.strokePath()

        context.move(to: CGPoint(x: center.x + 0.35 * scale, y: center.y - 1.55 * scale))
        context.addLine(to: CGPoint(x: center.x + 2.25 * scale, y: center.y - 1.55 * scale))
        context.strokePath()
        context.restoreGState()
    }
}
