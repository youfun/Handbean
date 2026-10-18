defmodule Handbean.Agent.Advisor do
  @moduledoc """
  Advisor resolution, consult budget, and review gate decisions.

  The module owns request construction and verdict validation. `Turn` calls
  one gate entry and does not infer a pass from free text.
  """

  alias Handbean.Agent.ModelConfig

  @modes ~w(off consult review plan_review)a
  @repair_limit 2
  @consult_timeout_ms 300_000
  @review_timeout_ms 300_000
  @run_budget_ms 8 * 60 * 1000
  @readonly ~w(read grep file_search code_search)

  def modes, do: @modes
  def repair_limit, do: @repair_limit
  def consult_timeout_ms, do: @consult_timeout_ms
  def review_timeout_ms, do: @review_timeout_ms
  def run_budget_ms, do: @run_budget_ms
  def readonly_tools, do: @readonly

  def initial_state(mode \\ :off) do
    %{
      mode: normalize_mode(mode),
      phase: :executing,
      consults: 0,
      repairs: 0,
      spent_ms: 0,
      criteria_version: 1,
      criteria: [],
      request_id: nil,
      artifact_digest: nil,
      verdict: nil,
      autonomous?: false
    }
  end

  def normalize_mode(mode) when mode in @modes, do: mode
  def normalize_mode("off"), do: :off
  def normalize_mode("consult"), do: :consult
  def normalize_mode("review"), do: :review
  def normalize_mode("plan_review"), do: :plan_review
  def normalize_mode(nil), do: :off
  def normalize_mode(_), do: {:error, :invalid_advisor_mode}

  @doc """
  Resolve the advisor for a run. A configured model can be called. A missing
  or disabled advisor does not block the run and does not expose the tool.
  There is no per-run task mode.
  """
  def validate_start(workspace_path, opts) when is_list(opts) do
    case resolve(workspace_path) do
      {:ok, resolved} -> {:ok, Map.merge(resolved, %{available: true})}
      _ -> {:ok, unavailable()}
    end
  end

  def resolve(workspace_path) do
    case Handbean.Settings.advisor_resolution(workspace_path) do
      {:ok, %{model: model, reasoning: reasoning, source: source}} ->
        case ModelConfig.resolve_model_for_workspace(workspace_path, model) do
          {:ok, _config, model_id} ->
            [provider_id, _] = String.split(model, "/", parts: 2)

            {:ok,
             %{
               composite_id: model,
               provider_id: provider_id,
               model_id: model_id,
               reasoning: reasoning,
               source: source
             }}

          {:error, reason} ->
            {:error, reason}
        end

      other ->
        other
    end
  end

  def review?(%{mode: mode}), do: mode in [:review, :plan_review]
  def review?(mode), do: mode in [:review, :plan_review]

  def tool_visible?(%{composite_id: id}) when is_binary(id) and id != "", do: true
  def tool_visible?(_), do: false

  def charge(state, ms) when is_integer(ms) and ms >= 0 do
    %{state | spent_ms: state.spent_ms + ms}
  end

  def record_consult(state), do: %{state | consults: state.consults + 1}

  def stale?(state, digest, request_id) do
    state.artifact_digest != digest or state.request_id != request_id
  end

  def validate_verdict(%{"verdict" => verdict} = payload)
      when verdict in ["pass", "revise", "blocked"] do
    findings = Map.get(payload, "findings", [])

    cond do
      not is_list(findings) ->
        {:error, :invalid_verdict}

      verdict == "pass" and findings != [] ->
        {:error, :pass_with_findings}

      verdict == "revise" and findings == [] ->
        {:error, :revise_without_findings}

      true ->
        {:ok,
         %{
           verdict: String.to_existing_atom(verdict),
           findings: findings,
           notes: Map.get(payload, "notes", [])
         }}
    end
  end

  def validate_verdict(_), do: {:error, :invalid_verdict}

  @doc """
  Decide the gate after a review call, before the queue is sealed.

  A pass is usable only when the request id and artifact digest still match.
  """
  def gate(state, verdict, digest, request_id) do
    cond do
      state.spent_ms >= @run_budget_ms ->
        {:blocked, %{state | phase: :reviewing, verdict: :blocked}}

      stale?(state, digest, request_id) ->
        {:stale, %{state | request_id: nil, verdict: nil}}

      verdict.verdict == :pass ->
        {:pass, %{state | phase: :reviewing, verdict: :pass, request_id: request_id}}

      verdict.verdict == :blocked ->
        {:blocked, %{state | phase: :reviewing, verdict: :blocked}}

      state.repairs >= @repair_limit ->
        {:blocked, %{state | phase: :reviewing, verdict: :blocked}}

      true ->
        {:revise,
         %{
           state
           | phase: :repairing,
             verdict: :revise,
             repairs: state.repairs + 1,
             request_id: nil
         }}
    end
  end

  @doc "Pin used when a run has no workspace advisor."
  def unavailable, do: unavailable_pin()

  defp unavailable_pin do
    %{
      available: false,
      composite_id: nil,
      provider_id: nil,
      model_id: nil,
      reasoning: nil,
      source: nil
    }
  end

  @doc """
  Run one acceptance review through Delegation and validate its verdict.

  A missing runner, invalid JSON, or exhausted budget is `blocked`, never `pass`.
  """
  def review(%Handbean.Agent.State{} = state, opts, request_id, digest)
      when is_binary(request_id) do
    advisor = state.advisor

    cond do
      advisor.spent_ms >= @run_budget_ms ->
        {:blocked, %{advisor | verdict: :blocked}, "advisor time budget exhausted"}

      not is_pid(state.config.runner_pid) ->
        {:blocked, %{advisor | verdict: :blocked}, "advisor review requires an active run"}

      true ->
        started = System.monotonic_time(:millisecond)

        result =
          Handbean.Agent.Delegation.run(
            %{"prompt" => review_prompt(state, digest)},
            review_context(state, opts, request_id),
            :advisor
          )

        advisor = charge(advisor, System.monotonic_time(:millisecond) - started)
        interpret(advisor, result, digest, request_id)
    end
  end

  defp review_context(state, opts, request_id) do
    config = state.config

    %{
      delegation_config: config,
      runner_pid: config.runner_pid,
      run_id: config.run_id,
      conversation_id: opts[:conversation_id] || opts[:session_id],
      working_directory: config.working_directory,
      workspace_id: config.context[:workspace_id],
      tool_timeout: config.tool_timeout,
      authorized_tools: config.allowed_tools || [],
      advisor_request_id: request_id,
      advisor_kind: :review,
      profile: :advisor
    }
  end

  @doc """
  The advisor's own text inside a Delegation result.

  `Delegation.run/3` wraps that text in an outer JSON report. Callers must
  not parse the wrapper.
  """
  def child_text({_status, _wrapper, data}) when is_map(data) do
    case Handbean.Utils.SafeMap.get_any(data, :report, "report") do
      text when is_binary(text) and text != "" -> text
      _ -> nil
    end
  end

  def child_text(_), do: nil

  defp review_prompt(state, digest) do
    criteria =
      case state.advisor.criteria do
        [] -> "No separate checklist. Judge whether the latest user request is done."
        list -> inspect(list)
      end

    files =
      Enum.map_join(state.progress.digest.files, "\n", fn {path, hashes} ->
        "- #{path} (#{length(hashes)} versions)"
      end)

    """
    Latest user request:
    #{latest_user_text(state)}

    Criteria:
    #{criteria}

    Files touched:
    #{if files == "", do: "(none recorded)", else: files}

    Artifact digest: #{digest}
    Return only JSON: {"verdict":"pass"|"revise"|"blocked","findings":[],"notes":[]}
    """
  end

  defp latest_user_text(state) do
    state.messages
    |> Enum.reverse()
    |> Enum.find_value("(no user request)", fn message ->
      if message.role == :user do
        text = Handbean.Agent.Message.text(message)
        if text == "", do: nil, else: text
      end
    end)
  end

  defp interpret(advisor, {:ok, _text, _data} = result, digest, request_id) do
    body = child_text(result) || ""

    case body |> extract_json() |> validate_verdict() do
      {:ok, verdict} ->
        case gate(
               %{advisor | artifact_digest: digest, request_id: request_id},
               verdict,
               digest,
               request_id
             ) do
          {:pass, advisor} -> {:pass, advisor}
          {:revise, advisor} -> {:revise, advisor, format_findings(verdict)}
          {:blocked, advisor} -> {:blocked, advisor, "验收未通过"}
          {:stale, advisor} -> {:stale, advisor}
        end

      {:error, reason} ->
        {:blocked, %{advisor | verdict: :blocked}, "invalid advisor verdict: #{inspect(reason)}"}
    end
  end

  defp interpret(advisor, {:error, reason, _data}, _digest, _request_id) do
    {:blocked, %{advisor | verdict: :blocked}, inspect(reason)}
  end

  defp interpret(advisor, {:error, reason}, _digest, _request_id) do
    {:blocked, %{advisor | verdict: :blocked}, inspect(reason)}
  end

  defp interpret(advisor, other, _digest, _request_id) do
    {:blocked, %{advisor | verdict: :blocked}, inspect(other)}
  end

  defp extract_json(text) when is_binary(text) do
    case Regex.run(~r/\{.*\}/s, text) do
      [json] ->
        case Handbean.JSON.decode(json) do
          {:ok, map} when is_map(map) -> map
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp format_findings(%{findings: findings}) when is_list(findings) do
    text =
      Enum.map_join(findings, "\n", fn finding ->
        id = finding["criterion_id"] || finding["id"]
        impact = finding["impact"] || finding["fix"]
        "未通过 #{id}: #{impact}"
      end)

    if text == "", do: "验收未通过", else: text
  end
end
