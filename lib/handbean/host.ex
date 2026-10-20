defmodule Handbean.Host do
  @moduledoc """
  Values the host writes once, before Handbean and the tool registry start.

  Desktop Mix sets `:host` only for the dev data root. Capability readers
  still fall back to the desktop defaults.
  The host stores declarations. It does not authorize a run, and it does not
  infer one capability from another.

  Boolean capabilities (`shell`, `shell_jobs`, `terminal`, `beam_eval`, `mcp`, `dist`,
  `packaged_mix_toolchain`, `host_script`) are present only when explicitly
  true. A missing key is the desktop default, not a guess from the OS, UI, or
  another capability.

  A backend is present only when the host injects a module or callback:

  * `browser_backend` — `:cli` or `:webview`. Selects the public `browser` tool
    and, for `:webview`, the in-app preview tool. Not the system browser.
  * `git_backend` — module used by the builtin Git tool. Phone hosts set
    `Handbean.Git.ExGit`. Desktop leaves it unset; agents use the repository
    command-line workflow through `bash`.
  * `artifact_delivery_backend` — module or `fun/2` that presents system UI for
    `open_url`, `open_file`, and `share_file`, and runs `device_calendar` /
    `device_alarm`.
  * `file_manager_backend` — module or `fun/1` that reveals a validated workspace
    entry in the desktop file manager. Hosts must declare it explicitly.
  * `directory_picker` — `fun/1` or a module exporting
    `request_directory_picker/1`. Desktop never sets it.
  * `speech_backend` — module implementing local speech-to-text inference. Desktop
    defaults to `Handbean.Speech.WhisperCpp`; other hosts must override it explicitly.
  * `shell_isolation` — `:platform_required` or `:none`. The former fails closed
    unless the platform sandbox can wrap a workspace command. `:none` is an explicit
    high-privilege host declaration and routes every Bash call through approval.
  * `shell_environment` — fixed string environment entries required by an injected
    shell runtime. Call-specific and workspace environments still override them.

  `script_http: :platform_dns_ca` declares that the host configured Req's
  platform DNS and CA certificates before tool registration. It is guidance,
  not a network permission.

  `dns_resolver` optionally supplies a native `fun/1` returning `{:ok, [ip]}`
  or `{:error, reason}`. Consumers still validate and pin the returned
  addresses; the callback does not grant network access. When it is set,
  `web_fetch` keeps that pinned public-address path and does not apply the
  desktop Fake-IP policy.

  `packaged_mix_toolchain` enables `mix_project` backed by `priv/mix_toolchain`.
  Phone hosts set it. Desktop does not register a dedicated Mix tool.

  `host_script` enables `run_elixir_script`. The builtin tool evaluates the
  workspace `.exs` itself; the flag is not a callback and does not follow from
  the browser or artifact delivery.
  """

  @keys [
    :data_dir,
    :priv_dir,
    :shell,
    :shell_jobs,
    :shell_isolation,
    :shell_environment,
    :terminal,
    :browser_backend,
    :computer_use_backend,
    :artifact_delivery_backend,
    :file_manager_backend,
    :host_script,
    :directory_picker,
    :script_http,
    :dns_resolver,
    :beam_eval,
    :mcp,
    :dist,
    :git_backend,
    :speech_backend,
    :packaged_mix_toolchain
  ]

  @boolean_keys [
    :shell,
    :shell_jobs,
    :terminal,
    :beam_eval,
    :mcp,
    :dist,
    :packaged_mix_toolchain,
    :host_script
  ]

  @spec get(atom(), term()) :: term()
  def get(key, default \\ nil) when key in @keys do
    :handbean
    |> Application.get_env(:host, %{})
    |> Map.get(key, default)
  end

  @spec put!(map()) :: :ok
  def put!(attrs) when is_map(attrs) do
    Application.put_env(:handbean, :host, Map.take(Map.new(attrs), @keys))
  end

  @spec configured?() :: boolean()
  def configured?, do: Application.get_env(:handbean, :host) != nil

  @spec data_dir() :: String.t()
  def data_dir do
    get(:data_dir) || System.get_env("HOME") || File.cwd!()
  end

  @spec priv_dir() :: String.t()
  def priv_dir do
    get(:priv_dir) || Application.app_dir(:handbean, "priv")
  end

  @spec shell?() :: boolean()
  def shell?, do: capability?(:shell, true)

  @spec shell_jobs?() :: boolean()
  def shell_jobs?, do: capability?(:shell_jobs, true)

  @spec shell_isolation() :: :platform_required | :none | :invalid
  def shell_isolation do
    case declared(:shell_isolation, :platform_required) do
      isolation when isolation in [:platform_required, :none] -> isolation
      _ -> :invalid
    end
  end

  @spec shell_environment() :: %{optional(String.t()) => String.t()}
  def shell_environment do
    case declared(:shell_environment, %{}) do
      environment when is_map(environment) ->
        Map.filter(environment, fn {key, value} -> is_binary(key) and is_binary(value) end)

      _ ->
        %{}
    end
  end

  @spec terminal?() :: boolean()
  def terminal?, do: capability?(:terminal, true)

  @doc "Declared browser backend, or nil when the host did not inject one."
  @spec browser_backend() :: :cli | :webview | nil
  def browser_backend do
    case declared(:browser_backend, :cli) do
      :cli -> :cli
      :webview -> :webview
      _ -> nil
    end
  end

  @doc "Declared local speech-to-text backend, or the desktop default."
  @spec speech_backend() :: module() | nil
  def speech_backend do
    case declared(:speech_backend, Handbean.Speech.WhisperCpp) do
      backend when is_atom(backend) and not is_nil(backend) -> backend
      _ -> nil
    end
  end

  @spec artifact_delivery_backend() :: module() | (map(), map() -> term()) | nil
  def artifact_delivery_backend do
    case declared(:artifact_delivery_backend, nil) do
      backend when is_atom(backend) and not is_nil(backend) -> backend
      backend when is_function(backend, 2) -> backend
      _ -> nil
    end
  end

  @spec file_manager_backend() :: module() | (String.t() -> term()) | nil
  def file_manager_backend do
    case declared(:file_manager_backend, nil) do
      backend when is_atom(backend) and not is_nil(backend) -> backend
      backend when is_function(backend, 1) -> backend
      _ -> nil
    end
  end

  @doc "`run_elixir_script` is registered only when the host sets this. The tool evaluates the script; this flag does not."
  @spec host_script?() :: boolean()
  def host_script?, do: capability?(:host_script, false)

  @doc """
  Ask the host to open its native directory picker for a new workspace.

  Returns `{:error, :unavailable}` when no host installed a picker.
  """
  @spec request_directory_picker(map()) :: :ok | {:error, term()}
  def request_directory_picker(context \\ %{}) when is_map(context) do
    case declared(:directory_picker, nil) do
      fun when is_function(fun, 1) -> fun.(context)
      mod when is_atom(mod) and not is_nil(mod) -> mod.request_directory_picker(context)
      _ -> {:error, :unavailable}
    end
  end

  @spec beam_eval?() :: boolean()
  def beam_eval?, do: capability?(:beam_eval, false)

  @spec mcp?() :: boolean()
  def mcp?, do: capability?(:mcp, mix_env() != :test)

  @spec dist?() :: boolean()
  def dist?, do: capability?(:dist, mix_env() != :prod)

  @spec packaged_mix_toolchain?() :: boolean()
  def packaged_mix_toolchain?, do: capability?(:packaged_mix_toolchain, false)

  @doc "Where a declared value came from. Does not describe run authorization."
  @spec source(atom()) :: :application_host | :host_default | :host_build_environment_default
  def source(key) when key in @keys do
    raw = Application.get_env(:handbean, :host, %{})

    cond do
      Map.has_key?(raw, key) -> :application_host
      key in [:mcp, :dist] -> :host_build_environment_default
      true -> :host_default
    end
  end

  defp capability?(key, default) when key in @boolean_keys do
    declared(key, default) == true
  end

  defp declared(key, default) do
    case Application.get_env(:handbean, :host) do
      raw when is_map(raw) -> Map.get(raw, key, default)
      _ -> default
    end
  end

  defp mix_env do
    if function_exported?(Mix, :env, 0), do: Mix.env(), else: :prod
  end
end
