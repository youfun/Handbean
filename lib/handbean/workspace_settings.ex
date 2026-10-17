defmodule Handbean.WorkspaceSettings do
  @moduledoc """
  Workspace-local settings stored as `.handbean/settings.jsonc`.

  The file is intentionally JSONC so users can keep inline notes next to
  workspace model restrictions and tool permissions.
  """

  @settings_relpath ".handbean/settings.jsonc"
  @lock_aborted_error "Failed to acquire workspace settings lock"

  @default_content """
  {
    // Workspace-local Handbean settings.
    // Path: .handbean/settings.jsonc
    //
    // Handbean's built-in memory is workspace-local. External MCP/extension
    // memory tools are unaffected when this is false.
    "memory": {
      "builtin_enabled": true
    },

    // `models` restricts which globally configured providers/models are available
    // in this workspace. An empty providers object means unrestricted.
    "models": {
      "allow": {
        "providers": {}
      }
    },

    // Ordinary tools run automatically; gated operations use AI review.
    // Use default_mode/per_tool/allow/deny to control execution per workspace.
    // Example: "per_tool": { "bash": "prompt", "edit": "prompt" }
    "tools": {
      "default_mode": "auto",
      // "user" asks a person. "auto_review" only re-reviews calls that would
      // already prompt. It does not widen sandbox, allow, or unsandboxed gates.
      "approvals_reviewer": "auto_review",
      "auto_review": {
        "model": null,
        "timeout_ms": 30000
      },
      "allow": [],
      "deny": [],
      "per_tool": {},

      // BEAM tools can inspect a running Elixir project.
      // docs/source/db_schema are read-only. Raw SQL is approval-gated because it
      // can mutate data or schemas. eval is disabled by default.
      "beam": {
        "auto": true,
        "eval": false
      },
      "explicit": []
    }
  }
  """

  @doc "Return the canonical workspace settings path."
  @spec path(Path.t()) :: Path.t()
  def path(path_or_checkout) do
    case resolve_path(path_or_checkout) do
      {:ok, settings_path} -> settings_path
      {:error, _reason} -> owner_path(path_or_checkout)
    end
  end

  @doc "Resolve a workspace or checkout path to the canonical settings owner."
  @spec resolve_path(Path.t()) :: {:ok, Path.t()} | {:error, String.t()}
  def resolve_path(path_or_checkout) when is_binary(path_or_checkout) do
    with {:ok, root} <- resolve_owner_root(path_or_checkout) do
      {:ok, owner_path(root)}
    else
      {:error, reason} ->
        {:error, "Failed to resolve workspace settings owner: #{inspect(reason)}"}
    end
  end

  def resolve_path(_path),
    do: {:error, "Failed to resolve workspace settings owner: :invalid_path"}

  @doc false
  def owner_path(canonical_root), do: Path.join(Path.expand(canonical_root), @settings_relpath)

  @doc false
  def ensure_owner_file(canonical_root) do
    settings_path = owner_path(canonical_root)
    with_settings_lock(settings_path, fn -> ensure_file_unlocked(settings_path) end)
  end

  @doc """
  Ensure `.handbean/settings.jsonc` exists without overwriting existing settings.
  """
  @spec ensure_file(Path.t()) :: :ok | {:error, String.t()}
  def ensure_file(path_or_checkout) do
    with {:ok, settings_path} <- resolve_path(path_or_checkout) do
      with_settings_lock(settings_path, fn -> ensure_file_unlocked(settings_path) end)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_owner_root(path) do
    case Handbean.WorkspaceStore.get_by_path(path) do
      {:ok, %{"path" => root}} -> {:ok, root}
      {:error, :not_found} -> resolve_unregistered_owner(path)
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_unregistered_owner(path) do
    case Handbean.RepoIdentity.resolve(path) do
      {:ok, identity} -> {:ok, identity.workspace_path}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def prepare_owner_change(old_root, new_root) do
    old_path = owner_path(old_root)
    new_path = owner_path(new_root)

    cond do
      old_path == new_path ->
        ensure_owner_file(new_root)

      not File.exists?(old_path) ->
        ensure_owner_file(new_root)

      not File.exists?(new_path) ->
        copy_owner_file(old_path, new_path)

      same_file_content?(old_path, new_path) ->
        :ok

      true ->
        {:error, :settings_policy_conflict}
    end
  end

  defp copy_owner_file(source, target) do
    with {:ok, content} <- File.read(source),
         {:ok, stat} <- File.stat(source),
         :ok <- File.mkdir_p(Path.dirname(target)),
         :ok <- atomic_write(target, content),
         :ok <- File.chmod(target, Bitwise.band(stat.mode, 0o777)),
         {:ok, ^content} <- File.read(target) do
      :ok
    else
      {:ok, _other} -> {:error, :settings_copy_verification_failed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp same_file_content?(left, right) do
    with {:ok, left_content} <- File.read(left),
         {:ok, right_content} <- File.read(right) do
      :crypto.hash(:sha256, left_content) == :crypto.hash(:sha256, right_content)
    else
      _ -> false
    end
  end

  defp ensure_file_unlocked(settings_path) do
    if File.exists?(settings_path) do
      :ok
    else
      with :ok <- File.mkdir_p(Path.dirname(settings_path)),
           :ok <- atomic_write(settings_path, @default_content) do
        :ok
      else
        {:error, reason} ->
          {:error, "Failed to initialize workspace settings: #{inspect(reason)}"}
      end
    end
  end

  @doc """
  Append a Matcher pattern to `tools.allow` or `tools.deny`.

  Duplicate patterns are ignored. Missing settings files are created.
  """
  @spec append_tool_rule(Path.t(), :allow | :deny, String.t()) :: :ok | {:error, String.t()}
  def append_tool_rule(workspace_root, list, pattern)
      when list in [:allow, :deny] and is_binary(pattern) do
    pattern = String.trim(pattern)

    if pattern == "" do
      {:error, "pattern must not be empty"}
    else
      settings_path = path(workspace_root)

      with_settings_lock(settings_path, fn ->
        with {:ok, existing} <- read_existing_for_write(settings_path),
             :ok <- File.mkdir_p(Path.dirname(settings_path)) do
          tools = existing |> Map.get("tools", %{}) |> ensure_map()
          current = tools |> Map.get(Atom.to_string(list), []) |> normalize_string_list()
          updated_list = if pattern in current, do: current, else: current ++ [pattern]
          updated_tools = Map.put(tools, Atom.to_string(list), updated_list)
          updated = Map.put(existing, "tools", updated_tools)

          case atomic_write(settings_path, Handbean.JSON.encode!(updated, pretty: true)) do
            :ok -> :ok
            {:error, reason} -> {:error, "Failed to write settings: #{inspect(reason)}"}
          end
        else
          {:error, reason} when is_binary(reason) -> {:error, reason}
          {:error, reason} -> {:error, "Failed to prepare settings path: #{inspect(reason)}"}
        end
      end)
    end
  end

  defp ensure_map(map) when is_map(map), do: map
  defp ensure_map(_), do: %{}

  defp normalize_string_list(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp normalize_string_list(_), do: []

  @doc "Whether Handbean's built-in memory is enabled for this workspace."
  @spec builtin_memory_enabled(Path.t()) :: boolean()
  def builtin_memory_enabled(workspace_root) do
    case load(workspace_root) do
      {:ok, settings} -> builtin_memory_enabled_from_settings(settings)
      {:error, _reason} -> false
    end
  end

  @doc "Resolve built-in memory from decoded settings; a missing value defaults to enabled."
  @spec builtin_memory_enabled_from_settings(map()) :: boolean()
  def builtin_memory_enabled_from_settings(settings) when is_map(settings) do
    get_in(settings, ["memory", "builtin_enabled"]) != false
  end

  def builtin_memory_enabled_from_settings(_settings), do: true

  @doc "Persist the workspace-local built-in memory switch."
  @spec update_builtin_memory_enabled(Path.t(), boolean()) :: :ok | {:error, String.t()}
  def update_builtin_memory_enabled(workspace_root, enabled) when is_boolean(enabled) do
    settings_path = path(workspace_root)

    with_settings_lock(settings_path, fn ->
      with :ok <- ensure_file_unlocked(settings_path),
           {:ok, content, settings} <- read_settings_for_update(settings_path),
           updated_content <- put_builtin_memory_jsonc(content, settings, enabled),
           :ok <- atomic_write(settings_path, updated_content) do
        :ok
      else
        {:error, reason} when is_binary(reason) -> {:error, reason}
        {:error, reason} -> {:error, "Failed to write settings: #{inspect(reason)}"}
      end
    end)
  end

  @doc "The three workspace permission modes exposed by Web and native hosts."
  def permission_mode(workspace_root) do
    case load(workspace_root) do
      {:ok, settings} ->
        case settings |> Map.get("tools") |> ensure_map() |> Map.get("default_mode") do
          "prompt" -> :prompt
          "yolo" -> :yolo
          "deny" -> :deny
          _ -> :auto_review
        end

      {:error, _} ->
        :prompt
    end
  end

  @doc "Save the execution policy and reviewer together for a permission mode."
  def update_permission_mode(workspace_root, mode) when mode in [:prompt, :auto_review, :yolo] do
    {default_mode, reviewer} =
      case mode do
        :prompt -> {"prompt", "user"}
        :auto_review -> {"auto", "auto_review"}
        :yolo -> {"yolo", "user"}
      end

    settings_path = path(workspace_root)

    with_settings_lock(settings_path, fn ->
      with :ok <- ensure_file_unlocked(settings_path),
           {:ok, content, settings} <- read_settings_for_update(settings_path),
           {:ok, content} <- put_approvals_reviewer(content, reviewer) do
        content =
          if Regex.match?(~r/"default_mode"\s*:\s*"[^"]*"/, content) do
            Regex.replace(
              ~r/"default_mode"\s*:\s*"[^"]*"/,
              content,
              "\"default_mode\": \"#{default_mode}\"",
              global: false
            )
          else
            tools =
              settings
              |> Map.get("tools")
              |> ensure_map()
              |> Map.merge(%{
                "default_mode" => default_mode,
                "approvals_reviewer" => reviewer
              })

            settings |> Map.put("tools", tools) |> Handbean.JSON.encode!(pretty: true)
          end

        case atomic_write(settings_path, content) do
          :ok -> :ok
          {:error, reason} -> {:error, "Failed to write settings: #{inspect(reason)}"}
        end
      else
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @default_review_timeout_ms 30_000

  @doc """
  Who reviews calls that `ToolPolicy` has already marked `:prompt`.

  Only `"user"` and `"auto_review"` are accepted. Anything else, including a
  missing key, stays `:user`.
  """
  @spec approvals_reviewer(Path.t()) :: :user | :auto_review
  def approvals_reviewer(workspace_root) do
    case load(workspace_root) do
      {:ok, settings} -> approvals_reviewer_from_settings(settings)
      {:error, _reason} -> :user
    end
  end

  @spec approvals_reviewer_from_settings(map()) :: :user | :auto_review
  def approvals_reviewer_from_settings(settings) when is_map(settings) do
    case get_in(settings, ["tools", "approvals_reviewer"]) do
      "auto_review" -> :auto_review
      _ -> :user
    end
  end

  def approvals_reviewer_from_settings(_settings), do: :user

  @doc """
  Optional reviewer model and hard deadline. `model: nil` means the workspace
  default model. This does not introduce a provider.
  """
  @spec auto_review_config(map()) :: %{model: String.t() | nil, timeout_ms: pos_integer()}
  def auto_review_config(settings) when is_map(settings) do
    auto = get_in(settings, ["tools", "auto_review"])
    auto = if is_map(auto), do: auto, else: %{}

    %{
      model: blank_to_nil(Map.get(auto, "model")),
      timeout_ms: positive_timeout(Map.get(auto, "timeout_ms"))
    }
  end

  def auto_review_config(_settings) do
    %{model: nil, timeout_ms: @default_review_timeout_ms}
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  defp positive_timeout(value) when is_integer(value) and value > 0, do: value

  defp positive_timeout(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> @default_review_timeout_ms
    end
  end

  defp positive_timeout(_value), do: @default_review_timeout_ms

  defp put_approvals_reviewer(content, value) when value in ["user", "auto_review"] do
    line = "\"approvals_reviewer\": \"#{value}\""

    cond do
      Regex.match?(~r/"approvals_reviewer"\s*:\s*"[^"]*"/, content) ->
        {:ok, Regex.replace(~r/"approvals_reviewer"\s*:\s*"[^"]*"/, content, line, global: false)}

      Regex.match?(~r/"approvals_reviewer"\s*:\s*null/, content) ->
        {:ok, Regex.replace(~r/"approvals_reviewer"\s*:\s*null/, content, line, global: false)}

      Regex.match?(~r/"default_mode"\s*:/, content) ->
        {:ok,
         Regex.replace(~r/("default_mode"\s*:)/, content, line <> ",\n        \\1", global: false)}

      Regex.match?(~r/"tools"\s*:\s*\{/, content) ->
        {:ok,
         Regex.replace(~r/"tools"\s*:\s*\{/, content, "\"tools\": {\n        " <> line <> ",",
           global: false
         )}

      Regex.match?(~r/\}\s*\z/, content) ->
        insertion = """
        ,
          "tools": {
            "approvals_reviewer": "#{value}"
          }
        }\
        """

        {:ok, Regex.replace(~r/\}\s*\z/, content, insertion)}

      true ->
        {:error, "workspace settings have no JSON object to update"}
    end
  end

  @doc """
  Load and parse workspace settings.


  Missing settings are treated as an empty settings map.
  """
  @spec load(Path.t()) :: {:ok, map()} | {:error, String.t()}
  def load(workspace_root) do
    with {:ok, settings_path} <- resolve_path(workspace_root) do
      case File.read(settings_path) do
        {:ok, content} ->
          case decode_jsonc(content) do
            {:ok, settings} when is_map(settings) ->
              {:ok, settings}

            {:ok, _other} ->
              {:error, "Failed to parse #{settings_path}: expected a JSON object"}

            {:error, reason} ->
              {:error, "Failed to parse #{settings_path}: #{inspect(reason)}"}
          end

        {:error, :enoent} ->
          {:ok, %{}}

        {:error, reason} ->
          {:error, "Failed to read #{settings_path}: #{inspect(reason)}"}
      end
    end
  end

  @doc """
  Return the workspace model policy from settings.

  Missing settings or missing `models` means unrestricted.
  """
  @spec models_policy(Path.t()) :: :unrestricted | {:ok, map()} | {:error, String.t()}
  def models_policy(workspace_root) do
    case load(workspace_root) do
      {:ok, settings} ->
        case Map.get(settings, "models") do
          %{} = models -> {:ok, models}
          _ -> :unrestricted
        end

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Return BEAM tool configuration with conservative defaults.
  """
  @spec beam_tools_config(Path.t()) :: %{
          required(:auto) => boolean(),
          required(:eval) => boolean(),
          required(:explicit) => [String.t()]
        }
  def beam_tools_config(workspace_root) do
    settings =
      case load(workspace_root) do
        {:ok, settings} -> settings
        {:error, _reason} -> %{}
      end

    beam = get_in(settings, ["tools", "beam"]) || %{}
    explicit = get_in(settings, ["tools", "explicit"]) || []

    %{
      auto: Map.get(beam, "auto", true) != false,
      eval: Map.get(beam, "eval", false) == true,
      explicit: if(is_list(explicit), do: Enum.filter(explicit, &is_binary/1), else: [])
    }
  end

  defp decode_jsonc(content) do
    content
    |> strip_jsonc_comments()
    |> strip_trailing_commas()
    |> Handbean.JSON.decode()
  end

  defp strip_jsonc_comments(content) do
    content
    |> String.graphemes()
    |> strip_comments([], :normal, nil)
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp strip_comments([], acc, _state, _quote), do: acc

  defp strip_comments(["/" | rest], acc, :normal, nil) do
    case rest do
      ["/" | tail] ->
        {_comment, tail} = Enum.split_while(tail, &(&1 not in ["\n", "\r"]))
        strip_comments(tail, acc, :normal, nil)

      ["*" | tail] ->
        strip_block_comment(tail, acc)

      _ ->
        strip_comments(rest, ["/" | acc], :normal, nil)
    end
  end

  defp strip_comments(["\"" = char | rest], acc, :normal, nil),
    do: strip_comments(rest, [char | acc], :string, "\"")

  defp strip_comments([char | rest], acc, :normal, nil),
    do: strip_comments(rest, [char | acc], :normal, nil)

  defp strip_comments(["\\" = char, escaped | rest], acc, :string, quote),
    do: strip_comments(rest, [escaped, char | acc], :string, quote)

  defp strip_comments([quote | rest], acc, :string, quote),
    do: strip_comments(rest, [quote | acc], :normal, nil)

  defp strip_comments([char | rest], acc, :string, quote),
    do: strip_comments(rest, [char | acc], :string, quote)

  defp strip_block_comment([], acc), do: acc

  defp strip_block_comment(["*" | rest], acc) do
    case rest do
      ["/" | tail] -> strip_comments(tail, acc, :normal, nil)
      _ -> strip_block_comment(rest, acc)
    end
  end

  defp strip_block_comment([_char | rest], acc), do: strip_block_comment(rest, acc)

  defp strip_trailing_commas(content) do
    Regex.replace(~r/,\s*([}\]])/, content, "\\1")
  end

  defp put_builtin_memory_jsonc(content, settings, enabled) do
    memory_pattern = ~r/("memory"\s*:\s*\{)([^{}]*)(\})/s
    enabled_text = to_string(enabled)

    cond do
      Regex.match?(memory_pattern, content) ->
        Regex.replace(
          memory_pattern,
          content,
          fn _match, open, body, close ->
            body =
              if Regex.match?(~r/"builtin_enabled"\s*:/, body) do
                Regex.replace(
                  ~r/"builtin_enabled"\s*:\s*(?:true|false)/,
                  body,
                  "\"builtin_enabled\": #{enabled_text}",
                  global: false
                )
              else
                "\n    \"builtin_enabled\": #{enabled_text}," <> body
              end

            open <> body <> close
          end,
          global: false
        )

      not Map.has_key?(settings, "memory") ->
        separator = if map_size(settings) == 0, do: "", else: ","

        block =
          "{\n  \"memory\": {\n    \"builtin_enabled\": #{enabled_text}\n  }#{separator}"

        Regex.replace(~r/\{/, content, block, global: false)

      true ->
        settings
        |> Map.update("memory", %{"builtin_enabled" => enabled}, fn memory ->
          memory = if is_map(memory), do: memory, else: %{}
          Map.put(memory, "builtin_enabled", enabled)
        end)
        |> Handbean.JSON.encode!(pretty: true)
    end
  end

  # ──────────────────────────────────────────────────────────────
  # Write methods
  # ──────────────────────────────────────────────────────────────

  @doc """
  Write or update the workspace model access policy.

  Reads the existing `.handbean/settings.jsonc` (if present), replaces the
  `"models"` key with the given policy, and writes back as prettified JSON.

  Non-model settings (e.g. `"tools"`) are preserved. JSONC comments are
  **not** preserved in the output (this is a known limitation).

  Creates the settings file and its parent directory if they do not exist.
  """
  @spec write_policy(Path.t(), map()) :: :ok | {:error, String.t()}
  def write_policy(workspace_root, policy) when is_map(policy) do
    settings_path = path(workspace_root)

    with_settings_lock(settings_path, fn ->
      with {:ok, existing} <- read_existing_for_write(settings_path),
           :ok <- File.mkdir_p(Path.dirname(settings_path)) do
        updated = Map.put(existing, "models", policy)

        case atomic_write(settings_path, Handbean.JSON.encode!(updated, pretty: true)) do
          :ok -> :ok
          {:error, reason} -> {:error, "Failed to write settings: #{inspect(reason)}"}
        end
      else
        {:error, reason} when is_binary(reason) -> {:error, reason}
        {:error, reason} -> {:error, "Failed to prepare settings path: #{inspect(reason)}"}
      end
    end)
  end

  def write_policy(_workspace_root, _policy) do
    {:error, "Policy must be a map"}
  end

  defp atomic_write(path, content) do
    tmp_path = "#{path}.tmp.#{System.unique_integer([:positive])}"

    try do
      File.write!(tmp_path, content)
      File.rename!(tmp_path, path)
      :ok
    rescue
      e in File.Error ->
        File.rm(tmp_path)
        {:error, e}
    end
  end

  defp read_settings_for_update(settings_path) do
    case File.read(settings_path) do
      {:ok, content} ->
        case decode_jsonc(content) do
          {:ok, settings} when is_map(settings) ->
            {:ok, content, settings}

          {:ok, _other} ->
            {:error, "Failed to parse #{settings_path}: expected a JSON object"}

          {:error, reason} ->
            {:error, "Failed to parse #{settings_path}: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "Failed to read #{settings_path}: #{inspect(reason)}"}
    end
  end

  defp read_existing_for_write(settings_path) do
    case File.read(settings_path) do
      {:ok, content} ->
        case decode_jsonc(content) do
          {:ok, settings} when is_map(settings) ->
            {:ok, settings}

          {:ok, _other} ->
            {:error, "Failed to parse #{settings_path}: expected a JSON object"}

          {:error, reason} ->
            {:error, "Failed to parse #{settings_path}: #{inspect(reason)}"}
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, "Failed to read #{settings_path}: #{inspect(reason)}"}
    end
  end

  @doc false
  def normalize_transaction_result(:aborted), do: {:error, @lock_aborted_error}
  def normalize_transaction_result(result), do: result

  defp with_settings_lock(settings_path, fun) when is_function(fun, 0) do
    owner_root = settings_path |> Path.dirname() |> Path.dirname()

    if File.dir?(owner_root) do
      resource =
        {:handbean_workspace_settings, Handbean.StorageLock.canonical_path(settings_path)}

      {resource, self()}
      |> :global.trans(fun, [node()])
      |> normalize_transaction_result()
    else
      {:error, "Failed to resolve workspace settings owner: :not_found"}
    end
  end
end
