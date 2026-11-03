//
//  RegistryManager.swift
//  AiguruContainerPanel
//
//  镜像仓库（Registry）登录管理服务；命令能力由版本指令库驱动。
//  功能：列表、登录（密码走 stdin）、登出。
//

import Foundation
import Combine

/// Registry 登录信息（宽松解码 registry list --format json）
struct RegistryInfo: Identifiable, Decodable, Equatable {
    var id: String { hostname }
    let hostname: String
    let username: String
    let scheme: String?
    let createdAt: String?
    let modifiedAt: String?

    enum CodingKeys: String, CodingKey {
        case hostname, server, username, user, scheme, createdAt, creationDate, created, modifiedAt, modified
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hostname = (try? c.decodeIfPresent(String.self, forKey: .hostname)) ?? (try? c.decodeIfPresent(String.self, forKey: .server)) ?? ""
        username = (try? c.decodeIfPresent(String.self, forKey: .username)) ?? (try? c.decodeIfPresent(String.self, forKey: .user)) ?? ""
        scheme = try? c.decodeIfPresent(String.self, forKey: .scheme)
        createdAt = (try? c.decodeIfPresent(String.self, forKey: .createdAt)) ?? (try? c.decodeIfPresent(String.self, forKey: .creationDate)) ?? (try? c.decodeIfPresent(String.self, forKey: .created))
        modifiedAt = (try? c.decodeIfPresent(String.self, forKey: .modifiedAt)) ?? (try? c.decodeIfPresent(String.self, forKey: .modified))
    }

    var createdDate: Date? {
        guard let createdAt else { return nil }
        return ISO8601DateFormatter().date(from: createdAt)
    }
}

class RegistryManager: ObservableObject {
    static let shared = RegistryManager()
    private init() {}

    private let executor = CommandExecutor.shared
    private let logService = LogService.shared
    private let catalog = CLICommandCatalog.shared

    @Published var registries: [RegistryInfo] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    // MARK: - 列表

    func fetchRegistries() async {
        await MainActor.run { isLoading = true }
        let command = "registry list --format json"
        do {
            let output = try await executor.execute(catalog.arguments(command: "registry.list", options: ["format": ["json"]]))
            guard !output.isEmpty else {
                await MainActor.run { registries = []; isLoading = false; errorMessage = nil }
                return
            }
            let decoded = try JSONDecoder().decode([RegistryInfo].self, from: output.data(using: .utf8) ?? Data())
            await MainActor.run {
                registries = decoded
                isLoading = false
                errorMessage = nil
            }
            logService.log(result: CLIResult(command: command, output: "\(decoded.count) registries", exitCode: 0, duration: 0, mode: .async),
                           module: "Registry", operationType: "列表")
        } catch {
            await MainActor.run {
                registries = []
                isLoading = false
                errorMessage = "获取 Registry 列表失败: \(error.localizedDescription)"
            }
            logService.log(result: CLIResult(command: command, output: error.localizedDescription, exitCode: -1, duration: 0, mode: .async),
                           module: "Registry", operationType: "列表失败")
        }
    }

    // MARK: - 登录（密码走 stdin，避免出现在命令行/日志）

    func login(server: String, username: String, password: String, scheme: String) async throws {
        let args = catalog.arguments(command: "registry.login", options: [
            "username": [username], "scheme": scheme.isEmpty ? [] : [scheme], "passwordStdin": ["true"]
        ], positionals: [server])
        let stdinData = (password + "\n").data(using: .utf8)
        _ = try await executor.execute(args, stdinData: stdinData)
        logService.log(result: CLIResult(command: "registry login \(server)", output: "OK", exitCode: 0, duration: 0, mode: .async),
                       module: "Registry", operationType: "登录")
        await fetchRegistries()
    }

    // MARK: - 登出

    func logout(server: String) async throws {
        _ = try await executor.execute(catalog.arguments(command: "registry.logout", positionals: [server]))
        logService.log(result: CLIResult(command: "registry logout \(server)", output: "OK", exitCode: 0, duration: 0, mode: .async),
                       module: "Registry", operationType: "登出")
        await fetchRegistries()
    }
}
