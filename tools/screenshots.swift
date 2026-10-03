// Renders README screenshots and a GIF from the real app views with demo data (no real
// photos, no real server). Built and run by tools/make-screenshots.sh.
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Borderless windows can't become key by default; key windows draw controls in their
/// active colours (blue default button, blue progress).
final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
enum Shots {
    static let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "docs")
    static let size = CGSize(width: 860, height: 700)

    // MARK: demo content

    /// A simple landscape "photo": sky gradient, sun, two mountain ridges.
    static func samplePhoto(_ seed: Int) -> NSImage {
        let palettes: [(NSColor, NSColor, NSColor, NSColor)] = [
            (.systemOrange, .systemPink, .systemIndigo, .black),
            (.systemTeal, .systemBlue, .systemGreen, .systemBrown),
            (.systemYellow, .systemOrange, .systemPurple, .systemIndigo),
            (.systemCyan, .white, .systemGray, .darkGray),
            (.systemPink, .systemPurple, .systemBlue, .systemIndigo),
            (.systemMint, .systemTeal, .systemGreen, .systemBrown),
        ]
        let (a, b, m1, m2) = palettes[seed % palettes.count]
        let w = 300.0, h = 200.0
        let img = NSImage(size: NSSize(width: w, height: h))
        img.lockFocus()
        NSGradient(colors: [a, b])!.draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: -90)
        NSColor.white.withAlphaComponent(0.85).setFill()
        let sx = 60.0 + Double((seed * 47) % 180)
        NSBezierPath(ovalIn: NSRect(x: sx, y: 115, width: 42, height: 42)).fill()
        for (i, c) in [m1, m2].enumerated() {
            c.withAlphaComponent(0.9).setFill()
            let p = NSBezierPath()
            p.move(to: NSPoint(x: 0, y: 0))
            var x = 0.0
            var up = true
            while x <= w {
                p.line(to: NSPoint(x: x, y: (up ? 105.0 : 55.0) - Double(i) * 30 + Double((seed * 13 + Int(x)) % 25)))
                x += 50 + Double((seed * 7 + i * 11) % 30)
                up.toggle()
            }
            p.line(to: NSPoint(x: w, y: 0))
            p.close()
            p.fill()
        }
        img.unlockFocus()
        return img
    }

    static func demoCard() -> CardInfo {
        var files: [MediaFile] = []
        for n in 0..<21 {
            let name = String(format: "DSC%05d", 1201 + n)
            let video = n % 7 == 6
            let url = URL(fileURLWithPath: video ? "/Volumes/SONY_ZV/PRIVATE/M4ROOT/CLIP/C\(String(format: "%04d", 40 + n)).MP4"
                                                 : "/Volumes/SONY_ZV/DCIM/100MSDCF/\(name).ARW")
            files.append(MediaFile(url: url, kind: video ? .video : .raw, size: video ? 412_000_000 : 24_500_000))
            ThumbnailCache.shared.insert(samplePhoto(n), for: url)
        }
        return CardInfo(path: "/Volumes/SONY_ZV", name: "SONY_ZV", files: files)
    }

    static func model(card: CardInfo) -> AppModel {
        let m = AppModel(preview: true)
        var s = AppSettings()
        s.server = "https://photos.example.com"
        m.settings = s
        m.hasKey = true
        m.cards = [card]
        m.selected = card.id
        return m
    }

    // MARK: rendering

    static func render<V: View>(_ view: V, size: CGSize = size) -> NSBitmapImageRep {
        let root = view.frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: .aqua)
        host.frame = CGRect(origin: .zero, size: size)
        let win = KeyWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: .aqua)
        win.contentView = host
        win.setFrameOrigin(NSPoint(x: -30000, y: -30000))  // off-screen
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))  // let the grid lay out
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// Wraps content in a macOS-style window frame with title bar and shadow.
    static func framed(_ content: NSBitmapImageRep, title: String) -> CGImage {
        let scale = Double(content.pixelsWide) / Double(content.size.width)
        let pad = 40.0, bar = 30.0
        let w = content.size.width + pad * 2, h = content.size.height + bar + pad * 2
        let out = NSImage(size: NSSize(width: w, height: h))
        out.lockFocus()
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {}
        NSAppearance.current = NSAppearance(named: .aqua)
        let win = NSRect(x: pad, y: pad, width: content.size.width, height: content.size.height + bar)
        let shape = NSBezierPath(roundedRect: win, xRadius: 11, yRadius: 11)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowBlurRadius = 24
        shadow.shadowOffset = NSSize(width: 0, height: -8)
        shadow.set()
        NSColor.windowBackgroundColor.setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        shape.addClip()
        NSColor(calibratedWhite: 0.93, alpha: 1).setFill()
        NSRect(x: pad, y: pad + content.size.height, width: content.size.width, height: bar).fill()
        for (i, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            c.setFill()
            NSBezierPath(ovalIn: NSRect(x: pad + 14 + Double(i) * 20, y: pad + content.size.height + 9, width: 12, height: 12)).fill()
        }
        let t = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                                                                .foregroundColor: NSColor(calibratedWhite: 0.35, alpha: 1)])
        t.draw(at: NSPoint(x: pad + (content.size.width - t.size().width) / 2, y: pad + content.size.height + 7))
        content.draw(in: NSRect(x: pad, y: pad, width: content.size.width, height: content.size.height))
        out.unlockFocus()
        var r = CGRect(x: 0, y: 0, width: w * scale, height: h * scale)
        return out.cgImage(forProposedRect: &r, context: nil, hints: nil)!
    }

    static func writePNG(_ img: CGImage, _ name: String) {
        let d = CGImageDestinationCreateWithURL(out.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(d, img, nil)
        CGImageDestinationFinalize(d)
        print("wrote", name)
    }

    static func scaled(_ img: CGImage, width: Int) -> CGImage {
        let h = Int(Double(img.height) * Double(width) / Double(img.width))
        let ctx = CGContext(data: nil, width: width, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: h))
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: width, height: h))
        return ctx.makeImage()!
    }

    static func writeGIF(_ frames: [(CGImage, Double)], _ name: String) {
        let d = CGImageDestinationCreateWithURL(out.appendingPathComponent(name) as CFURL, UTType.gif.identifier as CFString, frames.count, nil)!
        CGImageDestinationSetProperties(d, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for (img, delay) in frames {
            CGImageDestinationAddImage(d, img, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
        }
        CGImageDestinationFinalize(d)
        print("wrote", name)
    }

    // MARK: scenes

    static func run() {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let card = demoCard()
        let m = model(card: card)
        let view = { ContentView().environmentObject(m) }
        var frames: [(CGImage, Double)] = []
        func shot(_ hold: Double) -> CGImage {
            let img = framed(render(view()), title: "SD to Immich")
            frames.append((scaled(img, width: 820), hold))
            return img
        }

        // 1. Card inserted
        _ = shot(1.6)
        // 2. Checked: 6 already in Immich, the rest new
        for (i, f) in card.files.enumerated() { m.statuses[f.url] = i < 6 ? .inImmich : .new }
        m.phase = .finished("15 new, 6 already in Immich (2026-10-02: 15).")
        m.log = ["SONY_ZV: 18 RAW, 0 JPG, 3 videos", "Immich: https://photos.example.com as Alex"]
        _ = shot(1.6)
        // 3–5. Uploading
        let newFiles = card.files.filter { m.statuses[$0.url] == .new }
        var hero: CGImage?
        for (step, done) in [4, 9, 13].enumerated() {
            for (i, f) in newFiles.enumerated() {
                m.statuses[f.url] = i < done ? .inImmich : (i == done ? .uploading(0.35 + 0.2 * Double(step)) : .new)
            }
            m.phase = .running
            m.fraction = 0.05 + 0.9 * Double(done) / Double(newFiles.count)
            m.detail = "Uploading \(newFiles[done].url.lastPathComponent)"
            let img = shot(step == 1 ? 1.2 : 0.9)
            if step == 1 { hero = img }
        }
        // 6. Done
        for f in card.files { m.statuses[f.url] = .inImmich }
        m.phase = .finished("Imported 15 new, 6 already in Immich. Albums: 2026-10-02.")
        m.fraction = 1
        let done = shot(2.4)

        writePNG(hero!, "screenshot-importing.png")
        writePNG(done, "screenshot-done.png")
        writeGIF(frames, "demo.gif")

        // Settings sheet
        var s = AppSettings()
        s.server = "https://photos.example.com"
        let sm = model(card: card)
        let settings = framed(render(SettingsView(draft: s).environmentObject(sm), size: CGSize(width: 560, height: 600)),
                              title: "Settings")
        writePNG(settings, "screenshot-settings.png")
    }
}

@main
struct ScreenshotTool {
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)  // no Dock icon, but windows can be active
        MainActor.assumeIsolated { Shots.run() }
    }
}
