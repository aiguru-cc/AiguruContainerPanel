import Foundation

/// 严格根据当前模板声明补齐宿主机挂载源；不会为无关模板生成 Web/HA 目录。
enum TemplateMountScaffold {
    struct Result {
        let created: [String]
        let skippedExternal: [String]
    }

    static func generate(for template: ClusterTemplate, in projectDirectory: String) throws -> Result {
        let root = URL(fileURLWithPath: projectDirectory, isDirectory: true).standardizedFileURL
        var created: [String] = []
        var skippedExternal: [String] = []

        // 从候选资源库中只挑选模板当前实际声明的路径。模板来源、名称和 role
        // 都不参与判断：删除挂载或修改路径后，对应资源立即不再生成。
        created.append(contentsOf: try materializeKnownResources(
            for: template, root: root
        ))

        for service in template.services {
            for specification in service.volumes {
                guard let source = mountSource(specification) else { continue }
                if source.hasPrefix("{{SERVICE_VOLUME:") { continue }
                guard source.contains("{{PROJECT_DIR}}") else {
                    if source.hasPrefix("/") { skippedExternal.append(source) }
                    continue
                }
                let resolvedPath = source.replacingOccurrences(of: "{{PROJECT_DIR}}", with: root.path)
                let url = URL(fileURLWithPath: resolvedPath).standardizedFileURL
                guard url.path == root.path || url.path.hasPrefix(root.path + "/") else {
                    throw TemplateMountScaffoldError.escapesProjectDirectory(source)
                }
                try createIfMissing(url, relativeTo: root, created: &created)
                if isDirectory(url) {
                    // 一键生成挂载源时直接初始化宿主目录权限。Apple Container 的
                    // virtiofs bind mount 不允许容器内 root 执行 chown，镜像内的
                    // www/mysql 等用户因此必须在容器启动前就能访问宿主目录。
                    try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: url.path)

                    // 宝塔把 Nginx 的站点配置和 ACME challenge 放在 vhost/nginx。
                    // 该子目录有时由镜像初始化脚本以 600 创建，导致面板无法生成
                    // well-known。提前在宿主机创建并设置权限，避免依赖容器内 chown。
                    if mountDestination(specification) == "/www/server/panel/vhost" {
                        let nginxDirectory = url.appendingPathComponent("nginx", isDirectory: true)
                        try FileManager.default.createDirectory(at: nginxDirectory, withIntermediateDirectories: true)
                        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: nginxDirectory.path)
                        created.append(relativePath(nginxDirectory, root: root) + "/")
                    }
                }
            }
            if let preparation = service.preDeploy {
                let context = root.appendingPathComponent(preparation.context, isDirectory: true).standardizedFileURL
                guard context.path == root.path || context.path.hasPrefix(root.path + "/") else {
                    throw TemplateMountScaffoldError.escapesProjectDirectory(preparation.context)
                }
                try createDirectoryIfMissing(context, relativeTo: root, created: &created)
            }
        }
        return Result(created: Array(Set(created)).sorted(), skippedExternal: Array(Set(skippedExternal)).sorted())
    }

    private static func materializeKnownResources(for template: ClusterTemplate, root: URL) throws -> [String] {
        var requestedRelativePaths = Set<String>()
        for service in template.services {
            for specification in service.volumes {
                guard let source = mountSource(specification), source.hasPrefix("{{PROJECT_DIR}}/") else { continue }
                requestedRelativePaths.insert(String(source.dropFirst("{{PROJECT_DIR}}/".count)))
            }
            if let context = service.preDeploy?.context, !context.isEmpty {
                requestedRelativePaths.insert(context)
            }
        }
        guard !requestedRelativePaths.isEmpty else { return [] }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiguru-template-scaffold-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        _ = try WebDevelopmentScaffold.generate(in: staging.path)

        var created: [String] = []
        for relativePath in requestedRelativePaths.sorted() {
            let staged = staging.appendingPathComponent(relativePath)
            guard FileManager.default.fileExists(atPath: staged.path) else { continue }
            let destination = root.appendingPathComponent(relativePath)
            try copyMissing(from: staged, to: destination, root: root, created: &created)
        }
        return created
    }

    private static func copyMissing(from source: URL, to destination: URL, root: URL, created: inout [String]) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory) else { return }
        if !isDirectory.boolValue {
            guard !FileManager.default.fileExists(atPath: destination.path) else { return }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: destination)
            created.append(relativePath(destination, root: root))
            return
        }
        if !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            created.append(relativePath(destination, root: root) + "/")
        }
        let children = try FileManager.default.contentsOfDirectory(
            at: source, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )
        for child in children {
            try copyMissing(
                from: child,
                to: destination.appendingPathComponent(child.lastPathComponent),
                root: root,
                created: &created
            )
        }
    }

    private static func mountSource(_ specification: String) -> String? {
        // 宿主机绝对路径可能包含空格，但 macOS 路径本身不含冒号；最多拆成 source、target、options。
        let parts = specification.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        return String(parts[0])
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }

    private static func mountDestination(_ specification: String) -> String? {
        let parts = specification.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        return String(parts[1])
    }

    private static func createIfMissing(_ url: URL, relativeTo root: URL, created: inout [String]) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        // 有扩展名的挂载源通常是配置/证书/JAR 文件；无扩展名按目录创建。
        if !url.pathExtension.isEmpty {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url, options: .atomic)
            created.append(relativePath(url, root: root))
        } else {
            try createDirectoryIfMissing(url, relativeTo: root, created: &created)
        }
    }

    private static func createDirectoryIfMissing(_ url: URL, relativeTo root: URL, created: inout [String]) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        created.append(relativePath(url, root: root) + "/")
    }

    private static func relativePath(_ url: URL, root: URL) -> String {
        String(url.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

enum TemplateMountScaffoldError: LocalizedError {
    case escapesProjectDirectory(String)

    var errorDescription: String? {
        switch self {
        case .escapesProjectDirectory(let path):
            return "挂载路径超出项目目录，已拒绝生成：\(path)"
        }
    }
}
