# Handbean

自主可控的通用 AI 助手，编码是其中一个主要场景，而不是产品的全部边界。
仓库根目录是 Elixir/Phoenix 应用；`mobile/` 是复用共享 runtime 的
Android/iOS 宿主。

## 本文件只放长期约束

- 当前源码、测试、构建配置和 CI workflow 是实现事实来源。
- 不在 `AGENTS.md` 维护模块清单、调用链、事件/字段全集、依赖版本、已实现功能
  列表、设备参数或本地数据快照。
- 稳定的产品/协议说明放在 `docs/`；按需执行的操作流程放在 `.agents/skills/`。
- 修改子目录前继续读取更近层级的 `AGENTS.md`；其约束叠加于本文件。

## 工程约束

- 共享业务规则只有一个 owner。Web、mobile 和其他入口负责适配与呈现，不复制
  runtime、持久化或权限状态机。
- 明确区分持久事实、运行态和 UI projection；客户端不得成为共享数据或任务生命
  周期的唯一事实源，也不得维护影子状态。
- Host 能力、工具授权和平台权限必须显式声明并在调用边界校验；不得靠 OS、环境
  变量或进程探测偷偷开放能力。
- 遵循 `ElixirStyleGuide.md` 和现有职责边界。优先扩展已有 owner；不把新职责塞进
  大型 UI/运行循环，也不为一次使用增加抽象层。
- 修复缺陷时先复现问题并定位根因，遵循 Elixir/OTP 惯用法和现有架构边界；修复
  根因而非表面症状，并补充覆盖用户可见行为的回归测试。
- 涉及 Agent 的探索流程、工具调用或结果呈现时，先调研同类成熟 Agent 项目的交互
  与行为语义，再结合 Handbean 的 owner、协议和安全模型实现；借鉴实践，不照搬其
  架构或制造第二套状态。
- Handbean 自有业务代码通过 `Handbean.JSON` 编解码 JSON；不要直接新增 `Jason`
  或 OTP `:json` 调用。第三方依赖内部使用 Jason 不在此约束范围。
- 使用不可变数据、显式管道和 `{:ok, value} | {:error, reason}`。确实会 raise 的
  函数才使用 `!`。
- 不提交 `IO.inspect`，不用 `Process.sleep/1` 掩盖并发问题，不修改 `deps/`，不提交
  scratch、数据库、构建产物或真实凭据。
- 工作区可能有其他人或 Agent 的未提交改动；只修改、格式化和提交本任务文件。

## 验证约束

CI 的实际矩阵以 `.github/workflows/review.yml` 为准。先跑覆盖风险的最小测试集，
再按影响范围扩大：

```bash
mix compile --warnings-as-errors
mix test path/to/affected_test.exs
mix test
npm test
mix test --include slow --only slow
mix test --include e2e test/handbean/e2e/fake_provider_e2e_test.exs
mix test --include e2e test/feature
```

- 测试公共行为和持久/用户可见结果，不把私有调用顺序当契约。
- macOS 默认排除部分 Linux sandbox/job 测试；平台排除不能报告为全平台通过。
- 箭头、图标、留白、缩进、尺寸、颜色、动画姿态等纯视觉改动，必须在真实 Web 页面或
  原生界面检查折叠、展开、窄屏等代表性状态和宽度，并以截图验收；结构测试不能代替
  最终视觉检查。
- 不为纯视觉效果新增锁定 DOM/CSS 结构、class、SVG path 或 glyph、native render-tree
  节点或 spacer、像素坐标或精确视觉常量的自动测试。混合测试只移除视觉实现断言，
  保留用户行为、数据投影、安全边界、host/renderer 协议和生命周期覆盖。
- ARIA 状态、最小触控区、WCAG 对比度等可量化的可访问性要求不是纯视觉实现细节，
  仍应自动测试。
- 移动端结果必须区分 host test、package、模拟器与真机，且 Android/iOS 分别报告。

## 专项流程

- 发布版本时加载 `releasing-handbean` 技能。
- 修改或验收移动宿主时加载 `verifying-handbean-mobile` 技能，并遵守
  `mobile/AGENTS.md`。
- 在受信任局域网部署 Web UI 时加载 `deploying-handbean-lan` 技能，并遵守
  `docs/lan-deployment.md` 与 `docs/security.md`。
- 持久化、跨客户端 runtime、安全和 macOS computer-use 的具体契约以 `docs/`
  中相应文档为准。
