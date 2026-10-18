defmodule Handbean.Agent.ProgressGuard do
  @moduledoc """
  Detects a run that is repeating itself.

  Pure. Middleware records tool observations; this module does not call tools
  or decide how a channel should stop.
  """

  alias Handbean.Agent.WorkDigest

  @recent 8
  @repeat_threshold 3
  @error_streak 5
  @same_error 3
  @quiet_turns 12
  @grace 8

  def initial do
    %{
      recent: [],
      seen: MapSet.new(),
      failures: 0,
      error_key: nil,
      error_count: 0,
      quiet: 0,
      grace: 0,
      digest: WorkDigest.empty()
    }
  end

  def enabled?(%{delegated?: true}), do: false

  # Interactive runs stay under user control instead of pausing on heuristic signals.
  def enabled?(%{source: source}), do: Handbean.Agent.Channel.unattended?(source)
  def enabled?(_), do: false

  def interactive?(%{source: source}), do: Handbean.Agent.Channel.interactive?(source)
  def interactive?(_), do: false

  def grant(progress) do
    files =
      Map.new(progress.digest.files, fn {path, hashes} ->
        {path, Enum.take(hashes, -1)}
      end)

    %{initial() | digest: %{files: files}, grace: @grace}
  end

  @doc """
  Record one tool observation.

  Returns `{progress, nil}` or `{progress, signal, evidence}`.
  """
  def observe(progress, obs) when is_map(obs) do
    if progress.grace > 0 do
      {%{progress | grace: progress.grace - 1}, nil, nil}
    else
      progress = apply_obs(progress, obs)

      case signal(progress, obs) do
        nil -> {progress, nil, nil}
        {name, evidence} -> {progress, name, evidence}
      end
    end
  end

  @doc false
  def observation_key(obs) when is_map(obs) do
    {obs.tool, args_hash(obs.args), result_hash(obs.result)}
  end

  defp apply_obs(progress, obs) do
    signature = observation_key(obs)
    result = elem(signature, 2)
    new? = not MapSet.member?(progress.seen, signature) or write?(obs)
    error? = obs.error == true

    digest =
      if write?(obs) do
        WorkDigest.note(progress.digest, obs.path, obs.result)
      else
        progress.digest
      end

    {error_key, error_count, failures} =
      if error? do
        same = {obs.tool, result}

        count = if progress.error_key == same, do: progress.error_count + 1, else: 1
        {same, count, progress.failures + 1}
      else
        {nil, 0, 0}
      end

    %{
      progress
      | recent: Enum.take(progress.recent ++ [signature], -@recent),
        seen: MapSet.put(progress.seen, signature),
        failures: failures,
        error_key: error_key,
        error_count: error_count,
        quiet: if(new?, do: 0, else: progress.quiet + 1),
        digest: digest
    }
  end

  defp signal(progress, obs) do
    cond do
      progress.failures >= @error_streak or progress.error_count >= @same_error ->
        {:repeated_failure, "连续失败：#{obs.tool}"}

      repeat?(progress.recent, observation_key(obs)) ->
        {:repeated_call, "同一 #{obs.tool} 调用在最近 #{@recent} 次里重复 #{@repeat_threshold} 次，结果相同"}

      oscillation(progress, obs) ->
        {:edit_cycle, "文件 #{obs.path} 的内容摘要在本轮中来回变化"}

      progress.quiet >= @quiet_turns ->
        {:no_new_information, "连续 #{@quiet_turns} 次工具调用没有新的参数、结果或文件修改"}

      true ->
        nil
    end
  end

  defp repeat?(recent, signature), do: Enum.count(recent, &(&1 == signature)) >= @repeat_threshold

  defp oscillation(progress, %{path: path}) when is_binary(path) do
    WorkDigest.returns(WorkDigest.history(progress.digest, path)) >= 2
  end

  defp oscillation(_progress, _obs), do: false

  defp write?(%{tool: tool}) when tool in ["edit", "write"], do: true
  defp write?(_), do: false

  defp args_hash(args) do
    args
    |> stringify()
    |> Enum.sort()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp result_hash(result) do
    WorkDigest.hash(result || "")
  end

  defp stringify(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)
  end

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(other), do: other
end
