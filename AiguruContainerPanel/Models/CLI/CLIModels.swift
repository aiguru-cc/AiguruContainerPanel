import Foundation

/// CLI 请求的呈现方式。实际执行均在后台完成；该值用于 UI 和日志语义。
enum ExecutionMode: String, CaseIterable {
    case sync = "同步阻塞"
    case async = "异步后台"
    case stream = "流式实时"
}

struct CLIResult {
    let command: String
    let output: String
    let exitCode: Int32
    let duration: TimeInterval
    let mode: ExecutionMode

    var succeeded: Bool { exitCode == 0 }
}

enum CLIStreamEvent {
    case output(String)
    case progress(Double)
    case completion(CLIResult)
    case error(String)
}

struct LocalImage: Decodable, Identifiable {
    let id: String
    let repository: String
    let tag: String
    let size: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case repository = "Repository"
        case tag = "Tag"
        case size = "Size"
    }
}
