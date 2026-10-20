# Android Developer / Sideload 版本

Handbean 的 Android Developer 版本是独立的 ARM64 侧载包。它用于在手机上运行
Termux 为 Android/Bionic 编译的 Bash、Python、Node.js、Erlang/OTP、Elixir、Git 和常用
CLI；它不是 Alpine/Ubuntu 虚拟机，也不能直接运行任意 glibc Linux 二进制。

## 与标准版的边界

| 项目 | 标准版 | Developer / Sideload 版 |
| --- | --- | --- |
| applicationId | `com.example.handbean_probe.nativechat` | `io.hndbean` |
| targetSdk | 35 | 28 |
| ABI | 现有打包矩阵 | 仅 `arm64-v8a` |
| Termux rootfs | 不包含 | 包内固定版本并校验 SHA-256 |
| Bash | 关闭 | 开启，逐次经过未隔离命令审批 |
| Erlang/Elixir CLI | 不包含 | 固定的 Android/Bionic `erl`、`elixir`、`iex`、`mix` |
| 后台 Bash job | 关闭 | 第一版关闭 |
| terminal | 关闭 | 关闭 |

两个包可以同时安装，使用不同的 Android 私有数据目录、BEAM 节点后缀和本地端口。
Developer 构建参数不会改变标准包的 applicationId、targetSdk 或能力声明。

## 安全模型

Developer shell 与 Handbean 主进程使用同一个 Android UID。它能访问该 Developer
包的私有数据，包括配置、工作区和数据库，因此不是安全沙箱，也不应被描述为
“仅能访问 cwd”。共享 runtime 显式声明 `shell_isolation: :none` 和
`shell_jobs: false`；所有 Bash 调用仍经过现有权限策略、敏感路径预检、超时和受监督
同步进程 owner。

`targetSdk 28` 是 Android 对 app 私有可写目录中可执行文件的兼容条件。这个包只适合
用户主动侧载，不进入标准商店分发路径；未来 Android 或 OEM 仍可能收紧兼容行为。

Developer rootfs 中的 Erlang/Elixir 是用户项目使用的独立 CLI VM。它不会承载 Handbean
应用，也不应直接操作 Handbean 数据库；应用仍由 APK 自带的 Elixir/OTP runtime 运行。两套 VM
都固定在 OTP 29 / Elixir 1.20 系列，但补丁版本可以不同。Android 打包入口会校验应用 VM
必须使用 `mobile/.tool-versions` 指定的精确 Elixir/OTP 版本，避免打入不兼容的 Mix beams。

## Rootfs 供应链

`mobile/config/termux-rootfs.lock.json` 记录经仓库 `InRelease` 签名认证的 Termux 索引
SHA-256，以及每个递归依赖的包名、版本、架构、文件名和 SHA-256。更新 lock 时使用仓库中
固定的 Termux 自动构建公钥校验签名；普通 rootfs 构建只消费 lock。生成过程只解开 `.deb`
的 data archive，不运行 maintainer scripts。`com.termux` 与 `io.hndbean` 长度相同，构建器
会对普通文件和符号链接中的固定 prefix 及裸 application ID 做等长替换，并确认产物中不再
残留旧值。

更新 lock 是显式操作：

```bash
cd mobile
mix run --no-start script/build_termux_rootfs.exs --update-lock
```

审核 lock 的包版本与来源后，生成 APK 资产：

```bash
mix run --no-start script/build_termux_rootfs.exs
```

生成物包括：

- `termux-rootfs.tgz`：确定性 gzip 归档（使用 `.tgz` 避免 AAPT 自动展开并改名 `.gz` 资产）；
- `termux-rootfs.json`：ABI、prefix、lock/package manifest digest 和归档 SHA-256；
- `termux-packages.json`：包清单、来源和发现到的许可证文件；当前发布审核已完成，
  `license_review_required` 固定为 `false`。Developer 打包会拒绝该字段仍为 `true` 的旧资产。

这些大文件是本地/CI 构建产物，不提交 Git。APK 打包不会联网补包；缺少或校验失败时
会直接失败。

## 构建

```bash
cd mobile
bash script/pack_android_apks.sh --developer
```

等价的单包入口：

```bash
mix mob.pack_apk --abi arm64-v8a --developer-sideload --no-install \
  --output artifacts/Handbean-Developer-arm64-v8a.apk
```

Developer 与 foundation-test 参数互斥；非 ARM64 Developer 构建会在执行昂贵编译前
失败。

## 发布产物

GitHub Actions 和正式 GitHub Release 分开上传三种 Android 资产：

- `Handbean-arm64-v8a.apk`：标准 ARM64 手机包；
- `Handbean-x86_64.apk`：标准 ChromeOS / x86_64 模拟器包；
- `Handbean-Developer-arm64-v8a.apk`：仅 ARM64 的 Developer / Sideload 包。

CI 先构建 Developer 包，再构建标准包，以验证前一次打包留下的 profile 或资产不会进入
标准 APK。Developer 和标准包使用不同 application ID，可同时安装；它们不能相互升级，
也不共享应用私有数据。Release 页面必须保留本页“与标准版的边界”和“安全模型”中的说明，
不能把 Developer 包描述成标准版、商店版或 shell 沙箱。

当前 GitHub APK 使用 CI debug 签名，不提供跨 workflow 或跨构建的稳定签名身份，也不承诺
原地覆盖升级。签名变化时 Android 会拒绝覆盖安装，需要先卸载旧包；卸载会删除对应包的
应用私有数据，因此重装前必须自行导出需要保留的 workspace、配置和其他内容。

## 首次启动与升级

原生宿主在启动 BEAM 前完成安装：校验包内归档 SHA-256，在同一文件系统的暂存目录
安全解包，拒绝路径穿越和越界链接，确认 Bash、Erlang/Elixir、Python、Node 和 termux-exec 后原子替换
`files/usr`，最后写版本标记。`files/home` 与 Handbean workspace 不属于 rootfs，升级时
不会替换。安装失败或进程中断时，启动事务会恢复旧 rootfs 或完成已经发布的新版本；当前实现
没有对 rootfs 的每个文件和目录执行掉电级 `fsync`，因此这不是突然断电后的持久事务保证，
下次启动仍会重新校验运行时，无法恢复时会拒绝启动而不是暴露 shell。

## 验收层级

Host 测试、Kotlin 编译、APK 检查、模拟器和 ARM64 实体机是不同证据层。发布前至少要
分别记录：

- 标准包仍为 targetSdk 35，且不含 Developer rootfs/source；
- Developer 包为 `io.hndbean`、targetSdk 28、仅 ARM64；
- 冷启动执行 `bash`、`python`、`node`、`git`、`erl`、`elixir`、`iex`、`mix` 的实际输出；
- 创建最小 Mix 项目并执行 `mix compile`、`mix test`、`mix run`；
- 非零退出、超时、取消和后台 job 拒绝；
- 升级保留 home/workspace，标准包数据不受影响；
- 实体机型号、Android 版本、APK SHA-256 和明确的 PASS/FAIL/BLOCKED 状态。
