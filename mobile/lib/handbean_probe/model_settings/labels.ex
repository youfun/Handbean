defmodule HandbeanProbe.ModelSettings.Labels do
  @moduledoc """
  Localized display strings for the native model settings.

  Pure value → text functions. No node construction, no IO.
  """

  use Gettext, backend: HandbeanProbe.Gettext
  alias Handbean.Settings.ModelCatalog
  alias HandbeanProbe.SettingsSupport

  def reasoning("off"), do: gettext("Off")
  def reasoning("minimal"), do: gettext("Minimal")
  def reasoning("low"), do: gettext("Low")
  def reasoning("medium"), do: gettext("Medium")
  def reasoning("high"), do: gettext("High")
  def reasoning("xhigh"), do: gettext("Highest")
  def reasoning(other), do: to_string(other || gettext("Off"))

  def memory_scope("workspace"), do: gettext("This workspace")
  def memory_scope("global"), do: gettext("All workspaces")
  def memory_scope("both"), do: gettext("This workspace and global")

  def memory_scope(other) when is_binary(other) and other != "",
    do: gettext("Unknown value: %{value}", value: other)

  def memory_scope(_), do: gettext("Not set")

  def privacy("local_only"), do: gettext("Data isolated")
  def privacy("standard"), do: gettext("Standard")

  def privacy(other) when is_binary(other) and other != "",
    do: gettext("Unknown value: %{value}", value: other)

  def privacy(_), do: gettext("Not set")

  def protocol("openai-chat-completions"), do: gettext("OpenAI Chat Completions")
  def protocol("openai-responses"), do: gettext("OpenAI Responses")
  def protocol("anthropic-messages"), do: gettext("Anthropic Messages")
  def protocol("stepfun-step-plan"), do: gettext("StepFun Step Plan")
  def protocol("ollama-cloud"), do: gettext("Ollama Cloud")
  def protocol("opencode-go"), do: gettext("OpenCode Go")
  def protocol(other), do: to_string(other)

  def key_status(:missing), do: gettext("API key: not configured")
  def key_status(:configured), do: gettext("API key: configured")
  def key_status({:env, _var}), do: key_status(:configured)
  def key_status(_), do: gettext("API key: not configured")

  def key_help(_),
    do: gettext("Leave the field blank to keep the current key. A new value replaces it.")

  def default_model(nil, _state), do: gettext("None (use provider default)")

  def default_model(id, state) do
    case Enum.find(state.models, &(&1.id == id)) do
      nil -> gettext("Unknown model: %{id}", id: id)
      model -> model.name
    end
  end

  def follow(nil, fallback), do: fallback
  def follow("", fallback), do: fallback

  def follow(id, fallback) do
    # Stored ids stay the option values; this is display only.
    if is_binary(id) and id != "", do: id, else: fallback
  end

  def source_line(field, sources, value) do
    origin =
      case Map.get(sources, field, :global) do
        :workspace -> gettext("This workspace")
        :global -> gettext("Global default")
      end

    gettext("%{origin}: %{value}", origin: origin, value: display_value(field, value))
  end

  def memory_status(enabled?, source) do
    gettext("Effective: %{state} (%{source})",
      state: if(enabled?, do: gettext("on"), else: gettext("off")),
      source:
        if(source == :workspace,
          do: gettext("workspace override"),
          else: gettext("global default")
        )
    )
  end

  def policy_help(%{mode: :invalid, error: reason}),
    do: gettext("This workspace policy file is invalid: %{reason}", reason: inspect(reason))

  def policy_help(%{configured?: false}),
    do: gettext("No allowlist is set. Every catalog model can be used.")

  def policy_help(%{mode: :unrestricted, configured?: true}),
    do: gettext("All catalog models are allowed in this workspace.")

  def policy_help(_),
    do: gettext("Only checked models are allowed in this workspace.")

  def ref(%{source: :catalog_default_provider}), do: gettext("Catalog defaultProvider")
  def ref(%{source: :catalog_default_model}), do: gettext("Catalog defaultModel")

  def ref(%{source: :global_model_ai, field: field}),
    do: gettext("Global Model/AI %{field}", field: field)

  def ref(%{source: :workspace_model_ai, workspace_id: id, field: field}),
    do: gettext("Workspace %{id} Model/AI %{field}", id: id, field: field)

  def ref(%{source: :workspace_policy_default, workspace_id: id}),
    do: gettext("Workspace %{id} policy default", id: id)

  def ref(_), do: gettext("Referenced setting")

  def ref_errors(count) when is_integer(count) and count > 0 do
    gettext(
      "%{count} workspace settings files could not be read. References there are unknown.",
      count: count
    )
  end

  @doc "Preview of the effective max output tokens for the model form."
  def token_lines(state, form) do
    provider = Enum.find(state.providers, &(&1.id == form.provider))
    provider_meta = %{"maxTokens" => provider && provider.max_tokens}

    meta = %{
      "maxTokens" => parse_preview(form.max_tokens),
      "contextWindow" => parse_preview(form.context_window)
    }

    effective = ModelCatalog.effective_max_tokens(provider_meta, meta)

    source =
      case effective.source do
        :provider -> gettext("provider override")
        :model -> gettext("model value")
        :unset -> gettext("unset (request omits max_tokens or uses the protocol default)")
      end

    gettext("Effective max output tokens: %{value} (%{source})",
      value: effective.value || gettext("none"),
      source: source
    )
  end

  defp display_value(:default_model, nil), do: gettext("Not set (provider default)")
  defp display_value(:default_model, id), do: id
  defp display_value(:reasoning, value), do: reasoning(value)
  defp display_value(_field, nil), do: gettext("Not set")
  defp display_value(_field, value), do: to_string(value)

  defp parse_preview(value) do
    case SettingsSupport.parse_optional_positive(to_string(value || "")) do
      {:ok, n} when is_integer(n) -> n
      _ -> nil
    end
  end
end
