//
//  ContainerEnvironment.swift
//  AiguruContainerPanel
//
//  容器环境模型，包含 CLI 路径、环境变量、检测命令等。
//

import Foundation

/// 环境类型
enum EnvironmentType: String, Codable, CaseIterable {
    case system = "系统环境"
    case custom = "自定义环境"

    var icon: String {
        switch self {
        case .system: return "macbook"
        case .custom: return "gear"
        }
    }
}

/// 容器环境配置
struct ContainerEnvironment: Identifiable, Codable, Hashable {
    var id = UUID()
    let name: String
    let type: EnvironmentType
    let description: String
    var isActive: Bool = false

    // ✅ 核心属性：CLI 路径（默认 /usr/local/bin/container）
    let cliPath: String?

    // 额外环境变量
    let envVars: [String: String]?

    // 检测命令（用于验证环境是否可用）
    let detectionCommand: String?

    init(id: UUID = UUID(), name: String, type: EnvironmentType, description: String = "",
         cliPath: String? = nil, envVars: [String: String]? = nil,
         detectionCommand: String? = nil, isActive: Bool = false) {
        self.id = id
        self.name = name
        self.type = type
        self.description = description
        self.cliPath = cliPath
        self.envVars = envVars
        self.detectionCommand = detectionCommand
        self.isActive = isActive
    }

    // 获取实际使用的 CLI 路径（如果未指定，使用默认系统路径）
    var resolvedCliPath: String {
        return cliPath ?? AppConstants.CLI.executablePath
    }

    // 构建完整命令（包含路径）
    func buildCommand(_ command: String) -> String {
        return "\(resolvedCliPath) \(command)"
    }

    // 构建执行环境变量
    func buildEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if let customVars = envVars {
            for (key, value) in customVars {
                env[key] = value
            }
        }
        // 如果指定了 cliPath，将其加入 PATH
        if let path = cliPath {
            let dir = (path as NSString).deletingLastPathComponent
            let currentPath = env["PATH"] ?? ""
            env["PATH"] = "\(dir):\(currentPath)"
        }
        return env
    }

    // 检测命令（用于可用性验证）
    func detectionCheck() -> String {
        return detectionCommand ?? "\(resolvedCliPath) version"
    }

    // 用于 UI 显示
    var displayName: String {
        return "\(type.rawValue) - \(name)"
    }
}

// MARK: - 预定义环境
extension ContainerEnvironment {
    /// 系统环境（默认路径）
    static let systemEnvironment = ContainerEnvironment(
        id: AppConstants.Environment.systemEnvironmentID,
        name: "系统 Container",
        type: .system,
        description: "系统级 container CLI，通常位于 /usr/local/bin",
        cliPath: AppConstants.CLI.executablePath,
        detectionCommand: "\(AppConstants.CLI.executablePath) --version"
    )

    /// 获取默认环境列表
    static var defaultEnvironments: [ContainerEnvironment] {
        [systemEnvironment]
    }
}
