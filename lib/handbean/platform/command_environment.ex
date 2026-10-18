defmodule Handbean.Platform.CommandEnvironment do
  @moduledoc false

  @release_env ~w(
    BINDIR EMU PROGNAME RELEASE_NAME RELEASE_ROOT RELEASE_VSN ROOTDIR
    RELEASE_TMP RELEASE_DISTRIBUTION RELEASE_NODE RELEASE_COOKIE
    RELEASE_SYS_CONFIG RELEASE_BOOT_SCRIPT RELEASE_BOOT_SCRIPT_CLEAN
  )

  @desktop_internal_env ~w(
    HANDBEAN_RUNTIME_DIR HANDBEAN_DESKTOP_ENV_HELPER
    HANDBEAN_COMPUTER_PORT HANDBEAN_COMPUTER_TOKEN
    HANDBEAN_NOTIFY_PORT HANDBEAN_NOTIFY_TOKEN
  )

  # The desktop host injects these generic names for its Phoenix backend. They
  # must not become project settings merely because a command was launched by
  # that backend. A captured login shell or an explicit command environment can
  # still set its own values for these names.
  @backend_env ~w(PHX_SERVER PORT PHX_HOST DATABASE_PATH SECRET_KEY_BASE)
  @internal_env @release_env ++ @desktop_internal_env
  @inherited_backend_env @internal_env ++ @backend_env

  @spec sanitize(map()) :: map()
  def sanitize(environment) when is_map(environment) do
    environment
    |> Map.drop(@internal_env)
    |> Map.update("PATH", nil, &strip_release_erts/1)
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  @spec port_env(map()) :: [{String.t(), String.t() | false}]
  def port_env(environment) when environment == %{}, do: port_unsets()

  def port_env(environment) when is_map(environment) do
    environment = sanitize(environment)

    removed =
      (Map.keys(System.get_env()) -- Map.keys(environment)) ++
        (@inherited_backend_env -- Map.keys(environment))

    removed = Enum.uniq(removed)
    Enum.map(removed, &{&1, false}) ++ Map.to_list(environment)
  end

  @doc false
  @spec child_port_env(map() | [{String.t(), String.t() | false}]) ::
          [{String.t(), String.t() | false}]
  def child_port_env(environment) do
    environment = environment |> Map.new() |> sanitize()
    removed = @inherited_backend_env -- Map.keys(environment)
    Enum.map(removed, &{&1, false}) ++ Map.to_list(environment)
  end

  @doc false
  @spec system_cmd_unsets() :: [{String.t(), nil}]
  def system_cmd_unsets, do: Enum.map(@inherited_backend_env, &{&1, nil})

  @doc false
  @spec shell_unset_names() :: [String.t()]
  def shell_unset_names, do: @inherited_backend_env

  defp port_unsets, do: Enum.map(@inherited_backend_env, &{&1, false})

  @spec encode_port_env([{String.t(), String.t() | false}]) ::
          [{charlist(), charlist() | false}]
  def encode_port_env(environment) when is_list(environment) do
    Enum.map(environment, fn
      {key, false} -> {String.to_charlist(key), false}
      {key, value} -> {String.to_charlist(key), String.to_charlist(value)}
    end)
  end

  @spec find_executable(String.t(), map()) :: String.t() | nil
  def find_executable(name, environment) when is_binary(name) and is_map(environment) do
    environment
    |> Map.get("PATH", "")
    |> String.split(":", trim: true)
    |> Enum.find_value(fn dir ->
      path = Path.join(dir, name)

      case File.stat(path) do
        {:ok, %File.Stat{type: :regular, mode: mode}} when Bitwise.band(mode, 0o111) != 0 -> path
        _ -> nil
      end
    end)
  end

  @spec strip_release_erts(String.t()) :: String.t()
  def strip_release_erts(path) when is_binary(path) do
    path
    |> String.split(":", trim: true)
    |> Enum.reject(&release_erts_dir?/1)
    |> Enum.join(":")
  end

  defp release_erts_dir?(dir) do
    expanded = Path.expand(dir)
    erts = Path.dirname(expanded)
    release = Path.dirname(erts)

    not Handbean.Host.packaged_mix_toolchain?() and
      Path.basename(expanded) == "bin" and
      String.starts_with?(Path.basename(erts), "erts-") and
      File.regular?(Path.join(release, "releases/start_erl.data"))
  end
end
