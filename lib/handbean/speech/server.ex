defmodule Handbean.Speech.Server do
  @moduledoc false

  use GenServer

  alias Handbean.Speech
  alias Handbean.Speech.Model

  @topic "speech:status"
  @status_key {__MODULE__, :status}

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  def current_status, do: :persistent_term.get(@status_key, :unavailable)

  def prepare(server \\ __MODULE__), do: GenServer.call(server, :prepare, :infinity)

  def transcribe(pcm, opts \\ []) do
    transcribe(__MODULE__, pcm, opts)
  end

  def transcribe(server, pcm, opts) do
    GenServer.call(server, {:transcribe, pcm, opts}, :infinity)
  end

  @impl true
  def init(opts) do
    backend = Keyword.get(opts, :backend, Speech.backend())
    model = Keyword.get(opts, :model, Model.default())
    vad_model = Keyword.get(opts, :vad_model, Model.vad())
    model_opts = Keyword.get(opts, :model_opts, [])

    state = %{
      backend: backend,
      loaded_model: nil,
      vad_path: nil,
      model: model,
      vad_model: vad_model,
      model_opts: model_opts,
      public?: Keyword.get(opts, :name, __MODULE__) == __MODULE__,
      status: initial_status(backend, model, vad_model, model_opts)
    }

    publish_status(state, state.status)
    {:ok, state, {:continue, :prepare_enabled}}
  end

  @impl true
  def handle_continue(:prepare_enabled, state) do
    if Speech.enabled?(), do: send(self(), :prepare_enabled)
    {:noreply, state}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  def handle_call(:prepare, _from, state) do
    if Speech.enabled?() do
      case prepare_state(state) do
        {:ok, state} -> {:reply, :ok, state}
        {:error, reason, state} -> {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :disabled}, state}
    end
  end

  def handle_call({:transcribe, pcm, opts}, _from, state) do
    case ensure_loaded(state) do
      {:ok, state} ->
        state = put_status(state, :transcribing)
        opts = Keyword.put(opts, :vad_model_path, state.vad_path)
        result = state.backend.transcribe(state.loaded_model, pcm, opts)
        state = put_status(state, result_status(result))
        {:reply, normalize_result(result), state}

      {:error, reason, state} ->
        state = put_status(state, {:error, reason})
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info(:prepare_enabled, state) do
    if Speech.enabled?() do
      case prepare_state(state) do
        {:ok, state} -> {:noreply, state}
        {:error, _reason, state} -> {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  defp prepare_state(state) do
    case ensure_loaded(state) do
      {:ok, state} -> {:ok, put_status(state, :ready)}
      {:error, reason, state} -> {:error, reason, put_status(state, {:error, reason})}
    end
  end

  defp ensure_loaded(%{loaded_model: loaded_model, vad_path: vad_path} = state)
       when not is_nil(loaded_model) and is_binary(vad_path),
       do: {:ok, state}

  defp ensure_loaded(%{backend: backend} = state) do
    if backend_available?(backend) do
      state = put_status(state, model_install_status(state))

      with {:ok, path} <- Model.ensure_installed(state.model, state.model_opts),
           {:ok, vad_path} <- Model.ensure_installed(state.vad_model, state.model_opts),
           {:ok, loaded_model} <- backend.load_model(path) do
        {:ok, %{state | loaded_model: loaded_model, vad_path: vad_path}}
      else
        {:error, reason} -> {:error, reason, state}
      end
    else
      {:error, :unavailable, state}
    end
  end

  defp initial_status(backend, model, vad_model, model_opts) do
    directory = Keyword.get(model_opts, :directory, Model.directory())

    cond do
      not backend_available?(backend) -> :unavailable
      Model.present?(model, directory) and Model.present?(vad_model, directory) -> :installed
      true -> :not_downloaded
    end
  end

  defp model_install_status(state) do
    directory = Keyword.get(state.model_opts, :directory, Model.directory())

    if Model.present?(state.model, directory) and Model.present?(state.vad_model, directory),
      do: :loading,
      else: :downloading
  end

  defp backend_available?(backend) when is_atom(backend) do
    Code.ensure_loaded?(backend) and function_exported?(backend, :available?, 0) and
      backend.available?()
  end

  defp backend_available?(_backend), do: false

  defp normalize_result({:ok, text}) when is_binary(text),
    do: {:ok, Speech.normalize_text(text)}

  defp normalize_result({:error, _reason} = error), do: error
  defp normalize_result(other), do: {:error, {:invalid_backend_result, other}}

  defp result_status({:ok, _text}), do: :ready
  defp result_status({:error, reason}), do: {:error, reason}
  defp result_status(other), do: {:error, {:invalid_backend_result, other}}

  defp put_status(%{status: status} = state, status), do: state

  defp put_status(state, status) do
    publish_status(state, status)
    %{state | status: status}
  end

  defp publish_status(%{public?: true}, status) do
    :persistent_term.put(@status_key, status)
    Phoenix.PubSub.broadcast(Handbean.PubSub, @topic, {:speech_status, status})
  end

  defp publish_status(_state, _status), do: :ok
end
