defmodule Handbean.Agent.Provider do
  @moduledoc """
  Behaviour for LLM providers.

  Each provider translates between its native wire format and
  `Handbean.Agent.Message` structs.

  Usage preserves provider-native `input_tokens` and `output_tokens` counts.
  `total_input_tokens` includes uncached input, cache reads and cache writes
  exactly once, so consumers can compare cache usage across providers.
  """

  alias Handbean.Agent.Message

  @type tool_def :: %{name: String.t(), description: String.t(), input_schema: map()}

  @type completion_response :: %{
          required(:stop_reason) => :tool_use | :end_turn,
          required(:messages) => [Message.t()],
          required(:usage) => map(),
          optional(:provider_state) => map(),
          optional(:response_metadata) => map()
        }

  @doc """
  Send messages to the provider and get a completion response.

  Returns `{:ok, completion_response()}` on success or `{:error, term()}`.
  """
  @callback complete(
              messages :: [Message.t()],
              tool_defs :: [tool_def()],
              config :: map()
            ) :: {:ok, completion_response()} | {:error, term()}

  @doc """
  Stream a completion, calling `on_chunk` for each text delta.

  Returns the same `{:ok, completion_response()}` once the stream finishes.
  """
  @callback stream(
              messages :: [Message.t()],
              tool_defs :: [tool_def()],
              config :: map(),
              on_chunk :: (String.t() -> :ok)
            ) :: {:ok, completion_response()} | {:error, term()}

  @doc """
  Whether `read_context` and `edit_context` may be offered for this provider.

  The next request has to observe the edited transcript. A provider that only
  continues a server-side session returns false unless installing an edited
  context restarts that session and replays the edited messages.
  """
  @callback context_editing?() :: boolean()

  @optional_callbacks [stream: 4, context_editing?: 0]

  @context_tool_names ["read_context", "edit_context"]

  @doc """
  Context tools are available only when this provider opts in.

  A provider opts in by defining `context_editing?/0` and returning true.
  That means the next request observes the edited transcript. Server-side
  session providers stay opted out until they restart the session and replay
  the edited messages.
  """
  @spec context_editing?(module()) :: boolean()
  def context_editing?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :context_editing?, 0) and
      module.context_editing?()
  end

  def context_editing?(_module), do: false

  @doc "Drop context tools when this provider cannot apply an edited transcript."
  @spec filter_context_tools([tool_def()], module()) :: [tool_def()]
  def filter_context_tools(tool_defs, provider) when is_list(tool_defs) do
    if context_editing?(provider) do
      tool_defs
    else
      Enum.reject(tool_defs, &(&1.name in @context_tool_names))
    end
  end

  # ── Shared Helpers (used by provider implementations) ──────────────

  @doc """
  Normalizes Responses and Chat Completions usage without counting cache reads twice.

  OpenAI `input_tokens` / `prompt_tokens` already include cache reads and cache
  writes, so `total_input_tokens` stays equal to that inclusive count.
  GPT-5.6 and later report new cache writes as `cache_write_tokens` inside
  `input_tokens_details` or `prompt_tokens_details`. That count is kept as
  `cache_creation_input_tokens`. A missing write field stays 0; an explicit 0
  is not replaced by another key.

  ## Examples

      iex> Handbean.Agent.Provider.openai_usage(%{"prompt_tokens" => 100, "prompt_tokens_details" => %{"cached_tokens" => 80}})
      %{input_tokens: 100, total_input_tokens: 100, output_tokens: 0, cache_read_input_tokens: 80, cache_creation_input_tokens: 0}

      iex> Handbean.Agent.Provider.openai_usage(%{"input_tokens" => 2600, "input_tokens_details" => %{"cached_tokens" => 2000, "cache_write_tokens" => 400}})
      %{input_tokens: 2600, total_input_tokens: 2600, output_tokens: 0, cache_read_input_tokens: 2000, cache_creation_input_tokens: 400}
  """
  def openai_usage(usage) when is_map(usage) do
    input = usage["input_tokens"] || usage["prompt_tokens"] || 0

    details =
      case usage["input_tokens_details"] || usage["prompt_tokens_details"] do
        map when is_map(map) -> map
        _ -> %{}
      end

    %{
      input_tokens: input,
      total_input_tokens: input,
      output_tokens: usage["output_tokens"] || usage["completion_tokens"] || 0,
      cache_read_input_tokens: details["cached_tokens"] || usage["prompt_cache_hit_tokens"] || 0,
      cache_creation_input_tokens: cache_write_tokens(details, usage)
    }
  end

  defp cache_write_tokens(details, usage) do
    cond do
      is_number(details["cache_write_tokens"]) ->
        details["cache_write_tokens"]

      is_number(details["cache_creation_input_tokens"]) ->
        details["cache_creation_input_tokens"]

      is_number(usage["cache_write_tokens"]) ->
        usage["cache_write_tokens"]

      is_number(usage["cache_creation_input_tokens"]) ->
        usage["cache_creation_input_tokens"]

      true ->
        0
    end
  end

  @doc """
  Recursively convert atom keys to strings in maps.

  Used by providers to prepare JSON-compatible request bodies.
  """
  @spec stringify_keys(term()) :: term()
  def stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) ->
        {Atom.to_string(k), stringify_keys(v)}

      {k, v} when is_binary(k) ->
        {k, stringify_keys(v)}

      {k, _v} ->
        raise ArgumentError, "stringify_keys expects atom or string keys, got: #{inspect(k)}"
    end)
  end

  def stringify_keys(map) when is_list(map), do: Enum.map(map, &stringify_keys/1)
  def stringify_keys(map), do: map

  @doc """
  Decode a JSON binary response body, passing through maps unchanged.

  Returns `{:ok, decoded_map}` or `{:error, reason}`.
  """
  @spec decode_body(binary() | map()) :: {:ok, map()} | {:error, String.t()}
  def decode_body(body) when is_map(body), do: {:ok, body}

  def decode_body(body) when is_binary(body) do
    case Handbean.JSON.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> {:error, "Failed to decode response JSON"}
    end
  end
end
