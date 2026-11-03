//
//  DataManagerService.swift
//  AiguruContainerPanel
//
//  数据管理服务（C ABI 协议）：供外挂「数据管理」插件通过 dlopen 注入获取。
//  主 App 持有数据存储（当前为 Core Data / PersistenceController，协议抽象后
//  可无缝切换到 SwiftData），插件只通过本服务表读写，不直接操作数据。
//
//  注入机制：PluginManager.loadPluginDylib 加载插件时探测可选符号
//  acp_plugin_set_data_service，存在则传入本服务表（向后兼容旧插件）。
//
//  约定：所有返回 C 字符串均通过 strdup 分配，插件用毕后调用 releaseString 释放。
//

import Foundation
import CoreData
import Darwin

// MARK: - C ABI 服务表（V1）

/// 数据管理服务协议（C 结构，主 App 与插件各自独立定义，布局一致）
struct DataManagerServiceV1 {
    /// 实体列表 → JSON 数组字符串 [{"name":"X","propertyCount":N}, ...]
    var entityList: (@convention(c) () -> UnsafeMutablePointer<CChar>?)?
    /// 记录总数
    var recordCount: (@convention(c) (UnsafePointer<CChar>?) -> Int64)?
    /// 分页记录 → JSON 数组字符串（属性+关系描述，与内置版一致）
    var fetchRecords: (@convention(c) (UnsafePointer<CChar>?, Int64, Int64) -> UnsafeMutablePointer<CChar>?)?
    /// 导出全部 → JSON 数组字符串（UUID/Date/Data 已转为可序列化类型）
    var exportAll: (@convention(c) (UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?)?
    /// 导入（JSON 数组字符串）→ 错误字符串（空 = 成功）
    var importRecords: (@convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?)?
    /// 清空实体 → 错误字符串（空 = 成功）
    var clearEntity: (@convention(c) (UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?)?
    /// 释放 strdup 分配的字符串
    var releaseString: (@convention(c) (UnsafeMutablePointer<CChar>?) -> Void)?
}

// MARK: - 实现（基于 Core Data，主线程 viewContext）

private let dmContainer = PersistenceController.shared.container

private func dmStrdup(_ s: String) -> UnsafeMutablePointer<CChar>? {
    s.withCString { strdup($0) }
}

private func dmEntityListC() -> UnsafeMutablePointer<CChar>? {
    let model = dmContainer.managedObjectModel
    let items = model.entities.sorted { ($0.name ?? "") < ($1.name ?? "") }
        .map { ["name": $0.name ?? "未知", "propertyCount": $0.properties.count] }
    let data = (try? JSONSerialization.data(withJSONObject: items)) ?? Data("[{\"name\":\"未知\",\"propertyCount\":0}]".data(using: .utf8)!)
    return dmStrdup(String(data: data, encoding: .utf8) ?? "[]")
}

private func dmRecordCountC(_ entityPtr: UnsafePointer<CChar>?) -> Int64 {
    guard let entityPtr else { return 0 }
    let entityName = String(cString: entityPtr)
    let context = dmContainer.viewContext
    var count = 0
    context.performAndWait {
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
        request.resultType = .countResultType
        count = (try? context.count(for: request)) ?? 0
    }
    return Int64(count)
}

/// 把 NSManagedObject 转为 JSON 可序列化字典（含关系描述）
private func recordDict(from obj: NSManagedObject, export: Bool = false) -> [String: Any] {
    var dict: [String: Any] = [:]
    for (key, _) in obj.entity.attributesByName {
        let value = obj.value(forKey: key)
        if let uuid = value as? UUID {
            dict[key] = uuid.uuidString
        } else if let date = value as? Date {
            dict[key] = ISO8601DateFormatter().string(from: date)
        } else if let data = value as? Data {
            dict[key] = data.base64EncodedString()
        } else if let set = value as? Set<AnyHashable> {
            dict[key] = "\(set.count) items"
        } else {
            dict[key] = value ?? "nil"
        }
    }
    for (key, _) in obj.entity.relationshipsByName {
        if let related = obj.value(forKey: key) as? NSManagedObject {
            dict[key] = "\(related.entity.name ?? "unknown")[\(related.objectID)]"
        } else if let set = obj.value(forKey: key) as? Set<NSManagedObject> {
            dict[key] = "\(set.count) items"
        } else {
            dict[key] = "nil"
        }
    }
    return dict
}

private func dmFetchRecordsC(_ entityPtr: UnsafePointer<CChar>?, _ offset: Int64, _ limit: Int64) -> UnsafeMutablePointer<CChar>? {
    guard let entityPtr else { return dmStrdup("[]") }
    let entityName = String(cString: entityPtr)
    let context = dmContainer.viewContext
    var json = "[]"
    context.performAndWait {
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
        request.fetchOffset = Int(offset)
        request.fetchLimit = Int(limit)
        guard let objects = (try? context.fetch(request)) as? [NSManagedObject] else { return }
        let records = objects.map { recordDict(from: $0) }
        json = (try? String(data: JSONSerialization.data(withJSONObject: records), encoding: .utf8)) ?? "[]"
    }
    return dmStrdup(json)
}

private func dmExportAllC(_ entityPtr: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    guard let entityPtr else { return dmStrdup("[]") }
    let entityName = String(cString: entityPtr)
    let context = dmContainer.viewContext
    var json = "[]"
    context.performAndWait {
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
        guard let objects = (try? context.fetch(request)) as? [NSManagedObject] else { return }
        let records = objects.map { recordDict(from: $0, export: true) }
        let data = (try? JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        json = String(data: data, encoding: .utf8) ?? "[]"
    }
    return dmStrdup(json)
}

private func dmImportRecordsC(_ entityPtr: UnsafePointer<CChar>?, _ jsonPtr: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    guard let entityPtr, let jsonPtr else { return dmStrdup("参数无效") }
    let entityName = String(cString: entityPtr)
    let json = String(cString: jsonPtr)
    let context = dmContainer.viewContext
    var error = ""
    context.performAndWait {
        do {
            guard let data = json.data(using: .utf8),
                  let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                error = "JSON 必须是数组对象"
                return
            }
            guard let entity = NSEntityDescription.entity(forEntityName: entityName, in: context) else {
                error = "找不到实体: \(entityName)"
                return
            }
            let attributes = entity.attributesByName
            for dict in array {
                let obj = NSManagedObject(entity: entity, insertInto: context)
                for (key, value) in dict {
                    guard let attr = attributes[key], let val = value as? NSObject else { continue }
                    switch attr.attributeType {
                    case .UUIDAttributeType:
                        if let uuidStr = val as? String, let uuid = UUID(uuidString: uuidStr) {
                            obj.setValue(uuid, forKey: key)
                        } else {
                            obj.setValue(nil, forKey: key)
                        }
                    case .dateAttributeType:
                        if let dateStr = val as? String {
                            let formatter = ISO8601DateFormatter()
                            if let date = formatter.date(from: dateStr) {
                                obj.setValue(date, forKey: key)
                            } else {
                                let f2 = DateFormatter()
                                f2.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
                                obj.setValue(f2.date(from: dateStr), forKey: key)
                            }
                        } else if let date = val as? Date {
                            obj.setValue(date, forKey: key)
                        }
                    case .transformableAttributeType:
                        if let base64Str = val as? String, let data = Data(base64Encoded: base64Str) {
                            obj.setValue(data, forKey: key)
                        } else {
                            obj.setValue(val, forKey: key)
                        }
                    case .stringAttributeType:
                        obj.setValue(String(describing: val), forKey: key)
                    case .integer16AttributeType, .integer32AttributeType, .integer64AttributeType:
                        if let intVal = val as? Int {
                            obj.setValue(NSNumber(value: intVal), forKey: key)
                        } else if let strVal = val as? String, let intVal = Int(strVal) {
                            obj.setValue(NSNumber(value: intVal), forKey: key)
                        } else if let numVal = val as? NSNumber {
                            obj.setValue(numVal, forKey: key)
                        }
                    case .doubleAttributeType:
                        if let doubleVal = val as? Double {
                            obj.setValue(NSNumber(value: doubleVal), forKey: key)
                        } else if let strVal = val as? String, let doubleVal = Double(strVal) {
                            obj.setValue(NSNumber(value: doubleVal), forKey: key)
                        } else if let numVal = val as? NSNumber {
                            obj.setValue(numVal, forKey: key)
                        }
                    case .booleanAttributeType:
                        if let boolVal = val as? Bool {
                            obj.setValue(NSNumber(value: boolVal), forKey: key)
                        } else if let strVal = val as? String {
                            obj.setValue(NSNumber(value: strVal.lowercased() == "true" || strVal == "1"), forKey: key)
                        }
                    default:
                        obj.setValue(val, forKey: key)
                    }
                }
            }
            try context.save()
        } catch let e {
            error = e.localizedDescription
        }
    }
    return dmStrdup(error)
}

private func dmClearEntityC(_ entityPtr: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    guard let entityPtr else { return dmStrdup("参数无效") }
    let entityName = String(cString: entityPtr)
    let context = dmContainer.viewContext
    var error = ""
    context.performAndWait {
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
        let deleteRequest = NSBatchDeleteRequest(fetchRequest: request)
        do {
            try context.execute(deleteRequest)
            try context.save()
        } catch let e {
            error = e.localizedDescription
        }
    }
    return dmStrdup(error)
}

private func dmReleaseC(_ ptr: UnsafeMutablePointer<CChar>?) {
    if let ptr { free(ptr) }
}

// MARK: - 服务表实例（全局持有，注入后插件保存指针长期使用）

/// 全局数据管理服务表（生命周期 = App 进程）
let dataManagerServiceV1 = DataManagerServiceV1(
    entityList: dmEntityListC,
    recordCount: dmRecordCountC,
    fetchRecords: dmFetchRecordsC,
    exportAll: dmExportAllC,
    importRecords: dmImportRecordsC,
    clearEntity: dmClearEntityC,
    releaseString: dmReleaseC
)
