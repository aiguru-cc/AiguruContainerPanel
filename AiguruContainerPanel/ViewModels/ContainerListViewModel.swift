//
//  ContainerListViewModel.swift
//  AiguruContainerPanel
//
//  容器列表视图模型，委托给 ContainerManager 执行所有操作。
//  环境切换时立即清空列表，避免显示旧数据。
//

import SwiftUI
import Combine

class ContainerListViewModel: ObservableObject {
    @Published var containers: [Container] = []
    @Published var selectedContainer: Container? = nil
    @Published var isLoading = false
    @Published var errorMessage: String? = nil
    @Published var executionMode: ExecutionMode = .stream

    @Published var currentProgress: Double = 0.0
    @Published var currentProgressMessage: String = ""
    @Published var isProgressIndeterminate: Bool = false
    @Published var currentCommand: String = ""

    @Published var showLogView = false
    @Published var logContainer: Container? = nil
    @Published var logLines: [String] = []
    @Published var isLogLoading = false

    @Published var showTerminal = false
    @Published var terminalContainer: Container? = nil

    private let manager = ContainerManager.shared
    private let envManager = EnvironmentManager.shared
    private let guardian = ContainerGuardian.shared
    private var cancellables = Set<AnyCancellable>()

    init() {
        // 绑定 Manager 属性
        manager.$containers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newContainers in
                self?.containers = newContainers
                self?.updateSelectedContainer()
            }
            .store(in: &cancellables)

        manager.$isLoading
            .receive(on: DispatchQueue.main)
            .assign(to: &$isLoading)

        manager.$errorMessage
            .receive(on: DispatchQueue.main)
            .assign(to: &$errorMessage)

        manager.$currentProgress
            .receive(on: DispatchQueue.main)
            .assign(to: &$currentProgress)

        manager.$currentProgressMessage
            .receive(on: DispatchQueue.main)
            .assign(to: &$currentProgressMessage)

        manager.$isProgressIndeterminate
            .receive(on: DispatchQueue.main)
            .assign(to: &$isProgressIndeterminate)

        manager.$currentCommand
            .receive(on: DispatchQueue.main)
            .assign(to: &$currentCommand)

        manager.$logs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] logs in
                self?.logLines = logs
            }
            .store(in: &cancellables)

        // ✅ 环境切换监听：立即清空列表，再静默刷新
        envManager.$currentEnvironment
            .dropFirst()  // 忽略初始值
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                // 立即清空旧数据
                self.containers = []
                self.selectedContainer = nil
                self.errorMessage = nil
                // 触发静默刷新（异步加载新数据）
                self.refreshContainers(silent: true)
            }
            .store(in: &cancellables)
    }

    // MARK: - 选中容器
    func selectContainer(_ container: Container) {
        selectedContainer = container
    }

    // MARK: - 更新选中的容器（从最新列表重新获取）
    private func updateSelectedContainer() {
        guard let current = selectedContainer else { return }
        if let updated = containers.first(where: { $0.id == current.id }) {
            selectedContainer = updated
        } else {
            // 如果容器已被删除，则取消选中
            selectedContainer = nil
        }
    }

    // MARK: - 刷新列表（支持静默模式）
    func  refreshContainers(silent: Bool = false) {
        // 非静默模式才清除错误信息（静默模式下错误信息已在环境切换时清除）
        if !silent {
            self.errorMessage = nil
        }
        Task {
            await manager.fetchContainers()
            // 静默模式下如果失败，错误信息已在 manager 中设置，但我们可以清除（因为绑定会传递）
            if silent {
                await MainActor.run {
                    // 如果 manager 产生了错误，但我们不想显示，则清除
                    if self.errorMessage != nil {
                        self.errorMessage = nil
                    }
                }
            }
        }
    }

    // MARK: - 容器操作
    func startContainer(_ container: Container) {
        guardian.markExplicitStart(container)
        Task {
            await manager.startContainer(id: container.id)
        }
    }

    func stopContainer(_ container: Container) {
        guardian.markManualStop(container)
        Task {
            let stopped = await manager.stopContainer(id: container.id)
            if !stopped {
                guardian.markExplicitStart(container)
            }
        }
    }

    func restartContainer(_ container: Container) {
        guardian.markManualStop(container)
        Task {
            let stopped = await manager.stopContainer(id: container.id)
            guard stopped else {
                guardian.markExplicitStart(container)
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            guardian.markExplicitStart(container)
            await manager.startContainer(id: container.id)
        }
    }

    func deleteContainer(_ container: Container) {
        guardian.removeConfiguration(for: container)
        Task {
            await manager.deleteContainer(id: container.id)
        }
    }

    func forceDeleteContainer(_ container: Container) {
        guardian.removeConfiguration(for: container)
        Task {
            await manager.deleteContainer(id: container.id)
        }
    }

    func cleanContainer(_ container: Container) {
        Task { await manager.cleanContainer(id: container.id) }
    }

    func pruneContainers() {
        Task {
            let stopped = containers.filter { $0.state == .stopped || $0.state == .exited }
            for container in stopped {
                guardian.removeConfiguration(for: container)
                await manager.deleteContainer(id: container.id)
            }
        }
    }

    // MARK: - 日志
    func fetchLogs(for container: Container, tail: Int = 100) {
        isLogLoading = true
        logContainer = container
        showLogView = true
        Task {
            do {
                let output = try await manager.fetchContainerLogsRaw(id: container.id)
                let lines = output.split(separator: "\n").map(String.init)
                let tailed = lines.suffix(tail)
                await MainActor.run {
                    self.logLines = Array(tailed)
                    self.isLogLoading = false
                }
            } catch {
                await MainActor.run {
                    self.logLines = ["获取日志失败: \(error.localizedDescription)"]
                    self.isLogLoading = false
                }
            }
        }
    }

    func closeLogView() {
        showLogView = false
        logLines = []
        logContainer = nil
    }

    // MARK: - 终端
    func openTerminal(for container: Container) {
        terminalContainer = container
        showTerminal = true
        manager.openTerminal(for: container)
    }

    func closeTerminal() {
        showTerminal = false
        terminalContainer = nil
    }

    // MARK: - 创建容器
    func createContainer(name: String, image: String, ports: [String], env: [String], volumes: [String], options: ContainerRunOptions) {
        Task {
            do {
                let id = try await manager.createContainer(
                    name: name,
                    image: image,
                    detach: options.detach,
                    ports: ports,
                    env: env,
                    volumes: volumes,
                    options: options
                )
                print("✅ 容器创建成功，ID: \(id)")
            } catch {
                await MainActor.run {
                    self.errorMessage = "创建容器失败: \(error.localizedDescription)"
                }
            }
        }
    }
}
