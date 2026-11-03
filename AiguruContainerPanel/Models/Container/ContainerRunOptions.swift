//
//  ContainerRunOptions.swift
//  AiguruContainerPanel
//
//  容器运行选项模型；可用字段由当前工作环境匹配的 CLI 指令档位决定。
//  用于构建 container run 命令。
//

import Foundation

/// 容器运行选项（完整参数）
struct ContainerRunOptions {
    // MARK: - 基础选项
    var detach: Bool = true
    var rm: Bool = false
    var interactive: Bool = false
    var tty: Bool = false

    // MARK: - 资源限制
    var cpus: String?     // 如 "2", "0.5"
    var memory: String?   // 如 "2G", "512M"

    // MARK: - 运行时选项
    var entrypoint: String?
    var workdir: String?
    var user: String?
    var uid: String?
    var gid: String?
    var initProcess: Bool = false
    var readOnly: Bool = false
    var shmSize: String?    // --shm-size，如 "256M"
    var ulimits: [String] = []  // --ulimit，如 "nofile=1024:2048"
    var envFile: String?    // --env-file
    var runtime: String?    // --runtime

    // MARK: - 网络配置
    var network: String?
    var dns: [String] = []
    var dnsSearch: [String] = []
    var dnsDomain: String?
    var dnsOptions: [String] = []
    var noDNS: Bool = false
    var publishSockets: [String] = []

    // MARK: - 挂载选项
    var advancedMounts: [String] = []  // --mount 字符串
    var tmpfsMounts: [String] = []     // --tmpfs

    // MARK: - 平台与架构
    var os: String?      // linux / windows
    var arch: String?    // arm64 / amd64
    var platform: String? // --platform，格式 os/arch[/variant]，优先于 --os/--arch

    // MARK: - 能力与权限
    var capAdd: [String] = []
    var capDrop: [String] = []

    // MARK: - 标签与元数据
    var labels: [String: String] = [:]

    // MARK: - 高级内核
    var kernel: String?
    var initImage: String?

    // MARK: - 1.2.x 新增
    var rosetta: Bool = false          // --rosetta
    var progress: String?              // --progress: auto|none|ansi|plain|color

    // MARK: - 其他
    var cidfile: String?
    var sshForward: Bool = false
    var virtualization: Bool = false
    var scheme: String?   // auto, https, http；可选值以当前版本指令库为准
    var maxConcurrentDownloads: Int?
    /// 镜像后的进程参数，对应 `container run IMAGE [COMMAND ...]`。
    var command: [String] = []
    /// 配置文件动态生成的参数值；key 对应 CLICommandCatalog option.key。
    var catalogValues: [String: [String]] = [:]
}
