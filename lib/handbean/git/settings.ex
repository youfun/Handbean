defmodule Handbean.Git.Settings do
  @moduledoc """
  User Git identity and named HTTPS accounts.

  Stored in `~/.handbean/git.json` (mode 0o600). Never loaded from
  agent-controlled workspace settings. Host `:git_credentials` still
  wins at resolve time.
  """

  @email ~r/^[^@\s]+@[^@\s]+\.[^@\s]+$/
  @id ~r/^[a-zA-Z][a-zA-Z0-9_-]{0,62}$/

  def path(opts \\ []) do
    Keyword.get(opts, :user_config_path) ||
      Application.get_env(:handbean, :git_user_config_path) ||
      Path.join([Handbean.Home.path(), ".handbean", "git.json"])
  end

  def read(opts \\ []) do
    case File.read(path(opts)) do
      {:ok, bytes} ->
        case Handbean.JSON.decode(bytes) do
          {:ok, data} when is_map(data) ->
            if valid?(data),
              do: {:ok, normalize(data)},
              else: {:error, "Invalid Git configuration; fix the file before editing"}

          _ ->
            {:error, "Invalid Git configuration; fix the file before editing"}
        end

      {:error, :enoent} ->
        {:ok, empty()}

      {:error, _} ->
        {:error, "Cannot read Git configuration"}
    end
  end

  def load(opts \\ []) do
    with {:ok, data} <- read(opts) do
      {:ok,
       %{
         identity: identity_map(data),
         default_account: data["default_account"],
         accounts: public_accounts(data)
       }}
    end
  end

  def identity(opts \\ []) do
    case read(opts) do
      {:ok, data} ->
        name = String.trim(get_in(data, ["identity", "name"]) || "")
        email = String.trim(get_in(data, ["identity", "email"]) || "")
        if name != "" and email != "", do: [name: name, email: email], else: []

      _ ->
        []
    end
  end

  def default_account_id(opts \\ []) do
    case read(opts) do
      {:ok, %{"default_account" => id}} when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  def lookup(name, opts \\ []) when is_binary(name) do
    with {:ok, data} <- read(opts),
         {:ok, raw} <- fetch_account(data, name) do
      cred =
        [
          endpoint: raw["endpoint"],
          password: raw["password"],
          username: raw["username"]
        ]
        |> Enum.filter(fn {_k, v} -> is_binary(v) and v != "" end)

      {:ok, cred}
    else
      _ -> :error
    end
  end

  def summarize(opts \\ []) do
    case load(opts) do
      {:ok, %{accounts: []}} ->
        "No Git accounts are configured in Settings."

      {:ok, %{accounts: accounts, default_account: default}} ->
        names =
          Enum.map_join(accounts, ", ", fn account ->
            suffix = if account.id == default, do: ", default", else: ""
            "#{account.id} (#{account.endpoint}#{suffix})"
          end)

        "Configured accounts (pass credential name, never a password): #{names}. " <>
          "If credential is omitted, the default account is used when one is set."

      _ ->
        "Git account settings could not be read."
    end
  end

  def new_form do
    %{
      "id" => "",
      "name" => "",
      "username" => "",
      "endpoint" => "https://github.com",
      "password" => "",
      "has_password" => false
    }
  end

  def edit(id, opts \\ []) do
    with {:ok, data} <- read(opts),
         {:ok, raw} <- fetch_account(data, id) do
      {:ok,
       %{
         "id" => id,
         "name" => raw["name"] || id,
         "username" => raw["username"] || "",
         "endpoint" => raw["endpoint"],
         "password" => "",
         "has_password" => is_binary(raw["password"]) and raw["password"] != ""
       }}
    end
  end

  def save_identity(form, opts \\ []) do
    update(opts, fn data ->
      with {:ok, identity} <- validate_identity(form) do
        {:ok, Map.put(data, "identity", identity), :ok}
      end
    end)
  end

  def save_account(form, opts \\ []) do
    update(opts, fn data ->
      with {:ok, id, raw} <- prepare_account(form, data) do
        accounts = Map.put(data["accounts"], id, raw)
        default = data["default_account"] || id
        default = if Map.has_key?(accounts, default), do: default, else: id

        {:ok, %{data | "accounts" => accounts, "default_account" => default}, {:ok, id}}
      end
    end)
  end

  def delete_account(id, opts \\ []) do
    update(opts, fn data ->
      with {:ok, _} <- fetch_account(data, id) do
        accounts = Map.delete(data["accounts"], id)

        default =
          cond do
            data["default_account"] == id ->
              accounts |> Map.keys() |> List.first()

            true ->
              data["default_account"]
          end

        {:ok, %{data | "accounts" => accounts, "default_account" => default}, :ok}
      end
    end)
  end

  def set_default(id, opts \\ []) do
    update(opts, fn data ->
      cond do
        id in [nil, ""] ->
          {:ok, Map.put(data, "default_account", nil), :ok}

        Map.has_key?(data["accounts"], id) ->
          {:ok, Map.put(data, "default_account", id), :ok}

        true ->
          {:error, "Git account no longer exists"}
      end
    end)
  end

  defp empty do
    %{"identity" => %{"name" => "", "email" => ""}, "default_account" => nil, "accounts" => %{}}
  end

  defp normalize(data) do
    empty()
    |> Map.merge(Map.take(data, ["identity", "default_account", "accounts"]))
    |> update_in(["identity"], fn
      map when is_map(map) -> map
      _ -> %{"name" => "", "email" => ""}
    end)
    |> update_in(["accounts"], fn
      map when is_map(map) -> map
      _ -> %{}
    end)
  end

  defp valid?(data) do
    accounts = Map.get(data, "accounts", %{})
    identity = Map.get(data, "identity", %{})
    default = Map.get(data, "default_account")

    is_map(identity) and is_map(accounts) and
      Enum.all?(accounts, fn {id, raw} -> is_binary(id) and valid_account?(raw) end) and
      (is_nil(default) or default == "" or Map.has_key?(accounts, default))
  end

  defp valid_account?(raw) when is_map(raw) do
    is_binary(raw["endpoint"]) and is_binary(Map.get(raw, "password", ""))
  end

  defp valid_account?(_), do: false

  defp identity_map(data) do
    %{
      "name" => get_in(data, ["identity", "name"]) || "",
      "email" => get_in(data, ["identity", "email"]) || ""
    }
  end

  defp public_accounts(data) do
    default = data["default_account"]

    data["accounts"]
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {id, raw} ->
      %{
        id: id,
        name: raw["name"] || id,
        username: raw["username"] || "",
        endpoint: raw["endpoint"],
        default?: id == default,
        has_password: is_binary(raw["password"]) and raw["password"] != ""
      }
    end)
  end

  defp fetch_account(data, id) do
    case Map.fetch(data["accounts"], id) do
      {:ok, raw} -> {:ok, raw}
      :error -> {:error, "Git account no longer exists"}
    end
  end

  defp validate_identity(form) do
    name = String.trim(form["name"] || "")
    email = String.trim(form["email"] || "")

    cond do
      name == "" and email == "" ->
        {:ok, %{"name" => "", "email" => ""}}

      name == "" or email == "" ->
        {:error, "Commit name and email must both be set, or both left blank"}

      not Regex.match?(@email, email) ->
        {:error, "Enter a valid email address"}

      true ->
        {:ok, %{"name" => name, "email" => email}}
    end
  end

  defp prepare_account(form, data) do
    id = String.trim(form["id"] || "")
    creating? = not Map.has_key?(data["accounts"], id)
    old = Map.get(data["accounts"], id, %{})

    with :ok <- validate_id(id, creating?),
         {:ok, endpoint} <- validate_endpoint(form["endpoint"]),
         {:ok, password} <- account_password(form, old, endpoint) do
      raw = %{
        "name" => blank_to_id(String.trim(form["name"] || ""), id),
        "username" => String.trim(form["username"] || ""),
        "endpoint" => endpoint,
        "password" => password
      }

      {:ok, id, raw}
    end
  end

  defp validate_id(id, _creating?) do
    if Regex.match?(@id, id),
      do: :ok,
      else: {:error, "Account id must start with a letter and use only letters, digits, _ or -"}
  end

  defp validate_endpoint(endpoint) do
    trimmed = String.trim(endpoint || "") |> String.trim_trailing("/")

    case URI.parse(trimmed) do
      %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil} = uri
      when is_binary(host) and host != "" and uri.path in [nil, "", "/"] ->
        {:ok, "https://" <> host_with_port(uri)}

      _ ->
        {:error, "Endpoint must be HTTPS with a host and no path, for example https://github.com"}
    end
  end

  defp host_with_port(%URI{host: host, port: port}) when port in [nil, 443], do: host
  defp host_with_port(%URI{host: host, port: port}), do: "#{host}:#{port}"

  defp account_password(form, old, endpoint) do
    password = form["password"] || ""

    cond do
      String.trim(password) != "" and not String.contains?(password, ["\r", "\n"]) ->
        {:ok, String.trim(password)}

      password == "" and is_binary(old["password"]) and old["password"] != "" and
          old["endpoint"] == endpoint ->
        {:ok, old["password"]}

      password == "" and is_binary(old["password"]) and old["password"] != "" ->
        {:error, "Endpoint changed. Re-enter the password or token."}

      true ->
        {:error, "Password or token is required"}
    end
  end

  defp blank_to_id("", id), do: id
  defp blank_to_id(name, _id), do: name

  defp update(opts, fun) do
    file = path(opts)

    :global.trans({{__MODULE__, file}, self()}, fn ->
      with {:ok, data} <- read(opts),
           {:ok, updated, result} <- fun.(data),
           :ok <- write(file, updated) do
        result
      end
    end)
  end

  defp write(file, data) do
    temporary = file <> "." <> Ecto.UUID.generate() <> ".tmp"

    try do
      with :ok <- File.mkdir_p(Path.dirname(file)),
           {:ok, io} <- File.open(temporary, [:write, :exclusive, :binary]) do
        result =
          with :ok <- File.chmod(temporary, 0o600),
               :ok <- IO.binwrite(io, Handbean.JSON.encode!(data)),
               :ok <- :file.sync(io),
               do: :ok

        File.close(io)
        with :ok <- result, do: File.rename(temporary, file)
      end
      |> case do
        :ok -> :ok
        {:error, _} -> {:error, "Cannot save Git configuration"}
      end
    after
      File.rm(temporary)
    end
  end
end
