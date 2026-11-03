import Foundation
import Combine

struct ContainerGuardianConfiguration: Codable, Equatable {
    var containerName: String
    var enabled: Bool
    var maximumAttempts: Int
    var attempts: Int
    var manuallyStopped: Bool
}

/// 周期检查已启用守护的容器。面板内的手动停止会被明确标记，只有异常停止才会唤醒。
final class ContainerGuardian: ObservableObject {
    static let shared = ContainerGuardian()

    @Published private(set) var configurations: [String: ContainerGuardianConfiguration] = [:]

    private let manager = ContainerManager.shared
    private let environmentManager = EnvironmentManager.shared
    private let logService = LogService.shared
    private var monitoringTask: Task<Void, Never>?
    private var nextAttemptAt: [String: Date] = [:]
    private var restartInFlight = Set<String>()

    private init() {
        load()
        monitoringTask = Task { [weak self] in
            await self?.monitorLoop()
        }
    }

    deinit { monitoringTask?.cancel() }

    func configuration(for containerID: String) -> ContainerGuardianConfiguration {
        configurations[storageKey(for: containerID)] ?? ContainerGuardianConfiguration(
            containerName: containerID,
            enabled: false,
            maximumAttempts: AppConstants.Retry.maximumAttempts,
            attempts: 0,
            manuallyStopped: false
        )
    }

    func setEnabled(_ enabled: Bool, for container: Container) {
        let key = storageKey(for: container.id)
        var value = configuration(for: container.id)
        value.containerName = container.displayName
        value.enabled = enabled
        value.attempts = 0
        value.manuallyStopped = false
        configurations[key] = value
        nextAttemptAt.removeValue(forKey: key)
        save()
        log(
            containerID: container.id,
            operation: enabled ? "启用容器守护" : "关闭容器守护",
            output: "容器：\(container.displayName)，最大尝试次数：\(value.maximumAttempts)"
        )
    }

    func setMaximumAttempts(_ attempts: Int, for container: Container) {
        let key = storageKey(for: container.id)
        var value = configuration(for: container.id)
        value.containerName = container.displayName
        value.maximumAttempts = min(max(attempts, 1), 10)
        value.attempts = min(value.attempts, value.maximumAttempts)
        configurations[key] = value
        save()
        log(
            containerID: container.id,
            operation: "修改守护最大尝试次数",
            output: "容器：\(container.displayName)，最大尝试次数：\(value.maximumAttempts)"
        )
    }

    func markManualStop(_ container: Container) {
        let key = storageKey(for: container.id)
        guard var value = configurations[key], value.enabled else { return }
        value.manuallyStopped = true
        value.attempts = 0
        configurations[key] = value
        nextAttemptAt.removeValue(forKey: key)
        save()
        log(containerID: container.id, operation: "守护识别手动停止", output: "容器：\(container.displayName)，本次停止不自动唤醒")
    }

    func markExplicitStart(_ container: Container) {
        let key = storageKey(for: container.id)
        guard var value = configurations[key], value.enabled else { return }
        value.manuallyStopped = false
        value.attempts = 0
        configurations[key] = value
        nextAttemptAt.removeValue(forKey: key)
        save()
    }

    func removeConfiguration(for container: Container) {
        let key = storageKey(for: container.id)
        guard configurations.removeValue(forKey: key) != nil else { return }
        nextAttemptAt.removeValue(forKey: key)
        save()
        log(containerID: container.id, operation: "移除容器守护配置", output: "容器：\(container.displayName)")
    }

    private func monitorLoop() async {
        while !Task.isCancelled {
            await inspectCurrentEnvironment()
            try? await Task.sleep(for: .seconds(AppConstants.Time.monitoringInterval))
        }
    }

    private func inspectCurrentEnvironment() async {
        guard let environment = environmentManager.activeEnvironment else { return }
        let environmentID = environment.id
        let snapshot: [Container]
        do {
            snapshot = try await manager.fetchContainersSnapshot(in: environment)
        } catch {
            log(containerID: "-", operation: "守护检查失败", output: error.localizedDescription, succeeded: false)
            return
        }
        guard environmentManager.activeEnvironment?.id == environmentID else { return }

        for container in snapshot {
            let key = storageKey(environmentID: environmentID, containerID: container.id)
            guard var value = configurations[key], value.enabled, !value.manuallyStopped else { continue }

            if container.state == .running || container.state == .restarting {
                if value.attempts > 0 {
                    value.attempts = 0
                    configurations[key] = value
                    nextAttemptAt.removeValue(forKey: key)
                    save()
                    log(containerID: container.id, operation: "守护恢复确认", output: "容器：\(container.displayName) 已恢复运行")
                }
                continue
            }

            guard container.state == .stopped || container.state == .exited || container.state == .dead else { continue }
            guard !restartInFlight.contains(key) else { continue }
            guard nextAttemptAt[key, default: .distantPast] <= Date() else { continue }
            guard value.attempts < value.maximumAttempts else { continue }

            value.attempts += 1
            configurations[key] = value
            save()
            restartInFlight.insert(key)
            log(
                containerID: container.id,
                operation: "守护检测异常停止",
                output: "容器：\(container.displayName)，准备第 \(value.attempts)/\(value.maximumAttempts) 次唤醒"
            )

            let succeeded = await manager.startContainer(
                id: container.id,
                operationType: "守护自动唤醒 \(value.attempts)/\(value.maximumAttempts)",
                reportErrorsToUI: false
            )
            restartInFlight.remove(key)

            if succeeded {
                nextAttemptAt.removeValue(forKey: key)
            } else if value.attempts >= value.maximumAttempts {
                log(
                    containerID: container.id,
                    operation: "守护重试耗尽",
                    output: "容器：\(container.displayName)，已达到最大尝试次数 \(value.maximumAttempts)",
                    succeeded: false
                )
            } else {
                nextAttemptAt[key] = Date().addingTimeInterval(AppConstants.Time.monitoringInterval)
            }
        }
    }

    private func storageKey(for containerID: String) -> String {
        guard let environmentID = environmentManager.activeEnvironment?.id else { return containerID }
        return storageKey(environmentID: environmentID, containerID: containerID)
    }

    private func storageKey(environmentID: UUID, containerID: String) -> String {
        "\(environmentID.uuidString)|\(containerID)"
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: AppConstants.UserDefaultsKey.containerGuardianConfigurations),
              let decoded = try? JSONDecoder().decode([String: ContainerGuardianConfiguration].self, from: data) else { return }
        configurations = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(configurations) else { return }
        UserDefaults.standard.set(data, forKey: AppConstants.UserDefaultsKey.containerGuardianConfigurations)
    }

    private func log(containerID: String, operation: String, output: String, succeeded: Bool = true) {
        logService.log(
            result: CLIResult(
                command: "container guardian \(containerID)",
                output: output,
                exitCode: succeeded ? 0 : -1,
                duration: 0,
                mode: .async
            ),
            module: "容器守护",
            operationType: operation
        )
    }
}
