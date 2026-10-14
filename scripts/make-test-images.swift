// Генерирует синтетические тестовые данные: «рукописные» страницы (PNG) и PDF слайдов с текстовым слоем.
// Запуск: swift scripts/make-test-images.swift <выходная папка>
import AppKit
import CoreText

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "TestData/synthetic")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func handFont(_ size: CGFloat) -> NSFont {
    for name in ["Bradley Hand", "Noteworthy-Light", "Marker Felt"] {
        if let f = NSFont(name: name, size: size) { return f }
    }
    return NSFont.systemFont(ofSize: size)
}

func renderPage(lines: [String], size: CGSize, font: NSFont, paper: NSColor, ink: NSColor, ruled: Bool, to url: URL) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    paper.setFill()
    NSRect(origin: .zero, size: size).fill()
    let lineHeight = font.pointSize * 1.9
    if ruled {
        NSColor(calibratedRed: 0.6, green: 0.75, blue: 0.95, alpha: 0.6).setStroke()
        var y = size.height - 120
        while y > 40 {
            let p = NSBezierPath(); p.move(to: NSPoint(x: 0, y: y)); p.line(to: NSPoint(x: size.width, y: y)); p.lineWidth = 2; p.stroke()
            y -= lineHeight
        }
    }
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
    var y = size.height - 120 + font.pointSize * 0.25
    for line in lines {
        (line as NSString).draw(at: NSPoint(x: 90, y: y), withAttributes: attrs)
        y -= lineHeight
    }
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

let ink = NSColor(calibratedRed: 0.1, green: 0.15, blue: 0.45, alpha: 1)
let paper = NSColor(calibratedRed: 0.98, green: 0.97, blue: 0.93, alpha: 1)

try renderPage(lines: [
    "Тема: Окислительно-восстановительные реакции",
    "1. Окислитель принимает электроны,",
    "   восстановитель отдаёт.",
    "Пример:  2H2 + O2 -> 2H2O",
    "Fe(3+) + e -> Fe(2+)   (восстановление)",
    "Степень окисления O в H2O равна -2.",
    "Cu + 4HNO3(конц) -> Cu(NO3)2 + 2NO2 + 2H2O",
], size: CGSize(width: 1600, height: 1200), font: handFont(46), paper: paper, ink: ink, ruled: true,
   to: outDir.appendingPathComponent("chem-page.png"))

try renderPage(lines: [
    "Определение. Предел функции f(x) при x -> a",
    "lim (x->0) sin(x)/x = 1",
    "Производная: f'(x) = lim (h->0) (f(x+h) - f(x))/h",
    "Пример: (x^2)' = 2x,  (e^x)' = e^x",
    "Интеграл: ∫ x dx = x^2/2 + C",
    "∑ (n=1..∞) 1/n^2 = π^2/6",
], size: CGSize(width: 1600, height: 1200), font: handFont(46), paper: paper, ink: ink, ruled: true,
   to: outDir.appendingPathComponent("math-page.png"))

// PDF слайдов с текстовым слоем (3 страницы, 16:9).
let pdfURL = outDir.appendingPathComponent("slides.pdf")
var mediaBox = CGRect(x: 0, y: 0, width: 960, height: 540)
let ctx = CGContext(pdfURL as CFURL, mediaBox: &mediaBox, nil)!
let slides: [(String, [String])] = [
    ("Окислительно-восстановительные реакции", ["Лекция 5", "Общая и неорганическая химия"]),
    ("Основные понятия", ["• Окислитель — принимает электроны", "• Восстановитель — отдаёт электроны", "• Степень окисления — условный заряд атома"]),
    ("Спасибо за внимание!", []),
]
for (title, bullets) in slides {
    ctx.beginPDFPage(nil)
    let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ns
    (title as NSString).draw(at: NSPoint(x: 60, y: 440), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 34)])
    var y: CGFloat = 360
    for b in bullets { (b as NSString).draw(at: NSPoint(x: 80, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: 24)]); y -= 50 }
    NSGraphicsContext.restoreGraphicsState()
    ctx.endPDFPage()
}
ctx.closePDF()
print("Готово: \(outDir.path)")
