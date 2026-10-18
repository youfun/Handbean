defmodule Handbean.Agent.Tool.Result do
  @moduledoc """
  Dual-channel tool result — separates LLM-facing content from UI rendering data.

  - `content` — bounded text sent to the provider (LLM)
  - `details` — bounded whitelist metadata for UI; never a full body
  - `is_error` — derived from `status` for provider compatibility
  - `status` / `code` / `side_effect` / `recovery` / `artifacts` — recovery contract

  Failed results keep the concrete error in `content`. The executor appends
  the tool's `hint/0`, when one exists, before applying the output bound.

  Ported from `Gong.ToolResult`.
  """

  @type status :: :succeeded | :failed | :running | :interrupted
  @type side_effect :: :not_started | :committed | :unknown

  @type t :: %__MODULE__{
          content: String.t(),
          details: map() | nil,
          is_error: boolean(),
          operation_id: String.t() | nil,
          status: status(),
          code: atom() | String.t() | nil,
          side_effect: side_effect(),
          recovery: map() | atom() | nil,
          artifacts: [map()],
          images: [map()],
          published_media: [map()]
        }

  defstruct [
    :content,
    :details,
    :operation_id,
    :code,
    :recovery,
    is_error: false,
    status: :succeeded,
    side_effect: :unknown,
    artifacts: [],
    images: [],
    published_media: []
  ]

  @doc """
  Construct a full result with content, optional details, and error flag.
  """
  @spec new(String.t(), map() | nil, boolean()) :: t()
  def new(content, details \\ nil, is_error \\ false) do
    %__MODULE__{
      content: content,
      details: details,
      is_error: is_error,
      status: if(is_error, do: :failed, else: :succeeded)
    }
  end

  @doc """
  Construct a result from a plain text string.

  Backward-compatible with tools that return only a string.
  """
  @spec from_text(String.t()) :: t()
  def from_text(text) when is_binary(text) do
    %__MODULE__{content: text, details: nil, is_error: false}
  end

  @doc """
  Construct an error result.
  """
  @spec error(String.t(), map() | nil) :: t()
  def error(content, details \\ nil) do
    %__MODULE__{
      content: content,
      details: details,
      is_error: true,
      status: :failed,
      side_effect: :not_started
    }
  end

  @doc "Build a result that already names its recovery contract."
  @spec contract(String.t(), keyword()) :: t()
  def contract(content, opts) when is_binary(content) and is_list(opts) do
    status = Keyword.get(opts, :status, :succeeded)

    %__MODULE__{
      content: content,
      details: Keyword.get(opts, :details),
      is_error: status in [:failed, :interrupted],
      operation_id: Keyword.get(opts, :operation_id),
      status: status,
      code: Keyword.get(opts, :code),
      side_effect: Keyword.get(opts, :side_effect, :unknown),
      recovery: Keyword.get(opts, :recovery),
      artifacts: Keyword.get(opts, :artifacts, []),
      images: Keyword.get(opts, :images, []),
      published_media: Keyword.get(opts, :published_media, [])
    }
  end

  @doc """
  Get the LLM-facing content string.
  """
  @spec llm_content(t()) :: String.t()
  def llm_content(%__MODULE__{content: content}), do: content

  @doc """
  Get the UI/details metadata map.
  """
  @spec ui_details(t()) :: map() | nil
  def ui_details(%__MODULE__{details: details}), do: details

  @doc """
  Check if this is an error result.
  """
  @spec error?(t()) :: boolean()
  def error?(%__MODULE__{is_error: is_error}), do: is_error

  @doc """
  Check if this result has UI details (non-nil).
  """
  @spec has_details?(t()) :: boolean()
  def has_details?(%__MODULE__{details: nil}), do: false
  def has_details?(%__MODULE__{}), do: true
end
