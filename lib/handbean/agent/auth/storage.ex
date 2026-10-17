defmodule Handbean.Agent.Auth.Storage do
  @moduledoc """
  Provider credential store backed by `~/.handbean/auth.json`.

  The file shape matches pi's AuthStorage: a JSON object keyed by provider
  id. OAuth entries are `{type, access, refresh, expires}`. The file is
  written with mode 0600 and its parent directory is created as 0700.
  """

  @default_path "~/.handbean/auth.json"
  @path_env "HANDBEAN_AUTH_FILE"

  @type credential :: %{
          optional(String.t()) => term()
        }

  @spec file_path(keyword()) :: String.t()
  def file_path(opts \\ []) do
    case Keyword.get(opts, :auth_path) do
      path when is_binary(path) and path != "" ->
        Handbean.Home.expand(path)

      _ ->
        case System.get_env(@path_env) do
          path when is_binary(path) and path != "" -> Handbean.Home.expand(path)
          _ -> Handbean.Home.expand(@default_path)
        end
    end
  end

  @spec get(String.t(), keyword()) :: {:ok, credential()} | {:error, :not_found | String.t()}
  def get(provider_id, opts \\ []) when is_binary(provider_id) do
    path = file_path(opts)

    with {:ok, data} <- read_file(path) do
      case Map.fetch(data, provider_id) do
        {:ok, credential} ->
          validate_credential(provider_id, credential)

        :error ->
          {:error, :not_found}
      end
    end
  end

  @spec put(String.t(), map(), keyword()) :: :ok | {:error, String.t()}
  def put(provider_id, credential, opts \\ [])
      when is_binary(provider_id) and is_map(credential) do
    path = file_path(opts)

    with {:ok, normalized} <- normalize_credential(provider_id, credential) do
      update_file(path, &Map.put(&1, provider_id, normalized))
    end
  end

  @spec delete(String.t(), keyword()) :: :ok | {:error, String.t()}
  def delete(provider_id, opts \\ []) when is_binary(provider_id) do
    path = file_path(opts)

    update_file(path, &Map.delete(&1, provider_id))
  end

  # Different providers share one file, so provider-specific refresh locks alone
  # cannot protect the read-modify-write from dropping another provider's login.
  defp update_file(path, update) do
    result =
      :global.trans(
        {{__MODULE__, path}, self()},
        fn ->
          with {:ok, data} <- read_file_or_empty(path) do
            write_file(path, update.(data))
          end
        end,
        [Node.self()]
      )

    case result do
      :aborted -> {:error, "Credential storage is busy. Try again."}
      other -> other
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} ->
        decode_auth_file(content)

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, "Failed to read auth.json: #{inspect(reason)}"}
    end
  end

  defp read_file_or_empty(path) do
    case read_file(path) do
      {:error, :not_found} -> {:ok, %{}}
      other -> other
    end
  end

  defp decode_auth_file(content) do
    case Handbean.JSON.decode(content) do
      {:ok, data} when is_map(data) ->
        {:ok, data}

      {:ok, _} ->
        {:error, "Invalid auth.json: expected an object"}

      {:error, reason} ->
        {:error, "Failed to parse auth.json: #{inspect(reason)}"}
    end
  end

  defp write_file(path, data) do
    dir = Path.dirname(path)
    tmp_path = "#{path}.tmp.#{System.unique_integer([:positive])}"

    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700),
         :ok <- File.write(tmp_path, Handbean.JSON.encode!(data, pretty: true)),
         :ok <- File.chmod(tmp_path, 0o600),
         :ok <- File.rename(tmp_path, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp_path)
        {:error, "Failed to write auth.json: #{inspect(reason)}"}
    end
  end

  defp normalize_credential(provider_id, credential) do
    stringified = stringify_keys(credential)
    validate_credential(provider_id, stringified)
  end

  defp validate_credential(provider_id, credential) when is_map(credential) do
    type = Map.get(credential, "type")
    access = Map.get(credential, "access")
    refresh = Map.get(credential, "refresh")
    expires = Map.get(credential, "expires")

    cond do
      type != "oauth" ->
        invalid_credential(provider_id)

      not (is_binary(access) and access != "") ->
        invalid_credential(provider_id)

      not (is_binary(refresh) and refresh != "") ->
        invalid_credential(provider_id)

      not valid_expires?(expires) ->
        invalid_credential(provider_id)

      true ->
        {:ok,
         %{
           "type" => "oauth",
           "access" => access,
           "refresh" => refresh,
           "expires" => expires
         }}
    end
  end

  defp validate_credential(provider_id, _credential), do: invalid_credential(provider_id)

  defp valid_expires?(expires) when is_integer(expires), do: true
  defp valid_expires?(expires) when is_float(expires), do: expires == trunc(expires)
  defp valid_expires?(_), do: false

  defp invalid_credential(provider_id) do
    {:error, "Invalid auth.json credential for provider \"#{provider_id}\""}
  end

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end
end
