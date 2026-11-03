//
//  LogViewModel.swift
//  AiguruContainerPanel
//
//  日志管理视图模型，提供筛选、搜索和复制功能。
//  filterModule / filterResult 均为可选类型。
//

import SwiftUI
import Combine

class LogViewModel: ObservableObject {
    @Published var logs: [AiguruContainerPanel.LogEntry] = []
    @Published var selectedLog: AiguruContainerPanel.LogEntry? = nil
    @Published var filterModule: String? = nil
    @Published var filterResult: String? = nil
    @Published var searchText: String = ""

    private let logService = LogService.shared

    func loadLogs() {
        logs = logService.fetchAllLogs()
        applyFilters()
    }

    func applyFilters() {
        var filtered = logService.fetchAllLogs()

        if let module = filterModule, !module.isEmpty, module != "全部" {
            filtered = filtered.filter { $0.module == module }
        }
        if let result = filterResult, !result.isEmpty, result != "全部" {
            filtered = filtered.filter { $0.result == result }
        }
        if !searchText.isEmpty {
            filtered = filtered.filter {
                ($0.command?.lowercased().contains(searchText.lowercased()) ?? false) ||
                ($0.outputSummary?.lowercased().contains(searchText.lowercased()) ?? false)
            }
        }
        logs = filtered
    }

    func clearAllLogs() {
        logService.deleteAllLogs()
        loadLogs()
    }

    func deleteLog(_ entry: AiguruContainerPanel.LogEntry) {
        logService.deleteLog(entry)
        loadLogs()
    }

    func copyLogEntry(_ entry: AiguruContainerPanel.LogEntry) {
        let text = """
        时间: \(entry.timestamp?.formatted(date: .numeric, time: .standard) ?? "")
        模块: \(entry.module ?? "")
        操作: \(entry.operationType ?? "")
        命令: \(entry.command ?? "")
        结果: \(entry.result ?? "")
        耗时: \(entry.duration) 秒
        输出摘要: \(entry.outputSummary ?? "")
        完整输出: \(entry.fullOutput ?? "")
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func copyAllLogs() {
        let text = logs.map { entry in
            """
            [\(entry.timestamp?.formatted(date: .numeric, time: .standard) ?? "")] \(entry.module ?? "") - \(entry.operationType ?? "")
            命令: \(entry.command ?? "")
            结果: \(entry.result ?? "")
            输出: \(entry.outputSummary ?? "")
            """
        }.joined(separator: "\n---\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
