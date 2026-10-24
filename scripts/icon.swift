// Draws the SlideScroll app icon: a strip of window columns on a squircle,
// the focused column in the middle (split into a stack), its neighbours cut
// off at the edges as the strip scrolls past.
//
//   swift scripts/icon.swift out.png [size]
//
// Geometry follows Apple's macOS icon grid: an 824-point body centred on a
// 1024-point canvas, leaving room for the shadow.
import AppKit

let args = CommandLine.arguments
let out = args.count > 1 ? args[1] : "AppIcon.png"
let size = args.count > 2 ? Int(args[2]) ?? 1024 : 1024
let s = CGFloat(size) / 1024

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
ctx.scaleBy(x: s, y: s)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// Body, with a soft drop shadow.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = rounded(body, 185)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
ctx.addPath(bodyPath)
ctx.setFillColor(color(0x2B1E8C))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(bodyPath)
ctx.clip()

// Indigo to violet, lit from the top left.
let gradient = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
    colors: [color(0x6D6BFF), color(0x4B3FE0), color(0x2A1A86)] as CFArray,
    locations: [0, 0.45, 1])!
ctx.drawLinearGradient(
    gradient, start: CGPoint(x: 160, y: 924), end: CGPoint(x: 864, y: 100), options: [])

// The strip: columns 300 wide with 36-point gaps, vertically centred.
let top: CGFloat = 760, bottom: CGFloat = 264
let gap: CGFloat = 36
func column(_ x: CGFloat, _ w: CGFloat) -> CGRect {
    CGRect(x: x, y: bottom, width: w, height: top - bottom)
}

let centre = column(362, 300)

// Neighbours, the same width and gap, cut off by the body's edges.
for r in [column(centre.minX - gap - 300, 300), column(centre.maxX + gap, 300)] {
    ctx.addPath(rounded(r, 44))
    ctx.setFillColor(color(0xFFFFFF, 0.28))
    ctx.fillPath()
}

// The focused column: two stacked windows with a title bar each.
let half = (centre.height - gap) / 2
for (i, y) in [centre.minY + half + gap, centre.minY].enumerated() {
    let win = CGRect(x: centre.minX, y: y, width: centre.width, height: half)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: color(0x140A50, 0.35))
    ctx.addPath(rounded(win, 40))
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()
    // Title bar tint, darker on the focused (top) window.
    ctx.saveGState()
    ctx.addPath(rounded(win, 40))
    ctx.clip()
    ctx.setFillColor(color(i == 0 ? 0xC9C6FF : 0xE6E4FF))
    ctx.fill(CGRect(x: win.minX, y: win.maxY - 52, width: win.width, height: 52))
    ctx.restoreGState()
}

// Scroll hint: a short track under the strip with the visible part lit.
ctx.addPath(rounded(CGRect(x: 312, y: 188, width: 400, height: 16), 8))
ctx.setFillColor(color(0xFFFFFF, 0.22))
ctx.fillPath()
ctx.addPath(rounded(CGRect(x: 432, y: 188, width: 160, height: 16), 8))
ctx.setFillColor(color(0xFFFFFF, 0.9))
ctx.fillPath()

// A faint inner rim catches the light.
ctx.restoreGState()
ctx.addPath(rounded(body.insetBy(dx: 1.5, dy: 1.5), 184))
ctx.setStrokeColor(color(0xFFFFFF, 0.18))
ctx.setLineWidth(3)
ctx.strokePath()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
