defmodule Handbean.Skills.Expander do
  @moduledoc """
  Expands `/skill:name` shortcut syntax into full SKILL.md content.

  Parses user input for `/skill:<name> [args]` patterns, reads the
  corresponding SKILL.md from disk, strips frontmatter, and wraps the
  body in a `<skill>` XML block. Unknown skills and read errors pass
  through unchanged (no errors thrown).
  """

  require Logger

  @skill_prefix "/skill:"

  @doc """
  Expand skill shortcuts in a text string.

  Returns the expanded text, or the original text if no skill shortcut
  was found or the skill could not be loaded.
  """
  @spec expand(String.t(), [Handbean.Skills.Skill.t()]) :: String.t()
  def expand(text, skills) when is_binary(text) and is_list(skills) do
    case parse_skill_command(text) do
      {:match, skill_name, args} ->
        expand_skill(skill_name, args, text, skills)

      :no_match ->
        text
    end
  end

  @doc """
  Parse a skill command from text.

  Returns:
  - `{:match, skill_name, args}` — `/skill:` found at start of text
  - `:no_match` — no skill command detected
  """
  @spec parse_skill_command(String.t()) :: {:match, String.t(), String.t()} | :no_match
  def parse_skill_command(text) when is_binary(text) do
    cond do
      not String.starts_with?(text, @skill_prefix) ->
        :no_match

      text == @skill_prefix ->
        :no_match

      true ->
        prefix_len = byte_size(@skill_prefix)
        rest = binary_part(text, prefix_len, byte_size(text) - prefix_len)

        case rest do
          <<>> ->
            :no_match

          skill_and_args ->
            case String.split(skill_and_args, " ", parts: 2) do
              [""] ->
                :no_match

              [skill_name] ->
                {:match, skill_name, ""}

              [skill_name, args] ->
                {:match, skill_name, String.trim(args)}
            end
        end
    end
  end

  # ── Internal ──

  defp expand_skill(skill_name, args, original_text, skills) do
    case Enum.find(skills, &(&1.name == skill_name)) do
      nil ->
        Logger.debug("[Skills] unknown skill \"#{skill_name}\", passing through")
        original_text

      %Handbean.Skills.Skill{location: location, base_dir: base_dir} = _skill ->
        case File.read(location) do
          {:ok, content} ->
            result = format_content(skill_name, location, base_dir, content, args)
            Logger.debug("[Skills] expanded /skill:#{skill_name} -> #{byte_size(result)} bytes")
            result

          {:error, reason} ->
            Logger.warning(
              "[Skills] failed to read SKILL.md for \"#{skill_name}\": #{inspect(reason)}"
            )

            original_text
        end
    end
  end

  @doc false
  def format_content(name, location, base_dir, content, args) do
    body = strip_frontmatter(content)
    skill_block = build_skill_block(name, location, base_dir, body)
    if args != "", do: skill_block <> "\n\n" <> args, else: skill_block
  end

  defp build_skill_block(name, location, base_dir, body) do
    """
    <skill name="#{name}" location="#{location}">
    References are relative to #{base_dir}.

    #{body}
    </skill>
    """
    |> String.trim_trailing()
  end

  defp strip_frontmatter(content) do
    case String.split(content, "\n---\n", parts: 2) do
      [_, body] ->
        String.trim(body)

      _ ->
        String.trim(content)
    end
  end
end
