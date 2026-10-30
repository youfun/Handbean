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

  alias Handbean.Platform

  @default_windows_pathext ".COM;.EXE;.BAT;.CMD"

  @spec sanitize(map()) :: map()
  def sanitize(environment) when is_map(environment) do
    path_key = Platform.path_env_key(environment)

    environment
    |> Map.drop(@internal_env)
    |> Map.update(path_key, nil, &strip_release_erts/1)
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
    candidates = executable_candidates(name, environment)

    environment
    |> Platform.path_env()
    |> String.split(path_separator(), trim: true)
    |> Enum.find_value(fn dir ->
      Enum.find_value(candidates, fn candidate ->
        path = Path.join(dir, candidate)

        case File.stat(path) do
          {:ok, stat} -> if executable_stat?(stat), do: path
          _ -> nil
        end
      end)
    end)
  end

  defp executable_candidates(name, environment) do
    if Platform.windows?() do
      exts = windows_pathext(environment)
      ext_candidates = Enum.map(exts, &(name <> &1))

      if Path.extname(name) == "" do
        ext_candidates ++ [name]
      else
        [name | ext_candidates]
      end
    else
      [name]
    end
  end

  defp windows_pathext(environment) do
    raw =
      non_empty_string(Map.get(environment, "PATHEXT")) ||
        non_empty_string(Map.get(environment, "Pathext")) ||
        non_empty_string(Map.get(environment, "pathext")) ||
        non_empty_string(System.get_env("PATHEXT")) ||
        @default_windows_pathext

    raw
    |> String.split(";", trim: true)
    |> Enum.map(fn ext ->
      ext = ext |> String.trim() |> String.downcase()
      if String.starts_with?(ext, "."), do: ext, else: "." <> ext
    end)
    |> Enum.reject(&(&1 == "."))
    |> Enum.uniq()
  end

  defp non_empty_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp non_empty_string(_), do: nil

  defp executable_stat?(%File.Stat{type: :regular, mode: mode}) do
    if Platform.windows?() do
      true
    else
      Bitwise.band(mode, 0o111) != 0
    end
  end

  defp executable_stat?(_stat), do: false

  @spec strip_release_erts(String.t()) :: String.t()
  def strip_release_erts(path) when is_binary(path) do
    separator = path_separator()

    path
    |> String.split(separator, trim: true)
    |> Enum.reject(&release_erts_dir?/1)
    |> Enum.join(separator)
  end

  defp path_separator do
    if Platform.windows?(), do: ";", else: ":"
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
