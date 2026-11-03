//
//  LogService.swift
//  AiguruContainerPanel
//
//  日志服务，负责将 CLI 执行结果写入 Core Data。
//  使用 LogEntry 托管对象。
//

import CoreData
import Foundation
import Combine

class LogService {
    static let shared = LogService()
    private init() {}

    private let context = PersistenceController.shared.container.viewContext

    func log(result: CLIResult, module: String, operationType: String, user: String = NSUserName()) {
        let entry = LogEntry(context: context)  // 直接使用类型名，不添加模块前缀
        entry.timestamp = Date()
        entry.user = user
        entry.module = module
        entry.operationType = operationType
        entry.command = result.command
        entry.executionMode = result.mode.rawValue
        entry.result = result.succeeded ? "成功" : "失败"
        // 摘要统一为前 200 字符；完整内容（含安全审查明细）在"查看完整输出"展开区
        entry.outputSummary = String(result.output.prefix(200))
        entry.fullOutput = result.output
        entry.duration = result.duration
        entry.exitCode = result.exitCode

        do {
            try context.save()
        } catch {
            print("保存日志失败: \(error)")
        }
    }

    func fetchAllLogs() -> [LogEntry] {
        let request: NSFetchRequest<LogEntry> = LogEntry.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \LogEntry.timestamp, ascending: false)]
        do {
            return try context.fetch(request)
        } catch {
            print("获取日志失败: \(error)")
            return []
        }
    }

    func fetchLogs(module: String? = nil, result: String? = nil) -> [LogEntry] {
        let request: NSFetchRequest<LogEntry> = LogEntry.fetchRequest()
        var predicates: [NSPredicate] = []
        if let module = module, !module.isEmpty {
            predicates.append(NSPredicate(format: "module == %@", module))
        }
        if let result = result, !result.isEmpty {
            predicates.append(NSPredicate(format: "result == %@", result))
        }
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \LogEntry.timestamp, ascending: false)]
        do {
            return try context.fetch(request)
        } catch {
            print("筛选日志失败: \(error)")
            return []
        }
    }

    func deleteAllLogs() {
        let request: NSFetchRequest<NSFetchRequestResult> = LogEntry.fetchRequest()
        let deleteRequest = NSBatchDeleteRequest(fetchRequest: request)
        do {
            try context.execute(deleteRequest)
            try context.save()
        } catch {
            print("清空日志失败: \(error)")
        }
    }

    func deleteLog(_ entry: LogEntry) {
        context.delete(entry)
        do {
            try context.save()
        } catch {
            print("删除日志失败: \(error)")
        }
    }
}
