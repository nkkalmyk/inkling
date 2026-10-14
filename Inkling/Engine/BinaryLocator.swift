import Foundation

/// Поиск CLI для GUI-приложения, которое не наследует PATH из шелла (SPEC, раздел 2.4).
/// Порядок: ручной путь из настроек → известные места → интерактивный zsh.
struct BinaryLocator: Sendable {
    struct Located: Sendable, Equatable {
        enum Source: String, Sendable {
            case manual = "указан вручную"
            case knownLocation = "автопоиск"
            case shell = "найден через zsh"
        }

        var path: String
        var source: Source
        /// Каталоги, которые нужно добавить в PATH процесса: каталог бинарника и, для node-скриптов, каталог node.
        var extraPath: [String]
    }

    enum Failure: Error, Equatable {
        case manualPathInvalid(String)
        case notFound(String)
        case nodeNotFound(String)

        var message: String {
            switch self {
            case .manualPathInvalid(let path): "Путь из настроек не ведёт к исполняемому файлу: \(path)"
            case .notFound(let name): "\(name) не найден ни в известных местах, ни через zsh."
            case .nodeNotFound(let path): "\(path) — скрипт node, но node не найден."
            }
        }
    }

    var home: String
    var isExecutable: @Sendable (String) -> Bool
    var contentsOfDirectory: @Sendable (String) -> [String]
    /// Первые байты файла, чтобы узнать node-скрипт по `#!/usr/bin/env node`.
    var fileHeader: @Sendable (String) -> String
    /// `command -v <имя>` в интерактивном login-шелле; `nil`, если не найдено.
    var shellLookup: @Sendable (String) async -> String?

    static let live = BinaryLocator(
        home: NSHomeDirectory(),
        isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
        contentsOfDirectory: { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] },
        fileHeader: { path in
            guard let handle = FileHandle(forReadingAtPath: path) else { return "" }
            defer { try? handle.close() }
            return String(decoding: (try? handle.read(upToCount: 128)) ?? Data(), as: UTF8.self)
        },
        shellLookup: { name in await ShellLookup.commandPath(name) })

    /// Известные места из SPEC 2.4. Версии nvm перебираются от новой к старой.
    func knownDirectories() -> [String] {
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin", "\(home)/.local/bin",
                    "\(home)/.claude/local"]
        let nvm = "\(home)/.nvm/versions/node"
        dirs += contentsOfDirectory(nvm)
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { "\(nvm)/\($0)/bin" }
        dirs += ["\(home)/.volta/bin", "\(home)/.bun/bin"]
        return dirs
    }

    func locate(_ name: String, manualPath: String?) async throws(Failure) -> Located {
        if let manual = manualPath?.trimmingCharacters(in: .whitespaces), !manual.isEmpty {
            let path = (manual as NSString).expandingTildeInPath
            guard isExecutable(path) else { throw .manualPathInvalid(path) }
            return try await withRuntime(path, source: .manual)
        }
        if let dir = knownDirectories().first(where: { isExecutable("\($0)/\(name)") }) {
            return try await withRuntime("\(dir)/\(name)", source: .knownLocation)
        }
        if let path = await shellLookup(name), path.hasPrefix("/"), isExecutable(path) {
            return try await withRuntime(path, source: .shell)
        }
        throw .notFound(name)
    }

    /// Для node-скриптов находит node и добавляет его каталог в PATH (иначе «env: node: No such file or directory»).
    private func withRuntime(_ path: String, source: Located.Source) async throws(Failure) -> Located {
        let dir = (path as NSString).deletingLastPathComponent
        var extra = [dir]
        let header = fileHeader(path)
        if header.hasPrefix("#!"), header.prefix(while: { $0 != "\n" }).contains("node") {
            if isExecutable("\(dir)/node") {
                // node рядом со скриптом: каталог уже в PATH.
            } else if let nodeDir = knownDirectories().first(where: { isExecutable("\($0)/node") }) {
                extra.append(nodeDir)
            } else if let node = await shellLookup("node"), isExecutable(node) {
                extra.append((node as NSString).deletingLastPathComponent)
            } else {
                throw .nodeNotFound(path)
            }
        }
        return Located(path: path, source: source, extraPath: extra)
    }
}

/// `command -v` через интерактивный zsh: `zsh -lc` не читает `.zshrc`, где обычно подключается nvm.
/// Вывод обрамляется маркерами, потому что интерактивный шелл может печатать мусор.
enum ShellLookup {
    static let begin = "__INKLING_BEGIN__"
    static let end = "__INKLING_END__"

    static func commandPath(_ name: String) async -> String? {
        guard name.allSatisfy({ $0.isLetter || $0.isNumber || "-_.".contains($0) }) else { return nil }
        let script = "echo \(begin); command -v \(name); echo \(end)"
        let output = try? await ProcessRunner.run(executable: "/bin/zsh", arguments: ["-ilc", script],
                                                  environment: ProcessInfo.processInfo.environment,
                                                  workingDirectory: NSHomeDirectory(), timeout: 10, killGrace: 1)
        return output.flatMap { parse($0.stdoutText) }
    }

    /// Берёт первую строку-путь между маркерами.
    static func parse(_ output: String) -> String? {
        guard let start = output.range(of: begin), let stop = output.range(of: end, range: start.upperBound..<output.endIndex)
        else { return nil }
        return output[start.upperBound..<stop.lowerBound]
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("/") }
    }
}
