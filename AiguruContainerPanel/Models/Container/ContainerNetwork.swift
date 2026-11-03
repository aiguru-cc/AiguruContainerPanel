//
//  ContainerNetwork.swift
//  AiguruContainerPanel
//
//  Network 数据模型，对齐 `container network ls --format json` 输出。
//

import Foundation
import SwiftUI

struct NetworkInfo: Identifiable, Decodable, Equatable {
    let id: String
    let configuration: NetworkConfiguration
    let status: NetworkStatus?

    var name: String { configuration.name }
    var displayName: String { configuration.name }
    var driver: String { configuration.plugin }
    var mode: String { configuration.mode }
    var subnet: String { status?.ipv4Subnet ?? "" }
    var gateway: String { status?.ipv4Gateway ?? "" }
    var subnetV6: String { status?.ipv6Subnet ?? "" }
    var isInternal: Bool { configuration.internalFlag ?? false }
    var labels: [String: String] { configuration.labels ?? [:] }
    var createdAt: String? { configuration.creationDate }

    struct NetworkConfiguration: Decodable, Equatable {
        let name: String
        let plugin: String
        let mode: String
        let creationDate: String?
        let labels: [String: String]?
        let options: [String: String]?
        let internalFlag: Bool?

        enum CodingKeys: String, CodingKey {
            case name, plugin, mode, creationDate, labels, options
            case internalFlag = "internal"
        }
    }

    struct NetworkStatus: Decodable, Equatable {
        let ipv4Subnet: String?
        let ipv4Gateway: String?
        let ipv6Subnet: String?

        enum CodingKeys: String, CodingKey {
            case ipv4Subnet, ipv4Gateway, ipv6Subnet
        }
    }
}
