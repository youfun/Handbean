defmodule Handbean.Extension.Event do
  @moduledoc """
  Extension lifecycle event struct.

  Events flow through the extension hook system. They carry a name,
  session identifier, payload, contextual metadata, and a timestamp.

  Secret-looking keys in payload are redacted from Inspect output.
  """

  alias Handbean.Extension.Diagnostic

  @known_events [
    :session_start,
    :session_shutdown,
    :before_agent_start,
    :agent_start,
    :agent_end,
    :turn_start,
    :turn_end,
    :message_delta,
    :thinking_delta,
    :tool_call,
    :tool_start,
    :tool_end,
    :context,
    :before_provider_request,
    :after_provider_response,
    :input,
    :model_select,
    :resources_discover,
    :run_start,
    :run_end
  ]

  defstruct [
    :name,
    :session_id,
    payload: %{},
    context: %{},
    timestamp: nil
  ]

  @type t :: %__MODULE__{
          name: atom(),
          session_id: String.t(),
          payload: map(),
          context: map(),
          timestamp: DateTime.t()
        }

  @doc """
  Creates a new Event struct.

  Returns `{:ok, event}` or `{:error, diagnostic}`.
  """
  @spec new(atom(), String.t(), map(), map()) :: {:ok, t()} | {:error, Diagnostic.t()}
  def new(name, session_id, payload \\ %{}, context \\ %{})

  def new(name, _session_id, _payload, _context) when not is_atom(name) do
    {:error, %Diagnostic{type: :validation_error, message: "event name must be an atom"}}
  end

  def new(name, session_id, payload, context) do
    with :ok <- validate_known(name),
         :ok <- validate_payload(payload),
         :ok <- validate_context(context) do
      event = %__MODULE__{
        name: name,
        session_id: session_id,
        payload: payload,
        context: context,
        timestamp: DateTime.utc_now()
      }

      {:ok, event}
    end
  end

  @doc "Returns true if the event name is known."
  @spec known_event?(atom()) :: boolean()
  def known_event?(name) when name in @known_events, do: true
  def known_event?(_), do: false

  @doc "Alias for known_event?/1."
  @spec valid_event?(atom()) :: boolean()
  def valid_event?(name), do: known_event?(name)

  @doc "Returns the list of all known event names."
  @spec list_known_events() :: [atom()]
  def list_known_events, do: @known_events

  @doc "Only intent phases may block or transform; lifecycle notifications are read-only."
  def blockable?(name), do: name in [:before_agent_start, :tool_call, :context]

  # ── Inspect redaction ──

  defimpl Inspect do
    @secret_key_patterns [
      ~r/key/i,
      ~r/secret/i,
      ~r/token/i,
      ~r/password/i,
      ~r/passwd/i,
      ~r/auth/i,
      ~r/credential/i
    ]

    def inspect(event, opts) do
      safe_payload = redact_secrets(event.payload)
      safe_context = redact_secrets(event.context)

      safe_map =
        event
        |> Map.from_struct()
        |> Map.put(:payload, safe_payload)
        |> Map.put(:context, safe_context)

      Inspect.Map.inspect(safe_map, opts)
    end

    defp redact_secrets(map) when is_map(map) do
      Map.new(map, fn {key, value} ->
        {key, redact_value(key, value)}
      end)
    end

    defp redact_secrets(map), do: map

    defp redact_value(_key, value) when is_map(value) do
      redact_secrets(value)
    end

    defp redact_value(key, value) do
      if secret_key?(key) do
        "[REDACTED]"
      else
        value
      end
    end

    defp secret_key?(key) when is_atom(key) do
      key_str = Atom.to_string(key)

      Enum.any?(@secret_key_patterns, fn pattern ->
        String.match?(key_str, pattern)
      end)
    end

    defp secret_key?(key) when is_binary(key) do
      Enum.any?(@secret_key_patterns, fn pattern ->
        String.match?(key, pattern)
      end)
    end

    defp secret_key?(_), do: false
  end

  # ── Private helpers ──

  defp validate_known(name) do
    if known_event?(name) do
      :ok
    else
      {:error,
       %Diagnostic{
         type: :validation_error,
         message: "unknown event name: #{inspect(name)}. Known events: #{inspect(@known_events)}"
       }}
    end
  end

  defp validate_payload(payload) when is_map(payload), do: :ok

  defp validate_payload(_),
    do: {:error, %Diagnostic{type: :validation_error, message: "event payload must be a map"}}

  defp validate_context(context) when is_map(context), do: :ok

  defp validate_context(_),
    do: {:error, %Diagnostic{type: :validation_error, message: "event context must be a map"}}
end
