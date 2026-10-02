import Foundation
import Testing
@testable import UsageCore

struct ProcessRunnerTests {
    let runner = FoundationProcessRunner()

    @Test func returnsExitStatus() async throws {
        let status = try await runner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 3"],
                                          environment: [:], timeout: 5)
        #expect(status == 3)
    }

    @Test func passesEnvironment() async throws {
        let status = try await runner.run(executable: URL(fileURLWithPath: "/bin/sh"),
                                          arguments: ["-c", "test \"$CLAUDE_CONFIG_DIR\" = /tmp/x"],
                                          environment: ["CLAUDE_CONFIG_DIR": "/tmp/x"], timeout: 5)
        #expect(status == 0)
    }

    @Test func timesOut() async {
        let started = Date()
        await #expect(throws: ProcessRunnerError.timedOut) {
            _ = try await runner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"],
                                     environment: [:], timeout: 0.3)
        }
        #expect(Date().timeIntervalSince(started) < 3)
    }

    @Test func cancellationTerminatesTheProcess() async {
        let started = Date()
        let task = Task {
            try await runner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"],
                                 environment: [:], timeout: 10)
        }
        try? await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(Date().timeIntervalSince(started) < 3)
    }

    @Test func cancelBeforeLaunchStillCancels() async {
        let started = Date()
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await runner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"],
                                        environment: [:], timeout: 10)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(Date().timeIntervalSince(started) < 1)
    }

    @Test func killsAChildThatIgnoresSIGTERM() async {
        let started = Date()
        await #expect(throws: ProcessRunnerError.timedOut) {
            _ = try await runner.run(executable: URL(fileURLWithPath: "/bin/sh"),
                                     arguments: ["-c", "trap '' TERM; sleep 10"], environment: [:], timeout: 0.3)
        }
        #expect(Date().timeIntervalSince(started) < 5)
    }
}

struct ShellEnvironmentTests {
    func script(_ body: String, in dir: TempDir) throws -> String {
        let url = dir.file("fake-shell")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    @Test func ignoresBannersAndBackgroundedHelpers() throws {
        let dir = try TempDir()
        let shell = try script("echo banner; sleep 30 &\nprintf '__CU_PATH__:%s:__CU_END__' /x/bin:/y/bin; echo bye", in: dir)
        let started = Date()
        #expect(ShellEnvironment.loginPATH(shell: shell) == "/x/bin:/y/bin")
        #expect(Date().timeIntervalSince(started) < 4)
    }

    @Test func slowShellGivesNil() throws {
        let dir = try TempDir()
        let shell = try script("sleep 30", in: dir)
        let started = Date()
        #expect(ShellEnvironment.loginPATH(shell: shell, timeout: 0.5) == nil)
        #expect(Date().timeIntervalSince(started) < 4)
    }
}
