defmodule Handbeam.Agent.BuiltinModels do
  @moduledoc """
  Exact model metadata bundled with Handbeam when a remote catalog omits it.

  Model ids are matched exactly, optionally after a gateway provider prefix.
  Unknown ids never inherit capabilities by family or name.
  """

  @codex_models [
    %{
      "id" => "gpt-6.1-sol",
      "name" => "GPT-6.1-Sol",
      "reasoning" => true,
      "input" => ["text", "image"],
      "contextWindow" => 272_000,
      "reasoningLevels" => ["low", "medium", "high", "xhigh", "max", "ultra"],
      "defaultReasoning" => "low"
    },
    %{
      "id" => "gpt-6-sol",
      "name" => "GPT-6-Sol",
      "reasoning" => true,
      "input" => ["text", "image"],
      "contextWindow" => 272_000,
      "reasoningLevels" => ["low", "medium", "high", "xhigh", "max", "ultra"],
      "defaultReasoning" => "medium"
    },
    %{
      "id" => "gpt-6-luna",
      "name" => "GPT-6-Luna",
      "reasoning" => true,
      "input" => ["text", "image"],
      "contextWindow" => 272_000,
      "reasoningLevels" => ["low", "medium", "high", "xhigh", "max"],
      "defaultReasoning" => "medium"
    },
    %{
      "id" => "gpt-6-astra",
      "name" => "GPT-6-Astra",
      "reasoning" => true,
      "input" => ["text", "image"],
      "contextWindow" => 272_000,
      "reasoningLevels" => ["low", "medium", "high", "xhigh", "max", "ultra"],
      "defaultReasoning" => "low"
    },
    %{
      "id" => "gpt-5.6-sol",
      "name" => "GPT-5.6-Sol",
      "reasoning" => true,
      "input" => ["text", "image"],
      "contextWindow" => 272_000,
      "reasoningLevels" => ["low", "medium", "high", "xhigh", "max", "ultra"],
      "defaultReasoning" => "low"
    },
    %{
      "id" => "gpt-5.6-terra",
      "name" => "GPT-5.6-Terra",
      "reasoning" => true,
      "input" => ["text", "image"],
      "contextWindow" => 272_000,
      "reasoningLevels" => ["low", "medium", "high", "xhigh", "max", "ultra"],
      "defaultReasoning" => "medium"
    },
    %{
      "id" => "gpt-5.6-luna",
      "name" => "GPT-5.6-Luna",
      "reasoning" => true,
      "input" => ["text", "image"],
      "contextWindow" => 272_000,
      "reasoningLevels" => ["low", "medium", "high", "xhigh", "max"],
      "defaultReasoning" => "medium"
    },
    %{
      "id" => "gpt-5.5",
      "name" => "GPT-5.5",
      "reasoning" => true,
      "input" => ["text", "image"],
      "contextWindow" => 272_000,
      "reasoningLevels" => ["low", "medium", "high", "xhigh"],
      "defaultReasoning" => "medium"
    }
  ]

  @spec codex() :: [map()]
  def codex, do: @codex_models

  @spec find(String.t()) :: map() | nil
  def find(model_id) when is_binary(model_id) do
    bare_id = model_id |> String.split("/", parts: 2) |> List.last()
    Enum.find(@codex_models, &(&1["id"] == bare_id))
  end

  def find(_model_id), do: nil
end
