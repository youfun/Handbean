defmodule Handbean.CodeIndex.Embedder do
  @moduledoc """
  Embedding backend. Implementations must not log request bodies.
  """

  @callback config(keyword()) :: {:ok, map()} | {:error, :unconfigured}
  @callback embed([String.t()], map()) :: {:ok, [[float()]]} | {:error, term()}

  defmodule Noop do
    @moduledoc "Keyword-only backend. Never sends chunk text."
    @behaviour Handbean.CodeIndex.Embedder

    @impl true
    def config(_opts), do: {:error, :unconfigured}

    @impl true
    def embed(_texts, _config), do: {:error, :unconfigured}
  end

  defmodule HTTP do
    @moduledoc """
    OpenAI-compatible `POST /v1/embeddings`.

    Reads the `embeddings` object from `models.json`. Does not reuse the chat
    default model and does not read `OPENAI_API_KEY` unless `apiKey` is `env:VAR`.
    Request bodies are not logged.
    """

    @behaviour Handbean.CodeIndex.Embedder

    alias Handbean.Agent.ModelConfig

    @impl true
    def config(opts) do
      path = Keyword.get(opts, :models_file, ModelConfig.config_file_path())

      with {:ok, body} <- File.read(path),
           {:ok, json} <- Handbean.JSON.decode(body),
           %{} = section <- Map.get(json, "embeddings"),
           model when is_binary(model) and model != "" <- Map.get(section, "model"),
           base when is_binary(base) and base != "" <- Map.get(section, "baseUrl"),
           {:ok, key} <- api_key(Map.get(section, "apiKey")) do
        {:ok, %{model: model, base_url: String.trim_trailing(base, "/"), api_key: key}}
      else
        _ -> {:error, :unconfigured}
      end
    end

    @impl true
    def embed(texts, %{base_url: base, api_key: key, model: model}) when is_list(texts) do
      url = base <> "/embeddings"

      case Req.post(url,
             json: %{model: model, input: texts},
             auth: {:bearer, key},
             receive_timeout: 15_000
           ) do
        {:ok, %{status: 200, body: body}} -> decode(body)
        {:ok, %{status: status}} -> {:error, {:http, status}}
        {:error, reason} -> {:error, reason}
      end
    end

    def embed(_, _), do: {:error, :unconfigured}

    @doc "L2-normalize a vector into a little-endian float32 blob."
    @spec pack([float()]) :: {binary(), pos_integer()}
    def pack(values) when is_list(values) do
      norm = :math.sqrt(Enum.reduce(values, 0.0, fn v, acc -> acc + v * v end))
      scale = if norm == 0.0, do: 1.0, else: norm

      blob =
        values
        |> Enum.map(&<<&1 / scale::float-little-32>>)
        |> IO.iodata_to_binary()

      {blob, length(values)}
    end

    defp api_key("env:" <> var) do
      case System.get_env(var) do
        key when is_binary(key) and key != "" -> {:ok, key}
        _ -> {:error, :unconfigured}
      end
    end

    defp api_key(key) when is_binary(key) and key != "", do: {:ok, key}
    defp api_key(_), do: {:error, :unconfigured}

    defp decode(%{"data" => data}) when is_list(data) do
      vectors =
        data
        |> Enum.sort_by(&Map.get(&1, "index", 0))
        |> Enum.map(&Map.get(&1, "embedding"))

      if Enum.all?(vectors, &is_list/1) do
        {:ok, vectors}
      else
        {:error, :bad_embedding}
      end
    end

    defp decode(_), do: {:error, :bad_embedding}
  end
end
