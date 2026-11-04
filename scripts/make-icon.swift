// Draws the app icon: a flyer with a calendar on it, pinned to a coral background.
// Usage: swift scripts/make-icon.swift <output.png>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
// Draw with the origin at the top-left.
context.translateBy(x: 0, y: CGFloat(size))
context.scaleBy(x: 1, y: -1)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}

func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

let navy = color(0.13, 0.19, 0.32)
let coral = color(0.93, 0.36, 0.25)
let cream = color(0.99, 0.96, 0.89)
let cell = color(0.86, 0.82, 0.73)
let yellow = color(0.99, 0.78, 0.20)

// Background, on the standard macOS icon grid: 824 points inside a 1024 canvas.
let background = rounded(CGRect(x: 100, y: 100, width: 824, height: 824), 186)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: color(0, 0, 0, 0.30))
context.addPath(background)
context.setFillColor(coral)
context.fillPath()
context.restoreGState()

context.saveGState()
context.addPath(background)
context.clip()
let gradient = CGGradient(
    colorsSpace: space,
    colors: [color(0.97, 0.45, 0.31), color(0.84, 0.26, 0.21)] as CFArray,
    locations: [0, 1]
)!
context.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
context.restoreGState()

// The flyer, tilted as if pinned by hand.
context.saveGState()
context.translateBy(x: 512, y: 530)
context.rotate(by: -5 * .pi / 180)

let paper = CGRect(x: -235, y: -300, width: 470, height: 600)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -18), blur: 34, color: color(0, 0, 0, 0.34))
context.addPath(rounded(paper, 20))
context.setFillColor(cream)
context.fillPath()
context.restoreGState()

// Header band.
context.saveGState()
context.addPath(rounded(paper, 20))
context.clip()
context.setFillColor(navy)
context.fill(CGRect(x: paper.minX, y: paper.minY, width: paper.width, height: 165))
context.restoreGState()

// Calendar grid, with one day picked out.
let columns = 4
let rows = 3
let gap: CGFloat = 20
let inset: CGFloat = 42
let gridTop = paper.minY + 165 + 44
let cellSize = (paper.width - inset * 2 - gap * CGFloat(columns - 1)) / CGFloat(columns)
for row in 0..<rows {
    for column in 0..<columns {
        let rect = CGRect(
            x: paper.minX + inset + CGFloat(column) * (cellSize + gap),
            y: gridTop + CGFloat(row) * (cellSize + gap),
            width: cellSize, height: cellSize
        )
        context.addPath(rounded(rect, 16))
        context.setFillColor(row == 1 && column == 2 ? coral : cell)
        context.fillPath()
    }
}

// Pin.
let pinCenter = CGPoint(x: 0, y: paper.minY + 62)
context.saveGState()
context.setShadow(offset: CGSize(width: 6, height: -14), blur: 16, color: color(0, 0, 0, 0.45))
context.setFillColor(yellow)
context.fillEllipse(in: CGRect(x: pinCenter.x - 54, y: pinCenter.y - 54, width: 108, height: 108))
context.restoreGState()
context.setFillColor(color(1, 1, 1, 0.55))
context.fillEllipse(in: CGRect(x: pinCenter.x - 30, y: pinCenter.y - 34, width: 30, height: 30))
context.restoreGState()

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Couldn't write the icon") }
