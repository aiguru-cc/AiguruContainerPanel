//
//  DataManager.swift
//  AiguruContainerPanel
//
//  数据管理工具：查看、清理、导入导出 Core Data 数据。
//

import Foundation
import CoreData

class DataManager {
    static let shared = DataManager()
    private init() {}

    private let context = PersistenceController.shared.container.viewContext

    // MARK: - 获取所有实体名称
    func getAllEntityNames() -> [String] {
        let model = PersistenceController.shared.container.managedObjectModel
        return model.entities.map { $0.name ?? "未命名" }.sorted()
    }

    // MARK: - 获取指定实体的所有记录（以字典数组返回）
    func fetchAllRecords(for entityName: String) -> [[String: Any]] {
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
        request.returnsObjectsAsFaults = false
        do {
            let results = try context.fetch(request)
            var records: [[String: Any]] = []
            for obj in results {
                guard let managedObject = obj as? NSManagedObject else { continue }
                let dict = objectToDictionary(managedObject)
                records.append(dict)
            }
            return records
        } catch {
            print("❌ 获取实体 \(entityName) 数据失败: \(error)")
            return []
        }
    }

    // 将 NSManagedObject 转换为字典
    private func objectToDictionary(_ object: NSManagedObject) -> [String: Any] {
        var dict: [String: Any] = [:]
        let attributes = object.entity.attributesByName
        for key in attributes.keys {
            let value = object.value(forKey: key)
            if let date = value as? Date {
                dict[key] = date.formatted()
            } else if let data = value as? Data {
                dict[key] = data.base64EncodedString()
            } else if let uuid = value as? UUID {
                dict[key] = uuid.uuidString
            } else if let bool = value as? Bool {
                dict[key] = bool
            } else if let number = value as? NSNumber {
                dict[key] = number
            } else if let string = value as? String {
                dict[key] = string
            } else if let array = value as? [Any] {
                dict[key] = array
            } else if let dictValue = value as? [String: Any] {
                dict[key] = dictValue
            } else {
                dict[key] = value ?? NSNull()
            }
        }
        return dict
    }

    // MARK: - 打印指定实体的数据（格式化输出）
    func printEntityData(_ entityName: String) {
        let records = fetchAllRecords(for: entityName)
        guard !records.isEmpty else {
            print("📭 实体 \(entityName) 无数据")
            return
        }
        print("📊 实体 \(entityName) 共 \(records.count) 条记录:")
        for (index, record) in records.enumerated() {
            print("  [\(index + 1)]")
            for (key, value) in record {
                print("    \(key): \(value)")
            }
            print("  ---")
        }
    }

    // MARK: - 打印所有实体及其记录数（摘要）
    func printAllEntitiesSummary() {
        let names = getAllEntityNames()
        print("📋 所有实体摘要:")
        for name in names {
            let count = fetchAllRecords(for: name).count
            print("  - \(name): \(count) 条记录")
        }
    }

    // MARK: - 清理指定实体的所有数据
    func clearEntity(_ entityName: String) throws {
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
        let deleteRequest = NSBatchDeleteRequest(fetchRequest: request)
        try context.execute(deleteRequest)
        try context.save()
        print("🗑️ 已清理实体 \(entityName) 的所有数据")
    }

    // MARK: - 清理所有数据（所有实体）
    func clearAllData() throws {
        let names = getAllEntityNames()
        for name in names {
            try clearEntity(name)
        }
        print("🗑️ 已清理所有数据")
    }

    // MARK: - 删除 Core Data 存储文件（重置数据库）
    func deleteStoreFile() throws {
        let storeURL = PersistenceController.shared.container.persistentStoreCoordinator.persistentStores.first?.url
        guard let url = storeURL else {
            throw NSError(domain: "DataManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "未找到存储文件"])
        }
        try PersistenceController.shared.container.persistentStoreCoordinator.destroyPersistentStore(at: url, ofType: NSSQLiteStoreType, options: nil)
        print("🗑️ 已删除存储文件: \(url)")
    }

    // MARK: - 导出指定实体为 JSON
    func exportEntityToJSON(_ entityName: String) -> String? {
        let records = fetchAllRecords(for: entityName)
        guard !records.isEmpty else { return nil }
        do {
            let data = try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted])
            return String(data: data, encoding: .utf8)
        } catch {
            print("❌ 导出 JSON 失败: \(error)")
            return nil
        }
    }

    // MARK: - 导出所有实体为 JSON（多实体）
    func exportAllToJSON() -> String? {
        let names = getAllEntityNames()
        var allData: [String: [[String: Any]]] = [:]
        for name in names {
            let records = fetchAllRecords(for: name)
            if !records.isEmpty {
                allData[name] = records
            }
        }
        guard !allData.isEmpty else { return nil }
        do {
            let data = try JSONSerialization.data(withJSONObject: allData, options: [.prettyPrinted])
            return String(data: data, encoding: .utf8)
        } catch {
            print("❌ 导出所有 JSON 失败: \(error)")
            return nil
        }
    }

    // MARK: - 从 JSON 导入数据到指定实体（覆盖）
    func importFromJSON(_ jsonString: String, for entityName: String) throws {
        guard let data = jsonString.data(using: .utf8) else {
            throw NSError(domain: "DataManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的 JSON 字符串"])
        }
        let jsonArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        guard let array = jsonArray else {
            throw NSError(domain: "DataManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "JSON 格式应为数组"])
        }
        // 先清空
        try clearEntity(entityName)
        // 创建新对象
        let entity = NSEntityDescription.entity(forEntityName: entityName, in: context)!
        for dict in array {
            let obj = NSManagedObject(entity: entity, insertInto: context)
            for (key, value) in dict {
                if let attr = entity.attributesByName[key] {
                    let converted = convertValue(value, for: attr)
                    obj.setValue(converted, forKey: key)
                }
            }
        }
        try context.save()
        print("✅ 从 JSON 导入 \(array.count) 条记录到 \(entityName)")
    }

    // MARK: - 值转换（处理类型）
    private func convertValue(_ value: Any, for attribute: NSAttributeDescription) -> Any? {
        let attrType = attribute.attributeType
        switch attrType {
        case .stringAttributeType:
            return (value as? String) ?? "\(value)"
        case .integer16AttributeType, .integer32AttributeType, .integer64AttributeType:
            if let num = value as? NSNumber { return num }
            if let str = value as? String { return Int(str) as? NSNumber }
            return nil
        case .doubleAttributeType, .floatAttributeType:
            if let num = value as? NSNumber { return num }
            if let str = value as? String { return Double(str) as? NSNumber }
            return nil
        case .booleanAttributeType:
            if let bool = value as? Bool { return bool }
            if let num = value as? NSNumber { return num.boolValue }
            if let str = value as? String { return (str.lowercased() == "true") as NSNumber }
            return nil
        case .dateAttributeType:
            if let date = value as? Date { return date }
            if let str = value as? String {
                let formatter = ISO8601DateFormatter()
                return formatter.date(from: str)
            }
            return nil
        case .UUIDAttributeType:
            if let uuid = value as? UUID { return uuid }
            if let str = value as? String { return UUID(uuidString: str) }
            return nil
        default:
            return value
        }
    }
}
