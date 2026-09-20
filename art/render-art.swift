// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

// Draws the menu-bar glyph's states strip (docs/menubar-icon.png) from the real
// CharacterIcon, so the README always shows what the app actually draws.
//
// The app icon and the mascot are not drawn here: they are generated art, from
// art/gen_app_icon.py and the Menubarn site's mascot pipeline respectively.
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

// MARK: - The menu-bar strip

/// The states strip for the README, in the same dark tile the other repos use.
func menuBarStrip(states: [NSImage]) -> NSImage {
    let cell: CGFloat = 132, height: CGFloat = 104
    return image(width: cell * CGFloat(states.count), height: height) { context in
        let tile = CGRect(x: 0, y: 0, width: cell * CGFloat(states.count), height: height)
        context.addPath(CGPath(roundedRect: tile, cornerWidth: 18, cornerHeight: 18, transform: nil))
        color(0x1E1E1E).setFill()
        context.fillPath()

        for (index, state) in states.enumerated() {
            // Drawn at 2x, which is the density the glyph is designed for.
            let w = state.size.width * 2, h = state.size.height * 2
            let box = CGRect(x: CGFloat(index) * cell + (cell - w) / 2, y: (height - h) / 2, width: w, height: h)
            state.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1,
                       respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        }
    }
}

// MARK: - Output

let root = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath
let states = [
    CharacterIcon.house(lightsOn: 0, fanOn: false, reachable: true, configured: true),
    CharacterIcon.house(lightsOn: 1, fanOn: false, reachable: true, configured: true),
    CharacterIcon.house(lightsOn: 2, fanOn: false, reachable: true, configured: true),
    CharacterIcon.house(lightsOn: 2, fanOn: true, reachable: true, configured: true),
    CharacterIcon.house(lightsOn: 0, fanOn: false, reachable: false, configured: true),
]
write(menuBarStrip(states: states), to: root + "/docs/menubar-icon.png")
print("wrote docs/menubar-icon.png")
