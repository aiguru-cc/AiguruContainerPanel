//
//  SourceImageListViewModel.swift
//  AiguruContainerPanel
//
//  镜像列表视图模型，与 SourceImageManager 交互。
//  移除进度属性（由 TaskManager 统一管理），仅保留列表和错误状态。
//

import SwiftUI
import Combine

class SourceImageListViewModel: ObservableObject {
    @Published var images: [SourceImage] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let manager = SourceImageManager.shared
    private let envManager = EnvironmentManager.shared
    private var cancellables = Set<AnyCancellable>()

    init() {
        // ✅ 绑定 Manager 的基本状态（进度已由 TaskManager 统一管理，不再绑定）
        manager.$images
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newImages in
                self?.images = newImages
            }
            .store(in: &cancellables)

        manager.$isLoading
            .receive(on: DispatchQueue.main)
            .assign(to: &$isLoading)

        manager.$errorMessage
            .receive(on: DispatchQueue.main)
            .assign(to: &$errorMessage)

        // 环境切换监听（静默刷新）
        envManager.$currentEnvironment
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshImages(silent: true)
            }
            .store(in: &cancellables)
    }

    // MARK: - 刷新列表
    func refreshImages(silent: Bool = false) {
        if !silent {
            errorMessage = nil
        }
        Task {
            await manager.fetchImages()
            if silent {
                await MainActor.run {
                    if self.errorMessage != nil {
                        self.errorMessage = nil
                    }
                }
            }
        }
    }

    // MARK: - 镜像操作（直接调用 Manager，进度由 TaskManager 处理）
    func pullImage(name: String, tag: String = "latest", platform: String? = nil) {
        Task {
            do {
                try await manager.pullImage(name: name, tag: tag, platform: platform)
            } catch {
                // 错误已在 Manager 中设置
            }
        }
    }

    func buildImage(contextDir: String, file: String? = nil, tag: String, platform: String? = nil, target: String? = nil, noCache: Bool = false) {
        Task {
            do {
                try await manager.buildImage(contextDir: contextDir, file: file, tag: tag, platform: platform, target: target, noCache: noCache)
            } catch {
                // 错误已在 Manager 中设置
            }
        }
    }

    func deleteImage(_ image: SourceImage) {
        Task {
            do {
                try await manager.deleteImage(id: image.name)
            } catch {
                // 错误已在 Manager 中设置
            }
        }
    }

    func pushImage(name: String, tag: String = "latest") {
        Task {
            do {
                try await manager.pushImage(name: name, tag: tag)
            } catch {
                // 错误已在 Manager 中设置
            }
        }
    }

    func pruneDanglingImages() {
        Task {
            do {
                try await manager.pruneDanglingImages()
            } catch {
                // 错误已在 Manager 中设置
            }
        }
    }

    func deleteUnusedImagesSafely() {
        Task {
            do {
                try await manager.deleteUnusedImagesSafely()
            } catch {
                // 错误已由 Manager 记录并显示。
            }
        }
    }

    func saveImage(_ image: SourceImage, to url: URL) {
        Task {
            do {
                try await manager.saveImage(reference: image.name, to: url)
            } catch {
                // 错误已在 Manager 中设置
            }
        }
    }

    func loadImage(from url: URL, force: Bool = false) {
        Task {
            do {
                try await manager.loadImage(from: url, force: force)
            } catch {
                // 错误已在 Manager 中设置
            }
        }
    }
}
