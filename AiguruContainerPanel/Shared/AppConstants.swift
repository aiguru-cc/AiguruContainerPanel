import Foundation

/// 应用内跨模块共享的稳定值。
///
/// 只放运行时约定、CLI 选项和持久化键；页面文案应继续放在本地化资源中，
/// 避免将 UI 文案误当作业务常量扩散到各个 Service。
enum AppConstants {
    enum CLI {
        static let executablePath = "/usr/local/bin/container"
        static let officialPluginRoot = "/usr/local/libexec/container/plugins"
        static let executableName = "container"
        static let shellPath = "/bin/sh"
        static let osascriptPath = "/usr/bin/osascript"
        static let bashPath = "/bin/bash"
        static let tarPath = "/usr/bin/tar"
        static let defaultImageTag = "latest"
        static let jsonFormat = "json"
        static let affirmativeInput = Data("y\n".utf8)
    }

    enum ContainerLabel {
        static let cliVersion = "cc.aiguru.container-cli-version"
        static let managedBy = "cc.aiguru.managed-by"
        static let managedByValue = "AiguruContainerPanel"
        static let applicationDependsOn = "cc.aiguru.application-depends-on"
        static let applicationUpstreams = "cc.aiguru.application-upstreams"
        static let applicationDNSName = "cc.aiguru.application-dns-name"
    }

    enum Paths {
        static let containerDirectoryName = ".container"
        static let configurationRelativePath = ".config/container/config.toml"
        static let kernelRelativePath = ".container/kernel"
        static let pluginDirectoryName = "AiguruContainerPanel/Plugins"
    }

    enum UserDefaultsKey {
        static let selectedEnvironmentID = "SelectedEnvironmentID"
        static let customEnvironments = "CustomEnvironments"
        static let pluginSources = "PluginSources"
        static let installedPlugins = "InstalledPlugins"
        static let installedPluginPackages = "InstalledPluginPackages"
        static let containerGuardianConfigurations = "ContainerGuardianConfigurations"
    }

    enum Environment {
        /// 默认系统环境必须跨应用启动保持同一身份，否则已保存的选择和版本档位会失效。
        static let systemEnvironmentID = UUID(uuidString: "A16C0A11-EC01-4A13-8000-000000000001")!
    }

    enum Time {
        static let shortCommandTimeout: TimeInterval = 10
        static let standardCommandTimeout: TimeInterval = 30
        static let longCommandTimeout: TimeInterval = 120
        static let streamingCommandTimeout: TimeInterval = 60 * 60
        static let processTerminationGracePeriod: UInt64 = 200_000_000
        static let taskPanelDismissDelay: TimeInterval = 3
        static let environmentDetectionDelay: TimeInterval = 0.5
        static let monitoringInterval: TimeInterval = 10
    }

    enum Retry {
        static let maximumAttempts = 3
        static let initialDelayNanoseconds: UInt64 = 2_000_000_000
    }

    enum Display {
        static let unknown = "未知"
        static let noValue = "无"
        static let logSummaryLength = 200
        static let defaultLogTail = 100
        static let maximumTaskOutputLines = 1_000
    }

    // MARK: - 镜像

    enum Image {
        /// 默认 OCI Registry 前缀（短名称自动补全）
        static let defaultRegistry = "docker.io/library"
        /// 备用镜像源（Aliyun 杭州）
        static let aliyunRegistry = "registry.cn-hangzhou.aliyuncs.com"
        /// GHCR
        static let ghcrRegistry = "ghcr.io"
        /// Quay
        static let quayRegistry = "quay.io"
        /// OCI manifest 检测 URL 模板
        static let manifestTestTemplate = "https://$REGISTRY/v2/$PATH/manifests/$TAG"
    }

    // MARK: - 插件

    enum Plugin {
        /// 默认市场源列表
        static let defaultSources: [(name: String, url: String)] = [
            ("官方市场 (Gitee)", "https://gitee.com/imccc_net/librarys/raw/master/main/plugins.json"),
            ("镜像市场 (GitHub)", "https://raw.githubusercontent.com/imcccphp/librarys/refs/heads/master/main/plugins.json")
        ]
        /// 插件包扩展名
        static let packageExtension = "tar.gz"
        /// dlopen 入口符号名
        static let entrySymbol = "acp_plugin_register"
    }

    // MARK: - 镜像源

    enum ImageSource {
        static let defaultSources: [(name: String, url: String, type: String)] = [
            ("毫秒镜像", "https://docker.1ms.run", "1ms"),
            ("轩辕镜像", "https://docker.xuanyuan.me", "xuanyuan"),
            ("DaoCloud", "https://docker.m.daocloud.io", "daocloud"),
            ("Docker Hub", "https://registry-1.docker.io", "dockerhub"),
        ]
    }
}
