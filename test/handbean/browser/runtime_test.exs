defmodule Handbean.Browser.RuntimeTest do
  use ExUnit.Case, async: true

  alias Handbean.Browser.Runtime

  @tag :tmp_dir
  test "resolves the packaged browser runtime before external tools", %{tmp_dir: tmp_dir} do
    name = if match?({:win32, _}, :os.type()), do: "agent-browser.exe", else: "agent-browser"
    executable = Path.join([tmp_dir, "browser-runtime", name])
    File.mkdir_p!(Path.dirname(executable))
    File.write!(executable, "fixture")

    unless match?({:win32, _}, :os.type()), do: File.chmod!(executable, 0o755)

    assert Runtime.agent_browser_executable(priv_dir: tmp_dir) == executable
  end

  @tag :tmp_dir
  test "rejects a non-executable packaged Unix runtime", %{tmp_dir: tmp_dir} do
    if match?({:win32, _}, :os.type()) do
      assert Runtime.agent_browser_executable(priv_dir: tmp_dir) == nil
    else
      executable = Path.join([tmp_dir, "browser-runtime", "agent-browser"])
      File.mkdir_p!(Path.dirname(executable))
      File.write!(executable, "fixture")
      File.chmod!(executable, 0o644)

      assert Runtime.agent_browser_executable(priv_dir: tmp_dir) == nil
    end
  end

  @tag :tmp_dir
  test "prefers the packaged unpacked extension", %{tmp_dir: tmp_dir} do
    extension = Path.join(tmp_dir, "chrome-extension")
    File.mkdir_p!(extension)
    File.write!(Path.join(extension, "manifest.json"), "{}")

    assert Runtime.chrome_extension_path(priv_dir: tmp_dir) == extension
  end
end
