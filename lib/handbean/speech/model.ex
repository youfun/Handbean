defmodule Handbean.Speech.Model do
  @moduledoc false

  alias Handbean.Home

  @chunk_size 1_048_576
  @default %{
    id: "whisper-base-q5_1",
    filename: "ggml-base-q5_1.bin",
    url:
      "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base-q5_1.bin?download=true",
    size_bytes: 59_707_625,
    sha256: "422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898"
  }

  @vad %{
    id: "silero-vad-v5.1.2",
    filename: "ggml-silero-v5.1.2.bin",
    url:
      "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin?download=true",
    size_bytes: 885_098,
    sha256: "29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf"
  }

  @type spec :: %{
          id: String.t(),
          filename: String.t(),
          url: String.t(),
          size_bytes: pos_integer(),
          sha256: String.t()
        }

  @spec default() :: spec()
  def default, do: @default

  @spec vad() :: spec()
  def vad, do: @vad

  @spec directory() :: Path.t()
  def directory, do: Path.join([Home.path(), "models", "speech"])

  @spec path(spec(), Path.t()) :: Path.t()
  def path(spec \\ @default, directory \\ directory()) do
    Path.join(directory, spec.filename)
  end

  @spec present?(spec(), Path.t()) :: boolean()
  def present?(spec \\ @default, directory \\ directory()) do
    case File.stat(path(spec, directory)) do
      {:ok, %File.Stat{type: :regular, size: size}} -> size == spec.size_bytes
      _ -> false
    end
  end

  @spec ensure_installed(spec(), keyword()) :: {:ok, Path.t()} | {:error, term()}
  def ensure_installed(spec \\ @default, opts \\ []) do
    directory = Keyword.get(opts, :directory, directory())
    fetch = Keyword.get(opts, :fetch, &download/2)
    destination = path(spec, directory)

    case verify(destination, spec) do
      :ok ->
        {:ok, destination}

      {:error, _reason} ->
        install(spec, directory, destination, fetch)
    end
  end

  @spec verify(Path.t(), spec()) :: :ok | {:error, term()}
  def verify(path, spec \\ @default) do
    with {:ok, %File.Stat{type: :regular, size: size}} <- File.stat(path),
         :ok <- verify_size(size, spec.size_bytes),
         {:ok, digest} <- sha256(path),
         :ok <- verify_digest(digest, spec.sha256) do
      :ok
    else
      {:ok, %File.Stat{}} -> {:error, :not_regular}
      {:error, reason} -> {:error, reason}
    end
  end

  defp install(spec, directory, destination, fetch) do
    part = destination <> ".#{System.unique_integer([:positive])}.part"

    try do
      with :ok <- File.mkdir_p(directory),
           :ok <- normalize_fetch(fetch.(spec.url, part)),
           :ok <- verify(part, spec),
           :ok <- replace(part, destination) do
        {:ok, destination}
      end
    after
      File.rm(part)
    end
  end

  defp download(url, destination) do
    stream = File.stream!(destination, @chunk_size, [:write, :binary])

    case Req.get(url,
           into: stream,
           decode_body: false,
           receive_timeout: :timer.minutes(10),
           retry: :safe_transient
         ) do
      {:ok, %Req.Response{status: 200}} -> :ok
      {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, {:download, reason}}
    end
  rescue
    error in File.Error -> {:error, {:file, error.reason}}
  end

  defp normalize_fetch(:ok), do: :ok
  defp normalize_fetch({:ok, _value}), do: :ok
  defp normalize_fetch({:error, _reason} = error), do: error
  defp normalize_fetch(other), do: {:error, {:invalid_fetch_result, other}}

  defp replace(source, destination) do
    with :ok <- remove_existing(destination), do: File.rename(source, destination)
  end

  defp remove_existing(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:remove_existing, reason}}
    end
  end

  defp verify_size(actual, expected) when actual == expected, do: :ok
  defp verify_size(_actual, _expected), do: {:error, :size_mismatch}

  defp verify_digest(actual, expected) when actual == expected, do: :ok
  defp verify_digest(_actual, _expected), do: {:error, :checksum_mismatch}

  defp sha256(path) do
    digest =
      path
      |> File.stream!(@chunk_size, [])
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    {:ok, digest}
  rescue
    error in File.Error -> {:error, {:file, error.reason}}
  end
end
