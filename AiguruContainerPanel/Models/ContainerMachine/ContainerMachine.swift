//
//  ContainerMachine.swift
//  AiguruContainerPanel
//
//  Machine 数据模型，适配 `container machine ls --format json` 实际输出。
//  JSON keys: id, status, cpus, memory(Int), diskSize, createdDate, default, ipAddress?
//

import Foundation
import SwiftUI

/// Machine 状态（CLI 使用 "status" 字段，值: running / stopped）
enum MachineState: String, Decodable {
    case running = "running"
    case stopped = "stopped"
    case unknown = "unknown"

    var displayName: String {
        switch self {
        case .running: return "运行中"
        case .stopped: return "已停止"
        case .unknown: return "未知"
        }
    }

    var color: Color {
        switch self {
        case .running: return .green
        case .stopped, .unknown: return .gray
        }
    }

    var isRunning: Bool { self == .running }
}

/// Machine 配置
struct MachineConfig: Codable {
    var cpus: Int?
    var memory: String?
    var homeMount: String?
    var virtualization: Bool?
    var kernel: String?
    var noBoot: Bool?
    var setDefault: Bool?
}

/// Machine 信息 — 严格对齐 `container machine ls --format json`
struct ContainerMachine: Identifiable, Decodable, Equatable, Hashable {
    /// CLI 输出中的 "id" 即 machine 名称
    let id: String
    let state: MachineState
    let cpus: Int?
    let memoryBytes: Int?
    let diskSize: Int?
    let createdAt: String?
    let isDefault: Bool
    let ipAddress: String?
    /// 镜像引用，通过 `machine inspect` 单独获取，不在 ls JSON 中
    var image: String?

    var name: String { id }
    var displayName: String { id }

    var memory: String {
        guard let bytes = memoryBytes, bytes > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    var disk: String {
        guard let bytes = diskSize, bytes > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    var createdDate: Date? {
        guard let createdAt else { return nil }
        return ISO8601DateFormatter().date(from: createdAt)
    }

    var isRunning: Bool { state == .running }

    // MARK: - CodingKeys (CLI 实际 JSON)
    enum CodingKeys: String, CodingKey {
        case id
        case stateRaw = "status"
        case cpus
        case memoryBytes = "memory"
        case diskSize
        case createdAt = "createdDate"
        case isDefault = "default"
        case ipAddress
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        let status = try container.decode(String.self, forKey: .stateRaw)
        state = MachineState(rawValue: status) ?? .unknown
        cpus = try container.decodeIfPresent(Int.self, forKey: .cpus)
        memoryBytes = try container.decodeIfPresent(Int.self, forKey: .memoryBytes)
        diskSize = try container.decodeIfPresent(Int.self, forKey: .diskSize)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        ipAddress = try container.decodeIfPresent(String.self, forKey: .ipAddress)
    }

    /// 显式构造器（用于手动创建，如 fallback 解析）
    init(id: String, state: MachineState, cpus: Int? = nil, memoryBytes: Int? = nil,
         diskSize: Int? = nil, createdAt: String? = nil, isDefault: Bool = false,
         ipAddress: String? = nil) {
        self.id = id
        self.state = state
        self.cpus = cpus
        self.memoryBytes = memoryBytes
        self.diskSize = diskSize
        self.createdAt = createdAt
        self.isDefault = isDefault
        self.ipAddress = ipAddress
    }
}
