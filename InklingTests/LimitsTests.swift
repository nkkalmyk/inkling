import Foundation
import Testing
@testable import Inkling

@Suite("Лимиты и окружение")
struct LimitsTests {
    @Test func environmentDropsForeignSecretsButKeepsEssentials() {
        let base = ["HOME": "/Users/x", "LANG": "ru_RU.UTF-8", "PATH": "/usr/bin", "AWS_SECRET_ACCESS_KEY": "a",
                    "GITHUB_TOKEN": "b", "MY_SERVICE_TOKEN": "c", "ANTHROPIC_API_KEY": "d", "HTTPS_PROXY": "http://p"]
        let env = ClaudeCodeEngine.environment(base: base, extraPath: [])
        #expect(env["HOME"] == "/Users/x")
        #expect(env["LANG"] == "ru_RU.UTF-8")
        #expect(env["HTTPS_PROXY"] == "http://p")
        for key in ["AWS_SECRET_ACCESS_KEY", "GITHUB_TOKEN", "MY_SERVICE_TOKEN", "ANTHROPIC_API_KEY"] {
            #expect(env[key] == nil, "\(key)")
        }
    }

    @Test func hugeProcessOutputIsCappedAndProcessStillFinishes() async throws {
        // ~40 МБ в stdout: больше потолка 32 МБ, но процесс не должен зависнуть.
        let output = try await ProcessRunner.run(
            executable: "/usr/bin/head", arguments: ["-c", "41943040", "/dev/zero"],
            environment: ["PATH": "/usr/bin:/bin"], workingDirectory: NSTemporaryDirectory(),
            stdin: Data(), timeout: 60)
        #expect(output.exitCode == 0)
        #expect(output.stdout.count == 32 * 1024 * 1024)
    }
}
