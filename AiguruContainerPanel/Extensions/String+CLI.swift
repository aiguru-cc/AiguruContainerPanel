//
//  String+CLI.swift
//  ContainerPanel
//
//  字符串扩展，用于 CLI 命令解析等。
//

import Foundation

extension String {
    /// 将命令字符串拆分为参数数组，支持双引号
    func cliArguments() -> [String] {
        var args: [String] = []
        var current = ""
        var inQuotes = false
        for ch in self {
            if ch == " " && !inQuotes {
                if !current.isEmpty {
                    args.append(current)
                    current = ""
                }
            } else if ch == "\"" {
                inQuotes.toggle()
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty {
            args.append(current)
        }
        return args
    }
}

extension String {
    /// 若镜像引用未包含 tag，则补上指定 tag。注册表端口号不会被误判为 tag。
    func imageReference(tag: String = AppConstants.CLI.defaultImageTag) -> String {
        let lastPathComponent = split(separator: "/").last ?? Substring(self)
        return lastPathComponent.contains(":") ? self : "\(self):\(tag)"
    }

    /// Parse an OCI image reference for registry manifest lookups. Registry ports
    /// are deliberately distinguished from the tag separator in the final path
    /// component (for example, `localhost:5000/demo:1`).
    var ociManifestReference: (registry: String, repository: String, tag: String)? {
        let reference = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reference.isEmpty else { return nil }
        let components = reference.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard components.count >= 2 else { return nil }
        let registry = components[0]
        var repository = components.dropFirst().joined(separator: "/")
        let tag: String
        if let colon = repository.lastIndex(of: ":") {
            tag = String(repository[repository.index(after: colon)...])
            repository = String(repository[..<colon])
        } else {
            tag = AppConstants.CLI.defaultImageTag
        }
        guard !registry.isEmpty, !repository.isEmpty, !tag.isEmpty else { return nil }
        return (registry, repository, tag)
    }
}
