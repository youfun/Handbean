defmodule HandbeanWeb.ConversationHoverTest do
  use ExUnit.Case, async: true

  alias HandbeanWeb.WorkspaceLive.{ConversationSwitching, ViewComponents}

  test "short relative time uses the compact hover format" do
    now = DateTime.utc_now()

    assert ViewComponents.short_relative_time(%{updated_at: iso(now, -30)}) == "now"
    assert ViewComponents.short_relative_time(%{updated_at: iso(now, -120)}) == "2m"
    assert ViewComponents.short_relative_time(%{updated_at: iso(now, -7_200)}) == "2h"
    assert ViewComponents.short_relative_time(%{updated_at: iso(now, -86_400 * 5)}) == "5d"
    assert ViewComponents.short_relative_time(%{updated_at: iso(now, -86_400 * 90)}) == "3mo"
    assert ViewComponents.short_relative_time(%{}) == ""
  end

  test "hover context uses the conversation checkout and exposes its absolute path" do
    dir = Path.join(System.tmp_dir!(), "handbean-hover-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    context =
      ConversationSwitching.hover_context(%{
        "id" => "conversation",
        "workspace_id" => "ws",
        "checkout_path" => dir
      })

    assert context.folder == Path.basename(dir)
    assert context.branch == nil
    assert context.path == dir
    assert context.available

    File.rm_rf!(dir)
    unavailable = ConversationSwitching.hover_context(%{"checkout_path" => dir})
    assert unavailable.folder == Path.basename(dir)
    assert unavailable.path == dir
    refute unavailable.available
    assert unavailable.branch == nil

    assert ConversationSwitching.hover_context(nil) == %{
             folder: nil,
             branch: nil,
             path: nil,
             available: false
           }
  end

  test "repo name is absent when the path is not a repository" do
    assert ConversationSwitching.repo_name(nil) == nil
  end

  defp iso(now, offset_seconds) do
    now |> DateTime.add(offset_seconds, :second) |> DateTime.to_iso8601()
  end
end
