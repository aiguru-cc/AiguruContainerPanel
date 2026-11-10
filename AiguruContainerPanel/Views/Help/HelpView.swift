import SwiftUI
import AppKit

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("AiguruContainerPanel").font(.largeTitle.bold())
                Text("Apple Container 的原生 macOS 图形化管理面板。")
                    .font(.title3).foregroundStyle(.secondary)
                helpSection("功能概览", "容器、镜像、网络、Hosts、卷、Machine、Kubernetes/Container Cluster、系统状态和操作日志。")
                helpSection("版本兼容", "当前指令库目标版本为 Apple Container 1.7.1。1.6+ 使用 container cluster 命令组。1.7 移除了 cluster load-image，新增 shared image store、cluster run 和 worker 节点资源配置。")
                helpSection("Hosts 管理", "Hosts 页面会读取完整 /etc/hosts，并按已有 managed block 分组展示。只有 AiguruContainerPanel 自己的区块允许修改，其它应用和系统条目只读展示，避免覆盖和域名冲突。写入需要管理员密码，密码不会保存。")
                helpSection("安全提示", "删除容器、停止服务、清理资源和写入 Hosts 前请确认目标。请勿提交管理员密码、私有仓库凭据或 kubeconfig。")
                VStack(alignment: .leading, spacing: 12) {
                    Text("支持项目").font(.title2.bold())
                    Text("如果这个项目对你有帮助，欢迎赞助支持持续维护。")
                        .foregroundStyle(.secondary)
                    HStack(alignment: .top, spacing: 28) {
                        sponsorCard(title: "支付宝", imageName: "alipay")
                        sponsorCard(title: "微信", imageName: "wepay")
                    }
                }
                Divider()
                Text("开源资料").font(.title2.bold())
                Link("Apple Container 1.6.1 Release", destination: URL(string: "https://github.com/apple/container/releases/tag/1.6.1")!)
                Link("Command Reference 1.6.1", destination: URL(string: "https://github.com/apple/container/blob/1.6.1/docs/command-reference.md")!)
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(32)
        }
    }

    private func helpSection(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title2.bold())
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sponsorCard(title: String, imageName: String) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.headline)
            Group {
                if let image = loadBundleImage(named: imageName) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                } else {
                    Image(systemName: "qrcode")
                        .font(.system(size: 72))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 180, height: 180)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func loadBundleImage(named name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }
}
