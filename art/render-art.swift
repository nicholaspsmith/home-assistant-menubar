// Draws Homestead's artwork from code, the way the suite draws its glyphs:
//   Resources/bundle/AppIcon.icns   the app icon (via iconutil)
//   docs/mascot.png                 the README mascot
//   docs/menubar-icon.png           the menu-bar glyph's states
//
// Run from the repo root: art/render-art.sh
import AppKit

// MARK: - Canvas helpers

func image(_ size: CGFloat, _ draw: (CGContext) -> Void) -> NSImage {
    image(width: size, height: size, draw)
}

func image(width: CGFloat, height: CGFloat, _ draw: (CGContext) -> Void) -> NSImage {
    let image = NSImage(size: NSSize(width: width, height: height))
    image.lockFocusFlipped(false)
    if let context = NSGraphicsContext.current?.cgContext {
        context.setAllowsAntialiasing(true)
        context.interpolationQuality = .high
        draw(context)
    }
    image.unlockFocus()
    return image
}

func write(_ image: NSImage, to path: String) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:])
    else { fatalError("could not encode \(path)") }
    try! png.write(to: URL(fileURLWithPath: path))
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

/// Apple's icon corner is a squircle, not a circular round-rect: the curvature
/// eases continuously into the straight edge instead of meeting it at a
/// tangent. A superellipse is the closest honest approximation, and the
/// difference is visible at icon sizes — a plain rounded rect reads as slightly
/// pinched at the corners next to the rest of the Dock.
func squircle(in rect: CGRect, exponent: CGFloat = 5.6) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let centre = CGPoint(x: rect.midX, y: rect.midY)
    let steps = 720
    for step in 0...steps {
        let t = CGFloat(step) / CGFloat(steps) * 2 * .pi
        let cosT = cos(t), sinT = sin(t)
        let x = centre.x + a * pow(abs(cosT), 2 / exponent) * (cosT < 0 ? -1 : 1)
        let y = centre.y + b * pow(abs(sinT), 2 / exponent) * (sinT < 0 ? -1 : 1)
        step == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

func linearGradient(_ context: CGContext, in path: CGPath, colors: [NSColor],
                    from start: CGPoint, to end: CGPoint) {
    context.saveGState()
    context.addPath(path)
    context.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: colors.map(\.cgColor) as CFArray,
                              locations: nil)!
    context.drawLinearGradient(gradient, start: start, end: end, options: [])
    context.restoreGState()
}

func radialGlow(_ context: CGContext, centre: CGPoint, radius: CGFloat, color glowColor: NSColor) {
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [glowColor.cgColor, glowColor.withAlphaComponent(0).cgColor] as CFArray,
                              locations: [0, 1])!
    context.drawRadialGradient(gradient, startCenter: centre, startRadius: 0,
                               endCenter: centre, endRadius: radius, options: [])
}

/// The house silhouette both the icon and the mascot are built from, drawn to
/// fill `rect`. Roof and body come back separately so each can be shaded.
func houseParts(in rect: CGRect, cornerRadius: CGFloat) -> (roof: CGPath, body: CGPath, eaves: CGRect) {
    let bodyHeight = rect.height * 0.56
    let body = CGRect(x: rect.minX + rect.width * 0.12,
                      y: rect.minY,
                      width: rect.width * 0.76,
                      height: bodyHeight)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    let roof = CGMutablePath()
    let apex = CGPoint(x: rect.midX, y: rect.maxY)
    let eavesY = rect.minY + bodyHeight
    roof.move(to: CGPoint(x: rect.minX, y: eavesY))
    roof.addLine(to: CGPoint(x: apex.x - rect.width * 0.02, y: apex.y - rect.height * 0.01))
    roof.addQuadCurve(to: CGPoint(x: apex.x + rect.width * 0.02, y: apex.y - rect.height * 0.01),
                      control: apex)
    roof.addLine(to: CGPoint(x: rect.maxX, y: eavesY))
    roof.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.06, y: eavesY - rect.height * 0.055))
    roof.addLine(to: CGPoint(x: rect.minX + rect.width * 0.06, y: eavesY - rect.height * 0.055))
    roof.closeSubpath()

    return (roof, bodyPath, CGRect(x: rect.minX, y: eavesY - rect.height * 0.055,
                                   width: rect.width, height: rect.height * 0.055))
}

/// Three curved blades, the same motif the menu-bar glyph uses for a running fan.
func fanBlades(centre: CGPoint, radius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    for index in 0..<3 {
        let angle = CGFloat(index) * 2 * .pi / 3 + 0.3
        let tip = CGPoint(x: centre.x + cos(angle) * radius, y: centre.y + sin(angle) * radius)
        path.move(to: centre)
        path.addCurve(to: tip,
                      control1: CGPoint(x: centre.x + cos(angle - 0.9) * radius * 0.9,
                                        y: centre.y + sin(angle - 0.9) * radius * 0.9),
                      control2: CGPoint(x: centre.x + cos(angle - 0.3) * radius,
                                        y: centre.y + sin(angle - 0.3) * radius))
        path.addCurve(to: centre,
                      control1: CGPoint(x: centre.x + cos(angle + 0.35) * radius * 0.85,
                                        y: centre.y + sin(angle + 0.35) * radius * 0.85),
                      control2: CGPoint(x: centre.x + cos(angle + 0.5) * radius * 0.4,
                                        y: centre.y + sin(angle + 0.5) * radius * 0.4))
        path.closeSubpath()
    }
    return path
}

// MARK: - The app icon

/// A dusk sky with a lit house standing in it. The palette is deliberately blue
/// rather than the warm orange the system's own home icon wears: an homage
/// should be recognisable as its own thing at a glance in the Dock.
///
/// No drop shadow is drawn here. macOS composites its own beneath an icon, and
/// a baked one shows up as a grey smear anywhere else the artwork is used.
func appIcon(size: CGFloat) -> NSImage {
    image(size) { context in
        let scale = size / 1024
        func s(_ value: CGFloat) -> CGFloat { value * scale }

        // The tile: Apple leaves ~100/1024 of clear space around the shape.
        let tile = CGRect(x: s(100), y: s(100), width: s(824), height: s(824))
        let tilePath = squircle(in: tile)

        context.addPath(tilePath)
        color(0x16213E).setFill()
        context.fillPath()

        linearGradient(context, in: tilePath,
                       colors: [color(0x44649F), color(0x1E2F58), color(0x131D38)],
                       from: CGPoint(x: tile.midX, y: tile.maxY),
                       to: CGPoint(x: tile.midX, y: tile.minY))

        context.saveGState()
        context.addPath(tilePath)
        context.clip()

        // The house is one silhouette — the same shape the menu-bar glyph
        // draws — rather than a wall with a roof laid on top. A single outline
        // survives being scaled to 16pt; two overlapping planes turn to mush.
        // Sat a little above centre: an icon centred by geometry reads as
        // sitting low, because the eye weights the mass of the roof.
        let house = CGRect(x: tile.midX - s(255), y: tile.minY + s(268), width: s(510), height: s(420))
        let wallHalf = s(162), wallHeight = s(210)
        let eavesY = house.minY + wallHeight

        let silhouette = CGMutablePath()
        silhouette.move(to: CGPoint(x: house.midX - wallHalf, y: house.minY))
        silhouette.addLine(to: CGPoint(x: house.midX - wallHalf, y: eavesY))
        silhouette.addLine(to: CGPoint(x: house.minX, y: eavesY))
        // The ridge is a small rounded join, not a spike: a quad curve whose
        // control sits above the apex leaves a visible nub at 1024pt.
        silhouette.addLine(to: CGPoint(x: house.midX - s(16), y: house.maxY - s(18)))
        silhouette.addQuadCurve(to: CGPoint(x: house.midX + s(16), y: house.maxY - s(18)),
                                control: CGPoint(x: house.midX, y: house.maxY))
        silhouette.addLine(to: CGPoint(x: house.maxX, y: eavesY))
        silhouette.addLine(to: CGPoint(x: house.midX + wallHalf, y: eavesY))
        silhouette.addLine(to: CGPoint(x: house.midX + wallHalf, y: house.minY))
        silhouette.closeSubpath()

        // Light pooling on the ground in front of the windows.
        radialGlow(context, centre: CGPoint(x: house.midX, y: house.minY + s(20)),
                   radius: s(470), color: color(0xFFB347, 0.30))
        // A horizon the house stands on, rather than floating in the gradient.
        linearGradient(context,
                       in: CGPath(rect: CGRect(x: tile.minX, y: tile.minY,
                                               width: tile.width, height: house.minY - tile.minY + s(20)),
                                  transform: nil),
                       colors: [color(0x0B1226, 0), color(0x090F20, 0.75)],
                       from: CGPoint(x: tile.midX, y: house.minY + s(20)),
                       to: CGPoint(x: tile.midX, y: tile.minY))

        // The silhouette, lit from above, standing on its own shadow.
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -s(16)), blur: s(48),
                          color: color(0x070C1C, 0.55).cgColor)
        context.addPath(silhouette)
        color(0xF4EFE4).setFill()
        context.fillPath()
        context.restoreGState()

        linearGradient(context, in: silhouette,
                       colors: [color(0xFFFDF8), color(0xEDE6D8), color(0xD9D0BE)],
                       from: CGPoint(x: house.midX, y: house.maxY),
                       to: CGPoint(x: house.midX, y: house.minY))

        // The roof reads as its own plane through shading alone, so the
        // silhouette stays one shape.
        context.saveGState()
        context.addPath(silhouette)
        context.clip()
        linearGradient(context,
                       in: CGPath(rect: CGRect(x: house.minX, y: eavesY,
                                               width: house.width, height: house.maxY - eavesY), transform: nil),
                       colors: [color(0x7E95CE), color(0x4B639C)],
                       from: CGPoint(x: house.midX, y: house.maxY),
                       to: CGPoint(x: house.midX, y: eavesY))
        // The shadow the overhang casts on the wall.
        linearGradient(context,
                       in: CGPath(rect: CGRect(x: house.midX - wallHalf, y: eavesY - s(44),
                                               width: wallHalf * 2, height: s(44)), transform: nil),
                       colors: [color(0x2A3B66, 0.34), color(0x2A3B66, 0)],
                       from: CGPoint(x: house.midX, y: eavesY),
                       to: CGPoint(x: house.midX, y: eavesY - s(44)))
        context.restoreGState()

        // Windows: the app's whole point, so they carry the brightest value.
        let windowSize = s(84)
        for x in [house.midX - s(88) - windowSize / 2, house.midX + s(88) - windowSize / 2] {
            let frame = CGRect(x: x, y: eavesY - s(36) - windowSize, width: windowSize, height: windowSize)
            let window = CGPath(roundedRect: frame, cornerWidth: s(13), cornerHeight: s(13), transform: nil)

            context.saveGState()
            context.setShadow(offset: .zero, blur: s(40), color: color(0xFFC46B, 0.8).cgColor)
            context.addPath(window)
            color(0xFFC46B).setFill()
            context.fillPath()
            context.restoreGState()

            linearGradient(context, in: window,
                           colors: [color(0xFFF1CB), color(0xFFB347)],
                           from: CGPoint(x: frame.midX, y: frame.maxY),
                           to: CGPoint(x: frame.midX, y: frame.minY))
        }

        // Door: sits in the wall below the windows, never touching them.
        let door = CGRect(x: house.midX - s(39), y: house.minY, width: s(78), height: s(92))
        let doorPath = CGMutablePath()
        doorPath.move(to: CGPoint(x: door.minX, y: door.minY))
        doorPath.addLine(to: CGPoint(x: door.minX, y: door.maxY - s(24)))
        doorPath.addQuadCurve(to: CGPoint(x: door.maxX, y: door.maxY - s(24)),
                              control: CGPoint(x: door.midX, y: door.maxY + s(14)))
        doorPath.addLine(to: CGPoint(x: door.maxX, y: door.minY))
        doorPath.closeSubpath()
        linearGradient(context, in: doorPath,
                       colors: [color(0x3A4E84), color(0x243358)],
                       from: CGPoint(x: door.midX, y: door.maxY),
                       to: CGPoint(x: door.midX, y: door.minY))

        // Glass sheen across the top, the way system icons catch the light.
        linearGradient(context,
                       in: CGPath(rect: CGRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2),
                                  transform: nil),
                       colors: [color(0xFFFFFF, 0.13), color(0xFFFFFF, 0)],
                       from: CGPoint(x: tile.midX, y: tile.maxY),
                       to: CGPoint(x: tile.midX, y: tile.midY))

        context.restoreGState()

        // Rim light, so the tile keeps an edge against a dark Dock.
        context.addPath(tilePath)
        context.setLineWidth(s(3))
        color(0xFFFFFF, 0.16).setStroke()
        context.strokePath()
    }
}

// MARK: - The mascot

/// The sticker mascot: the same house, awake. Thick outline and flat colour,
/// matching the rest of the Menubarn cast.
func mascot(size: CGFloat) -> NSImage {
    image(size) { context in
        let scale = size / 512
        func s(_ value: CGFloat) -> CGFloat { value * scale }

        let outline = color(0x241E1A)
        let houseRect = CGRect(x: s(50), y: s(70), width: s(412), height: s(360))
        let parts = houseParts(in: houseRect, cornerRadius: s(22))

        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -s(8)), blur: s(18),
                          color: color(0x241E1A, 0.25).cgColor)

        // Walls.
        context.addPath(parts.body)
        color(0xFBF4E4).setFill()
        context.fillPath()
        context.addPath(parts.body)
        outline.setStroke()
        context.setLineWidth(s(12))
        context.strokePath()

        // Roof.
        context.addPath(parts.roof)
        color(0x6E86C4).setFill()
        context.fillPath()
        context.addPath(parts.roof)
        context.setLineWidth(s(12))
        context.strokePath()
        context.restoreGState()

        // Eyes: the lit windows, because that is what the glyph says too. They
        // sit wholly inside the wall — an eye crossing the eaves reads as a
        // mistake rather than a face.
        for x in [houseRect.midX - s(96), houseRect.midX + s(26)] {
            let frame = CGRect(x: x, y: houseRect.minY + s(96), width: s(70), height: s(70))
            let window = CGPath(roundedRect: frame, cornerWidth: s(14), cornerHeight: s(14), transform: nil)
            context.addPath(window)
            color(0xFFC94D).setFill()
            context.fillPath()
            context.addPath(window)
            outline.setStroke()
            context.setLineWidth(s(10))
            context.strokePath()

            // Pupil and a highlight, which is what stops it reading as a lamp.
            context.addEllipse(in: CGRect(x: frame.midX - s(13), y: frame.midY - s(15),
                                          width: s(26), height: s(30)))
            outline.setFill()
            context.fillPath()
            context.addEllipse(in: CGRect(x: frame.midX + s(1), y: frame.midY + s(3),
                                          width: s(10), height: s(10)))
            color(0xFFFFFF).setFill()
            context.fillPath()
        }

        // Cheeks.
        for x in [houseRect.midX - s(150), houseRect.midX + s(114)] {
            context.addEllipse(in: CGRect(x: x, y: houseRect.minY + s(62), width: s(38), height: s(23)))
            color(0xF4A28C, 0.75).setFill()
            context.fillPath()
        }

        // A smile where the door would be.
        let smile = CGMutablePath()
        smile.move(to: CGPoint(x: houseRect.midX - s(50), y: houseRect.minY + s(64)))
        smile.addQuadCurve(to: CGPoint(x: houseRect.midX + s(50), y: houseRect.minY + s(64)),
                           control: CGPoint(x: houseRect.midX, y: houseRect.minY + s(4)))
        context.addPath(smile)
        outline.setStroke()
        context.setLineWidth(s(12))
        context.setLineCap(.round)
        context.strokePath()
    }
}

// MARK: - The menu-bar strip

/// The states strip for the README, in the same dark tile the other repos use.
func menuBarStrip(states: [NSImage]) -> NSImage {
    let cell: CGFloat = 108, height: CGFloat = 96
    return image(width: cell * CGFloat(states.count), height: height) { context in
        let tile = CGRect(x: 0, y: 0, width: cell * CGFloat(states.count), height: height)
        context.addPath(CGPath(roundedRect: tile, cornerWidth: 18, cornerHeight: 18, transform: nil))
        color(0x1E1E1E).setFill()
        context.fillPath()

        for (index, state) in states.enumerated() {
            let box = CGRect(x: CGFloat(index) * cell + (cell - 52) / 2, y: (height - 52) / 2, width: 52, height: 52)
            state.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1,
                       respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        }
    }
}

// MARK: - Output

let root = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath
let iconset = root + "/art/Homestead.iconset"
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

for (points, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for scale in scales {
        let pixels = CGFloat(points * scale)
        let suffix = scale == 1 ? "" : "@2x"
        write(appIcon(size: pixels), to: "\(iconset)/icon_\(points)x\(points)\(suffix).png")
    }
}
write(mascot(size: 512), to: root + "/docs/mascot.png")
write(appIcon(size: 1024), to: root + "/docs/app-icon.png")

let states = [
    CharacterIcon.house(lightsOn: 0, fanOn: false, reachable: true, configured: true),
    CharacterIcon.house(lightsOn: 1, fanOn: false, reachable: true, configured: true),
    CharacterIcon.house(lightsOn: 2, fanOn: false, reachable: true, configured: true),
    CharacterIcon.house(lightsOn: 2, fanOn: true, reachable: true, configured: true),
    CharacterIcon.house(lightsOn: 0, fanOn: false, reachable: false, configured: true),
]
write(menuBarStrip(states: states), to: root + "/docs/menubar-icon.png")
print("wrote iconset, mascot, app-icon and menubar-icon")
