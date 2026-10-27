import Foundation

/// Делает ссылки внутри PDF понятными всем просмотрщикам. CoreGraphics пишет адрес ссылки отдельным объектом
/// (`/Dest 188 0 R`, а в нём `[страница /XYZ x y 0]`): это допустимо, на Mac работает, но просмотр в «Файлах»
/// на iPhone и в Google Диске такие ссылки игнорирует. Здесь адрес подставляется прямо в ссылку
/// (`/Dest [страница /XYZ x y 0]`), а таблица смещений объектов пересчитывается.
///
/// Рассчитан на PDF, который пишет `CGContext`: одна классическая таблица `xref`, без потоков объектов и без
/// дописанных обновлений. Файл другого устройства не меняется.
enum PDFLinkInliner {
    static func inline(_ url: URL) throws {
        if let rewritten = inline(try Data(contentsOf: url)) { try rewritten.write(to: url, options: .atomic) }
    }

    /// Новый файл или `nil`, если менять нечего или устройство файла незнакомо.
    static func inline(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard let table = XrefTable(bytes) else { return nil }

        // Правки: в каждой ссылке `/Dest N 0 R` заменяется содержимым объекта N, если это массив.
        var edits: [(start: Int, end: Int, replacement: [UInt8])] = []
        for offset in table.offsets.values {
            guard let link = table.body(at: offset, in: bytes), contains(bytes, "/Subtype /Link", in: link),
                  let dest = find(bytes, "/Dest ", in: link),
                  let reference = parseReference(bytes, at: dest.upperBound, before: link.upperBound),
                  let targetOffset = table.offsets[reference.number],
                  let target = table.body(at: targetOffset, in: bytes), bytes[target.lowerBound] == UInt8(ascii: "[") else { continue }
            let array = bytes[target].map { $0 == UInt8(ascii: "\n") ? UInt8(ascii: " ") : $0 }
            edits.append((dest.upperBound, reference.end, array))
        }
        guard !edits.isEmpty else { return nil }
        edits.sort { $0.start < $1.start }

        var output: [UInt8] = []
        output.reserveCapacity(bytes.count + edits.count * 48)
        var shifts: [(position: Int, delta: Int)] = []
        var cursor = 0
        for edit in edits {
            output += bytes[cursor..<edit.start]
            output += edit.replacement
            shifts.append((edit.start, edit.replacement.count - (edit.end - edit.start)))
            cursor = edit.end
        }
        output += bytes[cursor..<table.start]
        func moved(_ offset: Int) -> Int { offset + shifts.reduce(0) { $1.position < offset ? $0 + $1.delta : $0 } }

        let xrefStart = output.count
        var xref = "xref\n0 \(table.size)\n0000000000 65535 f \n"
        for number in 1..<table.size {
            xref += table.offsets[number].map { String(format: "%010d 00000 n \n", moved($0)) } ?? "0000000000 65535 f \n"
        }
        output += Array(xref.utf8) + table.trailer + Array("startxref\n\(xrefStart)\n%%EOF\n".utf8)
        return Data(output)
    }

    /// Таблица `xref` в конце файла: где начинается, смещения объектов и словарь `trailer` (байтами, как есть).
    private struct XrefTable {
        var start: Int
        var size = 0
        var offsets: [Int: Int] = [:]
        var trailer: [UInt8]

        init?(_ bytes: [UInt8]) {
            guard let startxref = PDFLinkInliner.lastIndex(of: "startxref", in: bytes),
                  let value = Int(String(decoding: bytes[startxref.upperBound...], as: UTF8.self)
                      .split(whereSeparator: \.isWhitespace).first ?? ""),
                  value < bytes.count else { return nil }
            let tail = String(decoding: bytes[value..<startxref.lowerBound], as: UTF8.self)
            // Потоки объектов и дописанные обновления этот разбор не поддерживает.
            guard tail.hasPrefix("xref"), let trailerRange = tail.range(of: "trailer"),
                  !PDFLinkInliner.contains(bytes, "/ObjStm", in: 0..<bytes.count),
                  PDFLinkInliner.count(of: "startxref", in: bytes) == 1 else { return nil }
            var lines = tail[tail.index(tail.startIndex, offsetBy: 4)..<trailerRange.lowerBound]
                .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.makeIterator()
            while let header = lines.next() {
                let parts = header.split(separator: " ")
                guard parts.count == 2, let first = Int(parts[0]), let count = Int(parts[1]) else { return nil }
                for number in first..<(first + count) {
                    guard let entry = lines.next() else { return nil }
                    let fields = entry.split(separator: " ")
                    guard fields.count == 3, let offset = Int(fields[0]) else { return nil }
                    if fields[2] == "n" { offsets[number] = offset }
                }
                size = max(size, first + count)
            }
            guard size > 0 else { return nil }
            start = value
            trailer = Array(tail[trailerRange.lowerBound...].utf8)
        }

        /// Содержимое объекта между `N 0 obj` и `endobj`, без пробелов по краям.
        func body(at offset: Int, in bytes: [UInt8]) -> Range<Int>? {
            guard offset < bytes.count, let obj = PDFLinkInliner.find(bytes, " obj", in: offset..<min(offset + 32, bytes.count)),
                  let end = PDFLinkInliner.find(bytes, "endobj", in: obj.upperBound..<bytes.count) else { return nil }
            var lower = obj.upperBound, upper = end.lowerBound
            while lower < upper, PDFLinkInliner.isSpace(bytes[lower]) { lower += 1 }
            while upper > lower, PDFLinkInliner.isSpace(bytes[upper - 1]) { upper -= 1 }
            return lower < upper ? lower..<upper : nil
        }
    }

    // MARK: Байтовые помощники

    private static func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 }

    private static func find(_ bytes: [UInt8], _ needle: String, in range: Range<Int>) -> Range<Int>? {
        let pattern = Array(needle.utf8)
        guard range.count >= pattern.count else { return nil }
        var index = range.lowerBound
        while index + pattern.count <= range.upperBound {
            if bytes[index] == pattern[0], bytes[index..<(index + pattern.count)].elementsEqual(pattern) {
                return index..<(index + pattern.count)
            }
            index += 1
        }
        return nil
    }

    private static func contains(_ bytes: [UInt8], _ needle: String, in range: Range<Int>) -> Bool {
        find(bytes, needle, in: range) != nil
    }

    private static func lastIndex(of needle: String, in bytes: [UInt8]) -> Range<Int>? {
        let pattern = Array(needle.utf8)
        var index = bytes.count - pattern.count
        while index >= 0 {
            if bytes[index] == pattern[0], bytes[index..<(index + pattern.count)].elementsEqual(pattern) {
                return index..<(index + pattern.count)
            }
            index -= 1
        }
        return nil
    }

    private static func count(of needle: String, in bytes: [UInt8]) -> Int {
        var total = 0, from = 0
        while let found = find(bytes, needle, in: from..<bytes.count) { total += 1; from = found.upperBound }
        return total
    }

    /// `N G R` начиная с `position`; номер объекта и конец записи.
    private static func parseReference(_ bytes: [UInt8], at position: Int, before limit: Int) -> (number: Int, end: Int)? {
        var index = position
        func number() -> Int? {
            let start = index
            while index < limit, (0x30...0x39).contains(bytes[index]) { index += 1 }
            return index > start ? Int(String(decoding: bytes[start..<index], as: UTF8.self)) : nil
        }
        guard let object = number(), index < limit, bytes[index] == 0x20 else { return nil }
        index += 1
        guard number() != nil, index + 1 < limit, bytes[index] == 0x20, bytes[index + 1] == UInt8(ascii: "R") else { return nil }
        return (object, index + 2)
    }
}
