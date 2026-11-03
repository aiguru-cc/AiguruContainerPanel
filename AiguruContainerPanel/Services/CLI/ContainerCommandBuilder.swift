import Foundation

/// 唯一的 `container run` 参数构建入口。
/// 运行命令使用参数数组而非重新解析字符串，因而能正确处理带空格的名称、路径和环境变量。
enum ContainerCommandBuilder {
    private static let catalog = CLICommandCatalog.shared
    private static let commandKey = "container.run"

    static func runArguments(
        image: String,
        name: String = "",
        ports: [String] = [],
        environment: [String] = [],
        volumes: [String] = [],
        options: ContainerRunOptions
    ) -> [String] {
        var arguments = catalog.path(command: commandKey) ?? []
        appendRunOptions(
            to: &arguments,
            name: name,
            ports: ports,
            environment: environment,
            volumes: volumes,
            options: options
        )
        arguments.append(image.taggedIfNeeded)
        arguments.append(contentsOf: options.command.filter { !$0.isEmpty })
        return arguments
    }

    static func displayCommand(for arguments: [String]) -> String {
        ([AppConstants.CLI.executableName] + arguments)
            .map(escapeForDisplay)
            .joined(separator: " ")
    }

    private static func appendRunOptions(
        to arguments: inout [String], name: String, ports: [String], environment: [String],
        volumes: [String], options: ContainerRunOptions
    ) {
        if options.detach { arguments.append(flag("detach")) }
        append("name", value: name, to: &arguments)
        if options.rm { arguments.append(flag("rm")) }
        if options.interactive { arguments.append(flag("interactive")) }
        if options.tty { arguments.append(flag("tty")) }

        append("publish", values: ports, to: &arguments)
        append("env", values: environment, to: &arguments)
        append("volume", values: volumes, to: &arguments)
        append("mount", values: options.advancedMounts, to: &arguments)
        append("tmpfs", values: options.tmpfsMounts, to: &arguments)

        append("cpus", value: options.cpus, to: &arguments)
        append("memory", value: options.memory, to: &arguments)
        append("entrypoint", value: options.entrypoint, to: &arguments)
        append("workdir", value: options.workdir, to: &arguments)
        append("user", value: options.user, to: &arguments)
        append("uid", value: options.uid, to: &arguments)
        append("gid", value: options.gid, to: &arguments)
        append("ulimit", values: options.ulimits, to: &arguments)
        append("envFile", value: options.envFile, to: &arguments)
        append("runtime", value: options.runtime, to: &arguments)
        append("shmSize", value: options.shmSize, to: &arguments)
        if options.initProcess { arguments.append(flag("init")) }
        if options.readOnly { arguments.append(flag("readOnly")) }

        append("network", value: options.network, to: &arguments)
        if options.noDNS { arguments.append(flag("noDNS")) }
        append("dns", values: options.dns, to: &arguments)
        append("dnsDomain", value: options.dnsDomain, to: &arguments)
        append("dnsSearch", values: options.dnsSearch, to: &arguments)
        append("dnsOption", values: options.dnsOptions, to: &arguments)
        append("publishSocket", values: options.publishSockets, to: &arguments)

        // --platform 优先于 --os/--arch（API 文档明确说明）
        append("platform", value: options.platform, to: &arguments)
        if options.platform == nil {
            append("os", value: options.os, to: &arguments)
            append("arch", value: options.arch, to: &arguments)
        }
        append("capAdd", values: options.capAdd, to: &arguments)
        append("capDrop", values: options.capDrop, to: &arguments)
        for (key, value) in options.labels.sorted(by: { $0.key < $1.key }) {
            arguments.append(contentsOf: [flag("label"), "\(key)=\(value)"])
        }

        append("kernel", value: options.kernel, to: &arguments)
        append("initImage", value: options.initImage, to: &arguments)
        append("cidfile", value: options.cidfile, to: &arguments)
        if options.sshForward { arguments.append(flag("ssh")) }
        if options.virtualization { arguments.append(flag("virtualization")) }
        if options.rosetta { arguments.append(flag("rosetta")) }
        append("scheme", value: options.scheme, to: &arguments)
        if let maximum = options.maxConcurrentDownloads {
            arguments.append(contentsOf: [flag("maxConcurrentDownloads"), String(maximum)])
        }
        append("progress", value: options.progress, to: &arguments)
        arguments.append(contentsOf: catalog.dynamicArguments(
            command: commandKey,
            values: options.catalogValues,
            version: EnvironmentManager.shared.currentVersion
        ))
    }

    private static func flag(_ key: String) -> String { catalog.flag(command: commandKey, option: key) }

    private static func append(_ key: String, value: String?, to arguments: inout [String]) {
        guard let value, !value.isEmpty else { return }
        arguments.append(contentsOf: [flag(key), value])
    }

    private static func append(_ key: String, values: [String], to arguments: inout [String]) {
        for value in values where !value.isEmpty { arguments.append(contentsOf: [flag(key), value]) }
    }

    nonisolated private static func escapeForDisplay(_ argument: String) -> String {
        guard argument.contains(where: { $0.isWhitespace || $0 == "\"" }) else { return argument }
        return "\"\(argument.replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}

private extension String {
    var taggedIfNeeded: String {
        // 仓库地址可能含端口号（localhost:5000/image），只有最后路径段的冒号才代表 tag。
        let lastPathComponent = split(separator: "/").last ?? Substring(self)
        return lastPathComponent.contains(":") ? self : "\(self):\(AppConstants.CLI.defaultImageTag)"
    }
}
