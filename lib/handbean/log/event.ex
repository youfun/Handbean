defmodule Handbean.Log.Event do
  @moduledoc """
  Structured log event.

  All events carry a unique `id`, monotonic `timestamp`, and typed `kind`/`level`.
  This module provides `new/1` for validated construction — invalid inputs
  return `{:error, reason}` without raising.

  ## Fields

    * `id` — UUID v4 string, auto-generated
    * `kind` — event category (see `valid_kinds/0`)
    * `level` — severity (see `valid_levels/0`)
    * `message` — human-readable description (required)
    * `timestamp` — system time in milliseconds, auto-generated
    * `session_id` — optional session identifier
    * `turn` — optional turn number
    * `source` — optional source component name (e.g. `"read_tool"`)
    * `metadata` — optional free-form map for additional context
  """

  defstruct [
    :id,
    :kind,
    :level,
    :message,
    :timestamp,
    :session_id,
    :turn,
    :source,
    :metadata
  ]

  @type kind ::
          :session
          | :tool
          | :provider
          | :memory
          | :security
          | :extension
          | :ui
          | :general

  @type level :: :debug | :info | :warning | :error

  @type t :: %__MODULE__{
          id: String.t(),
          kind: kind(),
          level: level(),
          message: String.t(),
          timestamp: integer(),
          session_id: String.t() | nil,
          turn: non_neg_integer() | nil,
          source: String.t() | nil,
          metadata: map()
        }

  @valid_kinds MapSet.new([
                 :session,
                 :tool,
                 :provider,
                 :memory,
                 :security,
                 :extension,
                 :ui,
                 :general
               ])

  @valid_levels MapSet.new([:debug, :info, :warning, :error])

  @doc """
  Returns the set of valid event kinds.
  """
  @spec valid_kinds() :: MapSet.t()
  def valid_kinds, do: @valid_kinds

  @doc """
  Returns the set of valid severity levels.
  """
  @spec valid_levels() :: MapSet.t()
  def valid_levels, do: @valid_levels

  @doc """
  Creates a new event struct with validation.

  Required keys:
    * `:kind` — must be a member of `valid_kinds/0`
    * `:level` — must be a member of `valid_levels/0`
    * `:message` — non-empty string

  Optional keys:
    * `:session_id`, `:turn`, `:source`, `:metadata`

  Returns `{:ok, %Event{}}` or `{:error, reason}`.
  Never raises on bad input.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, atom()}
  def new(attrs) when is_list(attrs) do
    with {:kind, kind} when not is_nil(kind) <- {:kind, Keyword.get(attrs, :kind)},
         true <- MapSet.member?(@valid_kinds, kind) || {:error, :invalid_kind},
         {:level, level} when not is_nil(level) <- {:level, Keyword.get(attrs, :level)},
         true <- MapSet.member?(@valid_levels, level) || {:error, :invalid_level},
         {:message, msg} when is_binary(msg) <- {:message, Keyword.get(attrs, :message)},
         true <- msg != "" || {:error, :missing_message} do
      event = %__MODULE__{
        id: Ecto.UUID.generate(),
        kind: kind,
        level: level,
        message: msg,
        timestamp: System.os_time(:millisecond),
        session_id: Keyword.get(attrs, :session_id),
        turn: Keyword.get(attrs, :turn),
        source: Keyword.get(attrs, :source),
        metadata: Keyword.get(attrs, :metadata, %{})
      }

      {:ok, event}
    else
      {:kind, nil} -> {:error, :invalid_kind}
      {:level, nil} -> {:error, :invalid_level}
      {:message, _} -> {:error, :missing_message}
      {:error, reason} -> {:error, reason}
    end
  end

  def new(_attrs) do
    {:error, :invalid_kind}
  end
end
