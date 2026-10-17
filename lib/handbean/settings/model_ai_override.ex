defmodule Handbean.Settings.ModelAIOverride do
  @moduledoc """
  Model/AI layer helpers on top of `Handbean.Settings`.

  Answers "which layer does each field come from", saves a full
  `Handbean.Settings.ModelAISettings` form to the global file or as a workspace
  override (diffed against global), and clears workspace overrides so a field
  inherits the global value again. No UI dependency; the native settings
  screen and LiveView can both sit on top of it.
  """

  alias Handbean.Settings
  alias Handbean.Settings.ModelAISettings

  @type target :: :global | {:workspace, Path.t()}
  @type source :: :workspace | :global

  @doc """
  Per-field origin of the effective Model/AI settings for a workspace.

  A field is `:workspace` when the workspace `.handbean/settings.jsonc` overrides
  it, otherwise `:global`. An unreadable workspace file is treated as "no
  overrides" (every field `:global`); callers that need the error use
  `Handbean.Settings.fetch_effective_model_ai/1`.
  """
  @spec sources(Path.t()) :: %{atom() => source()}
  def sources(workspace_root) do
    override =
      case Settings.load_workspace_model_ai(workspace_root) do
        {:ok, raw} -> ModelAISettings.normalize_override(raw)
        {:error, _reason} -> %{}
      end

    Map.new(ModelAISettings.fields(), fn field ->
      {field, if(Map.has_key?(override, field), do: :workspace, else: :global)}
    end)
    |> Map.put(:advisor, Settings.advisor_resolution(workspace_root))
  end

  @doc """
  Save a full settings form.

  `:global` writes the form as the global `model_ai` section. `{:workspace, path}`
  stores only the fields that differ from the current global settings, so the
  workspace file never freezes copies of global values.
  """
  @spec save(target(), ModelAISettings.t()) :: :ok | {:error, term()}
  def save(:global, %ModelAISettings{} = form) do
    form
    |> ModelAISettings.to_json_map()
    |> Map.update("advisor", nil, fn advisor ->
      case advisor do
        %{"model" => model} = value when is_binary(model) and model != "" ->
          Map.take(value, ["model", "reasoning"])

        _ ->
          nil
      end
    end)
    |> drop_nil_advisor()
    |> Settings.save_global()
  end

  def save({:workspace, path}, %ModelAISettings{} = form) do
    global = Settings.global_model_ai()

    global
    |> ModelAISettings.diff(form)
    |> Map.merge(advisor_workspace_override(form))
    |> ModelAISettings.override_to_json_map()
    |> then(&Settings.save_workspace_model_ai(path, &1))
  end

  defp drop_nil_advisor(map) do
    if Map.get(map, "advisor") == nil, do: Map.delete(map, "advisor"), else: map
  end

  @doc """
  Make `fields` inherit the global value again in the workspace override.

  Other workspace overrides are preserved.
  """
  @spec inherit(Path.t(), [atom()]) :: :ok | {:error, term()}
  def inherit(path, fields) when is_list(fields) do
    effective = Settings.effective_model_ai(path)
    global = Settings.global_model_ai()

    updated =
      Enum.reduce(fields, effective, fn field, acc ->
        if field == :advisor do
          ModelAISettings.clear_advisor(acc)
        else
          Map.put(acc, field, Map.get(global, field))
        end
      end)

    save({:workspace, path}, updated)
  end

  defp advisor_workspace_override(form) do
    case form.advisor_mode do
      :inherit ->
        %{}

      :disabled ->
        %{advisor_mode: :disabled, advisor_model: nil, advisor_reasoning: nil}

      :custom ->
        %{
          advisor_mode: :custom,
          advisor_model: form.advisor_model,
          advisor_reasoning: form.advisor_reasoning
        }
    end
  end

  @doc "Remove every workspace Model/AI override."
  @spec inherit_all(Path.t()) :: :ok | {:error, term()}
  def inherit_all(path), do: Settings.save_workspace_model_ai(path, %{})
end
