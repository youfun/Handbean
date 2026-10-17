# Handbean E2E / Dogfood 测试指南

## 标签策略

| 标签 | 含义 | 默认行为 |
|------|------|----------|
| `:e2e` | 端到端/集成测试，可能较慢 | **excluded**（不参与 `mix test`） |
| `:slow` | 耗时测试（100k tokens、大量迭代） | **excluded** |
| `:external_api` | 真实 API 调用 | **excluded** |

配置在 `test/test_helper.exs`：

```elixir
ExUnit.configure(exclude: [:slow, :e2e, :external_api])
```

## 运行命令

```bash
# 默认 — 只跑单元和快速集成测试（260 tests）
mix test

# 跑所有 e2e 测试（不含 external_api/slow）
mix test --include e2e

# 跑特定 e2e 测试文件
mix test --include e2e test/handbean/e2e/
mix test --include e2e test/handbean_web/live/

# 跑所有标签（包含 e2e, slow, external_api）
mix test --include e2e --include slow --include external_api

# 只跑 external_api 测试（需先设置 ANTHROPIC_API_KEY）
ANTHROPIC_API_KEY="sk-ant-..." mix test --only external_api
```

## 测试目录结构

```
test/
├── sigil/
│   ├── agent/            # 单元测试（默认运行）
│   │   ├── turn_test.exs
│   │   ├── state_test.exs
│   │   ├── message_test.exs
│   │   └── provider/
│   │       └── anthropic_test.exs  # Provider 单元测试（mock HTTP）
│   ├── e2e/
│   │   └── fake_provider_e2e_test.exs  # Agent Core e2e (@e2e)
│   ├── tool/             # 工具测试（默认运行）
│   ├── security/         # 安全测试（默认运行）
│   └── pubsub/           # PubSub 测试（默认运行）
├── handbean_web/
│   └── live/
│       └── workspace_live_test.exs   # LiveView smoke (@e2e)
└── test_helper.exs
```

## E2E 测试内容

### Agent Core e2e (`test/handbean/e2e/fake_provider_e2e_test.exs`)

11 个测试，通过 FakeProvider 验证完整 Agent 管道：

- **Dogfood 流程**: tool_use → tool_result（read 工具读取 fixture）→ final answer
- **Multi-tool**: 并行工具调用
- **Simple answer**: 无工具调用直接回答
- **Memory loop**: mem_learn → mem_recall → final answer（@tag :skip，见下方注释）
- **Agent.run/2 管道**: system_prompt、max_turns、PubSub Session 事件发射
- **Error handling**: provider 错误 → state.status = :error
- **State integrity**: config 保持、response_metadata 填充

已跳过的测试：`memory_learn_and_recall` — 因为 Memory 工具在 `Task.async` 中执行，而当前 Ecto sandbox 使用 `:manual` 模式，跨进程访问数据库会失败。这是工具执行器的已知限制，不在本次改动范围。

### LiveView smoke (`test/handbean_web/live/workspace_live_test.exs`)

27 个测试，验证 WorkspaceLive 的 UI 交互：

- **Mount 渲染**: 三栏布局、status bar、AI input、空状态
- **Input 交互**: 输入更新、空消息忽略
- **Send message**: 消息出现在列表、输入清除、running 状态
- **Tool 事件**: tool_start/tool_end 工具指示器
- **Run end**: agent-working 清除、tools_active 清除、状态更新
- **File preview**: 有效/无效文件渲染
- **Diff view**: 增删高亮、HTML 转义
- **Status helpers**: status_dot_class、tool_status_class

## 后续测试放置

| 测试类型 | 建议位置 | 标签 |
|----------|----------|------|
| 100k tokens 流式压测 | `test/handbean/e2e/streaming_stress_test.exs` | `@slow` |
| 真实 Anthropic API 测试 | `test/handbean/e2e/external_api_test.exs` | `@external_api` |
| Memory 集成测试（修复 sandbox） | 当前 `fake_provider_e2e_test.exs` memory 测试取消 skip | `@e2e` |
| 浏览器 E2E（Playwright/Wallaby） | `test/handbean/e2e/browser/` | `@e2e @slow` |

## 真实 API 测试（external_api）

真实 API 测试目前只有一个 manual gate。如需自动测试，在 `test/handbean/e2e/external_api_test.exs` 中创建测试文件，使用 `@moduletag :external_api`，运行时提供 `ANTHROPIC_API_KEY` 环境变量：

```elixir
defmodule Handbean.E2E.ExternalApiTest do
  use ExUnit.Case, async: false
  @moduletag :external_api

  test "real Anthropic turn" do
    config = %{
      model: "claude-sonnet-4-20250514",
      max_tokens: 50,
      api_key: System.get_env("ANTHROPIC_API_KEY")
    }

    {:ok, result} = Handbean.Agent.Provider.Anthropic.complete(
      [Handbean.Agent.Message.user("Say hi")],
      [],
      config
    )

    assert result.stop_reason == :end_turn
  end
end
```

```bash
# 运行真实 API 测试
ANTHROPIC_API_KEY="sk-ant-..." mix test --only external_api
```
