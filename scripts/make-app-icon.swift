// Рисует иконку-заготовку Inkling (монограмма «i» с каплей чернил) и раскладывает её по размерам macOS.
// Запуск: swift scripts/make-app-icon.swift Inkling/Resources/Assets.xcassets/AppIcon.appiconset
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func color(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

func render(pixels: Int) -> Data {
    let s = CGFloat(pixels) / 1024
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s, y: s)

    // Фон по сетке иконок macOS: плашка 824×824 с отступом 100.
    let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
    ctx.addPath(CGPath(roundedRect: plate, cornerWidth: 185, cornerHeight: 185, transform: nil))
    ctx.setFillColor(color(0x16161A))
    ctx.fillPath()

    // Ножка буквы «i» (координаты CoreGraphics: y растёт вверх).
    let stem = CGRect(x: 512 - 58, y: 250, width: 116, height: 330)
    ctx.addPath(CGPath(roundedRect: stem, cornerWidth: 58, cornerHeight: 58, transform: nil))
    ctx.setFillColor(color(0xF4F1EA))
    ctx.fillPath()

    // Точка — капля чернил остриём вверх.
    let cx: CGFloat = 512, cy: CGFloat = 690, r: CGFloat = 78
    let drop = CGMutablePath()
    drop.move(to: CGPoint(x: cx, y: cy + r * 2.15))
    drop.addCurve(to: CGPoint(x: cx + r, y: cy), control1: CGPoint(x: cx + r * 0.35, y: cy + r * 1.45),
                  control2: CGPoint(x: cx + r, y: cy + r * 0.85))
    drop.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: 0, endAngle: .pi, clockwise: true)
    drop.addCurve(to: CGPoint(x: cx, y: cy + r * 2.15), control1: CGPoint(x: cx - r, y: cy + r * 0.85),
                  control2: CGPoint(x: cx - r * 0.35, y: cy + r * 1.45))
    drop.closeSubpath()
    ctx.addPath(drop)
    ctx.setFillColor(color(0xF5B83D))
    ctx.fillPath()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for point in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(point)x\(point)\(scale == 2 ? "@2x" : "").png"
        try render(pixels: point * scale).write(to: outDir.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(point)x\(point)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: outDir.appendingPathComponent("Contents.json"))
print("Готово: \(outDir.path)")
