defmodule HandbeanProbe.NativeUI do
  @moduledoc false

  @surface "#FAF9F7"
  @card "#FFFFFF"
  @control "#F4F3F0"
  @bubble "#E7E5E1"
  # Web `--sig-bg-surface-active`. Conversation selection uses this, not
  # `:control`, which is the lighter settings chip.
  @active "#E6E3DE"
  @border "#E4E0DA"
  @separator "#F0EEEA"
  @ink "#1A1815"
  @muted "#6B6560"
  @hint "#9C9590"
  @added "#24834A"
  @danger "#B42318"
  @error_surface "#FFF0EE"
  @change_row "#F4F1EA"
  @change_tab "#DCE7F7"
  @change_ink "#8D857A"
  @change_danger "#A54842"
  @change_success "#3F775D"
  @change_diff "#252321"
  @change_label "#3D4651"
  @change_panel "#FBFAF7"
  @change_path "#4B4742"
  @change_diff_ink "#E8E2D9"
  @change_action "#FAF8F4"
  @change_idle "#F1EFEB"
  @handoff_card "#F5F3EE"
  @bean_colors [
    "#e4bd3f",
    "#ed9438",
    "#e66c55",
    "#dc5362",
    "#d878a1",
    "#c75dae",
    "#8b79d8",
    "#6c9add",
    "#3ebd79",
    "#89c351",
    "#c78049",
    "#af6c59"
  ]
  @bean_outline "#263b25"
  @bean_highlight "#f1efb5"
  @bean_eyes "#263b25"
  @bean_cheek "#db9968"
  @bean_shadow "#9c9590"

  def color(:surface), do: @surface
  def color(:card), do: @card
  def color(:control), do: @control
  def color(:bubble), do: @bubble
  def color(:active), do: @active
  def color(:border), do: @border
  def color(:separator), do: @separator
  def color(:ink), do: @ink
  def color(:muted), do: @muted
  def color(:hint), do: @hint
  def color(:added), do: @added
  def color(:danger), do: @danger
  def color(:error_surface), do: @error_surface
  def color(:change_row), do: @change_row
  def color(:change_tab), do: @change_tab
  def color(:change_ink), do: @change_ink
  def color(:change_danger), do: @change_danger
  def color(:change_success), do: @change_success
  def color(:change_diff), do: @change_diff
  def color(:change_label), do: @change_label
  def color(:change_panel), do: @change_panel
  def color(:change_path), do: @change_path
  def color(:change_diff_ink), do: @change_diff_ink
  def color(:change_action), do: @change_action
  def color(:change_idle), do: @change_idle
  def color(:handoff_card), do: @handoff_card
  def color(:bean_outline), do: @bean_outline
  def color(:bean_highlight), do: @bean_highlight
  def color(:bean_eyes), do: @bean_eyes
  def color(:bean_cheek), do: @bean_cheek
  def color(:bean_shadow), do: @bean_shadow

  def bean_colors, do: @bean_colors

  defp control_type do
    if HandbeanProbe.NativePlatform.ios?(), do: :button, else: :settings_button
  end

  def node(type, props, children \\ []) do
    # Mob's color contract is ARGB integers or theme atoms, not CSS strings.
    props =
      Map.new(props, fn
        {key, "#" <> hex} when key in [:text_color, :background, :border_color] ->
          {key, String.to_integer("FF" <> hex, 16)}

        prop ->
          prop
      end)

    %{type: type, props: props, children: Enum.reject(children, &is_nil/1)}
  end

  def text(value, props \\ []) do
    node(:text, Keyword.merge([text: value, text_size: 14, text_color: color(:ink)], props))
  end

  def button(label, tag, props \\ []) do
    node(
      :text,
      Keyword.merge(
        [
          text: label,
          on_tap: {self(), tag},
          id: id(tag),
          background: color(:control),
          text_color: color(:ink),
          text_size: 13,
          fill_width: false,
          padding: 10,
          corner_radius: 8
        ],
        props
      )
    )
  end

  # Settings-only variants. Do not change button/3 defaults — chat, approval,
  # and Work reuse that size. These emit :settings_button so Compose can keep a
  # 36–40dp chrome inside a 48dp tap target without padding+min stacking.
  def primary_button(label, tag, props \\ []),
    do:
      settings_button(
        label,
        tag,
        Keyword.merge([background: color(:ink), text_color: color(:card)], props)
      )

  def secondary_button(label, tag, props \\ []), do: settings_button(label, tag, props)

  def quiet_button(label, tag, props \\ []),
    do:
      settings_button(
        label,
        tag,
        Keyword.merge(
          [background: color(:surface), border_color: color(:border), border_width: 1],
          props
        )
      )

  def danger_button(label, tag, props \\ []),
    do:
      settings_button(
        label,
        tag,
        Keyword.merge([background: color(:danger), text_color: color(:card)], props)
      )

  def tab_button(label, tag, selected?, props \\ []) do
    settings_button(
      label,
      tag,
      Keyword.merge(
        [
          weight: 1,
          fill_width: true,
          text_align: "center",
          background: if(selected?, do: color(:ink), else: color(:control)),
          text_color: if(selected?, do: color(:card), else: color(:ink))
        ],
        props
      )
    )
  end

  def segment_button(label, tag, selected?, props \\ []) do
    settings_button(
      label,
      tag,
      Keyword.merge(
        [
          weight: 1,
          fill_width: true,
          text_align: "center",
          background: if(selected?, do: color(:ink), else: color(:surface)),
          text_color: if(selected?, do: color(:card), else: color(:ink)),
          border_color: color(:border),
          border_width: 1
        ],
        props
      )
    )
  end

  def settings_button(label, tag, props \\ []) do
    node(
      control_type(),
      Keyword.merge(
        [
          text: label,
          on_tap: {self(), tag},
          id: id(tag),
          background: color(:control),
          text_color: color(:ink),
          text_size: 13,
          fill_width: false,
          corner_radius: 8,
          accessibility_role: "button"
        ],
        props
      )
    )
  end

  def option_button(label, tag, selected?, props \\ []) do
    button(
      if(selected?, do: "✓ #{label}", else: label),
      tag,
      Keyword.merge(
        [
          fill_width: true,
          text_align: "left",
          padding: 10,
          text_size: 13,
          background: if(selected?, do: color(:bubble), else: color(:card)),
          text_color: color(:ink),
          border_color: if(selected?, do: color(:ink), else: color(:border)),
          border_width: 1
        ],
        props
      )
    )
  end

  def select(value, options, props \\ []) do
    {open?, props} = Keyword.pop(props, :open, false)
    {toggle, props} = Keyword.pop(props, :on_toggle)

    if HandbeanProbe.NativePlatform.ios?() do
      ios_select(value, options, props, open?, toggle)
    else
      node(
        :settings_select,
        Keyword.merge(
          [
            text: value,
            text_size: 14,
            fill_width: true,
            background: color(:control),
            border_color: color(:border),
            border_width: 1,
            corner_radius: 8,
            # Horizontal inset only. Uniform padding + SettingsSelect's 48dp
            # min height stacked to ~72dp. Vertical space is the 48dp target.
            padding_left: 12,
            padding_right: 12,
            accessibility_role: "dropdown"
          ],
          props
        ),
        options
      )
    end
  end

  # iOS has no `:settings_select`. A wrapping `:column` always gets
  # maxWidth: infinity on iOS, which squeezes "Step Router v1" onto two
  # lines. Collapsed = the trigger node itself so the chip hugs its label.
  # Open (settings) = trigger + opaque menu card.
  defp ios_select(value, options, props, open?, toggle) do
    text_size = Keyword.get(props, :text_size, 12)
    fill_width = Keyword.get(props, :fill_width, true)

    trigger =
      button(
        value,
        toggle || :noop,
        Keyword.merge(
          [
            text_size: text_size,
            fill_width: fill_width,
            background: color(:control),
            text_color: color(:ink),
            border_color: color(:border),
            border_width: 1,
            corner_radius: 8,
            padding: 8,
            accessibility_role: "dropdown"
          ],
          props
        )
      )

    if open? do
      menu =
        node(
          :column,
          [
            fill_width: fill_width,
            background: color(:bubble),
            border_color: color(:ink),
            border_width: 1,
            corner_radius: 8,
            padding: 4
          ],
          List.wrap(options)
        )

      node(:column, [fill_width: fill_width], [trigger, menu])
    else
      trigger
    end
  end

  def select_option(label, tag, selected? \\ false, props \\ []) do
    node(
      :text,
      Keyword.merge(
        [
          text: label,
          on_tap: {self(), tag},
          id: id(tag),
          selected: selected?,
          accessibility_role: "menuitem"
        ] ++ ios_select_option_chrome(selected?),
        props
      )
    )
  end

  # Android `:settings_select` paints its own menu from bare option children.
  # iOS stock `:text` nodes default to Color.primary, which is white in dark
  # mode and invisible on the light surface without an explicit fill.
  defp ios_select_option_chrome(selected?) do
    if HandbeanProbe.NativePlatform.ios?() do
      [
        fill_width: true,
        text_align: "left",
        padding: 10,
        text_size: 13,
        background: if(selected?, do: color(:bubble), else: color(:card)),
        text_color: color(:ink),
        border_color: if(selected?, do: color(:ink), else: color(:border)),
        border_width: 1,
        corner_radius: 8
      ]
    else
      []
    end
  end

  def list_row(label, tag, props \\ []) do
    button(
      label,
      tag,
      Keyword.merge(
        [
          fill_width: true,
          text_align: "left",
          padding: 10,
          text_size: 14,
          background: color(:card),
          border_color: color(:border),
          border_width: 1,
          corner_radius: 8
        ],
        props
      )
    )
  end

  def settings_section(title) do
    text(title,
      text_size: 12,
      text_color: color(:muted),
      padding_left: 16,
      padding_top: 14,
      padding_bottom: 6
    )
  end

  def settings_group(children, props \\ []) do
    rows = children |> List.wrap() |> Enum.reject(&is_nil/1)

    inner =
      Enum.intersperse(
        rows,
        node(:box, height: 1, fill_width: true, background: color(:separator))
      )

    node(:column, [fill_width: true, padding_bottom: 8], [
      node(
        :column,
        Keyword.merge(
          [
            fill_width: true,
            background: color(:card),
            border_color: color(:border),
            border_width: 1,
            corner_radius: 12
          ],
          props
        ),
        inner
      )
    ])
  end

  def settings_form_field(label, control) do
    node(
      :column,
      [
        fill_width: true,
        padding_left: 16,
        padding_right: 16,
        padding_top: 12,
        padding_bottom: 12
      ],
      [
        text(label, text_size: 13, text_color: color(:muted), max_lines: 1, padding_bottom: 6),
        control
      ]
    )
  end

  def settings_toggle_row(name, value?, tag, props \\ []) do
    {toggle_id, props} = Keyword.pop(props, :id, id(tag))

    row(
      [
        text(name, text_size: 16, max_lines: 1),
        node(:box, weight: 1),
        node(:toggle,
          id: toggle_id,
          value: value?,
          color: color(:ink),
          on_change: {self(), tag}
        )
      ],
      Keyword.merge(
        [
          fill_width: true,
          padding_top: 12,
          padding_bottom: 12,
          padding_left: 16,
          padding_right: 16
        ],
        props
      )
    )
  end

  def settings_value_row(name, value, props \\ []) do
    row(
      [
        text(name, text_size: 16, max_lines: 1),
        node(:box, weight: 1),
        text(to_string(value || ""),
          text_size: 13,
          text_color: color(:muted),
          max_lines: 1
        )
      ],
      Keyword.merge(
        [
          fill_width: true,
          padding_top: 12,
          padding_bottom: 12,
          padding_left: 16,
          padding_right: 16
        ],
        props
      )
    )
  end

  def settings_control_row(name, control, props \\ []) do
    row(
      [
        text(name, text_size: 16, max_lines: 1),
        node(:box, weight: 1),
        control
      ],
      Keyword.merge(
        [
          fill_width: true,
          padding_top: 8,
          padding_bottom: 8,
          padding_left: 16,
          padding_right: 16
        ],
        props
      )
    )
  end

  def settings_check_row(name, checked?, tag, props \\ []) do
    row(
      [
        text(name, text_size: 16, max_lines: 1),
        node(:box, weight: 1),
        text(if(checked?, do: "✓", else: ""), text_size: 16, text_color: color(:ink))
      ],
      Keyword.merge(
        [
          fill_width: true,
          padding_top: 12,
          padding_bottom: 12,
          padding_left: 16,
          padding_right: 16,
          on_tap: {self(), tag},
          id: id(tag),
          accessibility_role: "button"
        ],
        props
      )
    )
  end

  @doc "Grouped settings row: title, current value, drill chevron."
  def settings_nav_row(name, value, tag, props \\ []) do
    quiet? = Keyword.get(props, :quiet, false)
    props = Keyword.delete(props, :quiet)
    name_color = if quiet?, do: color(:hint), else: color(:ink)

    # Do not put `weight` or `text_align` on the label/value texts. Android
    # Text with text_align applies fillMaxWidth, which in a Row collapses the
    # title to zero width and wraps it into a tall column of glyphs.
    row(
      [
        text(name, text_size: 16, text_color: name_color, max_lines: 1),
        node(:box, weight: 1),
        text(to_string(value || ""),
          text_size: 13,
          text_color: color(:muted),
          max_lines: 1
        ),
        text("›", text_size: 18, text_color: color(:hint))
      ],
      Keyword.merge(
        [
          fill_width: true,
          padding_top: 12,
          padding_bottom: 12,
          padding_left: 16,
          padding_right: 16,
          on_tap: {self(), tag},
          id: id(tag),
          accessibility_role: "button"
        ],
        props
      )
    )
  end

  def card(children, props \\ []) do
    node(:column, [fill_width: true, padding_bottom: 12], [
      node(
        :column,
        Keyword.merge(
          [
            fill_width: true,
            padding: 16,
            background: color(:card),
            border_color: color(:border),
            border_width: 1,
            corner_radius: 12
          ],
          props
        ),
        children
      )
    ])
  end

  # Mob Row has no spacing prop. Insert a real spacer node between siblings.
  def gap(size \\ 8), do: node(:spacer, size: size)

  def spaced(children) do
    children
    |> List.wrap()
    |> Enum.reject(&is_nil/1)
    |> Enum.intersperse(gap())
  end

  def actions_row(children, props \\ []) do
    row(spaced(children), Keyword.merge([padding_top: 12, padding_bottom: 4], props))
  end

  def segment_row(children, props \\ []), do: row(spaced(children), props)

  def sheet(children, opts \\ []) do
    {dismiss, opts} = Keyword.pop(opts, :dismiss, :cancel_confirm)
    {id, opts} = Keyword.pop(opts, :id, "settings-confirm")

    props =
      Keyword.merge(
        [
          id: id,
          detents: [:medium, :large],
          on_dismiss: {self(), dismiss},
          background: argb(color(:card))
        ],
        opts
      )

    Mob.UI.sheet(Enum.reject(List.wrap(children), &is_nil/1), props)
  end

  defp argb("#" <> hex), do: String.to_integer("FF" <> hex, 16)
  defp argb(other), do: other

  def field(label, value, tag, props \\ []) do
    {placeholder, props} = Keyword.pop(props, :placeholder, "")

    node(:column, [fill_width: true, padding_bottom: 12], [
      text(label, text_size: 13, text_color: color(:muted), padding_bottom: 6),
      node(
        :text_field,
        Keyword.merge(
          [
            id: id(tag),
            value: value,
            placeholder: placeholder,
            plain: true,
            background: color(:card),
            border_color: color(:border),
            border_width: 1,
            corner_radius: 8,
            padding: 10,
            fill_width: true,
            on_change: {self(), tag}
          ],
          props
        )
      )
    ])
  end

  def page(children, props \\ []),
    do:
      node(
        :column,
        Keyword.merge(
          [fill_width: true, fill_height: true, padding: 10, background: color(:surface)],
          props
        ),
        children
      )

  def scroll(children, props \\ []),
    do: node(:scroll, Keyword.merge([weight: 1, fill_width: true], props), children)

  def row(children, props \\ []),
    do: node(:row, Keyword.merge([fill_width: true, align: "center"], props), children)

  def icon(name, tag) do
    node(:icon,
      name: name,
      text: name,
      text_size: 20,
      padding: 6,
      text_color: color(:muted),
      on_tap: {self(), tag},
      id: id(tag)
    )
  end

  def notice(nil), do: nil

  def notice(%{kind: :error, text: message}) when is_binary(message) do
    text(message,
      id: "notice-error",
      fill_width: true,
      text_color: color(:danger),
      background: color(:error_surface),
      border_color: color(:danger),
      border_width: 1,
      corner_radius: 10,
      padding: 12,
      font_weight: "bold",
      accessibility_role: "alert"
    )
  end

  def notice(%{text: message}) when is_binary(message), do: notice(message)

  def notice(message),
    do: text(message, text_color: color(:muted), padding_top: 8, padding_bottom: 8)

  defp id(tag) when is_atom(tag), do: Atom.to_string(tag)
  defp id(tag), do: inspect(tag)
end
