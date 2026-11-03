import Foundation

struct ContainerDirectory: Identifiable, Hashable {
    enum Kind: String {
        case data, cli, cache, logs, configuration, kernels, plugins

        var title: String {
            switch self {
            case .data: return "数据目录"
            case .cli : return "CLI目录"
            case .cache: return "镜像内容存储"
            case .logs: return "日志目录"
            case .configuration: return "配置目录"
            case .kernels: return "内核目录"
            case .plugins: return "插件目录"
            }
        }

        var explanation: String {
            switch self {
            case .cli: return "CLI安装主目录"
            case .data: return "镜像、容器与卷等运行数据。"
            case .cache: return "镜像层等内容寻址数据；不得直接删除，应使用官方 prune 指令。"
            case .logs: return "Container 服务及任务相关日志。"
            case .configuration: return "全局 TOML 配置文件所在位置。"
            case .kernels: return "为 Machine 指定或安装的内核文件。"
            case .plugins: return "为容器面板插件安装目录。"
            }
        }

        var icon: String {
            switch self {
            case .cli : return "command"
            case .data: return "externaldrive"
            case .cache: return "internaldrive"
            case .logs: return "doc.text"
            case .configuration: return "gearshape"
            case .kernels: return "cpu"
            case .plugins: return "calendar.badge.plus"
            }
        }
    }

    let kind: Kind
    let path: String
    let exists: Bool
    let sizeDescription: String

    var id: Kind { kind }
}

struct HostResourceSnapshot {
    let operatingSystem: String
    let architecture: String
    let logicalCPUs: Int
    let physicalMemory: UInt64

    var memoryDescription: String {
        ByteCountFormatter.string(fromByteCount: Int64(physicalMemory), countStyle: .memory)
    }
}
