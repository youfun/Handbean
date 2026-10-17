defmodule HandbeanWeb.Components.ModelPicker do
  @moduledoc """
  Progressive-enhancement model picker shared by the composer and settings.

  The native select remains the form and LiveView event owner. JavaScript adds
  search, grouping, and a mobile bottom sheet without introducing shadow state.
  """

  use HandbeanWeb, :html

  attr(:id, :string, required: true)
  attr(:name, :string, required: true)
  attr(:value, :any, default: nil)
  attr(:options, :list, required: true)
  attr(:label, :string, required: true)
  attr(:title, :string, default: nil)
  attr(:change, :string, required: true)
  attr(:target, :any, default: nil)
  attr(:refresh, :string, default: nil)
  attr(:compact, :boolean, default: false)

  def render(assigns) do
    assigns =
      assigns
      |> assign(:groups, group_options(assigns.options))
      |> assign(:selected_label, selected_label(assigns.options, assigns.value))
      |> assign(:model_count, Enum.count(assigns.options, &(&1.value != "")))
      |> assign(:target_attrs, event_target_attrs(assigns.target))
      |> assign(:refresh_attrs, refresh_attrs(assigns.refresh))

    ~H"""
    <div
      id={"#{@id}-control"}
      class={["model-picker", @compact && "model-picker-compact"]}
      phx-hook="ModelPicker"
      data-model-picker
    >
      <select
        id={@id}
        name={@name}
        value={@value || ""}
        phx-change={@change}
        aria-label={@label}
        title={@title || @label}
        class="model-picker-native"
        {@target_attrs}
        {@refresh_attrs}
      >
        <%= for {group, options} <- @groups do %>
          <optgroup :if={group} label={group}>
            <option
              :for={option <- options}
              value={option.value}
              selected={option.value == (@value || "")}
              disabled={Map.get(option, :disabled, false)}
            >
              {option.label}
            </option>
          </optgroup>
          <option
            :for={option <- if(is_nil(group), do: options, else: [])}
            value={option.value}
            selected={option.value == (@value || "")}
            disabled={Map.get(option, :disabled, false)}
          >
            {option.label}
          </option>
        <% end %>
      </select>

      <button
        id={"#{@id}-trigger"}
        type="button"
        class="model-picker-trigger"
        aria-haspopup="dialog"
        aria-expanded="false"
        aria-controls={"#{@id}-panel"}
        data-model-picker-trigger
        {@refresh_attrs}
      >
        <span class="model-picker-trigger-label">{@selected_label}</span>
        <svg viewBox="0 0 20 20" fill="none" aria-hidden="true">
          <path
            d="m6 8 4 4 4-4"
            stroke="currentColor"
            stroke-width="1.8"
            stroke-linecap="round"
            stroke-linejoin="round"
          />
        </svg>
      </button>

      <button
        type="button"
        class="model-picker-backdrop"
        aria-label={gettext("Close")}
        data-model-picker-close
        hidden
      ></button>

      <div
        id={"#{@id}-panel"}
        class="model-picker-panel"
        role="dialog"
        aria-modal="true"
        aria-label={@label}
        data-model-picker-panel
        hidden
      >
        <div class="model-picker-header">
          <div>
            <div class="model-picker-title">{@label}</div>
            <div class="model-picker-count">
              {ngettext("%{count} model", "%{count} models", @model_count, count: @model_count)}
            </div>
          </div>
          <button
            type="button"
            class="model-picker-close"
            aria-label={gettext("Close")}
            data-model-picker-close
          >
            <svg viewBox="0 0 20 20" fill="none" aria-hidden="true">
              <path
                d="m6 6 8 8m0-8-8 8"
                stroke="currentColor"
                stroke-width="1.8"
                stroke-linecap="round"
              />
            </svg>
          </button>
        </div>

        <div class="model-picker-search-wrap">
          <svg viewBox="0 0 20 20" fill="none" aria-hidden="true">
            <circle cx="9" cy="9" r="5.5" stroke="currentColor" stroke-width="1.5" />
            <path d="m13 13 3 3" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" />
          </svg>
          <input
            type="search"
            class="model-picker-search"
            placeholder={gettext("Search models")}
            aria-label={gettext("Search models")}
            autocomplete="off"
            data-model-picker-search
          />
        </div>

        <div class="model-picker-results" data-model-picker-results>
          <section
            :for={{group, options} <- @groups}
            class="model-picker-group"
            data-model-picker-group
          >
            <div :if={group} class="model-picker-group-label">{group}</div>
            <button
              :for={option <- options}
              type="button"
              class={["model-picker-option", option.value == (@value || "") && "is-selected"]}
              data-model-picker-option
              data-value={option.value}
              data-search={search_text(option, group)}
              aria-current={if option.value == (@value || ""), do: "true", else: nil}
              disabled={Map.get(option, :disabled, false)}
            >
              <span class="model-picker-option-copy">
                <span class="model-picker-option-label">{option.label}</span>
              </span>
              <svg class="model-picker-check" viewBox="0 0 20 20" fill="none" aria-hidden="true">
                <path
                  d="m5 10 3 3 7-7"
                  stroke="currentColor"
                  stroke-width="1.8"
                  stroke-linecap="round"
                  stroke-linejoin="round"
                />
              </svg>
            </button>
          </section>
          <div class="model-picker-empty" data-model-picker-empty hidden>
            {gettext("No matching models")}
          </div>
        </div>
      </div>
    </div>
    """
  end

  def option(value, label, group \\ nil) do
    %{value: value || "", label: label, group: group}
  end

  defp group_options(options) do
    options
    |> Enum.group_by(&Map.get(&1, :group))
    |> Enum.sort_by(fn
      {nil, _options} -> {0, ""}
      {group, _options} -> {1, String.downcase(group)}
    end)
  end

  defp selected_label(options, value) do
    selected_value = value || ""

    case Enum.find(options, &(&1.value == selected_value)) do
      nil -> gettext("Choose a model")
      option -> option.label
    end
  end

  defp search_text(option, group) do
    [option.label, option.value, group]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> String.downcase()
  end

  defp event_target_attrs(nil), do: %{}
  defp event_target_attrs(target), do: %{:"phx-target" => target}

  defp refresh_attrs(nil), do: %{}
  defp refresh_attrs(refresh), do: %{:"phx-click" => refresh}
end
