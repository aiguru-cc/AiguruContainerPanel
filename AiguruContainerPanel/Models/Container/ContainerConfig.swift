//
//  ContainerConfig.swift
//  AiguruContainerPanel
//
//  Created by samlu on 2026/7/28.
//

import Foundation

struct ContainerConfig: Identifiable {
    let id = UUID()
    let image: String
    let env: [String]
    let ports: [String]
    let volumes: [VolumeMapping]
    let name: String?
    let detach: Bool
    let options: ContainerRunOptions
}
