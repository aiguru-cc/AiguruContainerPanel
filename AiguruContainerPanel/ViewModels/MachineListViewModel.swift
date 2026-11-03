//
//  MachineListViewModel.swift
//  AiguruContainerPanel
//
//  Machine 列表视图模型，与 MachineManager 交互。
//  环境切换时自动刷新，并维护选中状态。
//

import SwiftUI
import Combine

class MachineListViewModel: ObservableObject {
    @Published var machines: [ContainerMachine] = []
    @Published var selectedMachine: ContainerMachine? = nil
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let manager = MachineManager.shared
    private let envManager = EnvironmentManager.shared
    private var cancellables = Set<AnyCancellable>()

    init() {
        // 绑定列表数据
        manager.$machines
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newMachines in
                self?.machines = newMachines
                // 更新选中状态：如果选中的 machine 不在新列表中，取消选中
                self?.updateSelectedMachine()
            }
            .store(in: &cancellables)

        manager.$isLoading
            .receive(on: DispatchQueue.main)
            .assign(to: &$isLoading)

        manager.$errorMessage
            .receive(on: DispatchQueue.main)
            .assign(to: &$errorMessage)

        // 环境切换监听（静默刷新）
        envManager.$currentEnvironment
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshMachines(silent: true)
            }
            .store(in: &cancellables)
    }

    // MARK: - 刷新列表
    func refreshMachines(silent: Bool = false) {
        if !silent {
            errorMessage = nil
        }
        Task {
            await manager.fetchMachines()
            if silent {
                await MainActor.run {
                    if self.errorMessage != nil {
                        self.errorMessage = nil
                    }
                }
            }
        }
    }

    // MARK: - 选中状态更新
    private func updateSelectedMachine() {
        guard let current = selectedMachine else { return }
        if let updated = machines.first(where: { $0.id == current.id }) {
            selectedMachine = updated
        } else {
            // 如果容器已被删除或环境切换，取消选中
            selectedMachine = nil
        }
    }

    // MARK: - Machine 操作
    func createMachine(_ configuration: MachineCreateConfiguration) async throws {
        try await manager.createMachine(configuration)
    }

    func stopMachine(_ machine: ContainerMachine) {
        Task {
            do {
                try await manager.stopMachine(machine)
            } catch {
                // 错误已在 Manager 中设置
            }
        }
    }

    func startMachine(_ machine: ContainerMachine) {
        Task {
            do {
                try await manager.startMachine(machine)
            } catch {
                // 错误已在 Manager 中设置
            }
        }
    }

    func deleteMachine(_ machine: ContainerMachine) {
        Task {
            do {
                try await manager.deleteMachine(machine)
            } catch {
                // 错误已在 Manager 中设置
            }
        }
    }

    func setDefaultMachine(_ machine: ContainerMachine) {
        Task {
            do {
                try await manager.setDefaultMachine(machine)
            } catch {
                // 错误已在 Manager 中设置
            }
        }
    }

    func runCommand(in machine: ContainerMachine, command: String? = nil) {
        Task {
            do {
                _ = try await manager.runCommand(in: machine, command: command)
            } catch {
                // 错误已在 Manager 中设置
            }
        }
    }

    func updateMachine(_ machine: ContainerMachine, config: MachineConfig) {
        Task {
            do {
                try await manager.updateMachine(machine, config: config)
            } catch {
                // 错误已在 Manager 中设置
            }
        }
    }

    func inspectMachine(_ machine: ContainerMachine) {
        Task {
            do {
                _ = try await manager.inspectMachine(machine)
            } catch {
                // 错误已在 Manager 中设置
            }
        }
    }
}
