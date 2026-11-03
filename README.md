# AiguruContainerPanel

原生 macOS 图形化管理面板，为 Apple Container 提供容器、镜像、网络、卷、Machine 和 Kubernetes/Container Cluster 的可视化操作。

> 本项目是 Apple Container CLI 的第三方 GUI，不是 Apple 官方项目。

## 功能

- 容器：创建、启动、停止、重启、删除、日志、终端、复制、导出、统计和批量操作。
- 镜像：拉取、推送、删除、清理、保存和加载。
- 网络：网络 CRUD、检查和清理；Hosts 页面读取完整 `/etc/hosts`，按管理区块分组展示。
- Hosts：仅维护 `AiguruContainerPanel` 自己的标记区块；其它应用和系统条目只读展示，避免覆盖和域名冲突。
- 卷：创建、删除、检查和清理。
- Machine：创建、运行、停止、删除、默认 Machine、配置和内核管理。
- Kubernetes：兼容旧版 `container k8s`，并自动适配 1.6+ 的 `container cluster` 命令组。
- 系统与日志：服务控制、环境探测、资源信息、命令日志、任务进度和缓存管理。
- 多环境：支持系统环境、MLX/自定义 CLI 路径，并在切换后刷新资源。

应用插件市场和第三方插件入口已移除；Kubernetes/Container 官方插件能力仍保留。

## 界面截图

### 容器

![容器列表](screens/containers.png)

![容器详情](screens/containers-1.png)

### 镜像

![镜像管理](screens/images.png)

### 网络与 Hosts

![网络管理](screens/network.png)

![Hosts 分组管理](screens/hosts.png)

### Machine 与系统

![Machine 与 CLI 环境](screens/cli.png)

![系统信息](screens/system.png)

### Kubernetes / Container Cluster

![Kubernetes](screens/k8s.png)

![Kubernetes 集群配置 1](screens/k8s-1.png)

![Kubernetes 集群配置 2](screens/k8s-2.png)

![Kubernetes 集群配置 3](screens/k8s-3.png)

![Kubernetes 集群配置 4](screens/k8s-4.png)

![Kubernetes 集群配置 5](screens/k8s-5.png)

![Kubernetes 集群配置 6](screens/k8s-6.png)

### 应用集群

![应用集群](screens/cluster.png)

![应用集群配置 1](screens/cluster-1.png)

![应用集群配置 2](screens/cluster-2.png)

![应用集群配置 3](screens/cluster-3.png)

![应用集群配置 4](screens/cluster-4.png)

### 日志

![操作日志](screens/logs.png)

## 版本兼容

当前指令库目标版本为 **Apple Container 1.6.1**，兼容 1.1.0 及以上版本。

1.6.1 的重要变化是 Kubernetes 命令组重命名：

```text
container k8s ...       # 旧版本
container cluster ...   # 1.6+
```

面板内部使用统一命令键，并根据实际 CLI 版本自动生成正确路径。`container-apiserver` 可能仍显示 1.5.x，这是同一主版本 XPC API 兼容策略下的正常情况，不代表 CLI 未升级。

官方资料：

- [Apple Container 1.6.1 Release](https://github.com/apple/container/releases/tag/1.6.1)
- [Command Reference 1.6.1](https://github.com/apple/container/blob/1.6.1/docs/command-reference.md)
- [Apple Container Repository](https://github.com/apple/container)

## 系统要求

- Apple Silicon Mac（Apple Container 官方要求）。
- macOS 15 或更高版本，建议使用最新 macOS。
- Apple Container CLI 1.1.0+；推荐 1.6.1。
- Xcode 15+（从源码构建）。

安装 CLI 后确认：

```bash
container --version
container system status
```

## 安装与运行

### 使用预编译版本

从项目 Releases 下载 `.app`，拖入“应用程序”，首次启动时允许访问容器 CLI、日志和必要的系统资源。

### 从源码构建

```bash
git clone <your-repository-url>
cd AiguruContainerPanel
open AiguruContainerPanel.xcodeproj
```

在 Xcode 中选择 `AiguruContainerPanel` Scheme 和当前 Mac 作为运行目标，然后执行 `⌘R`。命令行构建：

```bash
xcodebuild \
  -project AiguruContainerPanel.xcodeproj \
  -scheme AiguruContainerPanel \
  -configuration Debug \
  -derivedDataPath /tmp/AiguruContainerPanelBuild \
  CODE_SIGNING_ALLOWED=NO build
```

## Hosts 管理规则

面板不会直接重写整个 Hosts 文件。它识别并保留已有管理区块，例如：

```text
# >>> SomeApp managed block (do not edit manually)
127.0.0.1 example.local
# <<< SomeApp managed block
```

新增条目只写入：

```text
# >>> AiguruContainerPanel managed block (do not edit manually)
...
# <<< AiguruContainerPanel managed block
```

所有区块和系统条目都会展示，但只有当前应用自己的区块允许删除。写入 `/etc/hosts` 需要管理员密码；密码仅用于本次 `sudo` 操作，不会持久化。

## 项目结构

```text
AiguruContainerPanel/
├── App/                 # SwiftUI 应用入口
├── Models/              # 容器、镜像、Machine、日志等模型
├── Services/            # CLI 执行、环境、容器、镜像、网络和系统服务
├── ViewModels/          # 页面状态与异步操作
├── Views/               # SwiftUI 页面
├── Resources/           # CLI 指令库、Kubernetes API catalog、本地化资源
└── Shared/              # 常量、错误、任务与应用状态
```

## 安全说明

- 所有 CLI 命令通过统一执行器运行，带超时、取消、重试和输出采集。
- 删除、停止、系统服务控制和 Hosts 写入均有明确的权限/确认流程。
- 不建议对生产环境直接执行批量删除或强制清理。
- 请勿提交管理员密码、私有镜像凭据、kubeconfig 或本地环境路径。

## 贡献

欢迎提交 Issue 和 Pull Request。建议在提交前：

1. 说明 macOS、Apple Container CLI 和面板版本。
2. 附上可复现步骤和相关日志摘要，删除敏感信息。
3. 运行 `git diff --check`，并在可用环境中完成 Xcode 构建。
4. 涉及 CLI 行为变化时，同时更新 `Resources/CLICommandCatalog.json` 和相关版本兼容逻辑。

## 许可证

本项目采用 [PolyForm Noncommercial License 1.0.0](https://polyformproject.org/licenses/noncommercial/1.0.0)，完整条款见 [LICENSE](LICENSE)。

该许可允许学习、研究、实验、测试、个人使用、教育和其它非商业用途；禁止将本项目或其衍生作品用于商业目的、商业分发、商业服务或商业销售。PolyForm Noncommercial 不是 OSI 定义的传统“开源软件许可证”，本项目属于带非商业限制的 source-available 项目。

Apple Container、macOS 及第三方依赖的名称、商标和许可证归其各自权利人所有。
