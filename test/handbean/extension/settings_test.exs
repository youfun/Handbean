defmodule Handbean.Extension.SettingsTest do
  use ExUnit.Case, async: false

  alias Handbean.Extension.Settings
  alias Handbean.Plugins.Catalog

  setup do
    root = Path.join(System.tmp_dir!(), "ext-settings-#{Ecto.UUID.generate()}")
    project_dir = Path.join(root, "project")
    user_dir = Path.join(root, "user_exts")
    File.mkdir_p!(project_dir)
    File.mkdir_p!(user_dir)

    on_exit(fn -> File.rm_rf!(root) end)

    %{root: root, project_dir: project_dir, user_dir: user_dir}
  end

  test "installs template, lists extensions, inspects code, and toggles enabled state", %{
    project_dir: project_dir,
    user_dir: user_dir
  } do
    {:ok, template} = Catalog.get("cat-ext-workspace-ping")
    opts = [project: project_dir, user_home: user_dir, trusted_project?: true]

    assert {:ok, "workspace-ping"} = Settings.install_template(template, "user", opts)

    assert {:ok, [item]} = Settings.list(opts)
    assert item.name == "workspace-ping"
    assert item.source == :user
    assert item.enabled == true
    assert item.status == :enabled
    assert item.tool_count == 1

    manifest_path = Path.join(item.root, "extension.json")
    manifest_before = File.read!(manifest_path)
    assert {:error, message} = Settings.install_template(template, "user", opts)
    assert message =~ "同名扩展已存在"
    assert File.read!(manifest_path) == manifest_before

    assert {:ok, %{code: code, diagnostic: nil}} =
             Settings.inspect_extension("workspace-ping", opts)

    assert code =~ "defmodule HandbeanExt.WorkspacePing.Tool"

    assert :ok = Settings.set_enabled("workspace-ping", false, opts)
    assert {:ok, [disabled_item]} = Settings.list(opts)
    assert disabled_item.enabled == false
    assert disabled_item.status == :disabled

    assert :ok = Settings.set_enabled("workspace-ping", true, opts)
    assert {:ok, [reenabled_item]} = Settings.list(opts)
    assert reenabled_item.enabled == true
    assert reenabled_item.status == :enabled
  end

  test "lists unloaded extensions without compiling their entry", %{
    root: root,
    project_dir: project_dir,
    user_dir: user_dir
  } do
    ext_dir = Path.join([project_dir, ".handbean", "extensions", "broken-ext"])
    File.mkdir_p!(ext_dir)

    File.write!(
      Path.join(ext_dir, "extension.json"),
      Handbean.JSON.encode!(%{
        "name" => "broken-ext",
        "version" => "0.1.0",
        "entry" => "extension.ex",
        "enabled" => true
      })
    )

    marker = Path.join(root, "compiled-marker")

    File.write!(
      Path.join(ext_dir, "extension.ex"),
      "File.write!(#{inspect(marker)}, \"compiled\")\ndefmodule CompileMarker do\nend\n"
    )

    opts = [project: project_dir, user_home: user_dir, trusted_project?: true]
    assert {:ok, [item]} = Settings.list(opts)
    assert item.name == "broken-ext"
    assert item.status == :inactive
    assert is_binary(item.diagnostic)
    refute File.exists?(marker)
  end

  test "failed staged import publishes no target or staging directory", %{
    root: root,
    project_dir: project_dir,
    user_dir: user_dir
  } do
    source_dir = Path.join(root, "invalid-ext")
    File.mkdir_p!(source_dir)

    File.write!(
      Path.join(source_dir, "extension.json"),
      Handbean.JSON.encode!(%{"name" => "invalid-ext", "version" => "0.1.0"})
    )

    outside_file = Path.join(root, "outside.txt")
    File.write!(outside_file, "outside")
    File.ln_s!(outside_file, Path.join(source_dir, "linked.txt"))

    opts = [project: project_dir, user_home: user_dir, trusted_project?: true]
    assert {:error, message} = Settings.import_from_dir(source_dir, "workspace", opts)
    assert message =~ "符号链接"

    handbean_dir = Path.join(project_dir, ".handbean")
    extensions_dir = Path.join(handbean_dir, "extensions")
    refute File.exists?(Path.join(extensions_dir, "invalid-ext"))

    if File.dir?(handbean_dir) do
      refute Enum.any?(File.ls!(handbean_dir), &String.starts_with?(&1, ".extension-stage-"))
    end
  end

  test "imports extension from local directory and rejects symlinks", %{
    root: root,
    project_dir: project_dir,
    user_dir: user_dir
  } do
    source_dir = Path.join(root, "custom-ext")
    File.mkdir_p!(source_dir)

    File.write!(
      Path.join(source_dir, "extension.json"),
      Handbean.JSON.encode!(%{
        "name" => "custom-ext",
        "version" => "0.2.0",
        "description" => "Imported extension",
        "entry" => "extension.ex"
      })
    )

    File.write!(
      Path.join(source_dir, "extension.ex"),
      "defmodule HandbeanExt.CustomExt do\nend\n"
    )

    File.mkdir_p!(Path.join(source_dir, "assets"))
    File.write!(Path.join(source_dir, "assets/config.json"), ~s({"enabled":true}))

    opts = [project: project_dir, user_home: user_dir, trusted_project?: true]
    assert {:ok, "custom-ext"} = Settings.import_from_dir(source_dir, "workspace", opts)
    assert {:ok, [item]} = Settings.list(opts)
    assert item.name == "custom-ext"
    assert item.source == :project
    assert File.read!(Path.join(item.root, "assets/config.json")) == ~s({"enabled":true})

    assert {:error, message} = Settings.import_from_dir(source_dir, "workspace", opts)
    assert message =~ "同名扩展已存在"
    assert File.read!(Path.join(item.root, "extension.ex")) =~ "HandbeanExt.CustomExt"

    symlink_dir = Path.join(root, "symlink-ext")
    File.ln_s!(source_dir, symlink_dir)
    assert {:error, _} = Settings.import_from_dir(symlink_dir, "workspace", opts)
  end
end
