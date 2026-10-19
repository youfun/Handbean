defmodule Handbean.Speech do
  @moduledoc """
  Local speech-to-text owner shared by Handbean hosts.

  Hosts provide capture and a backend capability. This module owns the audio
  contract, model policy, transcription limits, and draft insertion semantics.
  """

  alias Handbean.{Host, Settings}
  alias Handbean.Speech.{Model, Server}

  @sample_rate 16_000
  @bytes_per_sample 4
  @minimum_duration_ms 300
  @maximum_duration_ms 60_000
  @topic "speech:status"

  @spec backend() :: module() | nil
  def backend, do: Host.speech_backend()

  @spec supported?() :: boolean()
  def supported? do
    case backend() do
      backend when is_atom(backend) and not is_nil(backend) ->
        Code.ensure_loaded?(backend) and function_exported?(backend, :available?, 0) and
          backend.available?()

      _ ->
        false
    end
  end

  @spec enabled?(keyword()) :: boolean()
  def enabled?(opts \\ []) do
    {:ok, settings} = Settings.load_global(opts)
    match?(%{"enabled" => true}, Map.get(settings, "speech", %{}))
  end

  @spec set_enabled(boolean(), keyword()) :: :ok | {:error, term()}
  def set_enabled(enabled, opts \\ []) when is_boolean(enabled) do
    case Settings.save_global_section("speech", %{"enabled" => enabled}, opts) do
      :ok ->
        broadcast({:speech_enabled, enabled})
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  @spec available?() :: boolean()
  def available? do
    enabled?() and supported?() and status() in [:ready, :transcribing]
  end

  @spec model_info() :: map()
  def model_info do
    model = Model.default()
    vad = Model.vad()

    model
    |> Map.take([:id, :filename])
    |> Map.put(:size_bytes, model.size_bytes + vad.size_bytes)
  end

  @spec prepare() :: :ok | {:error, term()}
  def prepare do
    cond do
      not enabled?() -> {:error, :disabled}
      not supported?() -> {:error, :unavailable}
      true -> Server.prepare()
    end
  end

  @spec status() :: term()
  def status, do: Server.current_status()

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Handbean.PubSub, @topic)

  defp broadcast(message) do
    if Process.whereis(Handbean.PubSub),
      do: Phoenix.PubSub.broadcast(Handbean.PubSub, @topic, message),
      else: :ok
  end

  @spec transcribe(binary(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def transcribe(pcm, opts \\ []) do
    cond do
      not enabled?() -> {:error, :disabled}
      not supported?() -> {:error, :unavailable}
      true -> with :ok <- validate_pcm(pcm), do: Server.transcribe(pcm, opts)
    end
  end

  @spec validate_pcm(term()) :: :ok | {:error, atom()}
  def validate_pcm(pcm) when is_binary(pcm) do
    size = byte_size(pcm)
    minimum = div(@sample_rate * @bytes_per_sample * @minimum_duration_ms, 1_000)
    maximum = div(@sample_rate * @bytes_per_sample * @maximum_duration_ms, 1_000)

    cond do
      rem(size, @bytes_per_sample) != 0 -> {:error, :invalid_pcm}
      size < minimum -> {:error, :too_short}
      size > maximum -> {:error, :too_long}
      true -> :ok
    end
  end

  def validate_pcm(_pcm), do: {:error, :invalid_pcm}

  @spec normalize_text(String.t()) :: String.t()
  def normalize_text(text) when is_binary(text) do
    text
    |> String.replace(~r/\[(?:BLANK_AUDIO|SILENCE|MUSIC|APPLAUSE)\]/iu, "")
    |> String.trim()
  end

  @spec append_to_draft(String.t() | nil, String.t()) :: String.t()
  def append_to_draft(draft, transcription) when is_binary(transcription) do
    draft = to_string(draft || "")
    transcription = normalize_text(transcription)

    cond do
      transcription == "" -> draft
      draft == "" -> transcription
      String.match?(draft, ~r/\s$/u) -> draft <> transcription
      true -> draft <> " " <> transcription
    end
  end
end
