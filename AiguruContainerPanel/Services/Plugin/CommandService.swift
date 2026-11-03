//
//  CommandService.swift
//  AiguruContainerPanel
//
//  通用命令执行服务（C ABI 协议）：供外挂插件通过 dlopen 注入执行容器/机器 CLI。
//  插件自身不做进程调用（安全审查限制），统一由主 App 的 CommandExecutor 执行。
//
//  注入机制：PluginManager.loadPluginDylib 探测可选符号
//  acp_plugin_set_command_service，存在则传入本服务表（向后兼容旧插件）。
//

import Foundation
import Darwin

// MARK: - C ABI 服务表（V1）

/// 命令执行服务协议（C 结构，主 App 与插件各自独立定义，布局一致）
struct CommandServiceV1 {
    /// 执行命令：executable(如 "container") + 参数数组，返回 stdout+stderr 文本（strdup，用 releaseString 释放）
    var execute: (@convention(c) (UnsafePointer<CChar>?, UnsafePointer<UnsafePointer<CChar>?>?, Int32) -> UnsafeMutablePointer<CChar>?)?
    /// 释放 strdup 分配的字符串
    var releaseString: (@convention(c) (UnsafeMutablePointer<CChar>?) -> Void)?
}

// MARK: - 实现

private func csStrdup(_ s: String) -> UnsafeMutablePointer<CChar>? {
    s.withCString { strdup($0) }
}

private func csExecute(_ executablePtr: UnsafePointer<CChar>?, _ argv: UnsafePointer<UnsafePointer<CChar>?>?, _ argc: Int32) -> UnsafeMutablePointer<CChar>? {
    guard let executablePtr, let argv else { return csStrdup("错误: 参数无效") }
    let executable = String(cString: executablePtr)
    var args: [String] = []
    for i in 0..<max(Int(argc), 0) {
        if let p = argv[i] { args.append(String(cString: p)) }
    }
    guard executable == "container" else {
        return csStrdup("错误: 仅允许执行 container 命令")
    }

    // CommandExecutor 为 async；用 detached 任务在后台执行，主线程 semaphore 等待（不会死锁）
    let executor = CommandExecutor.shared
    let semaphore = DispatchSemaphore(value: 0)
    var output = "错误: 命令执行超时"
    Task.detached(priority: .userInitiated) {
        do {
            output = try await executor.execute(args)
        } catch {
            output = "错误: \(error.localizedDescription)"
        }
        semaphore.signal()
    }
    semaphore.wait()
    return csStrdup(output)
}

private func csRelease(_ ptr: UnsafeMutablePointer<CChar>?) {
    if let ptr { free(ptr) }
}

/// 全局命令服务表（生命周期 = App 进程）
let commandServiceV1 = CommandServiceV1(
    execute: csExecute,
    releaseString: csRelease
)
