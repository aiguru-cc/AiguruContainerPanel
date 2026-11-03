//
//  VolumeManager.swift
//  AiguruContainerPanel
//
//  卷管理服务；命令能力由 CLICommandCatalog 按 Apple Container 版本驱动。
//

import Foundation
import Combine

struct VolumeInfo: Identifiable, Decodable, Equatable {
    let id: String
    static func == (lhs: VolumeInfo, rhs: VolumeInfo) -> Bool { lhs.id == rhs.id }
    let name: String
    let driver: String
    let source: String
    let format: String?
    let sizeInBytes: Int64?
    let createdAt: String?
    let labels: [String: String]?
    let options: [String: String]?

    enum CodingKeys: String, CodingKey {
        case id
        case configuration
    }
    enum ConfigKeys: String, CodingKey {
        case name, driver, source, format, sizeInBytes, creationDate, labels, options
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        let cfg = try c.nestedContainer(keyedBy: ConfigKeys.self, forKey: .configuration)
        name = try cfg.decode(String.self, forKey: .name)
        driver = try cfg.decode(String.self, forKey: .driver)
        source = try cfg.decode(String.self, forKey: .source)
        format = try cfg.decodeIfPresent(String.self, forKey: .format)
        sizeInBytes = try cfg.decodeIfPresent(Int64.self, forKey: .sizeInBytes)
        createdAt = try cfg.decodeIfPresent(String.self, forKey: .creationDate)
        labels = try cfg.decodeIfPresent([String: String].self, forKey: .labels)
        options = try cfg.decodeIfPresent([String: String].self, forKey: .options)
    }

    var sizeDescription: String {
        guard let bytes = sizeInBytes else { return "" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

class VolumeManager: ObservableObject {
    static let shared = VolumeManager()
    private init() {}

    private let executor = CommandExecutor.shared
    private let logService = LogService.shared
    private let catalog = CLICommandCatalog.shared

    @Published var volumes: [VolumeInfo] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    func fetchVolumes() async {
        await MainActor.run { isLoading = true }
        do {
            let output = try await executor.execute(catalog.arguments(command: "volume.list", options: ["format": ["json"]]))
            guard !output.isEmpty else {
                await MainActor.run { volumes = []; isLoading = false }; return
            }
            let data = output.data(using: .utf8) ?? Data()
            let decoded = try JSONDecoder().decode([VolumeInfo].self, from: data)
            await MainActor.run { volumes = decoded; isLoading = false; errorMessage = nil }
            logService.log(result: CLIResult(command: "volume list", output: "\(decoded.count) volumes", exitCode: 0, duration: 0, mode: .async), module: "卷", operationType: "列表")
        } catch {
            await MainActor.run { volumes = []; isLoading = false; errorMessage = error.localizedDescription }
            print("❌ 卷列表解析失败: \(error)")
        }
    }

    func createVolume(name: String, size: String? = nil, labels: [String: String] = [:], options: [String: String] = [:]) async throws {
        let args = catalog.arguments(command: "volume.create", options: [
            "label": labels.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" },
            "option": options.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" },
            "size": size.map { [$0] } ?? []
        ], positionals: [name])
        _ = try await executor.execute(args)
        logService.log(result: CLIResult(command: "volume create \(name)", output: "OK", exitCode: 0, duration: 0, mode: .async), module: "卷", operationType: "创建")
        await fetchVolumes()
    }

    /// `container run -v name:/path` 不负责可靠地创建实名卷。应用集群部署前先显式创建，
    /// 并通过标签保留归属，避免卷意外退化成支持目录中的 bind mount。
    func ensureNamedVolumes(for specifications: [String], clusterName: String, serviceName: String) async throws {
        let names = Set(specifications.compactMap { specification -> String? in
            let source = String(specification.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
            guard !source.isEmpty, !source.hasPrefix("/"), !source.hasPrefix("./") else { return nil }
            return source
        })
        guard !names.isEmpty else { return }

        let output = try await executor.execute(catalog.arguments(command: "volume.list", options: ["format": ["json"]]))
        let existing: Set<String>
        if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            existing = []
        } else {
            let decoded = try JSONDecoder().decode([VolumeInfo].self, from: Data(output.utf8))
            existing = Set(decoded.map(\.name))
        }
        for name in names.sorted() where !existing.contains(name) {
            try await createVolume(name: name, labels: [
                "cc.aiguru.application-cluster": clusterName,
                "cc.aiguru.application-service": serviceName
            ])
        }
    }

    func deleteVolume(name: String) async throws {
        _ = try await executor.execute(catalog.arguments(command: "volume.delete", positionals: [name]))
        logService.log(result: CLIResult(command: "volume delete \(name)", output: "OK", exitCode: 0, duration: 0, mode: .async), module: "卷", operationType: "删除")
        await fetchVolumes()
    }

    func pruneVolumes() async throws {
        _ = try await executor.execute(catalog.arguments(command: "volume.prune"))
        logService.log(result: CLIResult(command: "volume prune", output: "OK", exitCode: 0, duration: 0, mode: .async), module: "卷", operationType: "清理")
        await fetchVolumes()
    }
}
