# Handbean Mobile Host

`mobile/` 是 Handbean 的 Android/iOS native host。它复用根项目的业务与 Agent
runtime，不维护另一套产品逻辑。

当前功能、模块、版本、节点、端口和设备命令以源码、锁文件、测试、脚本和文档为
准，不在本文件维护快照。

## 长期约束

- 移动宿主只负责原生呈现、平台桥接、能力声明和生命周期适配。共享业务、
  transcript、工具、设置和权限规则应留在根项目的既有 owner。
- 不把 Agent 运行循环、网络请求、模型调用或长任务放进 screen 进程；长任务必须由
  明确的监督边界拥有。
- Web 与 native 共用持久事实和恢复契约。移动端不得维护第二套消息历史、pending
  队列、审批状态或恢复协议。
- 移动能力必须显式注入。不得根据 OS、环境变量或进程名改变共享 runtime 的能力；
  不得为调试开放 shell、关闭认证、放宽路径限制或申请不必要的文件权限。
- 已注册不等于已授权。Workspace、路径和平台权限必须在调用边界重新检查，不能只
  依赖 UI 是否显示入口。
- 平台消息在单一边界解码，wire key 使用固定白名单；不要动态创建 atom，也不要在
  业务代码散落 atom/string 双键 fallback。
- 离屏异步结果必须可关联、可过期。用户切换 workspace、conversation、页面或
  draft 后，旧结果不得合并进新状态。
- 系统 chooser/viewer 已打开只表示界面呈现，不代表文件已送达或分享完成。
- 移动业务代码沿用根项目的 `Handbean.JSON` 约束。

## 验证约束

修改移动代码时加载 `verifying-handbean-mobile` 技能。完整设备矩阵、风险控制和
证据格式见 `../docs/mobile-device-verification.md`；Mob 工具行为以仓库锁定版本的
文档和本目录下的 `mix help` 为准。

```bash
mix deps.get
mix test path/to/affected_test.exs
mix test
```

- Host tests 不得加载 Android/iOS NIF；host-side 测试不能冒充设备验收。
- 共享 runtime 或 schema 变更还必须运行根项目相应测试。
- 运行行为优先由受限 runtime 状态、transcript 或产物内容证明；截图只证明外观。
- 热加载只用于迭代。native code、静态 NIF、migration、manifest 或安装行为变更
  必须重新打包并冷启动验证。
- 模拟器与实体设备是不同证据层级；Android 与 iOS 分别报告。
- 一台设备同一时间只由一个 Agent 操作。明确选择设备，不清除真实数据，不破坏
  他人的 tunnel 或调试会话。
