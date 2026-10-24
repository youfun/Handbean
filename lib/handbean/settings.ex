defmodule Handbean.Settings do
  @moduledoc """
  Global settings persistence — read/write `~/.handbean/settings.json`.

  Works with `Handbean.WorkspaceSettings` for per-workspace overrides and
  `Handbean.Settings.ModelAISettings` for schema/validation/merge.
  """

  alias Handbean.Settings.ModelAISettings

  @global_filename "settings.json"

  @doc """
  Default global settings directory (`~/.handbean`).
  """
  def default_global_dir do
    Path.join(Handbean.Home.path(), ".handbean")
  end

  @doc """
  Return the global settings file path.

  Respects `HANDBEAN_GLOBAL_SETTINGS_FILE` env var override.
  """
  def global_settings_path(opts \\ []) do
    case System.get_env("HANDBEAN_GLOBAL_SETTINGS_FILE") do
      nil ->
        dir = Keyword.get(opts, :global_dir, default_global_dir())
        Path.join(dir, @global_filename)

      path ->
        path
    end
  end

  # ── Global settings ──────────────────────────────────────────

  @doc """
  Load global settings from `~/.handbean/settings.json`.

  Returns `{:ok, %{}}` when the file doesn't exist.
  Returns `{:ok, %{}}` on parse error (non-fatal).
  """
  @spec load_global(keyword()) :: {:ok, map()}
  def load_global(opts \\ []) do
    path = global_settings_path(opts)

    case File.read(path) do
      {:ok, content} ->
        case Handbean.JSON.decode(content) do
          {:ok, settings} when is_map(settings) -> {:ok, settings}
          _ -> {:ok, %{}}
        end

      {:error, _reason} ->
        {:ok, %{}}
    end
  end

  @doc "Persist one top-level global settings section while preserving the others."
  @spec save_global_section(String.t(), term(), keyword()) :: :ok | {:error, term()}
  def save_global_section(section, value, opts \\ []) when is_binary(section) do
    path = global_settings_path(opts)

    with {:ok, existing} <- load_global(opts),
         :ok <- File.mkdir_p(Path.dirname(path)) do
      updated = Map.put(existing, section, value)

      case File.write(path, Handbean.JSON.encode!(updated)) do
        :ok -> :ok
        {:error, reason} -> {:error, "Failed to write #{path}: #{inspect(reason)}"}
      end
    end
  end

  @doc """
  Save the `model_ai` section to global settings.

  Preserves existing non-`model_ai` top-level keys.
  """
  @spec save_global(map(), keyword()) :: :ok | {:error, term()}
  def save_global(model_ai_map, opts \\ []) do
    save_global_section("model_ai", model_ai_map, opts)
  end

  # ── Workspace model_ai override ─────────────────────────────

  @doc """
  Load the `model_ai` section from a workspace's `.handbean/settings.jsonc`.

  Returns `{:ok, %{}}` when there is no `model_ai` section or the file doesn't exist.
  """
  @spec load_workspace_model_ai(Path.t()) :: {:ok, map()} | {:error, term()}
  def load_workspace_model_ai(workspace_root) do
    with {:ok, settings} <- load_workspace(workspace_root) do
      model_ai = Map.get(settings, "model_ai", %{})
      {:ok, if(is_map(model_ai), do: model_ai, else: %{})}
    end
  end

  @doc """
  Load the full workspace settings from `.handbean/settings.jsonc`.

  Delegates to `Handbean.WorkspaceSettings.load/1`.
  """
  @spec load_workspace(Path.t()) :: {:ok, map()} | {:error, term()}
  def load_workspace(workspace_root) do
    Handbean.WorkspaceSettings.load(workspace_root)
  end

  @doc """
  Save the `model_ai` section to workspace `.handbean/settings.jsonc`.

  Preserves existing non-`model_ai` top-level keys.
  Creates `.handbean/` directory if missing.
  """
  @spec save_workspace_model_ai(Path.t(), map()) :: :ok | {:error, term()}
  def save_workspace_model_ai(workspace_root, model_ai_map) do
    sigil_dir = Path.join(workspace_root, ".handbean")
    settings_path = Path.join(sigil_dir, "settings.jsonc")

    with {:ok, existing} <- load_workspace(workspace_root),
         :ok <- File.mkdir_p(sigil_dir) do
      updated = Map.put(existing, "model_ai", model_ai_map)

      case File.write(settings_path, Handbean.JSON.encode!(updated)) do
        :ok -> :ok
        {:error, reason} -> {:error, "Failed to write #{settings_path}: #{inspect(reason)}"}
      end
    end
  end

  # ── Effective settings ──────────────────────────────────────

  @doc """
  Compute effective Model/AI settings by merging:

  1. Application defaults (`ModelAISettings.defaults/0`)
  2. Global settings (`~/.handbean/settings.json` → `model_ai`)
  3. Workspace override (`.handbean/settings.jsonc` → `model_ai`)

  Each layer overrides the one before it.
  """
  @spec effective_model_ai(Path.t(), keyword()) :: ModelAISettings.t()
  def effective_model_ai(workspace_root, opts \\ []) do
    case fetch_effective_model_ai(workspace_root, opts) do
      {:ok, settings} -> settings
      {:error, _reason} -> ModelAISettings.defaults()
    end
  end

  @doc "Fetch effective Model/AI settings, preserving load errors for UI display."
  @spec fetch_effective_model_ai(Path.t(), keyword()) ::
          {:ok, ModelAISettings.t()} | {:error, term()}
  def fetch_effective_model_ai(workspace_root, opts \\ []) do
    with {:ok, %{settings: settings}} <- inspect_model_ai(workspace_root, opts) do
      {:ok, settings}
    end
  end

  @doc "Effective settings and winning layer per field, using the normal merge path."
  def inspect_model_ai(workspace_root, opts \\ []) do
    with {:ok, global} <- load_global(opts),
         {:ok, workspace} <- load_workspace_model_ai(workspace_root) do
      global_model_ai = ModelAISettings.normalize_override(Map.get(global, "model_ai", %{}))
      workspace_model_ai = ModelAISettings.normalize_override(workspace)

      settings =
        ModelAISettings.defaults()
        |> ModelAISettings.merge(global_model_ai)
        |> ModelAISettings.merge(workspace_model_ai)

      sources =
        Map.new(Map.from_struct(settings), fn {key, _} ->
          source =
            cond do
              Map.has_key?(workspace_model_ai, key) -> :workspace_settings
              Map.has_key?(global_model_ai, key) -> :global_settings
              true -> :model_ai_defaults
            end

          {key, source}
        end)
        |> Map.put(:advisor, advisor_resolution(global_model_ai, workspace_model_ai, settings))
        |> Map.put(:subagent, subagent_resolution(global_model_ai, workspace_model_ai, settings))

      {:ok, %{settings: settings, sources: sources}}
    end
  end

  @doc "Return effective global Model/AI settings before workspace overrides."
  @spec global_model_ai(keyword()) :: ModelAISettings.t()
  def global_model_ai(opts \\ []) do
    {:ok, global} = load_global(opts)

    ModelAISettings.defaults()
    |> ModelAISettings.merge(ModelAISettings.normalize_override(Map.get(global, "model_ai", %{})))
  end

  @doc """
  Advisor resolution for a workspace.

  Returns `{:ok, %{model, reasoning, source}}`, `:none`, `:disabled`, or
  `{:error, reason}`.
  Web and native settings read this result instead of deriving the tri-state themselves.
  """
  def advisor_resolution(workspace_root) when is_binary(workspace_root) do
    case inspect_model_ai(workspace_root) do
      {:ok, %{sources: sources}} -> Map.get(sources, :advisor, :none)
      {:error, _reason} -> :none
    end
  end

  @doc """
  Subagent default resolution for a workspace.

  Returns `{:ok, %{model, reasoning, source}}`, `:inherit`, or `{:error, reason}`.
  `:inherit` means the child follows the parent run.
  """
  def subagent_resolution(workspace_root) when is_binary(workspace_root) do
    case inspect_model_ai(workspace_root) do
      {:ok, %{sources: sources}} -> Map.get(sources, :subagent, :inherit)
      {:error, _reason} -> :inherit
    end
  end

  defp advisor_resolution(global_override, workspace_override, settings) do
    cond do
      Map.get(workspace_override, :advisor_mode) == :disabled ->
        :disabled

      Map.get(workspace_override, :advisor_mode) == :invalid ->
        {:error, :invalid_advisor}

      Map.get(workspace_override, :advisor_mode) == :custom ->
        case ModelAISettings.resolve_advisor(%{
               settings
               | advisor_mode: :custom,
                 advisor_model: workspace_override[:advisor_model],
                 advisor_reasoning: workspace_override[:advisor_reasoning]
             }) do
          {:ok, info} -> {:ok, %{info | source: :workspace}}
          other -> other
        end

      Map.get(global_override, :advisor_mode) in [:custom, :inherit] and
          is_binary(global_override[:advisor_model]) ->
        case ModelAISettings.resolve_advisor(%{
               settings
               | advisor_mode: :custom,
                 advisor_model: global_override[:advisor_model],
                 advisor_reasoning: global_override[:advisor_reasoning]
             }) do
          {:ok, info} -> {:ok, %{info | source: :global}}
          other -> other
        end

      Map.get(global_override, :advisor_mode) == :invalid ->
        {:error, :invalid_advisor}

      true ->
        :none
    end
  end

  defp subagent_resolution(global_override, workspace_override, settings) do
    cond do
      Map.get(workspace_override, :subagent_mode) == :parent ->
        :inherit

      Map.get(workspace_override, :subagent_mode) == :invalid ->
        {:error, :invalid_subagent}

      Map.get(workspace_override, :subagent_mode) == :custom ->
        case ModelAISettings.resolve_subagent(%{
               settings
               | subagent_mode: :custom,
                 subagent_model: workspace_override[:subagent_model],
                 subagent_reasoning: workspace_override[:subagent_reasoning]
             }) do
          {:ok, info} -> {:ok, %{info | source: :workspace}}
          other -> other
        end

      Map.get(global_override, :subagent_mode) in [:custom, :inherit] and
          is_binary(global_override[:subagent_model]) ->
        case ModelAISettings.resolve_subagent(%{
               settings
               | subagent_mode: :custom,
                 subagent_model: global_override[:subagent_model],
                 subagent_reasoning: global_override[:subagent_reasoning]
             }) do
          {:ok, info} -> {:ok, %{info | source: :global}}
          other -> other
        end

      Map.get(global_override, :subagent_mode) == :invalid ->
        {:error, :invalid_subagent}

      true ->
        :inherit
    end
  end
end
