defmodule Handbean.Agent.SkillsIntegrationTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]

  setup %{tmp_dir: tmp_dir} do
    previous_home = System.get_env("HOME")
    System.put_env("HOME", tmp_dir)

    on_exit(fn ->
      if previous_home do
        System.put_env("HOME", previous_home)
      else
        System.delete_env("HOME")
      end
    end)

    :ok
  end

  defp write_skill(dir, name, description) do
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "SKILL.md"), """
    ---
    name: #{name}
    description: #{description}
    ---

    # #{name}

    Detailed skill body should stay on disk.
    """)
  end

  defp run_agent(prompt, opts) do
    {result, _log} = with_log(fn -> Handbean.Agent.run(prompt, opts) end)
    result
  end

  @tag :tmp_dir
  test "skills: true injects explicit skill path into provider-visible system prompt", %{
    tmp_dir: tmp_dir
  } do
    skill_dir = Path.join(tmp_dir, "review-helper")
    write_skill(skill_dir, "review-helper", "Review code for regressions")

    {:ok, state} =
      run_agent("hello",
        provider: Handbean.TestSupport.FakeProvider,
        model: "fake",
        provider_config: %{scenario: :simple_answer, notify: self()},
        working_directory: tmp_dir,
        skills: true,
        skill_paths: [skill_dir]
      )

    assert_receive {:provider_config, provider_config}
    system_prompt = provider_config.system_prompt

    assert state.status == :completed
    assert system_prompt =~ "<available_skills>"
    assert system_prompt =~ "<name>review-helper</name>"
    assert system_prompt =~ "<description>Review code for regressions</description>"
    assert system_prompt =~ Path.join(skill_dir, "SKILL.md")
    refute system_prompt =~ "Detailed skill body should stay on disk"
  end

  @tag :tmp_dir
  test "skills: false does not inject skills even when skill_paths are provided", %{
    tmp_dir: tmp_dir
  } do
    skill_dir = Path.join(tmp_dir, "review-helper")
    write_skill(skill_dir, "review-helper", "Review code for regressions")

    {:ok, state} =
      run_agent("hello",
        provider: Handbean.TestSupport.FakeProvider,
        model: "fake",
        provider_config: %{scenario: :simple_answer, notify: self()},
        working_directory: tmp_dir,
        skills: false,
        skill_paths: [skill_dir]
      )

    assert_receive {:provider_config, provider_config}
    system_prompt = provider_config.system_prompt

    assert state.status == :completed
    refute system_prompt =~ "<available_skills>"
    refute system_prompt =~ "review-helper"
    refute system_prompt =~ "Review code for regressions"
  end

  @tag :tmp_dir
  test "explicit system_prompt skips skills unless explicitly allowed", %{tmp_dir: tmp_dir} do
    skill_dir = Path.join(tmp_dir, "review-helper")
    write_skill(skill_dir, "review-helper", "Review code for regressions")

    {:ok, state} =
      run_agent("hello",
        provider: Handbean.TestSupport.FakeProvider,
        model: "fake",
        provider_config: %{scenario: :simple_answer, notify: self()},
        working_directory: tmp_dir,
        system_prompt: "Custom prompt",
        skills: true,
        skill_paths: [skill_dir]
      )

    assert_receive {:provider_config, provider_config}

    assert state.status == :completed

    # Not full equality: a context-editing provider (FakeProvider) also gets
    # the ModelContext protocol appended to the custom prompt. The intent of
    # this test is that skills stay out of an explicit system_prompt.
    assert String.starts_with?(provider_config.system_prompt, "Custom prompt")

    refute provider_config.system_prompt =~ "<available_skills>"
    refute provider_config.system_prompt =~ "review-helper"
  end

  @tag :tmp_dir
  test "explicit opt can inject skills into custom system_prompt", %{tmp_dir: tmp_dir} do
    skill_dir = Path.join(tmp_dir, "review-helper")
    write_skill(skill_dir, "review-helper", "Review code for regressions")

    {:ok, state} =
      run_agent("hello",
        provider: Handbean.TestSupport.FakeProvider,
        model: "fake",
        provider_config: %{scenario: :simple_answer, notify: self()},
        working_directory: tmp_dir,
        system_prompt: "Custom prompt",
        skills: true,
        inject_skills_into_custom_prompt: true,
        skill_paths: [skill_dir]
      )

    assert_receive {:provider_config, provider_config}

    assert state.status == :completed
    assert provider_config.system_prompt =~ "Custom prompt"
    assert provider_config.system_prompt =~ "<name>review-helper</name>"
  end

  @tag :tmp_dir
  test "explicit skill path overlapping default discovery is not duplicated", %{tmp_dir: tmp_dir} do
    skill_dir = Path.join(tmp_dir, ".handbean/skills/review-helper")
    write_skill(skill_dir, "review-helper", "Review code for regressions")

    {:ok, state} =
      run_agent("hello",
        provider: Handbean.TestSupport.FakeProvider,
        model: "fake",
        provider_config: %{scenario: :simple_answer, notify: self()},
        working_directory: tmp_dir,
        skills: true,
        skill_paths: [skill_dir]
      )

    assert_receive {:provider_config, provider_config}

    assert state.status == :completed
    assert provider_config.system_prompt =~ "<name>review-helper</name>"

    assert provider_config.system_prompt |> String.split("<name>review-helper</name>") |> length() ==
             2
  end

  @tag :tmp_dir
  test "bad skill path or invalid skill does not break Agent.run", %{tmp_dir: tmp_dir} do
    bad_skill_dir = Path.join(tmp_dir, "bad-skill")
    File.mkdir_p!(bad_skill_dir)

    File.write!(Path.join(bad_skill_dir, "SKILL.md"), """
    ---
    name: bad-skill
    ---

    # Missing description
    """)

    missing_dir = Path.join(tmp_dir, "missing-skill")

    {result, log} =
      with_log(fn ->
        Handbean.Agent.run("hello",
          provider: Handbean.TestSupport.FakeProvider,
          model: "fake",
          provider_config: %{scenario: :simple_answer},
          working_directory: tmp_dir,
          skills: true,
          skill_paths: [missing_dir, bad_skill_dir]
        )
      end)

    assert {:ok, state} = result
    assert state.status == :completed
    refute state.config.system_prompt =~ "<available_skills>"
    assert log =~ "description is required"
  end
end
