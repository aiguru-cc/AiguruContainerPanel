import Foundation

struct KubernetesAPIProfile: Codable, Identifiable, Hashable {
    let key: String
    let label: String
    let minimumPluginVersion: String
    let maximumPluginVersion: String?
    let kubernetesVersion: String
    let defaultNodeImage: String
    let resources: [String: String]

    var id: String { key }
}

private struct KubernetesAPICatalogFile: Codable {
    let schemaVersion: Int
    let documentationURL: String?
    let profiles: [KubernetesAPIProfile]
}

/// Kubernetes API 与 Apple K8s 插件版本的唯一映射库。
/// 档位只由当前工作环境实际返回的 `container k8s --version` 激活；探测失败时保留该环境上次验证档位。
final class KubernetesAPICatalog {
    static let shared = KubernetesAPICatalog()

    let schemaVersion: Int
    let documentationURL: URL?
    private let profiles: [KubernetesAPIProfile]
    private let defaults: UserDefaults
    private let persistencePrefix = "kubernetes.api.profile."

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let url = Bundle.main.url(forResource: "KubernetesAPICatalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(KubernetesAPICatalogFile.self, from: data) else {
            assertionFailure("KubernetesAPICatalog.json 缺失或格式错误")
            schemaVersion = 0
            documentationURL = nil
            profiles = []
            return
        }
        schemaVersion = file.schemaVersion
        documentationURL = file.documentationURL.flatMap(URL.init(string:))
        profiles = file.profiles
    }

    func profile(forPluginVersion version: CLIVersion) -> KubernetesAPIProfile? {
        guard version.isKnown else { return nil }
        return profiles
            .filter {
                version >= CLIVersion($0.minimumPluginVersion)
                    && ($0.maximumPluginVersion == nil || version <= CLIVersion($0.maximumPluginVersion!))
            }
            .max { CLIVersion($0.minimumPluginVersion) < CLIVersion($1.minimumPluginVersion) }
    }

    /// 插件升级成功后原子切换并持久化当前环境档位。未知插件版本不会覆盖上一档位。
    @discardableResult
    func synchronize(pluginVersion: CLIVersion, environmentID: UUID?) -> KubernetesAPIProfile? {
        guard let profile = profile(forPluginVersion: pluginVersion), let environmentID else { return nil }
        defaults.set(profile.key, forKey: persistencePrefix + environmentID.uuidString)
        return profile
    }

    func retainedProfile(environmentID: UUID?) -> KubernetesAPIProfile? {
        guard let environmentID,
              let key = defaults.string(forKey: persistencePrefix + environmentID.uuidString) else { return nil }
        return profiles.first { $0.key == key }
    }

    func activeProfile(pluginVersion: CLIVersion, environmentID: UUID?) -> KubernetesAPIProfile? {
        profile(forPluginVersion: pluginVersion) ?? retainedProfile(environmentID: environmentID)
    }

    var latestProfile: KubernetesAPIProfile? {
        profiles.max { CLIVersion($0.minimumPluginVersion) < CLIVersion($1.minimumPluginVersion) }
    }

    func apiVersion(for kind: String, pluginVersion: CLIVersion, environmentID: UUID?) -> String? {
        activeProfile(pluginVersion: pluginVersion, environmentID: environmentID)?.resources[kind]
    }
}
