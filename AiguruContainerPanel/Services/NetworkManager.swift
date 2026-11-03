//
//  NetworkManager.swift
//  AiguruContainerPanel
//
//  网络管理服务：list / create / delete / inspect / prune。
//

import Foundation
import Combine

class NetworkManager: ObservableObject {
    static let shared = NetworkManager()
    private init() {}

    private let executor = CommandExecutor.shared
    private let logService = LogService.shared
    private let catalog = CLICommandCatalog.shared

    @Published var networks: [NetworkInfo] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    // MARK: - 列表
    func fetchNetworks() async {
        await MainActor.run { isLoading = true }
        do {
            let output = try await executor.execute(catalog.arguments(command: "network.list", options: ["format": ["json"]]))
            let data = output.data(using: .utf8) ?? Data()
            let decoded = try JSONDecoder().decode([NetworkInfo].self, from: data)
            await MainActor.run {
                networks = decoded
                errorMessage = nil
                isLoading = false
            }
        } catch {
            await MainActor.run {
                errorMessage = "获取网络列表失败: \(error.localizedDescription)"
                isLoading = false
            }
        }
    }

    // MARK: - 创建
    func createNetwork(name: String, subnet: String? = nil, subnetV6: String? = nil,
                       internalOnly: Bool = false, labels: [String: String] = [:],
                       options: [String: String] = [:], plugin: String? = nil) async throws {
        let args = catalog.arguments(command: "network.create", options: [
            "subnet": subnet.map { [$0] } ?? [], "subnetV6": subnetV6.map { [$0] } ?? [],
            "internal": internalOnly ? ["true"] : [], "plugin": plugin.map { [$0] } ?? [],
            "label": labels.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" },
            "option": options.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }
        ], positionals: [name])

        let fullCmd = args.joined(separator: " ")
        do {
            _ = try await executor.execute(args)
            let result = CLIResult(command: fullCmd, output: "OK", exitCode: 0, duration: 0, mode: .async)
            logService.log(result: result, module: "网络", operationType: "创建")
            await fetchNetworks()
        } catch {
            let result = CLIResult(command: fullCmd, output: error.localizedDescription, exitCode: -1, duration: 0, mode: .async)
            logService.log(result: result, module: "网络", operationType: "创建失败")
            throw error
        }
    }

    // MARK: - 删除
    func deleteNetwork(_ id: String) async throws {
        let cmd = "network delete \(id)"
        do {
            _ = try await executor.execute(catalog.arguments(command: "network.delete", positionals: [id]))
            logService.log(result: CLIResult(command: cmd, output: "OK", exitCode: 0, duration: 0, mode: .async), module: "网络", operationType: "删除")
            await fetchNetworks()
        } catch {
            logService.log(result: CLIResult(command: cmd, output: error.localizedDescription, exitCode: -1, duration: 0, mode: .async), module: "网络", operationType: "删除失败")
            throw error
        }
    }

    // MARK: - 查看详情
    func inspectNetwork(_ id: String) async throws -> String {
        try await executor.execute(catalog.arguments(command: "network.inspect", positionals: [id]))
    }

    // MARK: - 清理
    func pruneNetworks() async throws {
        do {
            _ = try await executor.execute(catalog.arguments(command: "network.prune"))
            logService.log(result: CLIResult(command: "network prune", output: "OK", exitCode: 0, duration: 0, mode: .async), module: "网络", operationType: "清理")
            await fetchNetworks()
        } catch {
            logService.log(result: CLIResult(command: "network prune", output: error.localizedDescription, exitCode: -1, duration: 0, mode: .async), module: "网络", operationType: "清理失败")
            throw error
        }
    }
}
