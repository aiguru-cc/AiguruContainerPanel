import Foundation

/// `container machine create` 的输入模型，对应 Apple Container 的创建参数。
struct MachineCreateConfiguration {
    var name: String
    var image: String
    var cpus: Int?
    var memory: String?
    var homeMount: HomeMount = .readWrite
    var virtualization = false
    var kernelPath: String?
    var noBoot = false
    var setDefault = false
    var architecture: Architecture?
    var os: String?
    var scheme: RegistryScheme = .auto
    var maxConcurrentDownloads: Int?

    enum HomeMount: String, CaseIterable, Identifiable {
        case readWrite = "rw"
        case readOnly = "ro"
        case none

        var id: String { rawValue }
        var title: String {
            switch self {
            case .readWrite: return "读写"
            case .readOnly: return "只读"
            case .none: return "不挂载"
            }
        }
    }

    enum Architecture: String, CaseIterable, Identifiable {
        case arm64, amd64
        var id: String { rawValue }
    }

    enum RegistryScheme: String, CaseIterable, Identifiable {
        case auto, https, http
        var id: String { rawValue }
    }

    var validated: Result<MachineCreateConfiguration, ValidationError> {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedImage = image.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { return .failure(.missingName) }
        guard !normalizedImage.isEmpty else { return .failure(.missingImage) }
        guard cpus == nil || cpus! > 0 else { return .failure(.invalidCPUs) }
        guard maxConcurrentDownloads == nil || maxConcurrentDownloads! > 0 else {
            return .failure(.invalidConcurrentDownloads)
        }
        if let memory, !memory.isEmpty,
           memory.range(of: #"^\d+(?:[KMGTPE](?:i?B)?)?$"#, options: [.regularExpression, .caseInsensitive]) == nil {
            return .failure(.invalidMemory)
        }
        var copy = self
        copy.name = normalizedName
        copy.image = normalizedImage
        copy.memory = memory?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        copy.kernelPath = kernelPath?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        return .success(copy)
    }

    enum ValidationError: LocalizedError {
        case missingName, missingImage, invalidCPUs, invalidMemory, invalidConcurrentDownloads

        var errorDescription: String? {
            switch self {
            case .missingName: return "请输入 Machine 名称。"
            case .missingImage: return "请输入镜像引用。"
            case .invalidCPUs: return "CPU 数量必须是大于 0 的整数。"
            case .invalidMemory: return "内存格式应为数值，或带单位的数值（例如 2G、4096M）。"
            case .invalidConcurrentDownloads: return "并发下载数必须是大于 0 的整数。"
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
