import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let bounds = NSRect(x: 80, y: 80, width: 864, height: 864)
        let background = NSBezierPath(roundedRect: bounds, xRadius: 200, yRadius: 200)
        NSGradient(starting: NSColor(calibratedRed: 0.15, green: 0.23, blue: 0.37, alpha: 1),
                   ending: NSColor(calibratedRed: 0.06, green: 0.10, blue: 0.18, alpha: 1))!.draw(in: background, angle: -65)
        NSColor(calibratedWhite: 1, alpha: 0.06).setStroke()
        for y in [350, 500, 650] {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: 188, y: y)); line.line(to: NSPoint(x: 836, y: y))
            line.lineWidth = 3; line.stroke()
        }
        let pulse = NSBezierPath()
        pulse.move(to: NSPoint(x: 200, y: 520))
        for point in [NSPoint(x: 330, y: 520), NSPoint(x: 390, y: 710), NSPoint(x: 490, y: 380), NSPoint(x: 585, y: 620), NSPoint(x: 650, y: 520), NSPoint(x: 820, y: 520)] { pulse.line(to: point) }
        pulse.lineWidth = 42; pulse.lineCapStyle = .round; pulse.lineJoinStyle = .round
        NSColor(calibratedRed: 0.40, green: 0.76, blue: 1, alpha: 1).setStroke(); pulse.stroke()
        for index in 0..<5 {
            let bar = NSBezierPath(roundedRect: NSRect(x: 234 + index * 118, y: 230, width: 86, height: 42), xRadius: 11, yRadius: 11)
            (index < 3 ? NSColor(calibratedRed: 0.67, green: 0.55, blue: 1, alpha: 1) : NSColor(calibratedWhite: 1, alpha: 0.15)).setFill()
            bar.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
    }
}
let chunks = [("icp4", "icon_16x16.png"), ("icp5", "icon_32x32.png"),
              ("icp6", "icon_32x32@2x.png"), ("ic07", "icon_128x128.png"),
              ("ic08", "icon_256x256.png"), ("ic09", "icon_512x512.png"),
              ("ic10", "icon_512x512@2x.png"), ("ic11", "icon_16x16@2x.png"),
              ("ic12", "icon_32x32@2x.png"), ("ic13", "icon_128x128@2x.png"),
              ("ic14", "icon_256x256@2x.png")]
func lengthData(_ length: Int) -> Data {
    var number = UInt32(length).bigEndian
    return withUnsafeBytes(of: &number) { Data($0) }
}
var payload = Data()
for (type, name) in chunks {
    let png = try Data(contentsOf: directory.appendingPathComponent(name))
    payload.append(Data(type.utf8)); payload.append(lengthData(png.count + 8)); payload.append(png)
}
var container = Data("icns".utf8)
container.append(lengthData(payload.count + 8)); container.append(payload)
try container.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
