import Foundation

extension String {
    /// 从 CLI 流式输出中抽取通用进度信息，供容器、镜像和 Machine 操作共享。
    var percentageProgress: Double? {
        firstMatch(for: #"(\d+(?:\.\d+)?)%"#).flatMap(Double.init)
    }

    var blobProgress: (current: Int, total: Int)? {
        integerProgress(for: #"(\d+)\s+of\s+(\d+)\s+blobs?"#)
    }

    var layerProgress: (current: Int, total: Int)? {
        integerProgress(for: #"(\d+)/(\d+)"#)
    }

    private func firstMatch(for pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: self, range: NSRange(startIndex..., in: self)),
              let range = Range(match.range(at: 1), in: self) else { return nil }
        return String(self[range])
    }

    private func integerProgress(for pattern: String) -> (current: Int, total: Int)? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: self, range: NSRange(startIndex..., in: self)),
              let currentRange = Range(match.range(at: 1), in: self),
              let totalRange = Range(match.range(at: 2), in: self),
              let current = Int(self[currentRange]), let total = Int(self[totalRange]), total > 0 else { return nil }
        return (current, total)
    }
}
