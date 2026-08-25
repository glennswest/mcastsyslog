// Draws the app icon and writes an .icns.
//
// The icon is generated rather than checked in as an opaque binary, so that
// changing it is an edit to a file someone can read instead of a round trip
// through a drawing program. `make icon` runs this.
//
//   swift Tools/make-icon.swift Resources
//
// The motif is what the application is: a point emitting, and nobody at the
// centre asking anything of it. Arcs radiate from a single dot — the node —
// and the outermost pair is amber, because the thing you are usually looking
// for on this wire is the one node that has started warning.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Palette

/// Deep slate. Dark enough that the arcs carry the shape at 16 points, and
/// neutral enough not to fight whatever wallpaper it lands on.
let backgroundTop = CGColor(red: 0.13, green: 0.18, blue: 0.24, alpha: 1)
let backgroundBottom = CGColor(red: 0.05, green: 0.08, blue: 0.12, alpha: 1)
let signal = CGColor(red: 0.42, green: 0.80, blue: 0.94, alpha: 1)
let signalFaint = CGColor(red: 0.42, green: 0.80, blue: 0.94, alpha: 0.55)
let accent = CGColor(red: 1.00, green: 0.62, blue: 0.04, alpha: 1)
let core = CGColor(red: 0.94, green: 0.97, blue: 1.00, alpha: 1)

// MARK: - Shapes

/// The rounded square macOS icons live in. 22.37% of the side is Apple's
/// corner radius for the squircle; a plain rounded rect at that radius is
/// indistinguishable at every size this is rendered.
func squircle(in rect: CGRect) -> CGPath {
    CGPath(roundedRect: rect,
           cornerWidth: rect.width * 0.2237,
           cornerHeight: rect.width * 0.2237,
           transform: nil)
}

func draw(size: CGFloat, into context: CGContext) {
    let full = CGRect(x: 0, y: 0, width: size, height: size)
    context.setBlendMode(.normal)
    context.clear(full)

    // Apple's grid leaves the icon shape at about 80% of the canvas, with the
    // rest as margin the shadow lives in.
    let inset = size * 0.098
    let plate = full.insetBy(dx: inset, dy: inset)
    let shape = squircle(in: plate)

    // A soft shadow under the plate, so it sits on the desktop rather than
    // floating flat on it.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -size * 0.012),
                      blur: size * 0.03,
                      color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
    context.addPath(shape)
    context.setFillColor(backgroundBottom)
    context.fillPath()
    context.restoreGState()

    // The plate itself.
    context.saveGState()
    context.addPath(shape)
    context.clip()
    if let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [backgroundTop, backgroundBottom] as CFArray,
        locations: [0, 1]
    ) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: plate.midX, y: plate.maxY),
            end: CGPoint(x: plate.midX, y: plate.minY),
            options: [])
    }

    // The signal.
    let centre = CGPoint(x: plate.midX, y: plate.midY)
    let unit = plate.width
    context.setLineCap(.round)

    // Three pairs of arcs, growing outwards. The gap at top and bottom is what
    // stops this reading as a target: the arcs are leaving, not converging.
    let rings: [(radius: CGFloat, colour: CGColor, width: CGFloat)] = [
        (0.155, signal,      0.052),
        (0.255, signalFaint, 0.050),
        (0.355, accent,      0.048),
    ]

    for ring in rings {
        context.setStrokeColor(ring.colour)
        context.setLineWidth(unit * ring.width)
        for start in [-52.0, 128.0] {
            context.addArc(center: centre,
                           radius: unit * ring.radius,
                           startAngle: CGFloat(start * .pi / 180),
                           endAngle: CGFloat((start + 104) * .pi / 180),
                           clockwise: false)
            context.strokePath()
        }
    }

    // The node at the centre. Everything else in the picture came from here.
    context.setFillColor(core)
    let dot = unit * 0.062
    context.fillEllipse(in: CGRect(x: centre.x - dot, y: centre.y - dot,
                                   width: dot * 2, height: dot * 2))

    // A highlight along the top edge, which is what makes the plate read as
    // glass rather than as a flat rectangle.
    context.setBlendMode(.softLight)
    if let sheen = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [CGColor(red: 1, green: 1, blue: 1, alpha: 0.30),
                 CGColor(red: 1, green: 1, blue: 1, alpha: 0)] as CFArray,
        locations: [0, 1]
    ) {
        context.drawLinearGradient(
            sheen,
            start: CGPoint(x: plate.midX, y: plate.maxY),
            end: CGPoint(x: plate.midX, y: plate.midY),
            options: [])
    }
    context.restoreGState()
}

// MARK: - Writing

func render(size: Int) -> CGImage? {
    guard let context = CGContext(
        data: nil, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high
    draw(size: CGFloat(size), into: context)
    return context.makeImage()
}

func write(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "make-icon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "could not write \(url.lastPathComponent)"])
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "make-icon", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "could not finalise \(url.lastPathComponent)"])
    }
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 1
                          ? CommandLine.arguments[1] : "Resources")
let iconset = outputDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// The ten renditions an .icns wants, from the menu bar to the Finder preview.
let renditions: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for rendition in renditions {
    guard let image = render(size: rendition.pixels) else {
        FileHandle.standardError.write(Data("could not render \(rendition.name)\n".utf8))
        exit(1)
    }
    try write(image, to: iconset.appendingPathComponent("\(rendition.name).png"))
}

// A single large PNG too, for a README or a preview.
if let preview = render(size: 1024) {
    try write(preview, to: outputDirectory.appendingPathComponent("AppIcon.png"))
}

print("wrote \(renditions.count) renditions to \(iconset.path)")
