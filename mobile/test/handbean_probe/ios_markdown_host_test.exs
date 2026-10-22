defmodule HandbeanProbe.IosMarkdownHostTest do
  use ExUnit.Case, async: true

  @mob_ios Path.expand("deps/mob/ios")
  @script Path.expand("ios/patch_markdown_host.sh")

  test "forwards markdown props and routes assistant text to the native renderer" do
    if not (File.dir?(@mob_ios) and File.exists?(@script)) do
      flunk("iOS markdown patch needs deps/mob/ios and ios/patch_markdown_host.sh")
    end

    out = Path.join(System.tmp_dir!(), "handbean-md-#{System.unique_integer([:positive])}")
    File.mkdir_p!(out)

    {_, 0} =
      System.cmd("bash", [
        @script,
        @mob_ios,
        Path.join(out, "MobNode.h"),
        Path.join(out, "MobNode.m"),
        Path.join(out, "mob_nif.m"),
        Path.join(out, "MobRootView.swift")
      ])

    header = File.read!(Path.join(out, "MobNode.h"))
    assert header =~ "@property(nonatomic) BOOL markdown;"
    assert header =~ "@property(nonatomic) BOOL markdownStreaming;"

    nif = File.read!(Path.join(out, "mob_nif.m"))
    assert nif =~ ~s([MOB_PROP_markdown] = @"markdown")
    assert nif =~ ~s([MOB_PROP_markdown_streaming] = @"markdown_streaming")
    assert nif =~ "node.markdown = [markdown boolValue];"
    assert nif =~ "node.markdownStreaming = [markdownStreaming boolValue];"

    root = File.read!(Path.join(out, "MobRootView.swift"))
    assert root =~ ~s(case "folder":        return "folder")
    assert root =~ ~s(case "expand_more":   return "chevron.down")
    assert root =~ ~s(case "expand_less":   return "chevron.up")
    assert root =~ "HandbeanMarkdownText("
    assert root =~ "streaming: node.markdownStreaming"
    assert root =~ "Text(node.text ?? \"\")"
    assert root =~ "private var mobNodeColumn: some View"
    assert root =~ "case .column:\n                mobNodeColumn"
    assert root =~ "#if compiler(>=6.2)"
    assert root =~ "self.glassEffect(.clear.tint(fill), in: shape)"

    File.rm_rf!(out)
  end
end
