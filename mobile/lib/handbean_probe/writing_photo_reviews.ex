defmodule HandbeanProbe.WritingPhotoReviews do
  @moduledoc """
  Packed review skill: read APK/Mix priv each send, never copy to Home.
  """

  use Gettext, backend: HandbeanProbe.Gettext

  @skill_rel "skills/writing-photo-reviews/SKILL.md"
  @max_share_chars 100_000

  def skill_rel, do: @skill_rel
  def max_share_chars, do: @max_share_chars

  @doc "Authoritative path under `Handbean.Host.priv_dir/0`."
  def skill_path do
    Path.join(Handbean.Host.priv_dir(), @skill_rel)
  end

  @doc """
  Read and strip frontmatter. Host priv first (packed APK). Mix tests may
  fall back to the `:handbean_probe` app priv when Host still points at `:handbean`.
  """
  def load_instructions(opts \\ []) do
    paths =
      Keyword.get_lazy(opts, :paths, fn ->
        [skill_path() | mix_fallback_paths()]
      end)

    paths
    |> Enum.uniq()
    |> Enum.find_value({:error, {:skill_unavailable, :enoent}}, fn path ->
      case File.read(path) do
        {:ok, content} ->
          body = strip_frontmatter(content)

          if body == "" do
            {:error, {:skill_unavailable, :empty}}
          else
            {:ok, body}
          end

        {:error, :enoent} ->
          nil

        {:error, reason} ->
          {:error, {:skill_unavailable, reason}}
      end
    end)
  end

  def compose_user_text(assigns) when is_map(assigns) do
    place = trim_field(Map.get(assigns, :review_place))
    feeling = trim_field(Map.get(assigns, :review_feeling))
    draft = trim_field(Map.get(assigns, :draft))

    [
      if(place != "", do: gettext("Place: %{place}", place: place)),
      if(feeling != "", do: gettext("What I actually experienced: %{feeling}", feeling: feeling)),
      if(draft != "", do: draft)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  def shareable_text(text) when is_binary(text) do
    trimmed = String.trim(text)

    cond do
      trimmed == "" ->
        {:error, :empty}

      String.length(trimmed) > @max_share_chars ->
        {:error, :too_long}

      true ->
        {:ok, trimmed}
    end
  end

  def shareable_text(_), do: {:error, :empty}

  def strip_frontmatter(content) when is_binary(content) do
    case String.split(content, "\n---\n", parts: 2) do
      [_, body] -> String.trim(body)
      _ -> String.trim(content)
    end
  end

  defp mix_fallback_paths do
    probe = Application.app_dir(:handbean_probe, Path.join("priv", @skill_rel))
    if probe == skill_path(), do: [], else: [probe]
  end

  defp trim_field(value) when is_binary(value), do: String.trim(value)
  defp trim_field(_), do: ""
end
