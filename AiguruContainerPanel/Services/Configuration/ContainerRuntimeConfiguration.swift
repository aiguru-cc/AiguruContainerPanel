//
//  ContainerRuntimeConfiguration.swift
//  AiguruContainerPanel
//
//  读取 Apple Container 的运行时配置。写入和重启仍由 NetworkViewModel 负责，
//  此处保持只读，供创建、模板和诊断界面复用。
//

import Foundation

enum ContainerRuntimeConfiguration {
    static var configuredDNSDomain: String? {
        let configurationURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(AppConstants.Paths.configurationRelativePath)
        guard let content = try? String(contentsOf: configurationURL, encoding: .utf8) else {
            return nil
        }

        var inDNSSection = false
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                inDNSSection = trimmed == "[dns]"
                continue
            }
            guard inDNSSection, let equalsIndex = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<equalsIndex].trimmingCharacters(in: .whitespaces)
            guard key == "domain" else { continue }
            let value = trimmed[trimmed.index(after: equalsIndex)...]
                .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
            return value.isEmpty ? nil : value
        }
        return nil
    }
}
