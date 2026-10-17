defmodule HandbeanWeb.UiClasses do
  @moduledoc """
  Centralized UI class strings — single source of truth for component styling.

  Inspired by howcode's `src/app/ui/classes.ts` pattern.
  All reusable CSS class combinations are defined here.
  Components reference these functions instead of inlining class strings.

  ## Naming convention

    * `*_class` → single-element style (e.g. `icon_button_class`)
    * `*_classes` → multi-element or conditional (e.g. `button_classes/1`)

  ## Usage

      <button class={UiClasses.primary_button_class()}>Save</button>

  ## Customization

  Never override class ordering at call sites — edit the definition here
  and the change propagates everywhere.
  """

  # ── Transition ────────────────────────────────────────────────────────

  @doc "Standard color/background transition used by interactive elements."
  def transition_class, do: "transition-colors duration-150 ease-out"

  # ── Surfaces (panels / cards / containers) ────────────────────────────

  @doc "Default panel surface — rounded, bordered, shadowed."
  def panel_class do
    "rounded-2xl border border-[color:var(--border)] bg-[color:var(--panel)] shadow-[var(--shadow)]"
  end

  @doc "Floating panel (popover / dropdown) surface."
  def popover_panel_class do
    "border border-[color:var(--border-hover)] bg-[color:var(--panel)] shadow-[var(--shadow)]"
  end

  @doc "Main scrollable content panel."
  def main_panel_class do
    "min-h-0 overflow-y-auto overflow-x-hidden pt-1.5 [scrollbar-gutter:stable_both-edges]"
  end

  @doc "View shell — centered content area with padding."
  def view_shell_class do
    "mx-auto grid h-full w-full content-start gap-4 px-2 pt-6 pb-6"
  end

  @doc "Settings / form section surface."
  def section_shell_class do
    "grid gap-3 rounded-xl border border-[color:var(--border)] bg-[rgba(255,255,255,0.02)] p-3"
  end

  # ── Buttons ───────────────────────────────────────────────────────────

  @doc "Primary action button — rounded-full, accent-colored."
  def primary_button_class do
    "min-h-8 rounded-full border border-[color:var(--accent-border)] bg-[color:var(--accent-bg)] px-4 text-xs font-medium text-[color:var(--text)] transition-colors duration-150 ease-out hover:border-[color:var(--accent)] hover:bg-[color:var(--accent-bg-strong)] disabled:cursor-not-allowed disabled:border-transparent disabled:bg-[color:var(--panel)] disabled:text-[color:var(--muted-2)]"
  end

  @doc "Icon-only button — square, transparent bg, hover reveal."
  def icon_button_class do
    "inline-flex h-7 w-7 items-center justify-center rounded-lg border border-transparent bg-transparent text-[color:var(--muted)] transition-colors duration-150 ease-out hover:bg-[color:var(--surface-hover)] hover:text-[color:var(--text)]"
  end

  @doc "Compact icon button — smaller (`h-6 w-6`)."
  def compact_icon_button_class do
    "inline-flex h-6 w-6 items-center justify-center rounded-md text-[color:var(--muted)] transition-colors duration-150 ease-out hover:bg-[color:var(--surface-hover)] hover:text-[color:var(--text)]"
  end

  @doc "Toolbar button — inline-flex with gap and text label."
  def toolbar_button_class do
    "inline-flex min-h-7 items-center gap-1.5 rounded-lg border border-transparent px-1.5 text-[12.5px] leading-5 text-[color:var(--muted)] transition-colors duration-150 ease-out hover:bg-[color:var(--surface-hover)] hover:text-[color:var(--text)]"
  end

  @doc "Ghost-style button — minimal chrome."
  def ghost_button_class do
    "rounded-[10px] border border-transparent px-2 py-1 text-[12.5px] leading-5 text-[color:var(--muted)] transition-colors duration-150 ease-out hover:bg-[color:var(--surface-hover)] hover:text-[color:var(--text)]"
  end

  @doc "Composer text action button (settings-control-text style)."
  def composer_text_button_class do
    "settings-control-text inline-flex h-7 items-center justify-center gap-1.5 rounded-md border border-[color:var(--border)] bg-[color:var(--panel)] px-3 font-medium text-[color:var(--text)] transition-colors duration-150 ease-out hover:border-[color:var(--accent-border)] hover:bg-[color:var(--accent-bg)] disabled:cursor-not-allowed disabled:border-transparent disabled:bg-[color:var(--panel)] disabled:text-[color:var(--muted-2)]"
  end

  # ── Menu items ────────────────────────────────────────────────────────

  @doc "Menu item — full-width row with icon + label."
  def menu_item_class do
    "flex items-center gap-2.5 rounded-xl border border-transparent px-2.5 py-2 text-left text-sm"
  end

  @doc "Menu option — checkmark + label grid pattern."
  def menu_option_class do
    "grid grid-cols-[16px_minmax(0,1fr)] items-center gap-2 rounded-xl px-2.5 py-2 text-left text-xs hover:bg-[color:var(--surface-hover)]"
  end

  # ── Text / Typography ─────────────────────────────────────────────────

  @doc "View title (h1)."
  def view_title_class do
    "m-0 text-lg font-medium text-[color:var(--text)]"
  end

  @doc "View subtitle."
  def view_subtitle_class do
    "m-0 text-xs text-[color:var(--muted)]"
  end

  @doc "Section intro container — title + description group."
  def section_intro_class do
    "grid gap-1"
  end

  @doc "Section title."
  def section_title_class do
    "m-0 text-[15px] font-medium text-[color:var(--text)]"
  end

  @doc "Section description."
  def section_description_class do
    "m-0 text-xs text-[color:var(--muted)]"
  end

  @doc "Inline code span."
  def inline_code_class do
    "rounded-md bg-[color:var(--message-code-bg)] px-1.5 py-0.5 font-mono text-[11.5px] break-all text-[color:var(--text)]"
  end

  # ── Layout ────────────────────────────────────────────────────────────

  @doc "Content max-width constraint class."
  def workspace_content_max_width_class, do: "max-w-[800px]"

  @doc "Chrome max-width constraint class."
  def workspace_chrome_max_width_class, do: "max-w-[880px]"

  # ── Interactive / Feedback ────────────────────────────────────────────

  @doc "Standard hover surface treatment."
  def hover_surface_class do
    "hover:bg-[color:var(--surface-hover)] hover:text-[color:var(--text)]"
  end

  @doc "Segmented control group wrapper."
  def segmented_control_class do
    "inline-flex rounded-full border border-[color:var(--border)] bg-[color:var(--panel)] p-1"
  end

  @doc "Segmented control option."
  def segmented_control_option_class do
    "rounded-full px-3 py-1 text-xs capitalize transition-colors"
  end

  @doc "Empty state card — dashed border, muted text."
  def empty_state_card_class do
    "rounded-xl border border-dashed border-[color:var(--border)] px-3 py-4 text-xs text-[color:var(--muted)]"
  end

  @doc "Interactive card style."
  def interactive_card_class do
    "rounded-2xl border border-[color:var(--border)] bg-[color:var(--panel)] text-left shadow-[var(--shadow)] transition-colors duration-150 ease-out hover:bg-[color:var(--panel-2)]"
  end

  @doc "Feature card — interactive card + grid layout."
  def feature_card_class do
    "#{interactive_card_class()} grid min-h-[160px] gap-3.5 p-[18px]"
  end

  @doc "Disclosure toggle button style."
  def disclosure_button_class do
    "inline-flex items-center gap-1.5 text-left text-xs font-medium text-[color:var(--text)]"
  end

  @doc "Confirm popover shell (e.g. delete confirmation)."
  def confirm_popover_class do
    "motion-popover absolute top-[calc(100%+6px)] right-0 z-20 flex items-center gap-1 rounded-xl p-1"
  end

  # ── Settings / Form ───────────────────────────────────────────────────

  @doc "Settings list row."
  def settings_list_row_class do
    "grid grid-cols-[minmax(0,1fr)_auto] items-center gap-3 rounded-xl border border-[color:var(--border)] bg-[rgba(255,255,255,0.02)] px-3 py-2"
  end

  @doc "Settings compact list row."
  def settings_compact_list_row_class do
    "grid h-9 grid-cols-[minmax(0,1fr)_auto] items-center gap-1.5 rounded-xl border border-[color:var(--border)] bg-[rgba(255,255,255,0.02)] px-2.5"
  end

  @doc "Settings select button."
  def settings_select_button_class do
    "grid w-full grid-cols-[minmax(0,1fr)_auto] items-center gap-3 rounded-xl border border-[color:var(--border)] bg-[rgba(255,255,255,0.02)] px-3 py-2.5 text-left transition-colors hover:bg-[rgba(255,255,255,0.04)]"
  end

  @doc "Settings text input."
  def settings_input_class do
    "settings-control-text min-w-0 flex-1 rounded-xl border border-[color:var(--border)] bg-[rgba(255,255,255,0.02)] px-3 py-2 text-[color:var(--text)] outline-none placeholder:text-[color:var(--muted)]"
  end

  # ── Disabled state ────────────────────────────────────────────────────

  @doc "Disabled button visual treatment."
  def icon_button_disabled_class do
    "disabled:cursor-not-allowed disabled:bg-transparent disabled:text-[color:var(--muted)] disabled:opacity-40"
  end

  # ── Compact meta row ──────────────────────────────────────────────────

  @doc "Compact metadata row actions container."
  def compact_meta_row_actions_class do
    "flex items-center gap-0.5"
  end

  # ── Terminal ──────────────────────────────────────────────────────────

  @doc "Terminal output container style."
  def terminal_output_class do
    "grid min-h-[92px] gap-2 rounded-[14px] border border-[color:var(--border)] bg-[color:var(--bg)] p-2.5 font-mono text-xs"
  end

  # ── Diff ──────────────────────────────────────────────────────────────

  @doc "Diff panel empty state."
  def diff_empty_state_class do
    "flex min-h-60 items-center justify-center px-5 text-center text-xs text-[color:var(--muted)]"
  end

  @doc "Diff panel icon button."
  def diff_icon_button_class do
    "inline-flex h-7 w-7 items-center justify-center rounded-lg border text-[color:var(--muted)] transition-colors hover:bg-[rgba(255,255,255,0.04)] hover:text-[color:var(--text)]"
  end

  # ── Utility ───────────────────────────────────────────────────────────

  @doc "Clip-path conditional join — combines class lists, dropping nils."
  def cn(classes) when is_list(classes),
    do: classes |> List.flatten() |> Enum.reject(&is_nil/1) |> Enum.join(" ")
end
