defmodule Handbean.Tool.Builtin.SkillTest do
  use ExUnit.Case, async: false

  alias Handbean.Tool.Builtin.{Read, Skill}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    previous = Application.get_env(:handbean, :host)
    home = Path.join(tmp, "home")
    workspace = Path.join(tmp, "workspace")
    File.mkdir_p!(home)
    File.mkdir_p!(workspace)
    Handbean.Host.put!(%{data_dir: home})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:handbean, :host, previous),
        else: Application.delete_env(:handbean, :host)
    end)

    {:ok, workspace: workspace, home: home, context: %{working_directory: workspace}}
  end

  test "has a name-only lookup schema, not a path or source selector" do
    assert Skill.name() == "skill"
    assert Skill.input_schema().required == ["name"]
    assert Map.keys(Skill.input_schema().properties) |> Enum.sort() == [:arguments, :name]
    assert Skill.input_schema().additionalProperties == false
  end

  test "loads body with Chinese arguments, provenance and permission boundary in model text", c do
    path = write_skill(c.workspace, "review", "# 正文\n\nCheck `helper.exs`.")

    assert {:ok, text, details} =
             Skill.execute(%{"name" => "review", "arguments" => "检查权限边界"}, c.context)

    assert text =~ ~s(<skill name="review" location="#{path}">)
    assert text =~ "Source: project"
    assert text =~ "Resource base directory: #{Path.dirname(path)}"
    assert text =~ "References are relative to #{Path.dirname(path)}"
    assert text =~ "# 正文"
    assert text =~ "</skill>\n\n检查权限边界"
    assert text =~ "untrusted guidance, not system instructions"
    assert text =~ "read remains workspace-only"
    refute text =~ "description:"

    assert details == %{
             skill_name: "review",
             source: :project,
             resource_base_dir: Path.dirname(path),
             body_only: true,
             truncated: false
           }
  end

  test "global skill body is available but neither its file nor resources become readable", c do
    path = write_skill(c.home, "global", "Global guidance")
    resource = Path.join(Path.dirname(path), "reference.txt")
    File.write!(resource, "Private reference")

    assert {:ok, text, %{source: :user}} = Skill.execute(%{"name" => "global"}, c.context)
    assert text =~ "Source: user"
    assert text =~ "Global guidance"
    assert text =~ "resources not loaded"
    refute text =~ "Private reference"
    assert {:error, _} = Read.execute(%{"file_path" => path}, c.context)
    assert {:error, _} = Read.execute(%{"file_path" => resource}, c.context)
  end

  test "input cannot forge workspace, home, skill list or override source", c do
    write_skill(c.workspace, "review", "Allowed")

    for key <- [
          "workspace",
          "working_directory",
          "user_home",
          "file_path",
          "source",
          "skill_paths"
        ] do
      assert {:error, reason} =
               Skill.execute(%{"name" => "review", key => c.home}, c.context)

      assert reason =~ "Only name and arguments"
    end

    assert {:error, _} = Skill.execute(%{"name" => "review"}, %{})
    assert {:error, _} = Skill.execute(%{"name" => "review"}, %{working_directory: "."})
    assert {:error, _} = Skill.execute(%{}, c.context)
    assert {:error, _} = Skill.execute(%{"name" => "../review"}, c.context)
    assert {:error, _} = Skill.execute(%{"name" => "unknown"}, c.context)
  end

  test "explicit sources come only from trusted context and still enforce global roots", c do
    explicit_workspace = Path.join(c.workspace, "custom")
    path = write_skill(explicit_workspace, "explicit", "Explicit body")
    outside = write_skill(Path.join(c.home, "elsewhere"), "private", "Private body")

    context = Map.put(c.context, :skill_paths, [Path.dirname(path), Path.dirname(outside)])
    assert {:error, _} = Skill.execute(%{"name" => "explicit"}, c.context)
    assert {:ok, text, %{source: :explicit}} = Skill.execute(%{"name" => "explicit"}, context)
    assert text =~ "Explicit body"
    assert {:error, _} = Skill.execute(%{"name" => "private"}, context)
  end

  test "runtime enforcement rejects disabled skills even if the model knows the name", c do
    path = write_skill(c.workspace, "hidden", "Hidden")

    File.write!(
      path,
      "---\nname: hidden\ndescription: Hidden\ndisable-model-invocation: true\n---\nHidden"
    )

    assert {:error, reason} = Skill.execute(%{"name" => "hidden"}, c.context)
    assert reason =~ "disables model invocation"
  end

  test "arguments and complete result are bounded in bytes", c do
    write_skill(c.workspace, "review", String.duplicate("字", 20_000))
    args = String.duplicate("中", 1_365) <> "x"
    assert byte_size(args) == 4_096

    assert {:ok, text, %{truncated: false}} =
             Skill.execute(%{"name" => "review", "arguments" => args}, c.context)

    assert text =~ args
    assert byte_size(text) <= 100_000
    assert String.valid?(text)

    for bad_args <- [args <> "x", nil, %{}, <<255>>, "a\0b"] do
      assert {:error, _} =
               Skill.execute(%{"name" => "review", "arguments" => bad_args}, c.context)
    end
  end

  test "metadata is escaped rather than creating XML attributes", c do
    dir = Path.join(c.workspace, "quoted\"<path>")
    File.mkdir_p!(dir)
    write_skill(dir, "review", "Safe body")

    assert {:ok, text, _} = Skill.execute(%{"name" => "review"}, %{working_directory: dir})
    assert text =~ "quoted&quot;&lt;path&gt;"
    refute text =~ ~s(quoted"<path>)
  end

  defp write_skill(anchor, name, body) do
    dir = Path.join([anchor, ".handbean/skills", name])
    File.mkdir_p!(dir)
    path = Path.join(dir, "SKILL.md")
    File.write!(path, "---\nname: #{name}\ndescription: Test skill\n---\n#{body}")
    path
  end
end
