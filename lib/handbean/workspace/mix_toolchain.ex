defmodule Handbean.Workspace.MixToolchain do
  @moduledoc """
  Discovers and loads a Mix/Hex/ExUnit toolchain that matches this VM.

  Desktop Mix already has Mix and ExUnit on the code path. Mobile hosts
  load version-pinned beams from `priv/mix_toolchain` that pack/deploy
  copy into the app. Packaged Hex omits `Hex.HTTP.beam`; HTTP is the
  Req adapter in `Handbean.Workspace.HexHttp`.
  """

  @hex_version "2.4.1"
  @http_beam "Elixir.Hex.HTTP.beam"

  @type info :: %{
          mix?: boolean(),
          hex?: boolean(),
          ex_unit?: boolean(),
          source: :host | :packaged | :unavailable,
          elixir: String.t(),
          otp: String.t(),
          hex_version: String.t() | nil,
          root: String.t() | nil
        }

  @spec hex_version() :: String.t()
  def hex_version, do: @hex_version

  @spec available?() :: boolean()
  def available? do
    match?({:ok, %{mix?: true}}, info())
  end

  @spec info() :: {:ok, info()} | {:error, String.t()}
  def info do
    elixir = System.version()
    otp = otp_release()

    cond do
      host_mix_loaded?() ->
        {:ok,
         %{
           mix?: true,
           hex?: hex_loaded?(),
           ex_unit?: true,
           source: :host,
           elixir: elixir,
           otp: otp,
           hex_version: hex_app_version(),
           root: nil
         }}

      (root = packaged_root()) != nil ->
        case manifest(root) do
          {:ok, manifest} ->
            if manifest["elixir"] in [elixir, nil] and manifest["otp"] in [otp, nil] do
              {:ok,
               %{
                 mix?: File.dir?(ebin(root, "mix")),
                 hex?: File.dir?(ebin(root, "hex")),
                 ex_unit?: File.dir?(ebin(root, "ex_unit")),
                 source: :packaged,
                 elixir: elixir,
                 otp: otp,
                 hex_version: manifest["hex"] || @hex_version,
                 root: root
               }}
            else
              {:error,
               "packaged Mix toolchain is Elixir #{manifest["elixir"]}/OTP #{manifest["otp"]}, " <>
                 "this VM is Elixir #{elixir}/OTP #{otp}"}
            end

          {:error, reason} ->
            {:error, reason}
        end

      true ->
        {:error, "Mix/ExUnit/Hex are not packaged on this host and are not already loaded"}
    end
  end

  @spec ensure_loaded() :: {:ok, info()} | {:error, String.t()}
  def ensure_loaded do
    with {:ok, info} <- info(),
         :ok <- load_paths(info),
         :ok <- ensure_mix(),
         :ok <- ensure_ex_unit(info),
         :ok <- ensure_hex(info) do
      {:ok,
       %{
         info
         | mix?: Code.ensure_loaded?(Mix),
           hex?: hex_loaded?(),
           ex_unit?: Code.ensure_loaded?(ExUnit)
       }}
    end
  end

  @spec packaged_root() :: String.t() | nil
  def packaged_root do
    Enum.find_value(candidate_roots(), fn root ->
      if File.dir?(ebin(root, "mix")) and File.dir?(ebin(root, "ex_unit")), do: root
    end)
  end

  @spec candidate_roots() :: [String.t()]
  def candidate_roots do
    [
      Path.join(Handbean.Host.priv_dir(), "mix_toolchain"),
      case :code.priv_dir(:handbean) do
        {:error, _} -> nil
        path -> Path.join(to_string(path), "mix_toolchain")
      end
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @spec sync_to!(Path.t()) :: :ok
  def sync_to!(dest) when is_binary(dest) do
    mix = to_string(:code.lib_dir(:mix))
    ex_unit = to_string(:code.lib_dir(:ex_unit))
    hex = hex_archive_root!()

    File.mkdir_p!(dest)

    copy_ebin!(Path.join(mix, "ebin"), ebin(dest, "mix"))
    copy_ebin!(Path.join(ex_unit, "ebin"), ebin(dest, "ex_unit"))
    copy_ebin!(Path.join(hex, "ebin"), ebin(dest, "hex"), exclude: [@http_beam])
    embed_mix_shell!(ebin(dest, "mix"))

    manifest = %{
      "elixir" => System.version(),
      "otp" => otp_release(),
      "hex" => @hex_version,
      "hex_http" => "Handbean.Workspace.HexHttp"
    }

    File.write!(
      Path.join(dest, "manifest.json"),
      Handbean.JSON.encode!(manifest, pretty: true) <> "\n"
    )

    :ok
  end

  defp host_mix_loaded? do
    Code.ensure_loaded?(Mix) and Code.ensure_loaded?(ExUnit) and not mix_from_packaged?()
  end

  defp mix_from_packaged? do
    case :code.which(Mix) do
      path when is_list(path) ->
        String.contains?(List.to_string(path), "/mix_toolchain/")

      _ ->
        false
    end
  end

  defp load_paths(%{source: :host}), do: :ok

  defp load_paths(%{source: :packaged, root: root}) do
    Enum.each(["mix", "ex_unit", "hex"], fn name ->
      path = ebin(root, name)
      if File.dir?(path), do: Code.prepend_path(path)
    end)

    embed_runtime_mix_shell(ebin(root, "mix"))
    :ok
  end

  defp embed_runtime_mix_shell(mix_ebin) do
    dest = Path.join(mix_ebin, "Elixir.Handbean.Workspace.MixShell.beam")
    beam = :code.which(Handbean.Workspace.MixShell)

    cond do
      File.regular?(dest) ->
        :ok

      is_list(beam) ->
        File.mkdir_p!(mix_ebin)
        File.cp!(List.to_string(beam), dest)

      true ->
        :ok
    end
  end

  defp ensure_mix do
    if Code.ensure_loaded?(Mix) do
      ensure_home()
      Mix.start()
      :ok
    else
      {:error, "failed to load Mix from the packaged toolchain"}
    end
  end

  defp ensure_home do
    home = System.get_env("HOME") || Handbean.Host.data_dir()

    if is_binary(home) and home != "" do
      System.put_env("HOME", home)
      mix_home = System.get_env("MIX_HOME") || Path.join(home, ".mix")
      hex_home = System.get_env("HEX_HOME") || Path.join(home, ".hex")
      File.mkdir_p!(mix_home)
      File.mkdir_p!(hex_home)
      System.put_env("MIX_HOME", mix_home)
      System.put_env("HEX_HOME", hex_home)
    end

    :ok
  end

  defp ensure_ex_unit(info) do
    if info.ex_unit? == false do
      {:error, "ExUnit is not packaged on this host"}
    else
      case Code.ensure_loaded(ExUnit) do
        {:module, ExUnit} -> :ok
        _ -> {:error, "failed to load ExUnit from the packaged toolchain"}
      end
    end
  end

  defp ensure_hex(%{source: :host}) do
    # Desktop Mix loads Hex from archives itself. Do not replace host Hex.HTTP.
    :ok
  end

  defp ensure_hex(info) do
    cond do
      hex_running?() ->
        :ok

      not hex_available?(info) ->
        {:error, "Hex #{@hex_version} is not packaged on this host"}

      true ->
        start_packaged_hex(info)
    end
  end

  defp hex_available?(%{hex?: true}), do: true
  defp hex_available?(_), do: false

  defp start_packaged_hex(%{source: :packaged, root: root}) do
    with :ok <- install_hex_http_adapter(),
         :ok <- load_hex_app(ebin(root, "hex")) do
      case Application.ensure_all_started(:hex) do
        {:ok, _} ->
          :ok

        {:error, {app, reason}} ->
          {:error, "failed to start Hex (#{inspect(app)}): #{inspect(reason)}"}
      end
    end
  end

  defp start_packaged_hex(_info) do
    if Code.ensure_loaded?(Hex) do
      case Application.ensure_all_started(:hex) do
        {:ok, _} ->
          :ok

        {:error, {app, reason}} ->
          {:error, "failed to start host Hex (#{inspect(app)}): #{inspect(reason)}"}
      end
    else
      {:error, "Hex #{@hex_version} is not loaded on this host"}
    end
  end

  defp load_hex_app(hex_ebin) do
    case Application.spec(:hex) do
      spec when is_list(spec) ->
        :ok

      _ ->
        app_file = Path.join(hex_ebin, "hex.app")

        case :file.consult(String.to_charlist(app_file)) do
          {:ok, [{:application, :hex, spec}]} ->
            spec =
              spec
              |> Keyword.update(:applications, [], &List.delete(&1, :inets))
              |> Keyword.put(:mod, {Handbean.Workspace.HexApp, []})

            case :application.load({:application, :hex, spec}) do
              :ok -> :ok
              {:error, {:already_loaded, :hex}} -> :ok
              {:error, reason} -> {:error, "cannot load packaged Hex app: #{inspect(reason)}"}
            end

          other ->
            {:error, "cannot read packaged hex.app: #{inspect(other)}"}
        end
    end
  end

  defp install_hex_http_adapter do
    cond do
      hex_http_loaded?() ->
        :ok

      true ->
        _ = Code.ensure_loaded?(:mix_hex_http)

        {:module, Hex.HTTP, _binary, _} =
          Module.create(
            Hex.HTTP,
            quote do
              @moduledoc false

              def config, do: Handbean.Workspace.HexHttp.config()

              def request(method, url, headers, body),
                do: request(method, url, headers, body, %{})

              def request(method, url, headers, body, config) do
                Handbean.Workspace.HexHttp.request(method, url, headers, body, config)
              end
            end,
            Macro.Env.location(__ENV__)
          )

        :ok
    end
  end

  defp manifest(root) do
    path = Path.join(root, "manifest.json")

    case File.read(path) do
      {:ok, bytes} ->
        case Handbean.JSON.decode(bytes) do
          {:ok, map} when is_map(map) -> {:ok, map}
          {:error, reason} -> {:error, "invalid Mix toolchain manifest: #{inspect(reason)}"}
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, "cannot read Mix toolchain manifest: #{inspect(reason)}"}
    end
  end

  # Mix.Project.in_project / Mix.Dep.in_dependency change the code path
  # to the dependency ebin. Keep MixShell next to Mix so Mix.shell() still
  # resolves after those path swaps.
  defp embed_mix_shell!(mix_ebin) do
    beam = :code.which(Handbean.Workspace.MixShell)

    cond do
      is_list(beam) ->
        File.cp!(
          List.to_string(beam),
          Path.join(mix_ebin, "Elixir.Handbean.Workspace.MixShell.beam")
        )

      true ->
        Mix.raise("Handbean.Workspace.MixShell is not loaded; cannot pack Mix toolchain")
    end
  end

  defp copy_ebin!(from, to, opts \\ []) do
    unless File.dir?(from), do: Mix.raise("toolchain ebin missing: #{from}")
    File.mkdir_p!(to)
    exclude = MapSet.new(Keyword.get(opts, :exclude, []))

    for name <- File.ls!(from), File.regular?(Path.join(from, name)), name not in exclude do
      File.cp!(Path.join(from, name), Path.join(to, name))
    end

    :ok
  end

  defp ebin(root, name), do: Path.join([root, name, "ebin"])

  defp hex_loaded?, do: Code.ensure_loaded?(Hex)
  defp hex_running?, do: running_app?(:hex)
  defp hex_http_loaded?, do: :code.which(Hex.HTTP) != :non_existing

  defp hex_app_version do
    case Application.spec(:hex, :vsn) do
      vsn when is_list(vsn) -> List.to_string(vsn)
      vsn when is_binary(vsn) -> vsn
      _ -> if hex_loaded?(), do: @hex_version
    end
  end

  defp running_app?(app) do
    Enum.any?(Application.started_applications(), fn {name, _, _} -> name == app end)
  end

  defp otp_release, do: to_string(:erlang.system_info(:otp_release))

  defp hex_archive_root! do
    case hex_archive_root() do
      nil ->
        Mix.raise(
          "Hex #{@hex_version} archive not found. Install it with mix local.hex #{@hex_version} --force " <>
            "and keep this exact version for mobile packaging."
        )

      path ->
        path
    end
  end

  defp hex_archive_in(home) do
    direct = Path.join(home, "ebin")

    nested =
      Enum.find_value(Path.wildcard(Path.join(home, "hex-#{@hex_version}*")), fn dir ->
        inner = Path.join(dir, Path.basename(dir))
        ebin = Path.join(inner, "ebin")
        if File.dir?(ebin), do: inner
      end)

    cond do
      is_binary(nested) -> nested
      File.dir?(direct) -> home
      true -> nil
    end
  end

  defp hex_archive_root do
    homes =
      [
        mix_archives_dir(),
        Path.expand("~/.mix/archives"),
        System.get_env("HANDBEAN_HEX_ARCHIVE")
      ]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()

    Enum.find_value(homes, &hex_archive_in/1)
  end

  defp mix_archives_dir do
    case System.get_env("MIX_HOME") do
      home when is_binary(home) and home != "" -> Path.join(home, "archives")
      _ -> nil
    end
  end
end
