//
//  EnvironmentManager.swift
//  AiguruContainerPanel
//
//  环境管理器，负责管理可用环境、切换当前环境、持久化用户选择。
//  始终保持明确的工作环境；默认与失效回退均指向系统 CLI。
//

import Foundation
import Combine

class EnvironmentManager: ObservableObject {
    static let shared = EnvironmentManager()
    private init() {
        loadSavedEnvironments()
        let savedID = UserDefaults.standard.string(forKey: AppConstants.UserDefaultsKey.selectedEnvironmentID)
            .flatMap(UUID.init(uuidString:))
        currentEnvironment = savedID.flatMap { id in
            availableEnvironments.first { $0.id == id }
        } ?? availableEnvironments.first { $0.type == .system }
        synchronizeSelectedEnvironment()
        // 延迟检测环境（不阻塞 UI）
        DispatchQueue.main.asyncAfter(deadline: .now() + AppConstants.Time.environmentDetectionDelay) {
            self.detectEnvironments()
        }
    }

    @Published var availableEnvironments: [ContainerEnvironment] = []
    @Published var currentEnvironment: ContainerEnvironment? {
        didSet {
            if let env = currentEnvironment {
                UserDefaults.standard.set(env.id.uuidString, forKey: AppConstants.UserDefaultsKey.selectedEnvironmentID)
                // 同步到 CLIService 和 CommandExecutor
                CLIService.shared.setEnvironment(env)
                CommandExecutor.shared.environment = env
                DispatchQueue.main.async {
                    self.objectWillChange.send()
                }
            } else if let system = availableEnvironments.first(where: { $0.type == .system }) {
                // 不允许长期处于未指定状态，异步回退以避免 didSet 递归。
                DispatchQueue.main.async { self.currentEnvironment = system }
            }
        }
    }
    @Published var isDetecting = false
    @Published var detectionStatus: [String: Bool] = [:]
    @Published private(set) var detectedVersions: [UUID: CLIVersion] = [:]

    var currentVersion: CLIVersion {
        guard let id = currentEnvironment?.id else { return .unknown }
        return detectedVersions[id] ?? .unknown
    }

    /// 随工作环境切换自动解析的版本指令档位；页面和命令构建器不再保存独立版本状态。
    var currentInstructionProfile: CLICatalogProfile? {
        CLICommandCatalog.shared.profile(for: currentVersion)
    }

    private var cancellables = Set<AnyCancellable>()

    // MARK: - 加载保存的环境
    private func loadSavedEnvironments() {
        var customEnvs: [ContainerEnvironment] = []
        if let data = UserDefaults.standard.data(forKey: AppConstants.UserDefaultsKey.customEnvironments),
           let decoded = try? JSONDecoder().decode([ContainerEnvironment].self, from: data) {
            customEnvs = decoded
        }
        let defaults = ContainerEnvironment.defaultEnvironments
        availableEnvironments = defaults + customEnvs

        // 选择由 init 按持久化 ID 恢复；找不到（例如旧版随机系统 UUID）时回退系统环境。
    }

    private func synchronizeSelectedEnvironment() {
        guard let environment = currentEnvironment else { return }
        UserDefaults.standard.set(environment.id.uuidString, forKey: AppConstants.UserDefaultsKey.selectedEnvironmentID)
        CLIService.shared.setEnvironment(environment)
        CommandExecutor.shared.environment = environment
    }

    private func saveCustomEnvironments() {
        let custom = availableEnvironments.filter { $0.type == .custom }
        if let data = try? JSONEncoder().encode(custom) {
            UserDefaults.standard.set(data, forKey: AppConstants.UserDefaultsKey.customEnvironments)
        }
    }

    // MARK: - 检测所有环境（更新 isActive 状态）
    func detectEnvironments() {
        isDetecting = true
        detectionStatus.removeAll()

        let group = DispatchGroup()
        for env in availableEnvironments {
            group.enter()
            // 只探测该工作环境指定的绝对路径，不使用 PATH 中的其他 container。
            Task {
                do {
                    let result = try await CommandExecutor.shared.executeSystemCommand(
                        arguments: [env.resolvedCliPath] + CLICommandCatalog.shared.arguments(command: "cli.version")
                    )
                    let version = CLIVersion(result)
                    let available = version.isKnown
                    DispatchQueue.main.async {
                        self.detectionStatus[env.name] = available
                        self.detectedVersions[env.id] = version
                        if let index = self.availableEnvironments.firstIndex(where: { $0.id == env.id }) {
                            self.availableEnvironments[index].isActive = available
                        }
                        group.leave()
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.detectionStatus[env.name] = false
                        self.detectedVersions[env.id] = .unknown
                        if let index = self.availableEnvironments.firstIndex(where: { $0.id == env.id }) {
                            self.availableEnvironments[index].isActive = false
                        }
                        group.leave()
                    }
                }
            }
        }

        group.notify(queue: .main) {
            self.isDetecting = false
            // 如果当前选中的环境不可用，不自动切换，保留用户选择（用户可手动切换）
            // 但记录日志
            if let current = self.currentEnvironment,
               let index = self.availableEnvironments.firstIndex(where: { $0.id == current.id }),
               !self.availableEnvironments[index].isActive {
                print("⚠️ 当前环境 '\(current.name)' 检测为不可用，但用户仍可手动选择其他环境。")
            }
        }
    }

    /// 安装/升级完成后的同步探测入口，确保插件档位不会读取升级前缓存的 CLI 版本。
    @discardableResult
    func detectCurrentEnvironment() async -> CLIVersion {
        guard let environment = currentEnvironment else { return .unknown }
        do {
            let result = try await CommandExecutor.shared.executeSystemCommand(
                arguments: [environment.resolvedCliPath] + CLICommandCatalog.shared.arguments(command: "cli.version")
            )
            let version = CLIVersion(result)
            await MainActor.run {
                detectedVersions[environment.id] = version
                detectionStatus[environment.name] = version.isKnown
                if let index = availableEnvironments.firstIndex(where: { $0.id == environment.id }) {
                    availableEnvironments[index].isActive = version.isKnown
                }
            }
            return version
        } catch {
            await MainActor.run {
                detectedVersions[environment.id] = .unknown
                detectionStatus[environment.name] = false
            }
            return .unknown
        }
    }

    // MARK: - 切换环境（允许选择任何环境，不强制检查 isActive）
    func selectEnvironment(_ env: ContainerEnvironment) {
        // ✅ 不再检查 isActive，允许用户选择任何环境
        currentEnvironment = env
        // 如果该环境之前不可用，可以触发重新检测（可选）
        if let index = availableEnvironments.firstIndex(where: { $0.id == env.id }),
           !availableEnvironments[index].isActive {
            print("ℹ️ 选择了不可用的环境 '\(env.name)'，命令执行可能会失败。")
        }
    }

    // MARK: - 添加自定义环境
    func addCustomEnvironment(_ env: ContainerEnvironment) {
        var newEnv = env
        newEnv.isActive = false
        availableEnvironments.append(newEnv)
        saveCustomEnvironments()
        detectEnvironments()
    }

    func addCustomEnvironment(name: String, executablePath: String) {
        let env = ContainerEnvironment(
            name: name,
            type: .custom,
            description: "自定义环境: \(executablePath)",
            cliPath: executablePath,
            detectionCommand: "test -f \(executablePath)"
        )
        addCustomEnvironment(env)
    }

    // MARK: - 删除自定义环境
    func removeCustomEnvironment(_ env: ContainerEnvironment) {
        guard env.type == .custom else { return }
        availableEnvironments.removeAll { $0.id == env.id }
        saveCustomEnvironments()
        if currentEnvironment?.id == env.id {
            currentEnvironment = availableEnvironments.first { $0.type == .system }
        }
    }

    // MARK: - 获取当前有效环境（可能为 nil）
    var activeEnvironment: ContainerEnvironment? {
        return currentEnvironment
    }
}
