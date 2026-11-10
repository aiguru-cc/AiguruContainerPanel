import Foundation

struct CLIOptionUI: Codable {
    let section: String
    let label: String
    let control: String
    let placeholder: String?
    let help: String?
    let choices: [String]?
}

struct CLIOptionDefinition: Codable, Identifiable {
    let key: String
    let flag: String
    let minimumVersion: String
    let maximumVersion: String?
    let repeatable: Bool
    let ui: CLIOptionUI?

    var id: String { key }

    var requiredVersion: CLIVersion { CLIVersion(minimumVersion) }
}

struct CLICommandDefinition: Codable {
    let key: String
    let path: [String]
    let minimumVersion: String
    let maximumVersion: String?
    let options: [CLIOptionDefinition]
}

struct CLICatalogProfile: Codable, Identifiable {
    let key: String
    let label: String
    let minimumVersion: String
    let maximumVersion: String?

    var id: String { key }
}

struct CLIConstraintDefinition: Codable {
    let key: String
    let minimumVersion: String
    let maximumVersion: String?
    let integerValue: Int
    let recommendedValue: String?
}

struct CLICapabilityDefinition: Codable {
    let key: String
    let minimumVersion: String
    let maximumVersion: String?
    let enabled: Bool
}

private struct CLICommandCatalogFile: Codable {
    let schemaVersion: Int
    let targetVersion: String?
    let compatibleVersions: [String]?
    let documentationURL: String?
    let profiles: [CLICatalogProfile]?
    let capabilities: [CLICapabilityDefinition]?
    let constraints: [CLIConstraintDefinition]?
    let commands: [CLICommandDefinition]
}

/// CLI 命令与参数的唯一版本目录。新增参数优先修改 JSON，无需在各页面重复声明版本。
final class CLICommandCatalog {
    static let shared = CLICommandCatalog()
    var allCommandKeys: [String] { Array(commands.keys).sorted() }

    private let commands: [String: CLICommandDefinition]
    let schemaVersion: Int
    let targetVersion: CLIVersion
    let compatibleVersions: [CLIVersion]
    let documentationURL: URL?
    private let profiles: [CLICatalogProfile]
    private let capabilities: [CLICapabilityDefinition]
    private let constraints: [CLIConstraintDefinition]

    private init() {
        guard let url = Bundle.main.url(forResource: "CLICommandCatalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(CLICommandCatalogFile.self, from: data) else {
            assertionFailure("CLICommandCatalog.json 缺失或格式错误")
            commands = [:]
            schemaVersion = 0
            targetVersion = .unknown
            compatibleVersions = []
            documentationURL = nil
            profiles = []
            capabilities = []
            constraints = []
            return
        }
        commands = Dictionary(uniqueKeysWithValues: file.commands.map { ($0.key, $0) })
        schemaVersion = file.schemaVersion
        targetVersion = CLIVersion(file.targetVersion ?? "0.0.0")
        compatibleVersions = (file.compatibleVersions ?? []).map { rawVersion in
            CLIVersion(rawVersion)
        }
        documentationURL = file.documentationURL.flatMap(URL.init(string:))
        profiles = file.profiles ?? []
        capabilities = file.capabilities ?? []
        constraints = file.constraints ?? []
    }

    func flag(command: String, option key: String) -> String {
        commands[command]?.options.first(where: { $0.key == key })?.flag ?? "--\(key)"
    }

    func path(command key: String) -> [String]? {
        commands[key]?.path
    }

    func path(command key: String, version: CLIVersion) -> [String]? {
        guard supports(command: key, version: version), var path = commands[key]?.path else { return nil }
        // Container 1.6 renamed the Kubernetes plugin command group from `k8s` to `cluster`.
        if version >= CLIVersion("1.6.0"), path.first == "k8s" { path[0] = "cluster" }
        return path
    }

    /// 业务层唯一的 CLI 参数数组构建入口。命令路径和选项 flag 均来自 JSON 指令库。
    func arguments(
        command key: String,
        options: [String: [String]] = [:],
        positionals: [String] = []
    ) -> [String] {
        guard let definition = commands[key] else {
            assertionFailure("指令库缺少命令：\(key)")
            return []
        }
        var result = definition.path
        for option in definition.options {
            for value in options[option.key, default: []] where !value.isEmpty {
                result.append(option.flag)
                if value != "true" { result.append(value) }
                if !option.repeatable { break }
            }
        }
        result.append(contentsOf: positionals)
        return result
    }

    func minimumVersion(command: String, option key: String) -> CLIVersion? {
        commands[command]?.options.first(where: { $0.key == key })?.requiredVersion
    }

    func minimumVersion(command key: String) -> CLIVersion? {
        commands[key].map { CLIVersion($0.minimumVersion) }
    }

    func supports(command key: String, version: CLIVersion) -> Bool {
        guard version.isKnown, let definition = commands[key] else { return false }
        guard version >= CLIVersion(definition.minimumVersion) else { return false }
        if let maximum = definition.maximumVersion, version > CLIVersion(maximum) { return false }
        return true
    }

    func supports(command: String, option key: String, version: CLIVersion) -> Bool {
        guard supports(command: command, version: version),
              let option = commands[command]?.options.first(where: { $0.key == key }) else { return false }
        guard version >= option.requiredVersion else { return false }
        if let maximum = option.maximumVersion, version > CLIVersion(maximum) { return false }
        return true
    }

    /// 已知版本档位用于设置页展示和配置审计；实际执行仍以当前环境探测到的版本为准。
    func isConfiguredVersion(_ version: CLIVersion) -> Bool {
        profile(for: version) != nil
    }

    /// 根据当前工作环境实际探测到的 CLI 版本选择对应指令档位。
    /// 高于当前目录目标版本时使用最新档位；低于所有档位或未知版本不猜测。
    func profile(for version: CLIVersion) -> CLICatalogProfile? {
        guard version.isKnown else { return nil }
        return profiles
            .filter { profile in
                guard version >= CLIVersion(profile.minimumVersion) else { return false }
                if let maximum = profile.maximumVersion, version > CLIVersion(maximum) { return false }
                return true
            }
            .max { CLIVersion($0.minimumVersion) < CLIVersion($1.minimumVersion) }
            ?? (version > targetVersion ? profiles.max { CLIVersion($0.minimumVersion) < CLIVersion($1.minimumVersion) } : nil)
    }

    func profileLabel(for version: CLIVersion) -> String {
        profile(for: version)?.label ?? "未匹配"
    }

    /// 补丁级行为差异不应复制整套命令。能力由当前工作环境的实际 CLI 版本激活。
    func supportsCapability(_ key: String, version: CLIVersion) -> Bool {
        guard version.isKnown else { return false }
        return capabilities
            .filter { capability in
                guard capability.key == key, version >= CLIVersion(capability.minimumVersion) else { return false }
                if let maximum = capability.maximumVersion, version > CLIVersion(maximum) { return false }
                return true
            }
            .max { CLIVersion($0.minimumVersion) < CLIVersion($1.minimumVersion) }?
            .enabled ?? false
    }

    func integerConstraint(_ key: String, version: CLIVersion) -> Int? {
        let lookupVersion = version.isKnown ? version : targetVersion
        return constraints
            .filter { constraint in
                guard constraint.key == key, lookupVersion >= CLIVersion(constraint.minimumVersion) else { return false }
                if let maximum = constraint.maximumVersion, lookupVersion > CLIVersion(maximum) { return false }
                return true
            }
            .max { CLIVersion($0.minimumVersion) < CLIVersion($1.minimumVersion) }?
            .integerValue
    }

    func recommendedValue(forConstraint key: String, version: CLIVersion) -> String? {
        let lookupVersion = version.isKnown ? version : targetVersion
        return constraints
            .filter { $0.key == key && lookupVersion >= CLIVersion($0.minimumVersion) }
            .filter { $0.maximumVersion == nil || lookupVersion <= CLIVersion($0.maximumVersion!) }
            .max { CLIVersion($0.minimumVersion) < CLIVersion($1.minimumVersion) }?
            .recommendedValue
    }

    func dynamicOptions(command: String, version: CLIVersion) -> [CLIOptionDefinition] {
        guard version.isKnown else { return [] }
        guard let options = commands[command]?.options else { return [] }
        return options.filter { option in
            guard option.ui != nil else { return false }
            if version.isKnown && version < option.requiredVersion { return false }
            if version.isKnown, let maximum = option.maximumVersion, version > CLIVersion(maximum) { return false }
            return true
        }
    }

    func dynamicArguments(command: String, values: [String: [String]], version: CLIVersion) -> [String] {
        let definitions = dynamicOptions(command: command, version: version)
        var result: [String] = []
        for option in definitions {
            for value in values[option.key, default: []] where !value.isEmpty {
                if option.ui?.control == "toggle" {
                    if value == "true" { result.append(option.flag) }
                } else {
                    result.append(contentsOf: [option.flag, value])
                }
            }
        }
        return result
    }

    func unsupportedFlags(in arguments: [String], command: String, version: CLIVersion) -> [(String, CLIVersion)] {
        guard version.isKnown, let definition = commands[command] else { return [] }
        let used = Set(arguments.filter { $0.hasPrefix("-") })
        return definition.options.compactMap { option in
            used.contains(option.flag) && version < option.requiredVersion ? (option.flag, option.requiredVersion) : nil
        }
    }
}
