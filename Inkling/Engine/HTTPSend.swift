import Foundation

/// Отправка HTTP-запроса движка (Ollama, Gemini) со своим таймаутом и переводом отмены и таймаута в `AIError`.
/// Остальные ошибки сети каждый движок называет по-своему (`networkError`).
enum HTTPSend {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static func send(_ request: URLRequest, timeout: TimeInterval, transport: @escaping Transport,
                     networkError: (any Error) -> AIError) async throws(AIError) -> (Data, Int) {
        do {
            return try await withThrowingTaskGroup(of: (Data, Int).self) { group in
                group.addTask {
                    let (data, response) = try await transport(request)
                    return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    throw AIError.timeout
                }
                defer { group.cancelAll() }
                // В группе две задачи, и первая же завершившаяся даёт ответ или ошибку.
                guard let first = try await group.next() else { throw AIError.timeout }
                return first
            }
        } catch let error as AIError {
            throw error
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled || error is CancellationError { throw .cancelled }
            if (error as? URLError)?.code == .timedOut { throw .timeout }
            throw networkError(error)
        }
    }
}
