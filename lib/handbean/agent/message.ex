defmodule Handbean.Agent.Message do
  @moduledoc """
  Normalized message representation across providers.

  Struct and helpers for building user, assistant, tool_use, and tool_result messages.
  """

  defstruct [:role, :content, :tool_calls, :tool_use_id, :usage, :id, :name]

  @type role :: :user | :assistant | :tool_use | :tool_result

  @type content_block :: map()

  @type t :: %__MODULE__{
          role: role(),
          content: String.t() | [content_block()] | nil,
          tool_calls: [%{id: String.t(), name: String.t(), input: map()}] | nil,
          tool_use_id: String.t() | nil,
          usage: map() | nil,
          id: String.t() | nil,
          name: String.t() | nil
        }

  @doc "Create a user message."
  @spec user(String.t()) :: t()
  def user(content), do: %__MODULE__{role: :user, content: content}

  @doc "Create an assistant text message."
  @spec assistant(String.t()) :: t()
  def assistant(content), do: %__MODULE__{role: :assistant, content: content}

  @doc "Create a tool_use message (assistant with tool calls)."
  @spec tool_use([map()]) :: t()
  def tool_use(tool_calls), do: %__MODULE__{role: :assistant, content: tool_calls}

  @doc "Create an assistant message with content blocks (used for tool calls)."
  @spec assistant_blocks([content_block()]) :: t()
  def assistant_blocks(blocks) when is_list(blocks) do
    %__MODULE__{role: :assistant, content: blocks}
  end

  @doc "Create a tool_result message."
  @spec tool_result(map()) :: t()
  def tool_result(block), do: %__MODULE__{role: :tool_result, content: block}

  @doc "Create a list of tool_result messages."
  @spec tool_results([map()]) :: t()
  def tool_results(blocks), do: %__MODULE__{role: :tool_result, content: blocks}

  @doc "Extract tool calls from messages."
  @spec tool_calls(t()) :: [%{id: String.t(), name: String.t(), input: map()}]
  def tool_calls(%__MODULE__{role: :assistant, content: content}) when is_list(content) do
    Enum.filter(content, &(block_value(&1, :type) == "tool_use"))
    |> Enum.map(fn tc ->
      %{
        id: block_value(tc, :id),
        name: block_value(tc, :name),
        input: block_value(tc, :input) || %{}
      }
    end)
  end

  def tool_calls(_), do: []

  defp block_value(block, key) when is_map(block) do
    Map.get(block, key) || Map.get(block, Atom.to_string(key))
  end

  defp block_value(_block, _key), do: nil

  @doc """
  Extracts plain text from a message, ignoring tool blocks.
  Returns nil if no text content exists.
  """
  @spec text(t()) :: String.t()
  def text(%__MODULE__{content: content}) when is_binary(content), do: content

  def text(%__MODULE__{content: blocks}) when is_list(blocks) do
    blocks
    |> Enum.filter(&(is_map(&1) && block_value(&1, :type) == "text"))
    |> Enum.map_join("\n", &(block_value(&1, :text) || ""))
  end

  @doc """
  Build a tool_result block from result text.

  Accepts optional `details` map for UI metadata (not sent to provider).
  """
  @spec tool_result_block(String.t(), String.t(), boolean(), map() | nil) :: map()
  def tool_result_block(tool_use_id, content, is_error \\ false, details \\ nil) do
    result = %{
      type: "tool_result",
      tool_use_id: tool_use_id,
      content: content,
      is_error: is_error
    }

    if details, do: Map.put(result, :details, details), else: result
  end

  @doc "Build a server tool result block."
  @spec server_tool_result_block(String.t(), String.t(), boolean()) :: map()
  def server_tool_result_block(tool_use_id, content, is_error \\ false) do
    Map.put(tool_result_block(tool_use_id, content, is_error), :server_tool_use, true)
  end

  @doc "Creates an inline image content block."
  @spec image(String.t(), String.t()) :: content_block()
  def image(mime_type, data), do: %{type: "image", mime_type: mime_type, data: data}

  @doc "Creates an inline audio content block."
  @spec audio(String.t(), String.t()) :: content_block()
  def audio(mime_type, data), do: %{type: "audio", mime_type: mime_type, data: data}

  @doc "Creates an inline video content block."
  @spec video(String.t(), String.t()) :: content_block()
  def video(mime_type, data), do: %{type: "video", mime_type: mime_type, data: data}

  @doc "Creates a URI-referenced document content block."
  @spec document(String.t(), String.t()) :: content_block()
  def document(mime_type, uri), do: %{type: "document", mime_type: mime_type, uri: uri}
end
