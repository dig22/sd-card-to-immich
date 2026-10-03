// Renders the app icon (1024 px PNG): blue gradient squircle with an SD card and an upload arrow.
// Usage: swift tools/make-icon.swift out.png
import AppKit

let size = 1024.0
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(colors: [NSColor(calibratedRed: 0.20, green: 0.45, blue: 0.98, alpha: 1),
                    NSColor(calibratedRed: 0.42, green: 0.25, blue: 0.86, alpha: 1)])!.draw(in: path, angle: -60)

func symbol(_ name: String, _ pt: CGFloat, _ weight: NSFont.Weight) -> NSImage {
    let cfg = NSImage.SymbolConfiguration(pointSize: pt, weight: weight)
        .applying(.init(paletteColors: [.white]))
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(cfg)!
}
let card = symbol("sdcard.fill", 430, .regular)
card.draw(in: NSRect(x: 512 - card.size.width / 2 - 70, y: 512 - card.size.height / 2 + 10,
                     width: card.size.width, height: card.size.height))
let arrow = symbol("arrow.up.circle.fill", 230, .bold)
NSColor(calibratedRed: 0.42, green: 0.25, blue: 0.86, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 600, y: 190, width: 250, height: 250)).fill()
arrow.draw(in: NSRect(x: 725 - arrow.size.width / 2, y: 315 - arrow.size.height / 2,
                      width: arrow.size.width, height: arrow.size.height))
img.unlockFocus()

let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
