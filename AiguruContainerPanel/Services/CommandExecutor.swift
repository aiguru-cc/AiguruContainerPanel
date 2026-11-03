//
//  CommandExecutor.swift
//  AiguruContainerPanel
//
//  命令执行器，支持重试、超时、流式输出、多环境。
//  普通执行与 sudo 执行共用同一进程执行核心 runProcess：
//  - stdout/stderr 在进程运行期间并发排水，避免大输出（>64KB）填满管道缓冲导致进程阻塞 write 死锁
//  - stdin（含 sudo 密码）在 process.run() 之后再写入，避免与进程启动竞争
//  - 超时统一通过 waitForExit 处理（终止进程并抛错）
//

import Foundation

// MARK: - 错误定义
enum ContainerError: Error, LocalizedError {
    case commandFailed(String)
    case xpcTimeout(String)
    case networkTimeout(String)
    case invalidOutput
    case retryExhausted(String)

    var isRetryable: Bool {
        switch self {
        case .xpcTimeout, .networkTimeout:
            return true
        default:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .commandFailed(let msg): return "命令失败: \(msg)"
        case .xpcTimeout(let msg): return "XPC 超时: \(msg)"
        case .networkTimeout(let msg): return "网络超时: \(msg)"
        case .invalidOutput: return "无效的输出格式"
        case .retryExhausted(let msg): return "重试耗尽: \(msg)"
        }
    }
}

// MARK: - 命令执行器
class CommandExecutor {
    static let shared = CommandExecutor()
    private init() {}

    var environment: ContainerEnvironment? {
        didSet {
            cliPath = environment?.resolvedCliPath ?? AppConstants.CLI.executablePath
        }
    }

    private var cliPath = AppConstants.CLI.executablePath
    /// 当前生效的 CLI 路径（供 sudo 等外部进程使用）
    var currentCliPath: String { cliPath }
    var commandUpdateHandler: ((String) -> Void)?
    private let maxRetries = AppConstants.Retry.maximumAttempts

    /// 记录执行器是否主动因超时终止了子进程。Process 在收到 SIGTERM 后通常以
    /// 143 退出；没有这个标记时，该状态会被误报为 CLI 自己返回的业务失败。
    private final class TimeoutState: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func markTimedOut() {
            lock.lock(); defer { lock.unlock() }
            value = true
        }

        var didTimeout: Bool {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }

    private func retryDelay(attempt: Int) -> UInt64 {
        AppConstants.Retry.initialDelayNanoseconds * UInt64(pow(2.0, Double(attempt)))
    }

    private func classifyError(_ message: String) -> ContainerError {
        let lower = message.lowercased()
        if lower.contains("xpc") || lower.contains("connection invalid") || lower.contains("connection interrupted") {
            return .xpcTimeout(message)
        }
        if lower.contains("timeout") || lower.contains("timed out") || lower.contains("超时") {
            if lower.contains("download") || lower.contains("pull") || lower.contains("fetch") || lower.contains("resolve") {
                return .networkTimeout(message)
            }
            return .xpcTimeout(message)
        }
        if lower.contains("network") || lower.contains("dns") || lower.contains("resolve") ||
            lower.contains("connection refused") || lower.contains("no route") {
            return .networkTimeout(message)
        }
        return .commandFailed(message)
    }

    // MARK: - 进程执行结果

    private struct ProcessResult {
        let output: String
        let errorOutput: String
        let exitCode: Int32
        let terminationReason: Process.TerminationReason

        /// stdout 与 stderr 合并，优先展示 stderr（错误信息通常在这里）
        var combinedOutput: String {
            let err = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            let out = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if err.isEmpty { return out }
            if out.isEmpty { return err }
            return err + "\n[stdout] " + out
        }

        var failureDescription: String {
            let combined = combinedOutput
            if !combined.isEmpty { return combined }
            let reason = terminationReason == .uncaughtSignal ? "signal" : "exit"
            return "命令无输出，termination=\(reason)，status=\(exitCode)"
        }
    }

    // MARK: - 核心进程执行（普通 / 系统命令 / sudo 共用）

    /// 启动进程，并发排水 stdout/stderr，等待退出或超时。
    /// stdinData（如 sudo 密码）在 run() 之后写入，避免与进程启动竞争。
    private func runProcess(
        executable: String,
        arguments: [String],
        environment: [String: String]?,
        timeout: TimeInterval,
        progressHandler: ((String) -> Void)?,
        stdinData: Data?
    ) async throws -> ProcessResult {
        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        process.standardOutput = outPipe
        process.standardError = errPipe

        let stdinPipe: Pipe?
        if stdinData != nil {
            stdinPipe = Pipe()
            process.standardInput = stdinPipe
        } else {
            stdinPipe = nil
            // 后台 CLI 没有可交互终端。显式发送 EOF，避免子命令出现确认提示时
            // 继承应用进程的输入源并永久等待；需要交互响应的调用方必须传 stdinData。
            process.standardInput = FileHandle.nullDevice
        }

        let fullCommand = executable + " " + arguments.joined(separator: " ")
        commandUpdateHandler?(fullCommand)
        print("[执行] \(fullCommand)")

        do {
            try process.run()
        } catch {
            throw ContainerError.commandFailed(
                "无法启动 CLI：\(executable)；\(error.localizedDescription)"
            )
        }

        // run 之后再写入 stdin（密码等），避免与进程启动竞争
        if let stdinPipe, let stdinData {
            stdinPipe.fileHandleForWriting.write(stdinData)
            stdinPipe.fileHandleForWriting.closeFile()
        }

        let outputCollector = OutputCollector()

        if let handler = progressHandler {
            // 流式模式：逐行转发（用于镜像拉取等大输出任务）
            let outputTask = Task {
                for try await line in outPipe.fileHandleForReading.bytes.lines {
                    await outputCollector.appendOutput(line)
                    handler(line)
                }
            }
            let errorTask = Task {
                for try await line in errPipe.fileHandleForReading.bytes.lines {
                    await outputCollector.appendError(line)
                    handler("[stderr] \(line)")
                }
            }

            try await waitForExit(process, timeout: timeout)

            // 给异步 reader 充足时间消费管道缓冲区
            try? await Task.sleep(nanoseconds: 500_000_000)
            outputTask.cancel()
            errorTask.cancel()

            // 兜底：读取管道残留数据
            let outHandle = outPipe.fileHandleForReading
            let errHandle = errPipe.fileHandleForReading
            let remainingOut = (try? outHandle.readToEnd()).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let remainingErr = (try? errHandle.readToEnd()).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            if !remainingOut.isEmpty { await outputCollector.appendOutput(remainingOut) }
            if !remainingErr.isEmpty { await outputCollector.appendError(remainingErr) }

            return ProcessResult(
                output: await outputCollector.getOutput(),
                errorOutput: await outputCollector.getError(),
                exitCode: process.terminationStatus,
                terminationReason: process.terminationReason
            )
        } else {
            // 并发排水模式：进程运行期间持续读取，避免管道缓冲（64KB）填满导致进程阻塞 write
            let outHandle = outPipe.fileHandleForReading
            let errHandle = errPipe.fileHandleForReading
            let outTask = Task.detached(priority: .utility) { outHandle.readDataToEndOfFile() }
            let errTask = Task.detached(priority: .utility) { errHandle.readDataToEndOfFile() }

            try await waitForExit(process, timeout: timeout)

            let outData = await outTask.value
            let errData = await errTask.value
            return ProcessResult(
                output: String(data: outData, encoding: .utf8) ?? "",
                errorOutput: String(data: errData, encoding: .utf8) ?? "",
                exitCode: process.terminationStatus,
                terminationReason: process.terminationReason
            )
        }
    }

    /// 等待进程退出；超时则终止进程并抛错。
    private func waitForExit(_ process: Process, timeout: TimeInterval) async throws {
        let timeoutState = TimeoutState()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { process.waitUntilExit() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                timeoutState.markTimedOut()
                process.terminate()
                try await Task.sleep(nanoseconds: AppConstants.Time.processTerminationGracePeriod)
                throw ContainerError.commandFailed("命令执行超时 (\(Int(timeout))s)")
            }
            try await group.next()!
            group.cancelAll()
        }
        if timeoutState.didTimeout {
            throw ContainerError.commandFailed("命令执行超时 (\(Int(timeout))s)")
        }
    }

    private func getEnvironmentVariables() -> [String: String] {
        guard let env = environment else {
            return ProcessInfo.processInfo.environment
        }
        return env.buildEnvironment()
    }

    // MARK: - 公开：普通执行（container CLI）

    func execute(
        _ arguments: [String],
        timeout: TimeInterval? = nil,
        progressHandler: ((String) -> Void)? = nil,
        stdinData: Data? = nil
    ) async throws -> String {
        // 流式任务默认超时提升至 1 小时（大镜像拉取），普通任务保持短超时
        let actualTimeout = timeout ?? (progressHandler != nil
            ? AppConstants.Time.streamingCommandTimeout
            : AppConstants.Time.shortCommandTimeout)
        var lastError: Error?

        for attempt in 0..<maxRetries {
            do {
                let result = try await runProcess(
                    executable: cliPath,
                    arguments: arguments,
                    environment: getEnvironmentVariables(),
                    timeout: actualTimeout,
                    progressHandler: progressHandler,
                    stdinData: stdinData
                )
                if result.exitCode == 0 {
                    return result.output
                }
                throw classifyError(result.failureDescription)
            } catch let error as ContainerError {
                lastError = error
                if !error.isRetryable || attempt == maxRetries - 1 {
                    if attempt > 0 {
                        throw ContainerError.retryExhausted(error.errorDescription ?? "\(error)")
                    }
                    throw error
                }
                let delay = retryDelay(attempt: attempt)
                print("⚠️ 命令失败 (尝试 \(attempt + 1)/\(maxRetries)): \(error.errorDescription ?? "\(error)")，\(Int(delay / 1_000_000_000))s 后重试...")
                try await Task.sleep(nanoseconds: delay)
            } catch {
                // 未分类错误通常是配置或编程错误，重试不会改变结果
                throw error
            }
        }
        throw lastError ?? ContainerError.commandFailed("未知错误")
    }

    /// 在指定工作环境快照中执行。长流程使用该入口，避免用户切换环境后
    /// 后续子命令意外落到另一个 CLI、HOME 或数据目录。
    func execute(
        _ arguments: [String],
        in environment: ContainerEnvironment,
        timeout: TimeInterval? = nil,
        progressHandler: ((String) -> Void)? = nil
    ) async throws -> String {
        let actualTimeout = timeout ?? (progressHandler != nil
            ? AppConstants.Time.streamingCommandTimeout
            : AppConstants.Time.shortCommandTimeout)
        var lastError: Error?

        for attempt in 0..<maxRetries {
            do {
                let result = try await runProcess(
                    executable: environment.resolvedCliPath,
                    arguments: arguments,
                    environment: environment.buildEnvironment(),
                    timeout: actualTimeout,
                    progressHandler: progressHandler,
                    stdinData: nil
                )
                if result.exitCode == 0 { return result.output }
                throw classifyError(result.failureDescription)
            } catch let error as ContainerError {
                lastError = error
                if !error.isRetryable || attempt == maxRetries - 1 {
                    if attempt > 0 {
                        throw ContainerError.retryExhausted(error.errorDescription ?? "\(error)")
                    }
                    throw error
                }
                try await Task.sleep(nanoseconds: retryDelay(attempt: attempt))
            } catch {
                throw error
            }
        }
        throw lastError ?? ContainerError.commandFailed("未知错误")
    }

    // MARK: - 公开：任意系统命令（不经过 container CLI）

    func executeSystemCommand(arguments: [String]) async throws -> String {
        guard let executable = arguments.first else {
            throw ContainerError.invalidOutput
        }
        let result = try await runProcess(
            executable: executable,
            arguments: Array(arguments.dropFirst()),
            environment: nil,
            timeout: AppConstants.Time.shortCommandTimeout,
            progressHandler: nil,
            stdinData: nil
        )
        guard result.exitCode == 0 else {
            throw ContainerError.commandFailed(result.failureDescription)
        }
        return result.output
    }

    // MARK: - 公开：sudo 执行

    /// 通过 `sudo -S` 执行命令。密码错误与命令失败会返回明确区分的错误信息。
    /// 不附加 `-k`：若 sudo 存在有效的 timestamp 缓存（如用户刚在终端输过密码），会直接执行；
    /// 否则从 stdin 读取提供的密码验证。
    func executeSystemCommandWithSudo(
        _ arguments: [String],
        password: String,
        timeout: TimeInterval? = nil,
        stdinData: Data? = nil
    ) async throws -> String {
        let actualTimeout = timeout ?? AppConstants.Time.shortCommandTimeout
        // -p "" 抑制 "Password:" 提示混入输出；-S 从 stdin 读密码
        var input = (password + "\n").data(using: .utf8)!
        if let stdinData { input.append(stdinData) }
        let result = try await runProcess(
            executable: "/usr/bin/sudo",
            arguments: ["-S", "-p", ""] + arguments,
            environment: nil,
            timeout: actualTimeout,
            progressHandler: nil,
            stdinData: input
        )
        guard result.exitCode == 0 else {
            let combined = result.failureDescription
            let lower = combined.lowercased()
            if lower.contains("sorry, try again") || lower.contains("incorrect password") || lower.contains("no password was provided") {
                throw ContainerError.commandFailed("管理员密码验证失败：\(combined)")
            }
            throw ContainerError.commandFailed(combined.isEmpty ? "命令执行失败 (status \(result.exitCode))" : combined)
        }
        return result.output
    }

    private actor OutputCollector {
        var output = ""
        var error = ""

        func appendOutput(_ line: String) {
            output.append(line + "\n")
        }

        func appendError(_ line: String) {
            error.append(line + "\n")
        }

        func getOutput() -> String { output }
        func getError() -> String { error }
    }
}
