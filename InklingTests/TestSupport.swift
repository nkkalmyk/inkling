import Foundation
@testable import Inkling

/// Временная папка, которая удаляется вместе с объектом.
final class TempDir {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("InklingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func contents(of relative: String = "") -> [String] {
        let dir = relative.isEmpty ? url : url.appendingPathComponent(relative)
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }
}

/// «Корзина» для тестов: переносит папку в отдельный каталог, не трогая настоящую корзину.
final class FakeTrasher: Trasher, @unchecked Sendable {
    let bin: URL
    private(set) var trashed: [String] = []

    init(bin: URL) throws {
        self.bin = bin
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    }

    func trash(_ url: URL) throws {
        trashed.append(url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: bin.appendingPathComponent(UUID().uuidString))
    }
}

extension CalendarDate {
    static func d(_ s: String) -> CalendarDate { CalendarDate(string: s)! }
}
