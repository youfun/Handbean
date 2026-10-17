defmodule HandbeanProbe.WritingPhotoReviewsTest do
  use ExUnit.Case, async: false
  use Gettext, backend: HandbeanProbe.Gettext

  alias HandbeanProbe.WritingPhotoReviews

  test "loads packed skill body without frontmatter" do
    assert {:ok, body} = WritingPhotoReviews.load_instructions()
    refute body =~ "disable-model-invocation"
    assert body =~ "Writing photo reviews"
    assert body =~ "Visible facts"
    refute body =~ "---"
    assert length(String.split(body, "\n")) < 500
  end

  test "compose_user_text keeps place and feeling in the user-visible body" do
    text =
      WritingPhotoReviews.compose_user_text(%{
        review_place: " 分店A ",
        review_feeling: "牛肉有点老",
        draft: "等位半小时"
      })

    assert text ==
             gettext("Place: %{place}", place: "分店A") <>
               "\n" <>
               gettext("What I actually experienced: %{feeling}", feeling: "牛肉有点老") <>
               "\n等位半小时"
  end

  test "load_instructions fails honestly when no packed file exists" do
    assert {:error, {:skill_unavailable, :enoent}} =
             WritingPhotoReviews.load_instructions(paths: ["/definitely/missing/SKILL.md"])
  end

  test "shareable_text rejects empty and oversized payloads" do
    assert {:error, :empty} = WritingPhotoReviews.shareable_text("  ")
    assert {:ok, "ok"} = WritingPhotoReviews.shareable_text(" ok ")

    too_long = String.duplicate("a", WritingPhotoReviews.max_share_chars() + 1)
    assert {:error, :too_long} = WritingPhotoReviews.shareable_text(too_long)
  end
end
