defmodule Handbean.WorkspaceFiles.ClassifyTest do
  use ExUnit.Case, async: true

  alias Handbean.WorkspaceFiles

  test "routes from the display name without opening bytes" do
    assert {:ok, :image, "image/png"} = WorkspaceFiles.kind_from_name("x.png")
    assert {:ok, :external, "application/pdf"} = WorkspaceFiles.kind_from_name("doc.pdf")
    assert {:ok, :text, "text/html"} = WorkspaceFiles.kind_from_name("page.html")
    assert {:ok, :text, "text/markdown"} = WorkspaceFiles.kind_from_name("README.md")
    assert {:ok, :text, "text/plain"} = WorkspaceFiles.kind_from_name("LICENSE")
    assert {:ok, :text, "text/plain"} = WorkspaceFiles.kind_from_name("mod.ex")
  end
end
