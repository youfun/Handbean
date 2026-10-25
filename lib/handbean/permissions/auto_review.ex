defmodule Handbean.Permissions.AutoReview do
  @moduledoc """
  One-shot review for tool calls that `ToolPolicy` has already marked `:prompt`.

  This is not a permission expansion. Sandbox, allow/deny, and unsandboxed gates
  stay where they are. A review approval runs the call once and is not written
  to `tools.allow` or the session override map. Timeout, an unavailable model,
  and unparseable output fall back to human approval; they are not denials.
  """

  require Logger

  alias Handbean.Agent.{Config, Message, ModelConfig, ProviderGateway}
  alias Handbean.Permissions.{Boundary, InterruptData}
  alias Handbean.WorkspaceSettings

  @transport_key :handbean_auto_review_transport
  @consecutive_deny_limit 3
  @recent_window 50
  @recent_deny_limit 10
  @default_timeout_ms 30_000
  @hidden_types ~w(thinking redacted_thinking reasoning responses_reasoning codex_reasoning)

  @external_resource Path.join(__DIR__, "policy.md")
  @policy File.read!(Path.join(__DIR__, "policy.md"))
  @no_workaround "不要用绕路、间接执行或改参数来达成同一目的；只能换一条实质更安全的路径，否则停下来问用户。"
  @halt_error "智能审批连续拒绝过多越界操作，本轮已停止。超时不会被当成拒绝。"

  def policy_text, do: @policy
  def no_workaround, do: @no_workaround
  def halt_error, do: @halt_error

  def initial_ledger do
    %{consecutive_denies: 0, recent: [], stop: false}
  end

  @doc false
  def transport_key, do: @transport_key

  def enabled?(workspace) when is_binary(workspace) and workspace != "" do
    WorkspaceSettings.approvals_reviewer(workspace) == :auto_review
  end

  def enabled?(_workspace), do: false

  @doc """
  Review one `:prompt` batch.

  Returns `{:ok, state}` when every request has an approve or deny, or
  `{:fallback, state, reason}` when the review cannot be trusted. Fallback
  resets the consecutive deny counter and must be shown to the user.
  """
  def review(%Handbean.Agent.State{} = state, pending) when is_list(pending) do
    checkout = state.config.working_directory
    workspace = state.config.workspace_path || checkout

    requests =
      pending
      |> InterruptData.build([], checkout)
      |> Map.fetch!(:action_requests)
      |> Boundary.annotate_requests(state.tool_guard_pending_grants || %{})

    prompt = build_prompt(state.messages, requests, checkout)
    timeout = timeout_ms(workspace)

    request = %{
      prompt: prompt,
      action_requests: requests,
      timeout_ms: timeout,
      workspace_path: workspace,
      checkout_path: checkout,
      run_provider: state.config.provider,
      run_provider_config: state.config.provider_config || %{},
      run_model: state.config.model
    }

    case call_reviewer(request, timeout) do
      {:ok, text} when is_binary(text) ->
        case parse_decisions(text, requests) do
          {:ok, decisions} ->
            if Enum.any?(decisions, &(&1.decision == :needs_human)) do
              fallback(state, :reviewer_abstained)
            else
              {:ok, apply_decisions(state, pending, decisions)}
            end

          {:error, reason} ->
            fallback(state, reason)
        end

      {:error, reason} ->
        fallback(state, reason)
    end
  end

  def build_prompt(messages, requests, workspace_path) when is_list(requests) do
    """
    #{@policy}

    This batch is out of bounds. These calls were not auto-approved. Review only this batch.
    Current checkout: #{workspace_path || "(none)"}
    #{host_sandbox_note()}
    Recent visible conversation (hidden reasoning omitted):
    #{visible_excerpt(messages)}

    Out-of-bounds requests:
    #{format_requests(requests)}
    """
  end

  def parse_decisions(text, requests) when is_binary(text) and is_list(requests) do
    with {:ok, json} <- decode_json(text),
         {:ok, raw} <- decision_items(json, requests),
         {:ok, parsed} <- normalize_all(raw),
         :ok <- cover_all(parsed, requests) do
      {:ok, parsed}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :unparseable}
    end
  end

  def parse_decisions(_text, _requests), do: {:error, :unparseable}

  @doc """
  Fold approve/deny decisions into the turn ledger.

  A non-deny resets the consecutive counter. The rolling window keeps the last
  50 decisions. Three consecutive denies, or 10 denies in that window, latch
  `stop` even if a later approve in the same batch resets the consecutive count.
  """
  def record(ledger, decisions) when is_list(decisions) do
    Enum.reduce(decisions, normalize_ledger(ledger), fn decision, acc ->
      kind = decision_kind(decision)
      recent = Enum.take(acc.recent ++ [kind], -@recent_window)
      consecutive = if kind == :deny, do: acc.consecutive_denies + 1, else: 0

      %{
        acc
        | recent: recent,
          consecutive_denies: consecutive,
          stop:
            acc.stop or consecutive >= @consecutive_deny_limit or
              Enum.count(recent, &(&1 == :deny)) >= @recent_deny_limit
      }
    end)
  end

  def deny_content(rationale) do
    reason =
      rationale
      |> to_string()
      |> String.trim()
      |> case do
        "" -> "未给出具体理由。"
        text -> text
      end

    """
    智能审批拒绝了这次越界操作。
    理由：#{reason}

    #{@no_workaround}
    """
    |> String.trim()
  end

  defp apply_decisions(state, pending, decisions) do
    by_id = Map.new(decisions, &{&1.tool_call_id, &1})

    denied =
      Enum.filter(pending, fn call ->
        decision = Map.get(by_id, call_id(call))
        decision && decision.decision == :deny
      end)

    blocks =
      Enum.map(denied, fn call ->
        decision = Map.fetch!(by_id, call_id(call))

        Message.tool_result_block(
          call_id(call),
          deny_content(decision.rationale),
          true,
          %{permission: :denied, tool: call_name(call), reviewer: :auto_review}
        )
      end)

    ledger = record(state.auto_review, decisions)

    state = %{
      state
      | tool_guard_denied_calls: denied,
        tool_guard_result_blocks: blocks,
        auto_review: ledger,
        tool_guard_overrides: state.tool_guard_overrides || %{}
    }

    if ledger.stop do
      %{state | status: :halted, error: @halt_error}
    else
      state
    end
  end

  defp fallback(state, reason) do
    Logger.warning(
      "[AutoReview] review unavailable, returning to human approval: #{inspect(reason)}"
    )

    ledger = %{normalize_ledger(state.auto_review) | consecutive_denies: 0}
    {:fallback, %{state | auto_review: ledger}, reason}
  end

  defp call_reviewer(request, timeout) do
    parent = self()
    ref = make_ref()
    fun = transport()

    pid =
      spawn(fn ->
        result =
          try do
            fun.(request)
          catch
            kind, reason -> {:error, {kind, reason}}
          end

        send(parent, {ref, result})
      end)

    receive do
      {^ref, {:ok, text}} when is_binary(text) ->
        {:ok, text}

      {^ref, {:error, reason}} ->
        {:error, reason}

      {^ref, other} ->
        {:error, {:bad_review, other}}
    after
      timeout ->
        Process.exit(pid, :kill)
        flush_ref(ref)
        {:error, :timeout}
    end
  end

  defp flush_ref(ref) do
    receive do
      {^ref, _} -> :ok
    after
      0 -> :ok
    end
  end

  defp transport do
    case Process.get(@transport_key) do
      fun when is_function(fun, 1) -> fun
      _ -> &model_transport/1
    end
  end

  defp model_transport(%{prompt: prompt} = request) do
    with {:ok, provider, config} <- review_provider(request),
         {:ok, response} <- ProviderGateway.complete(provider, [Message.user(prompt)], [], config),
         text when is_binary(text) and text != "" <- response_text(response) do
      {:ok, text}
    else
      {:error, reason} -> {:error, reason}
      :error -> {:error, :model_unavailable}
      other -> {:error, other}
    end
  end

  # The main run already resolved the provider module, subscription, and base URL.
  # Re-reading ModelConfig and passing only `:provider` drops `provider_key` and
  # sends Cursor/Codex reviews to OpenAICompat's StepFun default.
  defp review_provider(request) do
    timeout = request.timeout_ms
    configured = configured_model(request.workspace_path)

    cond do
      use_run_provider?(configured, request) ->
        {:ok, request.run_provider,
         call_config(
           request.run_provider_config,
           request.run_model,
           timeout,
           request.checkout_path
         )}

      true ->
        resolve_configured_model(
          request.workspace_path,
          request.checkout_path,
          configured,
          timeout
        )
    end
  end

  defp use_run_provider?(configured, request) do
    is_atom(request.run_provider) and not is_nil(request.run_provider) and
      (blank_model?(configured) or configured == request.run_model)
  end

  defp blank_model?(model), do: not is_binary(model) or String.trim(model) == ""

  defp configured_model(workspace) do
    settings =
      case WorkspaceSettings.load(workspace) do
        {:ok, settings} -> settings
        _ -> %{}
      end

    WorkspaceSettings.auto_review_config(settings).model
  end

  defp call_config(provider_config, model, timeout, workspace) do
    provider_config
    |> Map.drop([:provider_state, :system_prompt, :conversation_id, :run_id])
    |> Map.put(:model, model)
    |> Map.put(:stream, false)
    |> Map.put(:receive_timeout, timeout)
    |> Map.put(:max_tokens, 1500)
    |> Map.put(:working_directory, workspace)
  end

  defp resolve_configured_model(workspace, checkout, model, timeout) do
    model =
      if blank_model?(model), do: ModelConfig.default_model_for_workspace(workspace), else: model

    with true <- is_binary(model) and model != "",
         {:ok, provider_config, model_id} <-
           ModelConfig.resolve_model_for_workspace(workspace, model),
         {:ok, provider} <- provider_module(provider_config) do
      {:ok, provider, call_config(provider_config, model_id, timeout, checkout)}
    else
      false -> {:error, :model_unavailable}
      {:error, reason} -> {:error, {:model_unavailable, reason}}
    end
  end

  defp provider_module(config) do
    name = config[:provider] || config[:provider_key]
    module = Config.resolve_provider_from_api(config[:api], config[:model], provider_name(name))

    cond do
      module == Handbean.Agent.Provider.OpenAICompat and subscription_key?(name) ->
        {:error, :model_unavailable}

      module == Handbean.Agent.Provider.OpenAICompat and blank_model?(config[:base_url]) ->
        {:error, :model_unavailable}

      true ->
        {:ok, module}
    end
  end

  defp provider_name(name) when is_atom(name) and not is_nil(name), do: Atom.to_string(name)
  defp provider_name(name) when is_binary(name), do: name
  defp provider_name(_name), do: nil

  defp subscription_key?(name) when name in ["cursor", "openai_codex"], do: true
  defp subscription_key?(_name), do: false

  defp response_text(%{messages: messages}) when is_list(messages) do
    messages
    |> Enum.map(&visible_content/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
    |> String.trim()
  end

  defp response_text(_), do: ""

  defp timeout_ms(workspace) do
    settings =
      case WorkspaceSettings.load(workspace) do
        {:ok, settings} -> settings
        _ -> %{}
      end

    timeout = WorkspaceSettings.auto_review_config(settings).timeout_ms
    if timeout > 0, do: timeout, else: @default_timeout_ms
  end

  defp decision_items(%{"decisions" => list}, _requests) when is_list(list), do: {:ok, list}
  defp decision_items(%{decisions: list}, _requests) when is_list(list), do: {:ok, list}

  defp decision_items(%{"decision" => _} = item, requests),
    do: {:ok, [assign_single_id(item, requests)]}

  defp decision_items(%{decision: _} = item, requests),
    do: {:ok, [assign_single_id(item, requests)]}

  defp decision_items(list, _requests) when is_list(list), do: {:ok, list}
  defp decision_items(_other, _requests), do: {:error, :unparseable}

  defp assign_single_id(item, [request]) do
    if blank_id?(Handbean.Utils.SafeMap.get_any(item, "tool_call_id", :tool_call_id)) do
      Map.put(item, "tool_call_id", request_id(request))
    else
      item
    end
  end

  defp assign_single_id(item, _requests), do: item

  defp blank_id?(id), do: not is_binary(id) or String.trim(id) == ""

  defp normalize_all(items) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case normalize_decision(item) do
        {:ok, decision} -> {:cont, {:ok, [decision | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      other -> other
    end
  end

  defp normalize_decision(item) when is_map(item) do
    decision = Handbean.Utils.SafeMap.get_any(item, "decision", :decision)
    rationale = Handbean.Utils.SafeMap.get_any(item, "rationale", :rationale) || ""
    id = Handbean.Utils.SafeMap.get_any(item, "tool_call_id", :tool_call_id)

    cond do
      decision not in ["approve", "deny", "needs_human"] ->
        {:error, :invalid_decision}

      not is_binary(rationale) ->
        {:error, :invalid_rationale}

      true ->
        {:ok,
         %{
           tool_call_id: if(is_binary(id), do: id, else: nil),
           decision: String.to_existing_atom(decision),
           rationale: rationale
         }}
    end
  end

  defp normalize_decision(_item), do: {:error, :unparseable}

  defp cover_all(parsed, requests) do
    expected = MapSet.new(Enum.map(requests, &request_id/1))
    ids = Enum.map(parsed, & &1.tool_call_id)

    cond do
      Enum.any?(ids, &blank_id?/1) ->
        {:error, :unattributable}

      length(ids) != length(Enum.uniq(ids)) ->
        {:error, :unattributable}

      MapSet.new(ids) != expected ->
        {:error, :unattributable}

      true ->
        :ok
    end
  end

  defp request_id(request),
    do: Handbean.Utils.SafeMap.get_any(request, :tool_call_id, "tool_call_id")

  defp decision_kind(%{decision: decision}) when decision in [:approve, :deny], do: decision
  defp decision_kind(%{"decision" => "approve"}), do: :approve
  defp decision_kind(%{"decision" => "deny"}), do: :deny
  defp decision_kind(:approve), do: :approve
  defp decision_kind(:deny), do: :deny
  defp decision_kind("approve"), do: :approve
  defp decision_kind("deny"), do: :deny

  defp normalize_ledger(%{consecutive_denies: n, recent: recent} = ledger)
       when is_integer(n) and is_list(recent) do
    %{
      consecutive_denies: n,
      recent: recent,
      stop: Map.get(ledger, :stop, false) == true
    }
  end

  defp normalize_ledger(_ledger), do: initial_ledger()

  defp visible_excerpt(messages) when is_list(messages) do
    messages
    |> Enum.map(&visible_message/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(-12)
    |> Enum.join("\n\n")
  end

  defp visible_excerpt(_messages), do: ""

  defp visible_message(%Message{role: role, content: content}) do
    text = visible_content(content)

    if text == "" do
      ""
    else
      "#{role}: #{String.slice(text, 0, 2000)}"
    end
  end

  defp visible_message(_message), do: ""

  defp visible_content(text) when is_binary(text), do: text

  defp visible_content(%Message{} = message), do: visible_content(message.content)

  defp visible_content(blocks) when is_list(blocks) do
    blocks
    |> Enum.map(&visible_block/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp visible_content(block) when is_map(block), do: visible_block(block)
  defp visible_content(_other), do: ""

  defp visible_block(block) when is_map(block) do
    type = Handbean.Utils.SafeMap.get_any(block, :type, "type")

    cond do
      hidden_type?(type) ->
        ""

      type == "text" ->
        Handbean.Utils.SafeMap.get_any(block, :text, "text") || ""

      type == "tool_use" ->
        name = Handbean.Utils.SafeMap.get_any(block, :name, "name")

        "tool_use #{name} #{encode_compact(Handbean.Utils.SafeMap.get_any(block, :input, "input") || %{})}"

      type == "tool_result" ->
        "tool_result #{truncate(to_string(Handbean.Utils.SafeMap.get_any(block, :content, "content") || ""))}"

      true ->
        ""
    end
  end

  defp visible_block(_block), do: ""

  defp hidden_type?(type) when is_binary(type) do
    type in @hidden_types or String.contains?(type, "reasoning") or
      String.contains?(type, "thinking")
  end

  defp hidden_type?(_type), do: false

  defp host_sandbox_note do
    if Handbean.Platform.ProcessSandbox.os_enforced?() do
      ""
    else
      """
      Host sandbox: none. This OS cannot confine bash. Checkout-local bash uses the unsandboxed approval gate because there is no Bubblewrap/Seatbelt, not because the command opted out of an existing sandbox. Do not deny solely for that. Still deny credentials, irreversible destruction, and persisting allow rules.
      """
    end
  end

  defp format_requests(requests) do
    Enum.map_join(requests, "\n", fn request ->
      id = Handbean.Utils.SafeMap.get_any(request, :tool_call_id, "tool_call_id")
      name = Handbean.Utils.SafeMap.get_any(request, :tool_name, "tool_name")
      args = Handbean.Utils.SafeMap.get_any(request, :arguments, "arguments") || %{}
      "- tool_call_id=#{id} tool=#{name} arguments=#{encode_compact(args)}"
    end)
  end

  defp encode_compact(value) do
    case Handbean.JSON.encode(value) do
      {:ok, json} -> truncate(json)
      {:error, _reason} -> truncate(inspect(value))
    end
  end

  defp truncate(text) when is_binary(text) and byte_size(text) > 2000,
    do: String.slice(text, 0, 2000)

  defp truncate(text) when is_binary(text), do: text
  defp truncate(other), do: to_string(other)

  defp decode_json(text) do
    trimmed = String.trim(text)
    candidates = [trimmed, strip_fences(trimmed), slice_object(trimmed)]

    Enum.find_value(candidates, {:error, :unparseable}, fn candidate ->
      case Handbean.JSON.decode(candidate) do
        {:ok, value} -> {:ok, value}
        _ -> nil
      end
    end)
  end

  defp strip_fences(text) do
    text
    |> String.replace(~r/^```(?:json)?\s*/i, "")
    |> String.replace(~r/\s*```$/, "")
    |> String.trim()
  end

  defp slice_object(text) do
    with {start, _} <- :binary.match(text, "{"),
         matches when matches != [] <- :binary.matches(text, "}") do
      {finish, _} = List.last(matches)
      String.slice(text, start..finish)
    else
      _ -> text
    end
  end

  defp call_id(call), do: Handbean.Utils.SafeMap.get_any(call, :id, "id")
  defp call_name(call), do: Handbean.Utils.SafeMap.get_any(call, :name, "name")
end
