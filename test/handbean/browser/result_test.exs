defmodule Handbean.Browser.ResultTest do
  @moduledoc """
  Tests for structured agent-browser result parsing.

  Artifacts are accepted only inside the conversation artifact dir.
  Failures stay machine-readable so the model can recover without
  parsing prose.
  """

  use ExUnit.Case, async: true

  alias Handbean.Browser.Result

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "handbean_browser_result_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  defp raw(overrides) do
    Map.merge(
      %{stdout: "", stderr: "", exit_code: 0, timed_out: false},
      overrides
    )
  end

  describe "parse/2 — success" do
    test "uses upstream text on zero-exit JSON" do
      stdout = Jason.encode!(%{"text" => "Example Domain", "url" => "https://example.com/"})

      parsed = Result.parse(raw(%{stdout: stdout}), [])

      assert parsed.content == "Example Domain"
      assert parsed.details.result_category == "success"
      refute parsed.details.failure_category
      assert parsed.details.artifacts == []
    end

    test "unwraps agent-browser 0.33 success/data/error envelopes" do
      stdout =
        Jason.encode!(%{
          "success" => true,
          "data" => %{
            "title" => "Example Domain",
            "url" => "https://example.com/",
            "lifecycle" => %{"reused" => true}
          },
          "error" => nil
        })

      parsed = Result.parse(raw(%{stdout: stdout}), [])

      assert parsed.content == "Example Domain\nhttps://example.com/"
      assert parsed.details.result_category == "success"
      refute parsed.details.data["lifecycle"]
      assert parsed.details.data["title"] == "Example Domain"
    end

    test "uses snapshot text from the 0.33 envelope" do
      stdout =
        Jason.encode!(%{
          "success" => true,
          "data" => %{
            "snapshot" => "- heading \"Example Domain\" [ref=e1]\n- link \"Learn more\" [ref=e2]",
            "refs" => %{"e1" => %{"role" => "heading"}}
          },
          "error" => nil
        })

      parsed = Result.parse(raw(%{stdout: stdout}), [])

      assert parsed.content =~ "Example Domain"
      assert parsed.content =~ "@e1" or parsed.content =~ "ref=e1"
      refute parsed.content =~ "\"success\""
    end

    test "collects screenshot path from the 0.33 data.path field", %{dir: dir} do
      shot = Path.join(dir, "page.png")
      File.write!(shot, <<137, 80, 78, 71>>)

      stdout =
        Jason.encode!(%{
          "success" => true,
          "data" => %{"path" => shot},
          "error" => nil
        })

      parsed = Result.parse(raw(%{stdout: stdout}), artifact_dir: dir)

      assert [artifact] = parsed.details.artifacts
      assert artifact.path == Path.expand(shot)
      assert parsed.content =~ "saved:"
    end

    test "keeps inspection stdout as plain text" do
      parsed = Result.parse(raw(%{stdout: "agent-browser 0.33.2\n"}), [])

      assert parsed.content =~ "agent-browser 0.33.2"
      assert parsed.details.result_category == "success"
    end

    test "collects screenshot artifacts inside the artifact dir", %{dir: dir} do
      shot = Path.join(dir, "page.png")
      File.write!(shot, <<137, 80, 78, 71>>)
      stdout = Jason.encode!(%{"screenshot" => shot, "text" => "captured"})

      parsed = Result.parse(raw(%{stdout: stdout}), artifact_dir: dir)

      assert parsed.content =~ "captured"
      assert [artifact] = parsed.details.artifacts
      assert artifact.type == "screenshot"
      assert artifact.path == Path.expand(shot)
      assert artifact.media_type == "image/png"
    end

    test "collects download artifacts from an artifacts array", %{dir: dir} do
      file = Path.join(dir, "report.csv")
      File.write!(file, "a,b\n")
      stdout = Jason.encode!(%{"artifacts" => [%{"type" => "download", "path" => file}]})

      parsed = Result.parse(raw(%{stdout: stdout}), artifact_dir: dir)

      assert [artifact] = parsed.details.artifacts
      assert artifact.type == "download"
      assert artifact.path == Path.expand(file)
    end

    test "drops artifact paths outside the artifact dir", %{dir: dir} do
      outside =
        Path.join(
          System.tmp_dir!(),
          "handbean_browser_outside_#{System.unique_integer([:positive])}.png"
        )

      File.write!(outside, "x")
      on_exit(fn -> File.rm(outside) end)

      stdout = Jason.encode!(%{"screenshot" => outside, "text" => "nope"})
      parsed = Result.parse(raw(%{stdout: stdout}), artifact_dir: dir)

      assert parsed.details.artifacts == []
      assert parsed.content == "nope"
    end
  end

  describe "parse/2 — failure" do
    test "classifies watchdog timeout" do
      parsed = Result.parse(raw(%{timed_out: true, stdout: "partial"}), [])

      assert parsed.details.result_category == "failure"
      assert parsed.details.failure_category == "timeout"
      assert parsed.details.timed_out == true
      assert [%{id: "retry-with-fresh-session"}] = parsed.details.next_actions
      assert parsed.content =~ "timed out"
    end

    test "classifies non-zero upstream exit" do
      stdout = Jason.encode!(%{"error" => "selector not found: @e9"})

      parsed = Result.parse(raw(%{stdout: stdout, exit_code: 1}), [])

      assert parsed.details.result_category == "failure"
      assert parsed.details.failure_category == "upstream-error"
      assert parsed.content =~ "selector not found"
      assert parsed.details.exit_code == 1
    end

    test "classifies 0.33 envelope errors" do
      stdout = Jason.encode!(%{"success" => false, "data" => nil, "error" => "Unknown ref: e999"})

      parsed = Result.parse(raw(%{stdout: stdout, exit_code: 0}), [])

      assert parsed.details.result_category == "failure"
      assert parsed.details.failure_category == "upstream-error"
      assert parsed.content == "Unknown ref: e999"
    end

    test "missing-binary helper builds a recoverable envelope" do
      parsed = Result.missing_binary("agent-browser")

      assert parsed.details.result_category == "failure"
      assert parsed.details.failure_category == "missing-binary"
      assert parsed.content =~ "agent-browser"
      assert parsed.content =~ "npm"
      assert [%{id: "install-agent-browser"}] = parsed.details.next_actions
    end
  end
end
