defmodule Handbean.Browser.Policy do
  @moduledoc """
  Classifies `browser` argv before any subprocess is spawned.

  Safe page interaction can follow the workspace default mode. Sensitive
  families require approval. Local files, caller-owned sessions, and shell
  command syntax in control, reference, flag, and path arguments are denied.
  Eval source and verified text payloads are passed as single argv values,
  never through a shell.
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

  @type policy_rule ::
          :forbidden_flag
          | :invalid_arguments
          | :navigation_scheme
          | :nul
          | :shell_metacharacters
          | :unsupported_action

  @type argument_role ::
          :action
          | :argument
          | :args
          | :command
          | :flag
          | :flag_value
          | :path
          | :ref
          | :script
          | :subcommand
          | :text
          | :trailing_arg
          | :url
          | :unknown

  @type meta :: %{
          optional(:command) => String.t(),
          optional(:capability) => capability(),
          optional(:reason) => String.t(),
          optional(:failure_category) => String.t(),
          optional(:policy_rule) => policy_rule(),
          optional(:argument_role) => argument_role()
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
  # agent-browser 0.39.1 flags.rs `clean_args/1` removes these exact global
  # options before command parsing. Inline spellings remain positional except
  # for the backend's special --restore= form.
  @global_value_flags ~w(
    --session --restore-save --restore-check-url --restore-check-text
    --restore-check-fn --namespace --headers --executable-path --cdp
    --extension --init-script --enable --profile --state --proxy
    --proxy-bypass --args --user-agent -p --provider --device
    --session-name --color-scheme --download-path --max-output
    --allowed-domains --action-policy --confirm-actions --config --engine
    --input-mode --screenshot-dir --screenshot-quality --screenshot-format
    --idle-timeout --ca-cert --model
  )
  @global_switch_flags ~w(
    --json --headed --webgpu --no-webmcp --debug --ignore-https-errors
    --allow-file-access --hide-scrollbars --auto-connect --pin-tab
    --no-pin-tab --no-ca-cert --use-system-ca --annotate
    --content-boundaries --confirm-interactive --no-auto-dialog
    -v --verbose -q --quiet --offline --quick --fix
  )
  @navigation_commands MapSet.new(["open", "goto", "navigate"])
  @native_actions MapSet.new(~w(open snapshot eval click fill back show hide close))
  @known_commands MapSet.new(
                    MapSet.to_list(@auto_commands) ++
                      Map.keys(@prompt_commands) ++
                      MapSet.to_list(@native_actions) ++
                      ["close", "quit", "unknown"] ++
                      @inspection_flags
                  )
  @backend_commands MapSet.new(~w(
                      open goto navigate back forward reload read click dblclick fill type hover
                      focus check uncheck select drag upload download press key keydown keyup keyboard
                      scroll scrollintoview scrollinto wait screenshot pdf snapshot eval close quit exit
                      inspect auth confirm deny connect stream get is find mouse set network storage cookies
                      tab window frame dialog trace profiler record console errors highlight clipboard state
                      tap swipe device diff batch react vitals web-vitals a11y pushstate removeinitscript
                      session mcp doctor install upgrade profiles skills dashboard plugin plugins chat webmcp
                    ))
  @policy_rules MapSet.new(
                  ~w(forbidden_flag invalid_arguments navigation_scheme nul shell_metacharacters unsupported_action)
                )
  @argument_roles MapSet.new(
                    ~w(action argument args command flag flag_value path ref script subcommand text trailing_arg url unknown)
                  )

  @doc """
  Classify caller args into `:auto`, `:prompt`, or `:deny`.
  """
  @spec classify(term()) :: decision()
  def classify(args) when not is_list(args) do
    deny("Browser command denied: args must be a list of strings.",
      command: "unknown",
      policy_rule: :invalid_arguments,
      argument_role: :args
    )
  end

  def classify([]) do
    deny("Browser command denied: args must be a non-empty list of strings.",
      command: "unknown",
      policy_rule: :invalid_arguments,
      argument_role: :args
    )
  end

  def classify(args) do
    if Enum.all?(args, &is_binary/1) do
      classify_string_args(args)
    else
      deny("Browser command denied: args must be a list of strings.",
        command: "unknown",
        policy_rule: :invalid_arguments,
        argument_role: :args
      )
    end
  end

  defp classify_string_args(args) do
    annotated = annotate_args(args)

    nul_arg =
      Enum.find(annotated, fn {arg, _role, _shell_checked?} ->
        String.contains?(arg, <<0>>)
      end)

    shell_arg =
      Enum.find(annotated, fn {arg, _role, shell_checked?} ->
        shell_checked? and shell_injection?(arg)
      end)

    cond do
      Enum.any?(args, &forbidden_token?/1) ->
        policy_deny(
          args,
          "Browser command denied: caller-provided --json, --session, --namespace, and --allow-file-access flags are not allowed.",
          :forbidden_flag,
          :flag
        )

      not is_nil(nul_arg) ->
        role = annotation_role(nul_arg)

        policy_deny(
          args,
          "Browser command denied: NUL bytes are not allowed in #{role_label(role)} arguments.",
          :nul,
          role
        )

      not is_nil(shell_arg) ->
        role = annotation_role(shell_arg)

        policy_deny(
          args,
          "Browser command denied: shell metacharacters are not allowed in #{role_label(role)} arguments.",
          :shell_metacharacters,
          role
        )

      true ->
        classify_command(args)
    end
  end

  @doc false
  @spec denial_details(meta()) :: map()
  def denial_details(meta) when is_map(meta) do
    %{
      code: :browser_policy_denied,
      side_effect: :not_started,
      error_owner: :browser_policy,
      error_command: fixed_value(meta[:command], @known_commands, "unknown"),
      error_rule: fixed_value(meta[:policy_rule], @policy_rules, "invalid_arguments"),
      error_argument_role: fixed_value(meta[:argument_role], @argument_roles, "unknown")
    }
  end

  @doc false
  @spec error_category(term()) :: {:ok, String.t()} | :error
  def error_category(metadata) when is_map(metadata) do
    with owner when owner in [:browser_policy, "browser_policy"] <-
           metadata_field(metadata, :error_owner),
         {:ok, command} <- fixed_metadata_value(metadata, :error_command, @known_commands),
         {:ok, rule} <- fixed_metadata_value(metadata, :error_rule, @policy_rules),
         {:ok, role} <- fixed_metadata_value(metadata, :error_argument_role, @argument_roles) do
      {:ok, Enum.join(["browser_policy", command, rule, role], "_")}
    else
      _ -> :error
    end
  end

  def error_category(_metadata), do: :error

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
    deny("Browser command denied: native browser input must be a map.",
      command: "unknown",
      policy_rule: :invalid_arguments,
      argument_role: :args
    )
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
    {positional_args, _global_args} = extract_global_args(args)

    case command_args(positional_args) do
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

  # agent-browser 0.39.1 removes recognized global flags before parsing command
  # positionals. Mirror that ordering so a flag or its value can never shift
  # into a text exemption. Only verified text positions (and eval source) skip
  # shell heuristics; every original argv still gets a role and the global NUL
  # and forbidden-flag checks above.
  defp annotate_args(args) do
    {positional_args, global_args} = extract_global_args(args)
    command_args = command_args(positional_args)
    command_index = length(positional_args) - length(command_args)
    {leading, command_args} = Enum.split(positional_args, command_index)

    annotated = annotate_options(leading, :argument)

    command_args =
      case command_args do
        [command | rest] ->
          [{command, :command, true} | command_arg_roles(command, rest)]

        [] ->
          []
      end

    global_args ++ annotated ++ command_args
  end

  defp extract_global_args(args), do: extract_global_args(args, [], [], false)

  defp extract_global_args([], positional, annotated, _seen_command?) do
    {Enum.reverse(positional), Enum.reverse(annotated)}
  end

  defp extract_global_args([flag, value | rest], positional, annotated, seen_command?)
       when flag in @global_value_flags do
    extract_global_args(
      rest,
      positional,
      [{value, :flag_value, true}, {flag, :flag, true} | annotated],
      seen_command?
    )
  end

  defp extract_global_args([flag], positional, annotated, _seen_command?)
       when flag in @global_value_flags do
    {Enum.reverse(positional), Enum.reverse([{flag, :flag, true} | annotated])}
  end

  defp extract_global_args([flag, value | rest], positional, annotated, seen_command?)
       when flag in @global_switch_flags and value in ["true", "false"] do
    extract_global_args(
      rest,
      positional,
      [{value, :flag_value, true}, {flag, :flag, true} | annotated],
      seen_command?
    )
  end

  defp extract_global_args([flag | rest], positional, annotated, seen_command?)
       when flag in @global_switch_flags do
    extract_global_args(
      rest,
      positional,
      [{flag, :flag, true} | annotated],
      seen_command?
    )
  end

  defp extract_global_args(["--restore=" <> _ = flag | rest], positional, annotated, seen?) do
    extract_global_args(rest, positional, [{flag, :flag, true} | annotated], seen?)
  end

  defp extract_global_args(["--restore", value | rest], positional, annotated, false)
       when is_binary(value) do
    if value in @backend_commands or String.starts_with?(value, "-") do
      extract_global_args(
        [value | rest],
        positional,
        [{"--restore", :flag, true} | annotated],
        false
      )
    else
      extract_global_args(
        rest,
        positional,
        [{value, :flag_value, true}, {"--restore", :flag, true} | annotated],
        false
      )
    end
  end

  defp extract_global_args(["--restore" | rest], positional, annotated, seen?) do
    extract_global_args(rest, positional, [{"--restore", :flag, true} | annotated], seen?)
  end

  defp extract_global_args([arg | rest], positional, annotated, seen_command?) do
    annotated =
      if is_binary(arg) and leading_inline_flag?(arg) do
        [{arg, :flag, true} | annotated]
      else
        annotated
      end

    seen_command? = seen_command? or (is_binary(arg) and MapSet.member?(@backend_commands, arg))
    extract_global_args(rest, [arg | positional], annotated, seen_command?)
  end

  defp command_arg_roles("eval", [script | rest]) do
    script_checked? = String.starts_with?(script, "-")
    [{script, :script, script_checked?} | annotate_options(rest, :trailing_arg)]
  end

  defp command_arg_roles("fill", [ref, text | rest]) do
    [{ref, :ref, true}, {text, :text, false} | annotate_options(rest, :trailing_arg)]
  end

  defp command_arg_roles("fill", [ref]), do: [{ref, :ref, true}]

  defp command_arg_roles("type", [ref | rest]) do
    [{ref, :ref, true} | annotate_type_args(rest, false)]
  end

  defp command_arg_roles("keyboard", [subcommand, text | rest])
       when subcommand in ["type", "inserttext", "insertText"] do
    [
      {subcommand, :subcommand, true},
      {text, :text, false}
      | annotate_options(rest, :trailing_arg)
    ]
  end

  defp command_arg_roles("keyboard", args), do: annotate_options(args, :subcommand)

  defp command_arg_roles(command, [url | rest]) when command in ["open", "goto", "navigate"] do
    [{url, :url, true} | annotate_options(rest, :trailing_arg)]
  end

  defp command_arg_roles("upload", [ref | paths]) do
    [{ref, :ref, true} | annotate_options(paths, :path)]
  end

  defp command_arg_roles("download", [ref | paths]) do
    [{ref, :ref, true} | annotate_options(paths, :path)]
  end

  defp command_arg_roles(command, args) when command in ["screenshot", "pdf"] do
    annotate_options(args, :path)
  end

  defp command_arg_roles(_command, args), do: annotate_options(args, :argument)

  defp annotate_type_args([], _text_seen?), do: []

  defp annotate_type_args(["--clear" | rest], text_seen?) do
    [{"--clear", :flag, true} | annotate_type_args(rest, text_seen?)]
  end

  defp annotate_type_args(["--delay", value | rest], text_seen?) do
    [
      {"--delay", :flag, true},
      {value, :flag_value, true}
      | annotate_type_args(rest, text_seen?)
    ]
  end

  defp annotate_type_args(["--delay"], _text_seen?), do: [{"--delay", :flag, true}]

  defp annotate_type_args([text | rest], false) do
    [{text, :text, false} | annotate_type_args(rest, true)]
  end

  defp annotate_type_args([arg | rest], true) do
    role = if String.starts_with?(arg, "-"), do: :flag, else: :trailing_arg
    [{arg, role, true} | annotate_type_args(rest, true)]
  end

  defp annotate_options([], _default_role), do: []

  defp annotate_options([arg | rest], default_role) do
    role = if String.starts_with?(arg, "-"), do: :flag, else: default_role
    [{arg, role, true} | annotate_options(rest, default_role)]
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
        deny("Browser command denied: missing browser command.",
          command: "unknown",
          policy_rule: :invalid_arguments,
          argument_role: :command
        )

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

      {:error, :missing_url} ->
        deny("Browser command denied: navigation requires an http(s) URL.",
          command: cmd,
          policy_rule: :invalid_arguments,
          argument_role: :url
        )

      {:error, :navigation_scheme} ->
        deny("Browser command denied: only http(s) URLs are allowed.",
          command: cmd,
          policy_rule: :navigation_scheme,
          argument_role: :url
        )
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
        {:error, :missing_url}

      url ->
        if http_url?(url) do
          {:ok, url}
        else
          {:error, :navigation_scheme}
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
        deny("Browser command denied: action is required.",
          command: "unknown",
          policy_rule: :invalid_arguments,
          argument_role: :action
        )

      action not in @native_actions ->
        deny("Browser command denied: unsupported browser action.",
          command: "unknown",
          policy_rule: :unsupported_action,
          argument_role: :action
        )

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
          deny("Browser command denied: only http(s) URLs are allowed.",
            command: "open",
            policy_rule: :navigation_scheme,
            argument_role: :url
          )
        end

      _ ->
        deny("Browser command denied: navigation requires an http(s) URL.",
          command: "open",
          policy_rule: :invalid_arguments,
          argument_role: :url
        )
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
  defp forbidden_token?("--json=" <> _), do: true
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

  defp policy_deny(args, reason, rule, role) do
    deny(reason,
      command: safe_command(args),
      policy_rule: rule,
      argument_role: role
    )
  end

  defp safe_command(args) do
    args
    |> command()
    |> case do
      command when is_binary(command) ->
        if MapSet.member?(@known_commands, command), do: command, else: "unknown"

      _ ->
        "unknown"
    end
  end

  defp fixed_metadata_value(metadata, key, allowed) do
    value = fixed_value(metadata_field(metadata, key), allowed, nil)
    if is_binary(value), do: {:ok, value}, else: :error
  end

  defp fixed_value(value, allowed, fallback) do
    value = if is_atom(value), do: Atom.to_string(value), else: value
    if is_binary(value) and MapSet.member?(allowed, value), do: value, else: fallback
  end

  defp metadata_field(metadata, key) do
    Map.get(metadata, key, Map.get(metadata, Atom.to_string(key)))
  end

  defp annotation_role({_arg, role, _shell_checked?}), do: role

  defp role_label(role) when role in [:text, :script], do: "text payload"
  defp role_label(:ref), do: "element reference"
  defp role_label(:flag_value), do: "flag value"
  defp role_label(:trailing_arg), do: "trailing"
  defp role_label(:subcommand), do: "subcommand"
  defp role_label(:url), do: "URL"
  defp role_label(:path), do: "file path"
  defp role_label(role) when role in [:command, :flag, :argument, :args], do: Atom.to_string(role)
  defp role_label(_role), do: "unknown"

  defp deny(reason, metadata) do
    meta =
      metadata
      |> Map.new()
      |> Map.merge(%{failure_category: "validation-error", reason: reason})

    {:deny, meta}
  end
end
