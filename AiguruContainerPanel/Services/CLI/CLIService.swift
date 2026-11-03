//
//  CLIService.swift
//  AiguruContainerPanel
//
//  CLI 服务，封装 container 命令的执行。
//  内部委托给 CommandExecutor，提供重试、超时、流式输出。
//

import Foundation
import Combine

/// CLI 服务类
class CLIService: ObservableObject {
    static let shared = CLIService()
    private init() {}

    private let executor = CommandExecutor.shared
    private var cancellables = Set<AnyCancellable>()

    /// 设置当前环境（由 EnvironmentManager 调用）
    func setEnvironment(_ env: ContainerEnvironment?) {
        executor.environment = env
    }

    /// 设置命令更新回调
    func setCommandUpdateHandler(_ handler: @escaping (String) -> Void) {
        executor.commandUpdateHandler = handler
    }

    /// 执行命令
    func execute(
        command: String,
        mode: ExecutionMode,
        timeout: TimeInterval? = nil,
        onEvent: ((CLIStreamEvent) -> Void)? = nil
    ) -> AnyPublisher<CLIResult, Never> {
        var cleanCommand = command
        if cleanCommand.hasPrefix("container ") {
            cleanCommand = String(cleanCommand.dropFirst(10))
        }
        if cleanCommand.isEmpty {
            return Just(CLIResult(
                command: command,
                output: "无有效子命令",
                exitCode: -1,
                duration: 0,
                mode: mode
            )).eraseToAnyPublisher()
        }
        let args = cleanCommand.cliArguments()

        let startTime = Date()

        return Future<CLIResult, Never> { promise in
            Task {
                do {
                    if mode == .stream, let onEvent = onEvent {
                        let output = try await self.executor.execute(
                            args,
                            timeout: timeout,
                            progressHandler: { line in
                                onEvent(.output(line))
                            }
                        )
                        let duration = Date().timeIntervalSince(startTime)
                        let result = CLIResult(
                            command: command,
                            output: output,
                            exitCode: 0,
                            duration: duration,
                            mode: mode
                        )
                        onEvent(.completion(result))
                        promise(.success(result))
                    } else {
                        let output = try await self.executor.execute(args, timeout: timeout)
                        let duration = Date().timeIntervalSince(startTime)
                        let result = CLIResult(
                            command: command,
                            output: output,
                            exitCode: 0,
                            duration: duration,
                            mode: mode
                        )
                        promise(.success(result))
                    }
                } catch let error as ContainerError {
                    let duration = Date().timeIntervalSince(startTime)
                    let result = CLIResult(
                        command: command,
                        output: error.errorDescription ?? error.localizedDescription,
                        exitCode: -1,
                        duration: duration,
                        mode: mode
                    )
                    if mode == .stream, let onEvent = onEvent {
                        onEvent(.error(error.localizedDescription))
                        onEvent(.completion(result))
                    }
                    promise(.success(result))
                } catch {
                    let duration = Date().timeIntervalSince(startTime)
                    let result = CLIResult(
                        command: command,
                        output: error.localizedDescription,
                        exitCode: -1,
                        duration: duration,
                        mode: mode
                    )
                    if mode == .stream, let onEvent = onEvent {
                        onEvent(.error(error.localizedDescription))
                        onEvent(.completion(result))
                    }
                    promise(.success(result))
                }
            }
        }
        .eraseToAnyPublisher()
    }
}

// MARK: - 镜像管理
extension CLIService {
    /// 获取本地镜像列表
    func fetchLocalImages() async -> [LocalImage] {
        let command = "image list --format json"
        let result = await withCheckedContinuation { continuation in
            execute(command: command, mode: .async)
                .sink { result in
                    continuation.resume(returning: result)
                }
                .store(in: &cancellables)
        }
        guard result.succeeded else { return [] }
        guard let data = result.output.data(using: .utf8) else { return [] }
        do {
            let images = try JSONDecoder().decode([LocalImage].self, from: data)
            return images
        } catch {
            print("解析本地镜像列表失败: \(error)")
            return []
        }
    }
}

// MARK: - 命令构建
extension CLIService {
    
    /// 构建 container run 命令字符串
    /// - Parameter options: 容器运行选项
    /// - Parameter image: 镜像名称（含标签）
    /// - Parameter name: 容器名称（可选）
    /// - Parameter ports: 端口映射数组
    /// - Parameter env: 环境变量数组
    /// - Parameter volumes: 卷挂载数组
    /// - Returns: 完整的命令字符串
    func buildRunCommand(
        image: String,
        name: String = "",
        ports: [String] = [],
        env: [String] = [],
        volumes: [String] = [],
        options: ContainerRunOptions
    ) -> String {
        ContainerCommandBuilder.displayCommand(for: ContainerCommandBuilder.runArguments(
            image: image,
            name: name,
            ports: ports,
            environment: env,
            volumes: volumes,
            options: options
        ))
    }

}
