//
//  Container.swift
//  AiguruContainerPanel
//
//  容器数据模型，适配 container list --format json 输出。
//  修复 hostPort 类型兼容和 networks 数组解码。
//

import Foundation
import SwiftUI

// MARK: - LosslessStringConvertible 包装类型（支持 Int 和 String）
struct LosslessString: Decodable, Hashable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            value = String(intValue)
        } else if let stringValue = try? container.decode(String.self) {
            value = stringValue
        } else {
            throw DecodingError.typeMismatch(
                LosslessString.self,
                DecodingError.Context(codingPath: decoder.codingPath,
                                      debugDescription: "Expected Int or String")
            )
        }
    }
}

// MARK: - 容器状态
enum ContainerState: String, Decodable {
    case running, stopped, paused, exited, created, restarting, dead, unknown

    var displayName: String {
        switch self {
        case .running: return "运行中"
        case .stopped: return "已停止"
        case .paused: return "已暂停"
        case .exited: return "已退出"
        case .created: return "已创建"
        case .restarting: return "重启中"
        case .dead: return "已终止"
        case .unknown: return "未知"
        }
    }

    var color: Color {
        switch self {
        case .running: return .green
        case .stopped, .exited, .dead: return .gray
        case .paused: return .yellow
        case .created: return .blue
        case .restarting: return .orange
        case .unknown: return .gray
        }
    }

    var icon: String {
        switch self {
        case .running: return "play.circle.fill"
        case .stopped: return "stop.circle.fill"
        case .paused: return "pause.circle.fill"
        case .exited: return "xmark.circle.fill"
        case .created: return "plus.circle.fill"
        case .restarting: return "arrow.clockwise.circle.fill"
        case .dead: return "exclamationmark.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }
}

// MARK: - 端口映射
struct ContainerPort: Decodable, Hashable {
    let hostIP: String?
    let hostPort: LosslessString?  // 兼容数字和字符串
    let containerPort: LosslessString
    let protocolType: String

    enum CodingKeys: String, CodingKey {
        case hostIP = "hostAddress"
        case hostPort = "hostPort"
        case containerPort = "containerPort"
        case protocolType = "proto"
    }

    var hostPortString: String? { hostPort?.value }
    var containerPortString: String { containerPort.value }
}

// MARK: - 挂载卷
struct ContainerMount: Decodable, Hashable {
    let source: String
    let destination: String
    let mode: String?
    let readOnly: Bool?

    enum CodingKeys: String, CodingKey {
        case source, destination
        case mode
        case readOnly = "rw"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decode(String.self, forKey: .source)
        destination = try container.decode(String.self, forKey: .destination)
        mode = try container.decodeIfPresent(String.self, forKey: .mode)
        readOnly = try container.decodeIfPresent(Bool.self, forKey: .readOnly)
    }
}

// MARK: - 网络设置（用于 networkSettings）
struct ContainerNetwork: Decodable {
    let networks: [String: NetworkSettings]
}

struct NetworkSettings: Decodable {
    let ipAddress: String?
    let macAddress: String?
    let gateway: String?
    let hostname: String?
    let mtu: Int?

    enum CodingKeys: String, CodingKey {
        case ipAddress = "ip"
        case macAddress = "mac"
        case gateway
        case hostname
        case mtu
    }
}

// MARK: - 镜像信息
struct ContainerImage: Decodable {
    let displayName: String?
    let reference: String?
    let descriptor: ImageDescriptor?
}

struct ImageDescriptor: Decodable {
    let digest: String?
    let mediaType: String?
    let size: Int?
}

// MARK: - 资源限制
struct ContainerResources: Decodable {
    let cpus: Double?
    let memoryInBytes: Int64?
    let cpuOverhead: Int?
}

// MARK: - 容器配置（完整）
struct ContainerConfiguration: Decodable {
    let id: String
    let creationDate: String?
    let image: ContainerImage?
    let mounts: [ContainerMount]?
    let publishedPorts: [ContainerPort]?
    let resources: ContainerResources?
    let readOnly: Bool?
    let networks: [NetworkConfig]?
    let dns: DNSConfig?
    let labels: [String: String]?
    let capAdd: [String]?
    let capDrop: [String]?
    let initProcess: InitProcess?
    let runtimeHandler: String?
    let virtualization: Bool?
    let rosetta: Bool?
    let useInit: Bool?
    let ssh: Bool?

    struct NetworkConfig: Decodable {
        let network: String
        let options: NetworkOptions?
    }

    struct NetworkOptions: Decodable {
        let hostname: String?
        let mtu: Int?
        let ip: String?
        let mac: String?
    }

    struct DNSConfig: Decodable {
        let domain: String?
        let nameservers: [String]?
        let searchDomains: [String]?
        let options: [String]?
    }

    struct InitProcess: Decodable {
        let arguments: [String]?
        let environment: [String]?
        let executable: String?
        let terminal: Bool?
        let user: User?
        let workingDirectory: String?
    }

    struct User: Decodable {
        let id: UserID?
    }

    struct UserID: Decodable {
        let uid: Int?
        let gid: Int?
    }

    var ipAddress: String? {
        guard let networks = networks, let first = networks.first else { return nil }
        return first.options?.ip
    }

    var hostname: String? {
        guard let networks = networks, let first = networks.first else { return nil }
        return first.options?.hostname
    }
}

// MARK: - 网络状态（status 中的 networks 是对象数组，非字符串）
struct NetworkStatus: Decodable {
    let hostname: String?
    let ipv4Address: String?
    let ipv4Gateway: String?
    let ipv6Address: String?
    let macAddress: String?
    let mtu: Int?
    let network: String?
}

// MARK: - 状态信息
struct ContainerStatusInfo: Decodable {
    let state: String
    let pid: Int?
    let networks: [NetworkStatus]?
}

// MARK: - 容器主模型
struct Container: Identifiable, Decodable, Equatable, Hashable {
    let id: String
    let name: String
    let image: String
    let state: ContainerState
    let status: String
    let createdAt: String
    let ports: [ContainerPort]?
    let mounts: [ContainerMount]?
    let networkSettings: ContainerNetwork?
    let sizeRootFs: Int64?
    let sizeRw: Int64?
    let configuration: ContainerConfiguration?
    let containerIP: String?  // 从 status.networks[0].ipv4Address 提取

    var displayName: String {
        name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    var createdDate: Date? {
        ISO8601DateFormatter().date(from: createdAt)
    }

    var formattedPorts: String {
        guard let ports = ports, !ports.isEmpty else { return "无" }
        return ports.map { "\($0.hostPortString ?? "?"):\($0.containerPortString)/\($0.protocolType)" }.joined(separator: ", ")
    }

    var formattedMounts: String {
        guard let mounts = mounts, !mounts.isEmpty else { return "无" }
        return mounts.map { "\($0.source) → \($0.destination)" }.joined(separator: "; ")
    }

    var ipAddress: String? {
        containerIP ?? configuration?.ipAddress ?? networkSettings?.networks.values.first?.ipAddress
    }

    var hostname: String? {
        configuration?.hostname
    }

    var resources: ContainerResources? {
        configuration?.resources
    }

    var dnsServers: [String]? {
        configuration?.dns?.nameservers
    }

    var labels: [String: String]? {
        configuration?.labels
    }

    enum CodingKeys: String, CodingKey {
        case id
        case configuration
        case status
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        let config = try container.decode(ContainerConfiguration.self, forKey: .configuration)
        let statusInfo = try container.decode(ContainerStatusInfo.self, forKey: .status)

        name = config.id
        image = config.image?.reference ?? "未知镜像"
        createdAt = config.creationDate ?? ""
        ports = config.publishedPorts
        mounts = config.mounts
        sizeRootFs = nil
        sizeRw = nil
        configuration = config

        state = ContainerState(rawValue: statusInfo.state) ?? .unknown
        status = statusInfo.state
        containerIP = statusInfo.networks?.first?.ipv4Address?
            .split(separator: "/").first.map(String.init)

        if let networks = config.networks {
            var netDict: [String: NetworkSettings] = [:]
            for net in networks {
                let settings = NetworkSettings(
                    ipAddress: net.options?.ip,
                    macAddress: net.options?.mac,
                    gateway: nil,
                    hostname: net.options?.hostname,
                    mtu: net.options?.mtu
                )
                netDict[net.network] = settings
            }
            networkSettings = ContainerNetwork(networks: netDict)
        } else {
            networkSettings = nil
        }
    }

    init(id: String, name: String, image: String, state: ContainerState, status: String,
         createdAt: String, ports: [ContainerPort]?, mounts: [ContainerMount]?,
         networkSettings: ContainerNetwork?, sizeRootFs: Int64?, sizeRw: Int64?,
         configuration: ContainerConfiguration? = nil) {
        self.id = id
        self.name = name
        self.image = image
        self.state = state
        self.status = status
        self.createdAt = createdAt
        self.ports = ports
        self.mounts = mounts
        self.networkSettings = networkSettings
        self.sizeRootFs = sizeRootFs
        self.sizeRw = sizeRw
        self.configuration = configuration
        self.containerIP = nil
    }

    static func == (lhs: Container, rhs: Container) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
