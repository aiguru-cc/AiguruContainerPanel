//
//  PersistenceController.swift
//  AiguruContainerPanel
//
//  Core Data 堆栈管理。
//

import CoreData
import Foundation

class PersistenceController {
    static let shared = PersistenceController()

    let container: NSPersistentContainer

    private init() {
        // 确保模型文件名与 .xcdatamodeld 一致
        container = NSPersistentContainer(name: "ContainerPanel")
        container.loadPersistentStores { description, error in
            if let error = error as NSError? {
                fatalError("Core Data 加载失败: \(error), \(error.userInfo)")
            }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    func saveContext() {
        let context = container.viewContext
        if context.hasChanges {
            do {
                try context.save()
            } catch {
                let nserror = error as NSError
                fatalError("保存上下文失败: \(nserror), \(nserror.userInfo)")
            }
        }
    }
}
