# Android / iOS 真机验收流程

本流程用于本地线程验收 `dev` 的移动宿主兼容性，**不是**已完成的验收报告。

编写时参考版本：[21d0627](https://github.com/youfun/Handbean/commit/21d062706fd749e873138e73bf147261f36b3f77)。执行时冻结实际待验收 SHA；后续修改必须记录新 SHA 并重测受影响项目。

相关阅读（执行前必读，不要把 GitHub `master` 当锁定文档）：

- [mobile/AGENTS.md](../mobile/AGENTS.md)
- 本仓库锁定的 Mob 工具文档：`mobile/deps/mob_dev/README.md`、`mix help`（在 `mobile/` 下）
- [transcript-durability.md](transcript-durability.md)
- 源码测试：`test/handbean/storage_nif_test.exs`、`test/handbean/storage_lock_test.exs`、`test/handbean/conversation_transcript_store_test.exs`、`test/handbean/e2e/transcript_durability_test.exs`

> **模拟器 / ARC / 桌面 Mix / 浏览器设备模拟不能替代真机签收。** 它们只可作为预检。分别报告 Android 实体机与 iOS 实体 iPhone。预检结果必须标明环境，不得写成“Android/iOS 全通过”。

## 1. 范围、授权与证据

- Android 实体 ARM64 手机、iOS 实体 iPhone **分别出结论**。
- 原生页面是 Compose / SwiftUI，不是 WorkspaceLive。Web 的历史分页、线程交接卡片、模型继承行为不得直接当作原生功能要求。
- 不做公网部署、TLS/proxy 部署验证，不发布商店、不 push/merge。安装覆盖、强制退出、故障注入只在用户确认的测试设备和可丢弃数据中执行。
- 先确认现有安装是否有真实数据；不要卸载、清数据或导入真实凭据来“修好”测试。SQLite 全量切换需要明确授权后 clear-data/卸载重装；升级前用受支持命令建立并校验备份，禁止盲目降级。
- 默认先用受控 Provider / 直接 runtime 探针，不消耗模型费用。真实模型用例需确认测试账号、模型及费用上限；未获授权标记未执行。
- 一台设备只由一个线程操作。不得为连接方便开放公网 Dist、关闭认证或放宽路径权限。
- 功能证据优先：设备上 `Mob.Test` 的限定状态、Runner/Session、transcript API、产物内容。截图只证明外观，必须打开检查后附报告。不要输出完整 assigns、环境、API key、cookie、真实对话或私人路径。

结果统一为 `PASS / FAIL / BLOCKED / NOT_RUN / N/A`：

| 结果 | 含义 |
| --- | --- |
| PASS | 在声明环境上满足判定标准，且有 runtime / 落盘证据 |
| FAIL | 行为错误、数据丢失/重复、未授权读写、串工作区、取消后仍执行 |
| BLOCKED | 缺设备、签名、调试连接、安装权限；**不算通过** |
| NOT_RUN | 可执行但本轮未做（费用、时间、风险） |
| N/A | 平台/产品边界；必须注明原因 |

NIF 冷启动失败、数据丢失/重复、未授权读写、跨工作区串状态、取消后持续执行时立即标 FAIL，保留最小 fixture 并回报开发线程；不要默默改产品后沿用旧 SHA 报告。修复后重新打包冷启动，并跑受影响矩阵。

## 2. 冻结版本与构建前检查

使用独立 checkout，保留原工作区改动；不要直接在用户正在开发的目录切分支。记录：

```bash
# 仓库根目录；不将 git diff 中的潜在秘密直接贴入报告
git status --short
git rev-parse HEAD
git rev-parse origin/dev
elixir --version
mix --version
mix compile --warnings-as-errors
mix test --seed 48172
# 然后在 mobile/ 目录执行
mix deps.get
mix test --seed 48172
```

记录 root/mobile 锁文件、OTP/Elixir、Mob、Zig、NDK/Xcode、设备 OS/ABI、构建模式、应用版本和安装包 SHA256。

macOS 上 `mix test` 会运行桌面 Bash job 测试，但仍排除 `:linux_sandbox`（见 `test/test_helper.exs`）。这些 **bwrap / 桌面 Bash job** 测试要单列，它们不是手机验收项目。手机无 shell，不要求在设备安装 bwrap。

Zig 必须是 `mobile/.tool-versions` 锁定的精确版本（当前 pin：`0.17.0-dev.269+ebff43698`）。`mix mob.doctor` 失败时先修工具链，不要用错版本的 Zig 打包后宣称 NIF 通过。

打包前核对 gitignored `mobile/mob.exs` 与 `mobile/config/mob.exs.template` 的 `static_nifs` 是否一致。`mix mob.write_mob_exs` **不会覆盖**已有 `mob.exs`；陈旧文件会漏掉 `handbean_storage` 等静态 NIF，安装后表现为 `:on_load_failure`。`--skip-setup` 不会修复该漂移。

若 Orb 配置要求密码，用私密环境提供，不修改安全配置。

## 3. 安装与真正冷启动

### Android

本地终端先确定设备序列号，不默认操作 adb 列表中的第一台设备：

```bash
adb devices -l
export DEVICE='<已确认的实体手机序列号>'
adb -s "$DEVICE" shell getprop ro.product.cpu.abi
adb -s "$DEVICE" shell getprop ro.build.version.release
# mobile/ 目录；打包脚本默认包含 setup 与测试
bash script/pack_android_apks.sh --abi arm64-v8a
shasum -a 256 artifacts/Handbean-arm64-v8a.apk
# 以下仅在已确认允许更新该测试安装后执行
adb -s "$DEVICE" install -r artifacts/Handbean-arm64-v8a.apk
adb -s "$DEVICE" shell am force-stop com.example.handbean_probe.nativechat
adb -s "$DEVICE" shell am start -n com.example.handbean_probe.nativechat/com.example.handbean_probe.MainActivity
adb -s "$DEVICE" forward tcp:9200 tcp:9200
adb -s "$DEVICE" reverse tcp:4369 tcp:4369
epmd -daemon
mix run --no-start script/mob_debug_probe.exs
```

必须确认探针连到 `handbean_probe_android_nativechat@127.0.0.1`，并显示 `HandbeanProbe.HomeScreen`。脚本有旧 probe fallback，连上旧包不算成功。不要用默认 `mix mob.connect` 重启错误包。不要使用 `forward --remove-all` 影响他人连接。

`arm64-v8a` 是手机与 **arm64 模拟器**；`x86_64` 是 Chromos / x86 模拟器。不要把 ARC x86_64 APK 装到 ARM 设备。模拟器预检可以走同一套 Dist 配方，但结论必须写 `emulator`，不能签收真机。

### iOS

在 macOS 上检查 Xcode、开发者模式、设备信任、签名/team 和 provisioning。按本地锁定版本工具文档识别**实体设备** UDID，而非 simulator UDID。

```bash
# mobile/ 目录，先阅读本地工具帮助确认目标选择
mix help mob.deploy
mix help mob.devices
mix ios.native --device <实体iPhone-UDID>
```

这是包含原生宿主的构建入口；`mix ios` 或 RPC 热加载不能证明新的静态 NIF 已安装。若工具版本不支持该设备安装路径，记录精确错误并使用该版本支持的 Xcode 真机签名/安装流程，不改目标为模拟器后宣称真机通过。

bundle id 为 `com.example.handbean_probe`。记录实际签名产物及其哈希，彻底结束应用进程后由设备重新启动。从启动日志核实实际 node/端口与设备可用的受控调试通道；README 的 iOS simulator 节点名/loopback 配方**不是实体 iPhone 连接配方**。无法取得运行态证据时，只能报告 UI 烟测，不得签收 runtime 项目。

### 两端冷启动门槛

1. 未通过热加载修补，安装产物本身能启动 HomeScreen 与 Handbean runtime。
2. `Handbean.Host` 是设备 profile；`Handbean.ConfigInspection.report(workspace: 测试目录)` 的 allowlist 报告与实际 Registry 一致。不打印完整 prompt。
3. `:handbean_storage` 不出现 `nif_not_loaded` / `on_load` 错误。模板 `mobile/config/mob.exs.template` 必须包含 Android/iOS 静态 NIF；源码桥为 `mobile/c_src/handbean_storage.c`。
4. 创建测试对话、落盘一条 Unicode 消息，重启后经 transcript API 读到同一 ID/内容。仅 `Code.ensure_loaded?` 或构建退出 0 不足以通过。

## 4. 必测矩阵

每行分别记录 Android/iOS 的结果、操作、期望与实际、脱敏证据路径。使用带唯一前缀的两个测试工作区 A/B；所有产物留在测试目录。

| ID | 操作 | 判定标准 |
| --- | --- | --- |
| H1 能力门控 | 检查 Host、Registry、原生导航；如测试设备宿主的 Web 入口也被使用，再检查其窄屏入口与事件处理 | shell/terminal/beam_eval 关闭；`browser_backend` 为 `:webview`；无 bash；文件、grep、task 与线程工具仍注册。不能以“手机是 Linux”开启 shell。Web 伪造 open-terminal 事件也不能启动终端 |
| C1 聊天恢复 | 发送中文、emoji、多行/代码回复；中途切换会话再返回，完成后冷启动 | 可见文本与 transcript 一致，无重复 delta、乱码或历史消失；复制保留完整文本 |
| C2 输入与审批 | 受控长工具执行中 Send/IME、显式排队；触发一次审批，关闭对话框、切换会话后返回，再批准/拒绝 | 默认 steer，显式 follow_up；pending 按 ID 消退；dismiss 不执行工具，仍 awaiting_approval；只执行获准调用一次 |
| C3 取消 | Stop 当前 run，并观察已启动 job 与 descendant 退出 | Runner 真终态、工具正确收尾，无残留执行；审批中断不是终态，不提前关闭 job scope |
| M1 默认模型 | A/B 配置不同的可用默认模型；新会话发送后核对实际 provider/model，再切回已有会话 | 原生 `NativeChat.send_message` 使用有效工作区设置及 catalog fallback；不能只读模型标签。默认不可用时不得绕过工作区 allowlist |
| M2 Web 模型回归 | 仅在实际提供 Web UI 时：目标工作区有效默认优先；删除/禁用该默认后新会话；切回旧会话 | Web 的旧模型兜底与现有会话独立选择均保留。原生没有同一选择状态时标明边界，不凭 Web 测试判原生通过 |
| J1 无 Mix 脚本 | 在没有 mix.exs 的目录调用 run_elixir_script，同步及 job:true 各一次；使用 args/workspace 写入唯一结果 | 同步返回结果；长 job 返回 job_id 后可查完成，stdout/return 与实际文件相符，无 cwd 污染 |
| J2 Mix jobs | 可丢弃纯 Elixir 项目执行 compile/test/run；交错另一 workspace job；再测超时、取消与脚本异常 | MixOwner 串行所有权与 cwd/env 恢复；结果不会串工作区；错误/输出截断可识别；终态清理，无挂死 |
| J3 生命周期 | 同一 run 在 job 活动时审批暂停、恢复、结束；另测 Runner 异常退出 | 暂停保留 scope，真终态关闭；普通 spawn 后代也退出。用 monitor/DOWN 与存活检查，不只看 UI 状态 |
| F1 文件与路径 | 文件树打开文本/图片，隐藏文件开关与加载更多；关闭 viewer 回聊天；测试 ../ 与 symlink 越界 | viewer 不清草稿、不停 Runner；受限读写拒绝越界。BEAM 脚本是宿主高权限，不能把它宣传成 shell sandbox |
| F2 附件/导出 | 选图→草稿→发送→重开历史；产物 Open/Share；操作中切工作区 | 上传引用可恢复，无旧异步结果串草稿；系统 chooser 打开不等于已送达。Android 分享 intake 确认不自动发送，重复进入不重复导入；iOS 未接入的入口列 N/A |
| B1 后台 | 运行中前后台切换、锁屏、回前台、通知跳转 | Android 检查 FGS/停止按钮与正确 conversation；iOS 记录实际挂起/恢复，不要求无限后台运行，不把系统挂起当成功结束 |

J1/J2 建议先用 runtime 工具调用和受控阻塞/释放信号验证，再做可选模型端到端。不要靠短任务“碰巧已完成”验证 job 行为。

## 5. 存储专项：此次真机验收重点

参照 [transcript-durability.md](transcript-durability.md)、`test/handbean/storage_lock_test.exs`、`test/handbean/conversation_transcript_store_test.exs` 和 `test/handbean/e2e/transcript_durability_test.exs`，在设备上移植最小探针。不要原样运行会 spawn 桌面 elixir 的测试。每个故障用独立 fixture，不改真实全局 HOME、不停止带有用户任务的 owner。

1. **静态 NIF 实际 IO**：测试目录取得 `:handbean_storage.lock/1`，第二次 lock 得 `:locked`；执行 append_sync/replace_sync/remove_sync 并读回精确内容；close 后写入得 `:closed`，重新获取成功。不得删除锁文件绕过竞争。
2. **SQLite transcript/page**：通过 Store API 构造 205 条不同 ID 的 Unicode entry，并进行至少 300 次原子追加/更新/删除；保留独立期望列表。冷启动重读后内容、顺序、revision、删除结果一致；用 transcript `page/2` 穷尽分页，无漏项/重复，删除 cursor 返回 invalid_cursor。
3. **WAL/恢复/备份**：构造 streaming assistant 与 running tool 后强杀宿主，冷启动只收口对应 run 且不重放工具；重复启动保持幂等。并行写入期间执行受支持的在线备份，副本通过 quick/FK/schema 校验。记录明确故障点；模拟强杀不能冒称断电或闪存损坏测试。
4. **进程退出恢复**：受控 Provider 先输出已持久化的已知前缀，再阻塞；工具另写一次计数标记。在确认已 sync 后终止测试应用进程，冷启动核对保留文本、孤儿 run 的 assistant/tool error 收尾与稳定错误 ID。再次重启不重复错误、不重跑工具、不重新投递。记录是 force-stop、调试器 terminate 还是实际 crash，不能混称断电测试。
5. **授权与 active run**：同进程 recovery 跳过 running/awaiting_approval；internal orphan 仅可信 recovery owner 可维护。公共 read/page 仍 not_found，closed scope 不重获执行权。不允许用 `internal: true` 等伪造开关绕过授权。
6. **锁释放边界**：owner 退出后资源释放且不遗留写入；全应用退出后冷启动可重新取得锁。两个 Elixir 进程不是两个 OS 实例；真机无法启动共享目录的第二 VM 时，跨实例互斥明确 NOT_RUN，并单列桌面覆盖，不能借用作真机结论。
7. **拒写与重试**：仅在可恢复 fixture 注入写失败，区分 intent 已拥有数据与 intent 未落盘；恢复可写后核对 drain 无丢失/重复。不填满手机磁盘、不 chmod 用户目录。无法安全注入则列未覆盖，不宣称可恢复磁盘拒绝写入的字节。

## 6. 线程通讯与 Web 专属投影

- 原生页面当前没有等同 Web 的线程通讯启用/交接展开控件；不要把缺此控件判成已有功能回归，也不要临时新增它来验收。
- 设备 runtime 的受控测试可以验证 human enable 前拒绝、enable 后 create/read/send/reply、同 child 的两个 handoff 隔离、readonly 拒绝修改、run/reservation 上限和 internal 读权限。必须沿可信授权入口，不能直接改私有状态制造通过。
- 原生无法提供人类启用入口时，该原生端到端链路标 N/A/受限；如经现有 Web 入口启用，报告明确是“设备 runtime + Web 控制”，不是原生 UI 验收。
- 有 Web 入口才检查：100 条初始历史→加载更早→交接 details 仍在；切换会话时分页 cursor 与 collaboration 状态同时隔离。没有该入口不要求开放公网服务。
- 真实模型测试另需授权，记实际调用、关联 ID、provider usage 与 transcript；不能用模型说“完成”替代工具执行证据。不宣称 exactly-once、独立 checkout 或严格货币预算。

## 7. 现有脚本如何复用

- `mobile/script/mob_debug_probe.exs`：Android 只读形状探针，核实目标节点后使用；仍需人工审查产物脱敏。
- `mobile/script/android_git_smoke.exs`：可选 Android 冷启动 Git/HTTPS 验证，需要外网，不调用模型；与公网部署验证不同。只使用它自己的临时目录。
- `mobile/script/validate_native_work.exs`：标注 ARC-only 且需 instrumentation fixture；不要直接当两端真机通用脚本。按其受控 Provider 模式另建设备探针，保留 cleanup。
- `mobile/script/device_exs_git_smoke.exs`：会调用真实 LLM 并写当前工作区，不是免费只读检查；获授权且切到专用 workspace 后才可执行。

## 8. 报告、退出条件与交接

最终报告至少包含：精确 SHA/dirty 状态、安装产物哈希、设备/OS/ABI、冷启动证据、每个用例的平台结果、命令及 decisive output、已查看的截图、失败复现、未覆盖项、测试数据和隧道清理结果。设备标识可脱敏但保留可关联代号。记录是否发生付费调用及 usage，不保存 key。

不得只因桌面全量绿或一台设备通过就写“Android/iOS 全通过”。跨 VM、额外整 VM 暴力 kill、物理断电、真实模型、真实系统分享接收结果等未覆盖项须显式保留。

可直接交给本地线程：

> 在 Handbean 独立 checkout 按 docs/mobile-device-verification.md 验收指定 dev SHA。先报告可用实体设备、签名/安装条件、现有数据风险与费用需求，再在已授权范围执行。保留所有其他工作，不 push/merge/部署，不扩大终端或权限能力。先构建及冷启动，再完成能力门控、存储/NIF/WAL、BEAM jobs、原生聊天/文件/模型设置矩阵；Web 专属和原生边界分开记。优先受控 Provider，真实模型需预算授权。每项提供实际状态/落盘/产物证据，外观截图打开检查；分别报告 Android/iOS 的 PASS/FAIL/BLOCKED/NOT_RUN/N/A 与未覆盖项。若修复产品代码，先回报精确失败、版本和最小复现，不能把修改前验收结论用于修改后产物。
