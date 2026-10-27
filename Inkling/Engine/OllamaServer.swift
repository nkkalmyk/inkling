import Foundation

/// Сервер Ollama для локального движка (SPEC, раздел 13, этап 8): если сервер не отвечает, запускает `ollama serve`
/// и при выходе из приложения гасит только тот сервер, который запустил сам. Заодно пропускает к модели
/// по одному запросу за раз.
actor OllamaServer {
    static let shared = OllamaServer()

    struct Status: Sendable, Equatable {
        var version: String?
        var binaryPath: String?
        var source: String?
    }

    /// Процесс, запущенный приложением. Доступен без актора: его гасят синхронно при завершении приложения.
    private final class Owned: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?

        var current: Process? { lock.withLock { process } }
        func set(_ value: Process?) { lock.withLock { process = value } }
    }

    private let owned = Owned()
    private let locator: BinaryLocator
    private let startupTimeout: TimeInterval
    private var starting: Task<Status, Never>?
    private var startError: AIError?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Журнал `ollama serve`, запущенного приложением: из него берётся текст ошибки, если сервер не поднялся.
    static let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("Inkling-ollama.log")

    init(locator: BinaryLocator = .live, startupTimeout: TimeInterval = 20) {
        self.locator = locator
        self.startupTimeout = startupTimeout
    }

    // MARK: Запуск

    @discardableResult
    func ensureRunning(manualPath: String?, baseURL: URL,
                       transport: @escaping OllamaEngine.Transport) async throws(AIError) -> Status {
        if let version = await Self.version(baseURL: baseURL, transport: transport) {
            return Status(version: version, binaryPath: owned.current?.executableURL?.path,
                          source: owned.current == nil ? "сервер уже запущен" : "запущен приложением")
        }
        if starting == nil {
            startError = nil
            starting = Task { await self.start(manualPath: manualPath, baseURL: baseURL, transport: transport) }
        }
        let status = await starting!.value
        starting = nil
        if let startError { throw startError }
        return status
    }

    private func start(manualPath: String?, baseURL: URL, transport: @escaping OllamaEngine.Transport) async -> Status {
        let located: BinaryLocator.Located
        do {
            located = try await locator.locate("ollama", manualPath: manualPath)
        } catch {
            startError = .ollamaUnavailable(error.message)
            return Status()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: located.path)
        process.arguments = ["serve"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (located.extraPath + [env["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        env["OLLAMA_HOST"] = baseURL.host.map { "\($0):\(baseURL.port ?? 11434)" }
        // Одна модель в памяти и один запрос за раз: на 16 ГБ больше не помещается.
        env["OLLAMA_MAX_LOADED_MODELS"] = "1"
        env["OLLAMA_NUM_PARALLEL"] = "1"
        env["OLLAMA_FLASH_ATTENTION"] = "1"
        env["OLLAMA_KV_CACHE_TYPE"] = "q8_0"
        process.environment = env
        FileManager.default.createFile(atPath: Self.logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        if let log = try? FileHandle(forWritingTo: Self.logURL) {
            process.standardOutput = log
            process.standardError = log
        }
        do {
            try process.run()
        } catch {
            startError = .ollamaUnavailable("Не удалось запустить \(located.path) serve: \(error.localizedDescription)")
            return Status()
        }
        owned.set(process)
        try? "\(process.processIdentifier)".write(to: Self.pidURL, atomically: true, encoding: .utf8)

        let deadline = Date().addingTimeInterval(startupTimeout)
        while Date() < deadline {
            if let version = await Self.version(baseURL: baseURL, transport: transport) {
                return Status(version: version, binaryPath: located.path, source: located.source.rawValue)
            }
            if !process.isRunning { break }
            try? await Task.sleep(for: .milliseconds(300))
        }
        if process.isRunning { process.terminate() }
        owned.set(nil)
        try? FileManager.default.removeItem(at: Self.pidURL)
        let log = (try? String(contentsOf: Self.logURL, encoding: .utf8)) ?? ""
        startError = .ollamaUnavailable("ollama serve не ответил за \(Int(startupTimeout)) с.\n" + String(log.suffix(2000)))
        return Status()
    }

    /// Версия сервера, если он отвечает.
    static func version(baseURL: URL, transport: @escaping OllamaEngine.Transport) async -> String? {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/version"))
        request.timeoutInterval = 2
        guard let (data, status) = try? await OllamaEngine.send(request, timeout: 3, transport: transport),
              status == 200 else { return nil }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return json?["version"] as? String ?? ""
    }

    /// Гасит сервер, если его запустило приложение. Вызывается при завершении приложения.
    nonisolated func stopIfOwned() {
        guard let process = owned.current, process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning, Date() < deadline { usleep(50_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        owned.set(nil)
        try? FileManager.default.removeItem(at: Self.pidURL)
    }

    /// PID сервера, запущенного приложением. Если приложение упало или было убито, сервер (~9 ГБ памяти) остаётся
    /// в системе; при следующем запуске по этому файлу он находится и гасится.
    static let pidURL = FileManager.default.temporaryDirectory.appendingPathComponent("Inkling-ollama.pid")

    /// Гасит сервер, оставшийся от прошлого запуска. Трогает только процесс с PID из файла и только если его
    /// исполняемый файл называется `executableName`: переиспользованный системой PID чужого процесса не пострадает.
    /// Возвращает `true`, если процесс был найден и ему отправлен сигнал.
    @discardableResult
    nonisolated static func reapOrphan(pidFile: URL = pidURL, executableName: String = "ollama") -> Bool {
        defer { try? FileManager.default.removeItem(at: pidFile) }
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return false }
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = Int(proc_pidpath(pid, &buffer, UInt32(buffer.count)))
        guard length > 0,
              URL(fileURLWithPath: String(decoding: buffer.prefix(length), as: UTF8.self)).lastPathComponent == executableName
        else { return false }
        return kill(pid, SIGTERM) == 0
    }

    // MARK: Один запрос за раз

    func exclusively<T: Sendable>(_ body: @Sendable () async throws(AIError) -> T) async throws(AIError) -> T {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
        defer {
            if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
        }
        if Task.isCancelled { throw .cancelled }
        return try await body()
    }
}
