defmodule Handbean.Memory.Metrics do
  @moduledoc """
  Lightweight metrics helpers for evaluating the memory system.

  These metrics intentionally avoid judging semantic correctness by themselves;
  they provide measurable signals that tests, logs, and future evaluation jobs
  can combine with human/LLM relevance labels.
  """

  alias Handbean.Memory.Engram

  @type relevance_label :: :useful | :irrelevant | :stale | :contradictory | :unknown

  @doc """
  Summarize recall effectiveness from retrieved engrams and optional relevance labels.

  Labels can be provided as `%{engram_id => label}` or `%{"engram_id" => label}`.
  """
  @spec recall_quality([Engram.t()], map(), keyword()) :: map()
  def recall_quality(engrams, labels \\ %{}, opts \\ [])
      when is_list(engrams) and is_map(labels) do
    total = length(engrams)
    useful = count_label(engrams, labels, :useful)
    irrelevant = count_label(engrams, labels, :irrelevant)
    stale = count_label(engrams, labels, :stale)
    contradictory = count_label(engrams, labels, :contradictory)
    unknown = total - useful - irrelevant - stale - contradictory
    injected_tokens = Keyword.get(opts, :injected_tokens, estimate_tokens(engrams))

    %{
      total_recalled: total,
      useful_count: useful,
      irrelevant_count: irrelevant,
      stale_count: stale,
      contradictory_count: contradictory,
      unknown_count: unknown,
      useful_rate: ratio(useful, total),
      stale_rate: ratio(stale, total),
      contradiction_rate: ratio(contradictory, total),
      injected_tokens: injected_tokens,
      useful_per_1k_tokens:
        if(injected_tokens > 0, do: useful / injected_tokens * 1000, else: 0.0)
    }
  end

  @doc """
  Return leakage-related metrics for a recalled engram list.
  """
  @spec isolation_quality([Engram.t()], String.t() | nil) :: map()
  def isolation_quality(engrams, workspace_id) when is_list(engrams) do
    cross_workspace =
      Enum.count(engrams, fn engram ->
        metadata_value(engram, "scope") == "workspace" and
          is_binary(workspace_id) and metadata_value(engram, "workspace_id") != workspace_id
      end)

    global = Enum.count(engrams, &(metadata_value(&1, "scope") == "global"))
    workspace = Enum.count(engrams, &(metadata_value(&1, "scope") == "workspace"))

    %{
      total_recalled: length(engrams),
      workspace_hits: workspace,
      global_hits: global,
      cross_workspace_hits: cross_workspace,
      leakage_rate: ratio(cross_workspace, length(engrams))
    }
  end

  @doc """
  Estimate token cost for memory injection. This is intentionally approximate.
  """
  @spec estimate_tokens([Engram.t()] | [String.t()] | String.t()) :: non_neg_integer()
  def estimate_tokens(text) when is_binary(text), do: ceil(String.length(text) / 4)

  def estimate_tokens(text) when is_list(text) do
    text
    |> Enum.reduce(0, fn el, acc ->
      acc +
        (fn
           %Engram{content: content} ->
             estimate_tokens(content || "")

           text when is_binary(text) ->
             estimate_tokens(text)

           other ->
             other
             |> inspect()
             |> estimate_tokens()
         end).(el)
    end)
  end

  defp count_label(engrams, labels, expected) do
    Enum.count(engrams, fn engram -> normalize_label(label_for(labels, engram.id)) == expected end)
  end

  defp label_for(labels, id), do: Map.get(labels, id) || Map.get(labels, to_string(id))

  defp normalize_label(label)
       when label in [:useful, :irrelevant, :stale, :contradictory, :unknown],
       do: label

  defp normalize_label(label) when is_binary(label) do
    case label do
      "useful" -> :useful
      "irrelevant" -> :irrelevant
      "stale" -> :stale
      "contradictory" -> :contradictory
      _ -> :unknown
    end
  end

  defp normalize_label(_), do: :unknown

  defp ratio(_numerator, 0), do: 0.0
  defp ratio(numerator, denominator), do: numerator / denominator

  defp metadata_value(%Engram{metadata: metadata}, key), do: metadata_value(metadata, key)

  defp metadata_value(metadata, key) when is_map(metadata),
    do: Handbean.Utils.SafeMap.get(metadata, key)

  defp metadata_value(_, _), do: nil
end
