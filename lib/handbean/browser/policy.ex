defmodule Handbean.Browser.Policy do
  @moduledoc """
  Classifies `browser` argv before any subprocess is spawned.

  Safe page interaction can follow the workspace default mode. Sensitive
  families require approval. Local files, caller-owned sessions, and
  shell command syntax outside the eval script argument is denied. Eval source
  is passed as a single argv value, never through a shell.
  """

  alias Handbean.Agent.Tool.Helpers
  alias Handbean.Security.PathValidator

  @type capability ::
          :navigation
          | :inspect
          | :interact
          | :eval
          | :cookies
          | :storage
          | :auth
          | :upload
          | :download
          | :profile
          | :headed
          | :connect
          | :cdp
          | :unknown

  @type meta :: %{
          optional(:command) => String.t(),
          optional(:capability) => capability(),
          optional(:reason) => String.t(),
          optional(:failure_category) => String.t()
        }

  @type decision :: {:auto, meta()} | {:prompt, meta()} | {:deny, meta()}

  @auto_commands MapSet.new([
                   "open",
                   "goto",
                   "navigate",
                   "snapshot",
                   "click",
                   "dblclick",
                   "fill",
                   "type",
                   "press",
                   "hover",
                   "scroll",
                   "scrollintoview",
                   "get",
                   "is",
                   "find",
                   "select",
                   "check",
                   "uncheck",
                   "focus",
                   "tab",
                   "wait",
                   "screenshot",
                   "read",
                   "back",
                   "forward",
                   "reload"
                 ])

  @prompt_commands %{
    "eval" => :eval,
    "cookies" => :cookies,
    "storage" => :storage,
    "auth" => :auth,
    "upload" => :upload,
    "download" => :download,
    "connect" => :connect,
    "pdf" => :download,
    "keyboard" => :interact,
    "session" => :profile,
    "network" => :connect,
    "set" => :auth
  }

  @inspection_flags ["--help", "-h", "--version", "-V"]
  @leading_value_flags ["--profile", "--cdp"]
  @leading_switch_flags ["--headed"]
  @navigation_commands MapSet.new(["open", "goto", "navigate"])
  @native_actions MapSet.new(~w(open snapshot eval click fill back show hide close))

  @doc """
  Classify caller args into `:auto`, `:prompt`, or `:deny`.
  """
  @spec classify(term()) :: decision()
  def classify(args) when not is_list(args) do
    deny("args must be a list of strings")
  end

  def classify([]) do
    deny("args must be a non-empty list of strings")
  end

  def classify(args) do
    cond do
      not Enum.all?(args, &is_binary/1) ->
        deny("args must be a list of strings")

      forbidden_token = Enum.find(args, &forbidden_token?/1) ->
        deny("blocked token: #{forbidden_token}")

      Enum.any?(args, &String.contains?(&1, <<0>>)) ->
        deny("args must not contain NUL bytes")

      shell_arg = Enum.find(shell_checked_args(args), &shell_injection?/1) ->
        deny("shell metacharacters are not allowed: #{inspect(shell_arg)}")

      true ->
        classify_command(args)
    end
  end

  @doc "True when the call is a stateless inspection command."
  @spec inspection?([String.t()]) :: boolean()
  def inspection?(args) when is_list(args) do
    command(args) in @inspection_flags
  end

  def inspection?(_), do: false

  @doc "True when browser file input or output resolves to a credential path."
  @spec sensitive_local_path?(term(), String.t() | nil) :: boolean()
  def sensitive_local_path?(args, root) when is_list(args) do
    args
    |> local_paths()
    |> Enum.any?(&sensitive_path?(&1, root))
  end

  def sensitive_local_path?(_args, _root), do: false

  @doc """
  Classify native structured browser input (`action` / `url` / `js` / `ref`).

  Desktop CLI policy must keep using `classify/1` on `args`. This path is
  only for the WebView host schema.
  """
  @spec classify_native(term()) :: decision()
  def classify_native(input) when not is_map(input) do
    deny("native browser input must be a map")
  end

  def classify_native(input) do
    classify_native_action(input)
  end

  @doc """
  Command token used by workspace deny/allow globs.

  Desktop parses the command after leading global flags. WebView uses `action`
  and never falls back to injecting `action` into argv.
  """
  @spec command_token(map()) :: String.t()
  def command_token(input) when is_map(input) do
    args = Handbean.Utils.SafeMap.get_any(input, "args", :args)

    if Handbean.Tool.Builtin.Browser.backend() == :webview do
      case native_field(input, "action") do
        action when is_binary(action) -> action
        _ -> ""
      end
    else
      case command(args) do
        command when is_binary(command) -> command
        _ -> ""
      end
    end
  end

  def command_token(_), do: ""

  @doc "First command token after leading global flags, including an inspection flag."
  @spec command([String.t()]) :: String.t() | nil
  def command(args) when is_list(args) do
    case command_args(args) do
      [command | _] -> command
      [] -> nil
    end
  end

  def command(_), do: nil

  defp command_args([]), do: []

  defp command_args([flag]) when flag in @leading_value_flags, do: []

  defp command_args([flag, _value | rest]) when flag in @leading_value_flags,
    do: command_args(rest)

  defp command_args([arg | rest] = args) do
    cond do
      arg in @inspection_flags ->
        args

      arg in @leading_switch_flags or leading_inline_flag?(arg) ->
        command_args(rest)

      is_binary(arg) and String.starts_with?(arg, "-") ->
        command_args(rest)

      is_binary(arg) ->
        args

      true ->
        []
    end
  end

  # Only the inline eval source is JavaScript. Keep checking leading options,
  # their values, and trailing argv; forbidden flags are checked on all args.
  # JavaScript syntax and execution errors belong to the browser backend.
  defp shell_checked_args(args) do
    case command_args(args) do
      ["eval", script | rest] ->
        if String.starts_with?(script, "-") do
          args
        else
          Enum.take(args, length(args) - length(rest) - 1) ++ rest
        end

      _ ->
        args
    end
  end

  defp leading_inline_flag?(arg) when is_binary(arg) do
    Enum.any?(@leading_value_flags ++ @leading_switch_flags, fn flag ->
      String.starts_with?(arg, flag <> "=")
    end)
  end

  defp leading_inline_flag?(_), do: false

  defp classify_command(args) do
    cmd = command(args)

    cond do
      is_nil(cmd) ->
        deny("missing browser command")

      cmd in @inspection_flags ->
        {:auto, %{command: cmd, capability: :inspect}}

      cmd in @navigation_commands ->
        classify_navigation_with_flags(cmd, args)

      prompt_flag = prompt_flag_capability(args) ->
        {:prompt, %{command: cmd, capability: prompt_flag}}

      Map.has_key?(@prompt_commands, cmd) ->
        {:prompt, %{command: cmd, capability: Map.fetch!(@prompt_commands, cmd)}}

      cmd in ["close", "quit"] ->
        classify_close(cmd, args)

      cmd in @auto_commands ->
        {:auto, %{command: cmd, capability: :interact}}

      true ->
        {:prompt, %{command: cmd, capability: :unknown}}
    end
  end

  defp classify_navigation_with_flags(cmd, args) do
    case classify_navigation(cmd, args) do
      {:deny, _meta} = denied ->
        denied

      decision ->
        case prompt_flag_capability(args) do
          nil -> decision
          capability -> {:prompt, %{command: cmd, capability: capability}}
        end
    end
  end

  defp classify_navigation(cmd, args) do
    case navigation_url(args) do
      {:ok, url} ->
        if private_or_local_url?(url) do
          {:prompt, %{command: cmd, capability: :navigation, reason: "local or private URL"}}
        else
          {:auto, %{command: cmd, capability: :navigation}}
        end

      {:error, reason} ->
        deny(reason)
    end
  end

  defp classify_close(cmd, args) do
    if has_flag?(args, "--all") do
      {:prompt,
       %{command: cmd, capability: :profile, reason: "close --all affects every session"}}
    else
      {:auto, %{command: cmd, capability: :interact}}
    end
  end

  defp navigation_url(args) do
    case Enum.find(args, &http_or_other_url?/1) do
      nil ->
        {:error, "navigation requires an http(s) URL"}

      url ->
        if http_url?(url) do
          {:ok, url}
        else
          {:error, "only http(s) URLs are allowed: #{url}"}
        end
    end
  end

  defp http_or_other_url?(value) when is_binary(value) do
    String.contains?(value, "://") or String.starts_with?(value, "about:")
  end

  defp http_or_other_url?(_), do: false

  defp classify_native_action(input) do
    action = native_field(input, "action")

    cond do
      not is_binary(action) or action == "" ->
        deny("action is required")

      action not in @native_actions ->
        deny("unsupported browser action: #{action}")

      action == "open" ->
        classify_native_open(input)

      action == "eval" ->
        {:prompt, %{command: "eval", capability: :eval}}

      takeover?(input) ->
        {:prompt, %{command: action, capability: :profile, reason: "user takeover"}}

      true ->
        {:auto, %{command: action, capability: :interact}}
    end
  end

  defp classify_native_open(input) do
    case native_field(input, "url") do
      url when is_binary(url) and url != "" ->
        if http_url?(url) do
          if private_or_local_url?(url) do
            {:prompt, %{command: "open", capability: :navigation, reason: "local or private URL"}}
          else
            {:auto, %{command: "open", capability: :navigation}}
          end
        else
          deny("only http(s) URLs are allowed: #{url}")
        end

      _ ->
        deny("navigation requires an http(s) URL")
    end
  end

  defp takeover?(input) do
    native_field(input, "takeover") in [true, "true"]
  end

  defp native_field(input, key) when is_map(input) and is_binary(key) do
    Map.get(input, key) || Map.get(input, native_atom(key))
  end

  defp native_atom("action"), do: :action
  defp native_atom("url"), do: :url
  defp native_atom("js"), do: :js
  defp native_atom("ref"), do: :ref
  defp native_atom("value"), do: :value
  defp native_atom("text"), do: :text
  defp native_atom("reason"), do: :reason
  defp native_atom("takeover"), do: :takeover
  defp native_atom(_), do: nil

  @doc """
  True when `url` is an http(s) URL the user browser may load.

  Rejects missing hosts, whitespace, and non-http schemes such as `file:`
  and `javascript:`. Local and private hosts are allowed: this is the user's
  address bar, not the agent tool's auto-navigation policy.
  """
  @spec allowed_navigation_url?(term()) :: boolean()
  def allowed_navigation_url?(url) when is_binary(url) do
    String.length(url) <= 2_000 and String.trim(url) == url and url != "" and
      not String.contains?(url, ["\n", "\r", " ", "\t"]) and http_url?(url)
  end

  def allowed_navigation_url?(_), do: false

  defp http_url?(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] ->
        is_binary(host) and host != ""

      _ ->
        false
    end
  end

  defp private_or_local_url?(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) ->
        host = String.downcase(host)

        host in ["localhost", "127.0.0.1", "0.0.0.0", "::1", "[::1]"] or
          String.starts_with?(host, "169.254.") or
          String.starts_with?(host, "10.") or
          String.match?(host, ~r/^192\.168\./) or
          String.match?(host, ~r/^172\.(1[6-9]|2\d|3[0-1])\./)

      _ ->
        false
    end
  end

  defp local_paths(args) do
    args
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {"upload", index} -> path_candidates_after(args, index)
      {"screenshot", index} -> path_candidates_after(args, index)
      {"pdf", index} -> path_candidates_after(args, index)
      {"download", index} -> path_candidates_after(args, index)
      {"wait", _index} -> option_values(args, "--download")
      _ -> []
    end)
    |> Kernel.++(option_values(args, "--screenshot-dir"))
    |> Enum.uniq()
  end

  defp path_candidates_after(args, command_index) do
    args
    |> Enum.drop(command_index + 1)
    |> positional_args()
  end

  defp positional_args(args) do
    Enum.filter(args, &(is_binary(&1) and not String.starts_with?(&1, "-")))
  end

  defp option_values(args, option) do
    prefix = option <> "="

    args
    |> Enum.with_index()
    |> Enum.flat_map(fn {arg, index} ->
      cond do
        arg == option ->
          case Enum.at(args, index + 1) do
            value when is_binary(value) ->
              if(String.starts_with?(value, "-"), do: [], else: [value])

            _ ->
              []
          end

        is_binary(arg) and String.starts_with?(arg, prefix) ->
          case String.replace_prefix(arg, prefix, "") do
            "" -> []
            value -> [value]
          end

        true ->
          []
      end
    end)
  end

  defp sensitive_path?(path, root) do
    expanded = Helpers.expand_tilde(path)

    lexical =
      if Path.type(expanded) == :absolute do
        expanded
      else
        path
      end

    base = if is_binary(root) and root != "", do: root, else: File.cwd!()

    resolved =
      if Path.type(expanded) == :absolute,
        do: Path.expand(expanded),
        else: Path.expand(expanded, base)

    PathValidator.reject_sensitive(lexical) != :ok or
      PathValidator.reject_resolved(resolved) != :ok
  end

  defp forbidden_token?("--json"), do: true
  defp forbidden_token?("--session"), do: true
  defp forbidden_token?("--namespace"), do: true
  defp forbidden_token?("--allow-file-access"), do: true
  defp forbidden_token?("--session=" <> _), do: true
  defp forbidden_token?("--namespace=" <> _), do: true
  defp forbidden_token?("--allow-file-access=" <> _), do: true
  defp forbidden_token?(_), do: false

  defp prompt_flag_capability(args) do
    cond do
      has_flag?(args, "--profile") -> :profile
      has_flag?(args, "--headed") -> :headed
      has_flag?(args, "--cdp") -> :cdp
      true -> nil
    end
  end

  defp has_flag?(args, flag) do
    prefix = flag <> "="
    Enum.any?(args, fn arg -> arg == flag or String.starts_with?(arg, prefix) end)
  end

  defp shell_injection?(arg) when is_binary(arg) do
    String.contains?(arg, ["&&", "||", "$(", "`", "\n"]) or
      (String.contains?(arg, [";", "|", ">", "<"]) and looks_like_shell_pipeline?(arg))
  end

  defp shell_injection?(_), do: false

  defp looks_like_shell_pipeline?(arg) do
    String.match?(arg, ~r/(?:^|[\s;|&])(?:rm|cat|curl|wget|bash|sh|zsh|python|perl|nc)\b/)
  end

  defp deny(reason) do
    {:deny, %{failure_category: "validation-error", reason: reason}}
  end
end
