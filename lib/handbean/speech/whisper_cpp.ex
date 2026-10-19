defmodule Handbean.Speech.WhisperCpp do
  @moduledoc false

  @behaviour Handbean.Speech.Backend

  @compile {:no_warn_undefined, WhisperCpp}
  @native WhisperCpp

  @impl true
  def available?, do: Code.ensure_loaded?(@native)

  @impl true
  def load_model(path) when is_binary(path) do
    if available?(), do: @native.load_model(path), else: {:error, :unavailable}
  end

  @impl true
  def transcribe(model, pcm, opts) when is_binary(pcm) do
    whisper_opts =
      opts
      |> Keyword.take([:language, :initial_prompt, :vad_model_path])
      |> Keyword.put_new(:language, "auto")
      |> Keyword.put(:suppress_blank, true)
      |> Keyword.put(:suppress_non_speech_tokens, true)
      |> Keyword.put(:print_progress, false)

    case @native.transcribe(model, {:pcm_f32, pcm}, whisper_opts) do
      {:ok, transcription} -> {:ok, Map.get(transcription, :text, "")}
      {:error, reason} -> {:error, reason}
    end
  end
end
