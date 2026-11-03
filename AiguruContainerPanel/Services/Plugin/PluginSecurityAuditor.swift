//
//  PluginSecurityAuditor.swift
//  AiguruContainerPanel
//
//  插件安全审查器：在插件安装、加载前进行静态审查，
//  防止安装后门、木马、危险操作、内存操作、危险二进制等。
//
//  审查内容：
//    - 包结构：pluginInfo.json 完整性、符号链接逃逸、SUID 权限、异常文件
//    - 二进制字符串：网络外联/反弹 shell、危险命令执行、内存操作、系统路径
//    - 符号表：未定义的危险 C 函数（system/popen/dlopen/ptrace 等）
//    - 元数据与包名一致性
//
//  判定规则：出现任一「危险」级别发现即拒绝安装/加载；「警告」级别记录但不阻断。
//

import Foundation

struct PluginSecurityFinding: Identifiable, Equatable {
    enum Severity: String, Equatable {
        case info, warning, danger
    }
    let id = UUID()
    let severity: Severity
    let category: String
    let detail: String
    let source: String   // 哪个文件/位置

    static func == (lhs: PluginSecurityFinding, rhs: PluginSecurityFinding) -> Bool {
        lhs.severity == rhs.severity && lhs.category == rhs.category && lhs.detail == rhs.detail && lhs.source == rhs.source
    }
}

struct PluginSecurityReport {
    let findings: [PluginSecurityFinding]
    var dangerCount: Int { findings.filter { $0.severity == .danger }.count }
    var warningCount: Int { findings.filter { $0.severity == .warning }.count }
    /// 是否允许安装/加载（无危险项）
    var allowed: Bool { dangerCount == 0 }
    var summary: String {
        var parts: [String] = []
        if dangerCount > 0 { parts.append("\(dangerCount) 项危险") }
        if warningCount > 0 { parts.append("\(warningCount) 项警告") }
        if parts.isEmpty { return "通过" }
        return parts.joined(separator: "，")
    }
}

final class PluginSecurityAuditor {
    static let shared = PluginSecurityAuditor()
    private init() {}

    /// 允许出现在插件二进制中的域名白名单（插件市场/仓库域名）
    private let allowedDomains: Set<String> = [
        "gitee.com", "github.com", "raw.githubusercontent.com", "gitlab.com",
        "bitbucket.org", "jsdelivr.net", "cdn.jsdelivr.net",
        "apple.com", "icloud.com", "localhost","aiguru.cc","aiguru.vip","imccc.cc"
    ]

    // MARK: - 审查缓存（按目录指纹，避免重复审查拖慢启动/环境切换）

    private struct AuditCacheEntry {
        let fingerprint: String
        let report: PluginSecurityReport
    }
    private let cacheLock = NSLock()
    private var auditCache: [String: AuditCacheEntry] = [:]

    /// 目录指纹：所有文件（路径 + 修改时间 + 大小），文件未变则复用上次审查结果
    private func fingerprint(of dir: URL) -> String {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
        let parts = contents.map { url -> String in
            let name = url.lastPathComponent
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return "\(name):\(Int(mtime)):\(size)"
        }.sorted().joined(separator: "|")
        return parts
    }

    // MARK: - 入口

    /// 审查插件目录（安装后 / 启动加载前），带指纹缓存
    func audit(packageDirectory dir: URL) -> PluginSecurityReport {
        let fp = fingerprint(of: dir)
        cacheLock.lock()
        if let cached = auditCache[dir.path], cached.fingerprint == fp {
            cacheLock.unlock()
            return cached.report
        }
        cacheLock.unlock()

        let report = performAudit(packageDirectory: dir)

        cacheLock.lock()
        auditCache[dir.path] = AuditCacheEntry(fingerprint: fp, report: report)
        cacheLock.unlock()
        return report
    }

    private func performAudit(packageDirectory dir: URL) -> PluginSecurityReport {
        var findings: [PluginSecurityFinding] = []

        // 1. pluginInfo.json 必须存在且可解析
        let infoPath = dir.appendingPathComponent("pluginInfo.json")
        guard FileManager.default.fileExists(atPath: infoPath.path) else {
            findings.append(.init(severity: .danger, category: "包结构", detail: "缺少 pluginInfo.json", source: dir.lastPathComponent))
            return PluginSecurityReport(findings: findings)
        }
        guard let data = try? Data(contentsOf: infoPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            findings.append(.init(severity: .danger, category: "包结构", detail: "pluginInfo.json 无法解析", source: dir.lastPathComponent))
            return PluginSecurityReport(findings: findings)
        }

        // 2. 目录内文件清单
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isSymbolicLinkKey, .fileSizeKey])) ?? []

        // 3. 符号链接逃逸检查
        for url in files {
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                let dest = (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) ?? ""
                if dest.hasPrefix("/") && !dest.hasPrefix(dir.path) {
                    findings.append(.init(severity: .danger, category: "包结构", detail: "符号链接指向包外: \(dest)", source: url.lastPathComponent))
                }
            }
        }

        // 4. SUID / 危险权限
        for url in files where !url.hasDirectoryPath {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let perms = attrs[.posixPermissions] as? NSNumber, perms.uint16Value & 0o4000 != 0 {
                findings.append(.init(severity: .danger, category: "权限", detail: "SUID 权限位被设置", source: url.lastPathComponent))
            }
        }

        // 5. 包名一致性（.market_name 或 pluginInfo name 必须匹配）
        if let marketName = try? String(contentsOf: dir.appendingPathComponent(".market_name"), encoding: .utf8),
           let jsonName = json["name"], marketName.trimmingCharacters(in: .whitespacesAndNewlines) != jsonName {
            findings.append(.init(severity: .warning, category: "包结构", detail: "市场名与内部名不一致", source: ".market_name"))
        }

        // 6. 二进制文件审查（dylib 等）
        for url in files where url.pathExtension == "dylib" || url.pathExtension == "so" || url.pathExtension == "bundle" {
            findings += auditBinary(at: url)
            findings += auditSymbols(at: url)
        }

        // 7. 脚本/配置文件文本审查
        for url in files where ["sh", "py", "js", "rb", "pl", "command"].contains(url.pathExtension.lowercased()) {
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                findings += auditText(text, source: url.lastPathComponent)
            }
        }

        return PluginSecurityReport(findings: findings)
    }

    /// 审查单个 dylib（dlopen 前调用）
    func audit(dylib url: URL) -> PluginSecurityReport {
        PluginSecurityReport(findings: auditBinary(at: url) + auditSymbols(at: url))
    }

    // MARK: - 二进制审查

    private func auditBinary(at url: URL) -> [PluginSecurityFinding] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
        var findings: [PluginSecurityFinding] = []
        let strings = extractStrings(from: data)

        // 预过滤：合并全部危险关键词为单个正则，未命中的字符串跳过详细规则（大幅提速）
        let prefilterPattern = "nc -e|/dev/tcp|bash -i|socat|mkfifo|system\\(|popen\\(|posix_spawn|exec|NSTask|Process\\(|osascript|dlopen\\(|dlsym\\(|mprotect|mmap|PROT_EXEC|ptrace|vm_protect|pthread_create|https?://|/Library/LaunchDaemons|/Library/LaunchAgents|/etc/|/usr/bin/sudo|/bin/sh|/bin/bash|/bin/zsh|/tmp/"
        let prefilter = try? NSRegularExpression(pattern: prefilterPattern)
        let suspicious: [String]
        if let prefilter {
            suspicious = strings.filter { s in
                prefilter.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
            }
        } else {
            suspicious = strings
        }

        // 1. 反弹 shell 特征（最高危）
        let reverseShellPatterns: [(String, String)] = [
            (".*nc\\s+-e.*", "netcat -e 反弹 shell"),
            (".*/bin/(ba|z|k)?sh.*>&?/dev/tcp.*", "通过 /dev/tcp 反弹 shell"),
            (".*bash\\s+-i.*", "交互式 bash 反弹特征"),
            (".*socat.*(exec|system).*", "socat 执行反弹"),
            (".*mkfifo.*", "FIFO 反弹 shell"),
        ]
        for (pattern, desc) in reverseShellPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               suspicious.contains(where: { regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }) {
                findings.append(.init(severity: .danger, category: "后门", detail: "检测到反弹 shell 特征（\(desc)）", source: url.lastPathComponent))
            }
        }

        // 2. 危险命令执行
        let execPatterns: [(String, String, PluginSecurityFinding.Severity)] = [
            ("system\\s*\\(", "system() 命令执行", .danger),
            ("popen\\s*\\(", "popen() 命令执行", .danger),
            ("posix_spawn", "posix_spawn 进程创建", .danger),
            ("exec[lvpe]*\\s*\\(", "exec 系列进程执行", .danger),
            ("NSTask|__NSTask", "NSTask 进程执行", .warning),
            ("Process\\s*\\(", "Process 进程执行", .warning),
            ("osascript", "AppleScript 执行", .danger),
        ]
        for (pattern, desc, sev) in execPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               suspicious.contains(where: { regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }) {
                findings.append(.init(severity: sev, category: "危险操作", detail: desc, source: url.lastPathComponent))
            }
        }

        // 3. 内存操作
        let memoryPatterns: [(String, String)] = [
            ("dlopen\\s*\\(", "dlopen 动态加载"),
            ("dlsym\\s*\\(", "dlsym 符号解析"),
            ("mprotect", "mprotect 修改内存权限"),
            ("mmap\\s*\\([^)]*PROT_EXEC|PROT_EXEC", "mmap 可执行内存映射"),
            ("ptrace", "ptrace 进程注入/调试"),
            ("vm_protect", "vm_protect 内存权限修改"),
            ("pthread_create", "pthread_create 创建线程"),
        ]
        for (pattern, desc) in memoryPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               suspicious.contains(where: { regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }) {
                findings.append(.init(severity: .danger, category: "内存操作", detail: desc, source: url.lastPathComponent))
            }
        }

        // 4. 网络外联
        let urlRegex = try? NSRegularExpression(pattern: "https?://([^/\\s\"'<>]+)")
        var urls = Set<String>()
        for s in suspicious {
            let range = NSRange(s.startIndex..., in: s)
            guard let matches = urlRegex?.matches(in: s, range: range) else { continue }
            for m in matches {
                if let r = Range(m.range(at: 1), in: s) {
                    urls.insert(String(s[r]))
                }
            }
        }
        for host in urls.sorted() {
            let hostname = host.lowercased()
            let allowed = allowedDomains.contains { hostname == $0 || hostname.hasSuffix("." + $0) }
            if allowed { continue }
            // IP 直连（非回环/内网）：C2 后门典型特征 → 危险
            let isIP = (try? NSRegularExpression(pattern: "^\\d{1,3}(\\.\\d{1,3}){3}(:\\d+)?$"))?.firstMatch(in: hostname, range: NSRange(hostname.startIndex..., in: hostname)) != nil
            let privateIP = hostname.hasPrefix("127.") || hostname.hasPrefix("10.") || hostname.hasPrefix("192.168.") || hostname.hasPrefix("169.254.")
            if isIP && !privateIP {
                findings.append(.init(severity: .danger, category: "网络外联", detail: "直连外部 IP 地址: \(host)", source: url.lastPathComponent))
            } else {
                // 未知域名：警告（API 类插件可能合法访问自定义域名）
                findings.append(.init(severity: .warning, category: "网络外联", detail: "访问白名单外域名: \(host)", source: url.lastPathComponent))
            }
        }

        // 5. 敏感系统路径（精确匹配敏感文件/目录，避免 /etc/ 等宽泛路径误伤合法应用配置如 /etc/nginx/）
        let pathPatterns: [(String, String, PluginSecurityFinding.Severity)] = [
            ("/Library/LaunchDaemons", "写入系统启动守护", .danger),
            ("/Library/LaunchAgents", "写入系统启动代理", .danger),
            ("/etc/passwd|/etc/shadow|/etc/sudoers|/etc/crontab|/etc/hosts|/etc/rc\\.|/etc/init\\.d/|/etc/launchd", "写入系统敏感配置", .danger),
            ("/usr/bin/sudo|/usr/bin/su|/usr/bin/doas", "提权命令", .danger),
            ("/bin/sh|/bin/bash|/bin/zsh", "调用系统 shell", .warning),
            ("/tmp/|/private/tmp/", "临时目录读写", .info),
        ]
        for (pattern, desc, sev) in pathPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               suspicious.contains(where: { regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }) {
                findings.append(.init(severity: sev, category: "系统路径", detail: desc, source: url.lastPathComponent))
            }
        }

        return findings
    }

    /// 符号表审查：检查 dylib 引用的未定义危险符号
    private func auditSymbols(at url: URL) -> [PluginSecurityFinding] {
        var findings: [PluginSecurityFinding] = []
        // 输出重定向到临时文件，避免管道缓冲（>64KB）导致 nm 阻塞死锁
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-\(UUID().uuidString).nm")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        guard FileManager.default.createFile(atPath: tempURL.path, contents: nil) else { return [] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nm")
        process.arguments = ["-u", url.path]   // -u 仅未定义符号（外部引用）
        process.standardOutput = FileHandle(forWritingAtPath: tempURL.path)
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard let data = try? Data(contentsOf: tempURL),
                  let output = String(data: data, encoding: .utf8) else { return [] }
            let dangerousSymbols: [(String, String)] = [
                ("_system", "system() 命令执行"),
                ("_popen", "popen() 命令执行"),
                ("_posix_spawn", "posix_spawn 进程创建"),
                ("_execve", "execve 进程执行"),
                ("_dlopen", "dlopen 动态加载"),
                ("_mprotect", "mprotect 内存权限"),
                ("_ptrace", "ptrace 进程注入"),
                ("_vm_protect", "vm_protect 内存权限"),
                ("_mkfifo", "FIFO 创建（反弹 shell 特征）"),
            ]
            for (sym, desc) in dangerousSymbols {
                if output.contains(sym) {
                    findings.append(.init(severity: .danger, category: "符号表", detail: "引用危险符号 \(sym)（\(desc)）", source: url.lastPathComponent))
                }
            }
        } catch {
            // nm 不可用时静默跳过（不影响其它审查）
        }
        return findings
    }

    /// 文本审查（脚本/配置文件）
    private func auditText(_ text: String, source: String) -> [PluginSecurityFinding] {
        var findings: [PluginSecurityFinding] = []
        let dangerPatterns: [(String, String)] = [
            ("/bin/(ba|z|k)?sh.*>&?/dev/tcp", "反弹 shell（/dev/tcp）"),
            ("nc\\s+-e", "netcat 反弹 shell"),
            ("rm\\s+-rf\\s+/", "删除根目录"),
            ("chmod\\s+777\\s+/", "根目录权限修改"),
            ("curl\\s+.*\\|\\s*(ba|z)?sh", "管道执行远程脚本"),
        ]
        for (pattern, desc) in dangerPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                findings.append(.init(severity: .danger, category: "脚本", detail: desc, source: source))
            }
        }
        return findings
    }

    // MARK: - 工具

    /// 从二进制数据提取 ASCII 字符串（含 UTF-8 中文）
    private func extractStrings(from data: Data, minLength: Int = 4) -> [String] {
        var strings: [String] = []
        var current = ""
        for byte in data {
            if byte >= 0x20 && byte <= 0x7E {
                current.append(Character(UnicodeScalar(byte)))
            } else {
                if current.count >= minLength { strings.append(current) }
                current = ""
            }
        }
        if current.count >= minLength { strings.append(current) }
        return strings
    }
}
