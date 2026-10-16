import Darwin
import Foundation

/// Запуск внешнего процесса в собственной группе процессов (SPEC, раздел 2.5).
/// При таймауте или отмене вся группа получает SIGTERM, через `killGrace` секунд — SIGKILL:
/// node и CLI порождают дочерние процессы, и убить нужно всех.
enum ProcessRunner {
    struct Output: Sendable, Equatable {
        var exitCode: Int32
        var stdout: Data
        var stderr: Data
        /// Сигнал, которым завершён процесс, если он завершён сигналом.
        var signal: Int32?

        var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
        var stderrText: String { String(decoding: stderr, as: UTF8.self) }
    }

    enum Failure: Error, Sendable {
        case launchFailed(String)
        case timedOut(Output)
        case cancelled(Output)
    }

    static func run(executable: String, arguments: [String], environment: [String: String],
                    workingDirectory: String, stdin: Data? = nil, timeout: TimeInterval,
                    killGrace: TimeInterval = 3) async throws(Failure) -> Output {
        ignoreSIGPIPE
        let child: SpawnedChild
        do {
            child = try SpawnedChild(executable: executable, arguments: [executable] + arguments,
                                     environment: environment, workingDirectory: workingDirectory)
        } catch {
            throw .launchFailed(error.message)
        }
        let control = KillControl(pid: child.pid, grace: killGrace)

        child.feedStdin(stdin)
        let readers = child.startReaders()

        let outcome: (status: Int32, reason: KillControl.Reason?) = await withTaskCancellationHandler {
            let timer = Task.detached {
                try? await Task.sleep(for: .seconds(timeout))
                if !Task.isCancelled { control.kill(.timeout) }
            }
            let status = await child.waitForExit()
            control.markExited()
            timer.cancel()
            return (status, control.reason)
        } onCancel: {
            control.kill(.cancelled)
        }

        // Внуки могут держать трубы открытыми: даём читателям немного времени, потом добиваем группу.
        if await !readers.finished(within: 2) {
            control.killGroupNow()
            _ = await readers.finished(within: 5)
        }
        if outcome.reason != nil { control.killGroupNow() }

        let status = outcome.status
        let signal = status & 0x7f
        let output = Output(exitCode: signal == 0 ? (status >> 8) & 0xff : 128 + signal,
                            stdout: readers.stdout.data, stderr: readers.stderr.data,
                            signal: signal == 0 ? nil : signal)
        switch outcome.reason {
        case .timeout: throw .timedOut(output)
        case .cancelled: throw .cancelled(output)
        case nil: return output
        }
    }

    private static let ignoreSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN) }()
}

// MARK: Запуск

private struct SpawnError: Error {
    let message: String
}

private final class SpawnedChild: @unchecked Sendable {
    let pid: pid_t
    private let stdinFD: Int32
    private let stdoutFD: Int32
    private let stderrFD: Int32

    init(executable: String, arguments: [String], environment: [String: String], workingDirectory: String) throws {
        var inPipe: [Int32] = [0, 0], outPipe: [Int32] = [0, 0], errPipe: [Int32] = [0, 0]
        guard pipe(&inPipe) == 0, pipe(&outPipe) == 0, pipe(&errPipe) == 0 else {
            throw SpawnError(message: "Не удалось создать каналы: \(String(cString: strerror(errno)))")
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, inPipe[0], 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        posix_spawn_file_actions_addchdir(&actions, workingDirectory)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Своя группа процессов; в ребёнка не утекают дескрипторы приложения; сигналы по умолчанию.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
                                                    | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        sigaddset(&defaults, SIGPIPE)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)

        let argv = arguments.map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        close(inPipe[0])
        close(outPipe[1])
        close(errPipe[1])
        guard rc == 0 else {
            close(inPipe[1])
            close(outPipe[0])
            close(errPipe[0])
            throw SpawnError(message: "\(executable): \(String(cString: strerror(rc)))")
        }
        self.pid = pid
        stdinFD = inPipe[1]
        stdoutFD = outPipe[0]
        stderrFD = errPipe[0]
    }

    func feedStdin(_ data: Data?) {
        let fd = stdinFD
        guard let data, !data.isEmpty else {
            close(fd)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let n = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                    if n > 0 { offset += n } else if n < 0 && errno == EINTR { continue } else { break }
                }
            }
            close(fd)
        }
    }

    func startReaders() -> Readers {
        let readers = Readers()
        readers.drain(stdoutFD, into: readers.stdout)
        readers.drain(stderrFD, into: readers.stderr)
        return readers
    }

    func waitForExit() async -> Int32 {
        let pid = pid
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var status: Int32 = 0
                while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
                continuation.resume(returning: status)
            }
        }
    }
}

private final class Readers: @unchecked Sendable {
    let stdout = LockedBuffer()
    let stderr = LockedBuffer()
    private let group = DispatchGroup()

    func drain(_ fd: Int32, into buffer: LockedBuffer) {
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [group] in
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = read(fd, &chunk, chunk.count)
                if n > 0 { buffer.append(chunk[0..<n]) } else if n < 0 && errno == EINTR { continue } else { break }
            }
            close(fd)
            group.leave()
        }
    }

    func finished(within seconds: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [group] in
                continuation.resume(returning: group.wait(timeout: .now() + seconds) == .success)
            }
        }
    }
}

private final class LockedBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    /// Потолок объёма: лишнее отбрасывается, но канал читается дальше, чтобы процесс не завис на записи.
    static let limit = 32 * 1024 * 1024

    func append(_ bytes: ArraySlice<UInt8>) {
        lock.withLock {
            let room = max(Self.limit - storage.count, 0)
            storage.append(contentsOf: bytes.prefix(room))
        }
    }
    var data: Data { lock.withLock { storage } }
}

// MARK: Остановка группы

private final class KillControl: @unchecked Sendable {
    enum Reason { case timeout, cancelled }

    private let pid: pid_t
    private let grace: TimeInterval
    private let lock = NSLock()
    private var exited = false
    private(set) var reason: Reason? {
        get { lock.withLock { _reason } }
        set { lock.withLock { _reason = newValue } }
    }
    private var _reason: Reason?

    init(pid: pid_t, grace: TimeInterval) {
        self.pid = pid
        self.grace = grace
    }

    func markExited() { lock.withLock { exited = true } }

    /// SIGTERM всей группе, через `grace` секунд SIGKILL, если процесс ещё жив.
    func kill(_ why: Reason) {
        let first: Bool = lock.withLock {
            guard _reason == nil, !exited else { return false }
            _reason = why
            return true
        }
        guard first else { return }
        Darwin.kill(-pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [self] in
            if !lock.withLock({ exited }) { Darwin.kill(-pid, SIGKILL) }
        }
    }

    /// Добить оставшихся в группе (после выхода лидера или если трубы так и не закрылись).
    func killGroupNow() {
        Darwin.kill(-pid, SIGKILL)
    }
}

private extension Error {
    var message: String { (self as? SpawnError)?.message ?? localizedDescription }
}
