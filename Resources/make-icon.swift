// Draws Resources/AppIcon.icns: a disc with a play mark on a warm squircle. Run: swift Resources/make-icon.swift
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
let squircle = NSBezierPath(roundedRect: rect, xRadius: 186, yRadius: 186)
NSGraphicsContext.current?.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor(white: 0, alpha: 0.28)
shadow.shadowOffset = NSSize(width: 0, height: -14)
shadow.shadowBlurRadius = 28
shadow.set()
NSColor.black.setFill()
squircle.fill()
NSGraphicsContext.current?.restoreGraphicsState()
let gradient = NSGradient(colors: [NSColor(red: 0.42, green: 0.20, blue: 0.78, alpha: 1), NSColor(red: 0.86, green: 0.25, blue: 0.45, alpha: 1), NSColor(red: 0.98, green: 0.55, blue: 0.25, alpha: 1)])!
gradient.draw(in: squircle, angle: -55)
// a soft highlight on the top edge
let gloss = NSGradient(colors: [NSColor(white: 1, alpha: 0.22), NSColor(white: 1, alpha: 0)])!
gloss.draw(in: NSBezierPath(roundedRect: NSRect(x: 100, y: 512, width: 824, height: 412), xRadius: 186, yRadius: 186), angle: -90)
// the disc: a white ring with its hole
let c = size / 2
let disc = NSBezierPath(ovalIn: NSRect(x: c - 290, y: c - 290, width: 580, height: 580))
disc.appendOval(in: NSRect(x: c - 62, y: c - 62, width: 124, height: 124))
disc.windingRule = .evenOdd
NSColor(white: 1, alpha: 0.95).setFill()
disc.fill()
// the play mark on the disc, to the right of the hole
let play = NSBezierPath()
play.move(to: NSPoint(x: c + 115, y: c + 105))
play.line(to: NSPoint(x: c + 115, y: c - 105))
play.line(to: NSPoint(x: c + 235, y: c))
play.close()
play.lineJoinStyle = .round
play.lineWidth = 24
NSColor(red: 0.80, green: 0.25, blue: 0.50, alpha: 1).set()
play.fill()
play.stroke()
image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
let png = rep.representation(using: .png, properties: [:])!
let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources")
let iconset = dir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let master = iconset.appendingPathComponent("master.png")
try png.write(to: master)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
    p.arguments = ["-z", "\(px)", "\(px)", master.path, "--out", iconset.appendingPathComponent("icon_\(name).png").path]
    p.standardOutput = FileHandle.nullDevice
    try p.run(); p.waitUntilExit()
}
try FileManager.default.removeItem(at: master)
let i = Process()
i.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
i.arguments = ["-c", "icns", iconset.path, "-o", dir.appendingPathComponent("AppIcon.icns").path]
try i.run(); i.waitUntilExit()
try FileManager.default.removeItem(at: iconset)
