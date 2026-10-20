defmodule Handbean.Diagnostics.ErrorExportTest do
  use Handbean.DataCase, async: false

  alias ErrorTracker.{Error, Occurrence}
  alias Handbean.Diagnostics.ErrorExport

  @now ~U[2026-06-01 12:00:00.000000Z]

  setup do
    previous = Application.get_env(:error_tracker, :enabled)
    Application.put_env(:error_tracker, :enabled, true)
    on_exit(fn -> Application.put_env(:error_tracker, :enabled, previous) end)
    :ok
  end

  test "empty exports are valid and invalid filters fail closed" do
    assert {:ok, doc} = ErrorExport.build(%{}, @now)
    assert doc.errors == []
    assert doc.counts.matching_occurrences == 0
    refute doc.truncated
    assert Handbean.JSON.decode!(Handbean.JSON.encode!(doc))["schema_version"] == 1
    assert {:error, :invalid_filters} = ErrorExport.build(%{"range" => "yesterday"}, @now)
    assert {:error, :invalid_filters} = ErrorExport.build(%{"status" => "secret"}, @now)
  end

  test "independent allowlist excludes arbitrary payloads, identities, paths and stack arguments" do
    occurrence =
      report(10, %{
        "failure_class" => "tool_error",
        "reason_category" => "timeout",
        "tool" => "read",
        "request.params" => %{"token" => "sentinel-token"},
        "live_view.event_params" => %{"body" => "sentinel-chat"},
        "nested" => %{secret: "sentinel-secret"},
        "username" => "sentinel-user",
        "workspace_path" => "/Users/sentinel-user/private",
        "provider" => "sentinel-provider"
      })

    at(occurrence, @now)
    assert {:ok, doc} = ErrorExport.build(%{}, @now)
    [group] = doc.errors
    assert group.kind == "RuntimeError"
    assert group.failure_class == "tool_error"
    assert group.reason_category == "timeout"
    assert group.tool == "read"
    [sample] = group.occurrences

    assert [
             %{
               module: "Handbean.JSON",
               function: "decode",
               arity: 1,
               file: "lib/handbean/json.ex",
               line: 10
             }
           ] = sample.stack

    encoded = Handbean.JSON.encode!(doc)
    refute encoded =~ "sentinel"
    refute encoded =~ "/Users/"
    refute encoded =~ "request.params"
    refute Map.has_key?(sample, :breadcrumbs)
  end

  test "unknown classifications and untrusted stack names and files become null" do
    occurrence =
      report(11, %{
        "failure_class" => "sentinel-class",
        "reason_category" => "sentinel-reason",
        "tool" => "sentinel-tool"
      })

    at(occurrence, @now)

    stack = %ErrorTracker.Stacktrace{
      lines: [
        %ErrorTracker.Stacktrace.Line{
          module: "sentinel-module",
          function: "sentinel-function",
          file: "C:\\Users\\sentinel\\a.ex",
          line: 4,
          arity: 1
        },
        %ErrorTracker.Stacktrace.Line{
          module: "Handbean.JSON",
          function: "sentinel-function",
          file: "/srv/lib/sentinel/checkout/lib/handbean/json.ex",
          line: 4,
          arity: 1
        }
      ]
    }

    from(o in Occurrence, where: o.id == ^occurrence.id)
    |> Repo.update_all(set: [stacktrace: stack])

    assert {:ok, doc} = ErrorExport.build(%{}, @now)
    [group] = doc.errors
    assert is_nil(group.failure_class) and is_nil(group.reason_category) and is_nil(group.tool)
    [sample] = group.occurrences
    assert sample.omitted_classification_fields == ["failure_class", "reason_category", "tool"]
    assert doc.privacy.original_message_count == 1

    assert Enum.all?(
             sample.stack,
             &(is_nil(&1.file) and is_nil(&1.function) and is_nil(&1.arity))
           )

    refute Handbean.JSON.encode!(doc) =~ "sentinel"
  end

  test "inclusive occurrence time bounds, current status, retained counts and recent samples" do
    old = report(20)
    at(old, DateTime.add(@now, -604_801))
    boundary = report(20)
    at(boundary, DateTime.add(@now, -604_800))
    for seconds <- [3, 2, 1, 0], do: report(20) |> at(DateTime.add(@now, -seconds))
    report(20) |> at(DateTime.add(@now, 1))
    assert {:ok, doc} = ErrorExport.build(%{}, @now)
    [group] = doc.errors
    assert group.occurrence_count == 5
    assert group.exported_occurrence_count == 3
    assert group.first_occurrence_at == DateTime.add(@now, -604_800)
    assert group.last_occurrence_at == @now

    assert Enum.map(group.occurrences, & &1.occurred_at) == [
             @now,
             DateTime.add(@now, -1),
             DateTime.add(@now, -2)
           ]

    assert doc.truncated
    assert {:ok, _} = ErrorTracker.resolve(Repo.get!(Error, old.error_id))
    assert {:ok, %{errors: []}} = ErrorExport.build(%{}, @now)
    assert {:ok, %{errors: [_]}} = ErrorExport.build(%{"status" => "all"}, @now)
    assert {:ok, all} = ErrorExport.build(%{"status" => "all", "range" => "all"}, @now)
    assert hd(all.errors).occurrence_count == 6
  end

  test "private BEAM functions survive and provider/model references correlate only inside one export" do
    stack = [
      {Handbean.JSON, :restore_elixir_values, ["sentinel"],
       [file: "lib/handbean/json.ex", line: 1]}
    ]

    for _ <- 1..2 do
      ErrorTracker.report(RuntimeError.exception("sentinel"), stack, %{
        "provider" => "sentinel-same",
        "model" => "sentinel-same"
      })
      |> at(@now)
    end

    assert {:ok, doc} = ErrorExport.build(%{}, @now)
    [group] = doc.errors
    [first, second] = group.occurrences
    assert first.provider_ref == second.provider_ref
    assert first.model_ref == second.model_ref

    assert String.replace_prefix(first.provider_ref, "provider-", "") !=
             String.replace_prefix(first.model_ref, "model-", "")

    assert hd(first.stack).function == "restore_elixir_values"
    refute Handbean.JSON.encode!(doc) =~ "sentinel"
    assert {:ok, next} = ErrorExport.build(%{}, @now)
    assert hd(hd(next.errors).occurrences).provider_ref != first.provider_ref
  end

  test "stack limits and muted errors are explicit" do
    stack =
      List.duplicate({Handbean.JSON, :decode, 1, [file: "lib/handbean/json.ex", line: 1]}, 31)

    occurrence = ErrorTracker.report(RuntimeError.exception("sentinel"), stack, %{})
    at(occurrence, @now)
    assert {:ok, _} = ErrorTracker.mute(Repo.get!(Error, occurrence.error_id))
    assert {:ok, doc} = ErrorExport.build(%{}, @now)
    [group] = doc.errors
    [sample] = group.occurrences
    assert group.muted
    assert length(sample.stack) == 30
    assert sample.stack_truncated and group.truncated and doc.truncated
  end

  test "group limits report truncation and exports never mutate records" do
    for line <- 100..200, do: report(line) |> at(@now)
    before = Repo.aggregate(Error, :count)
    assert {:ok, doc} = ErrorExport.build(%{}, @now)
    assert doc.counts.matching_groups == 101
    assert doc.counts.exported_groups == 100
    assert doc.counts.matching_occurrences == 101
    assert doc.truncated
    assert hd(doc.errors).id == "error-1"
    assert hd(hd(doc.errors).occurrences).stack |> hd() |> Map.fetch!(:line) == 200
    assert Repo.aggregate(Error, :count) == before
    assert Repo.aggregate(from(e in Error, where: e.status == :resolved), :count) == 0
  end

  defp report(line, context \\ %{}) do
    ErrorTracker.report(
      RuntimeError.exception(
        "sentinel-message token=sentinel-token /Users/sentinel-user/private"
      ),
      [
        {Handbean.JSON, :decode, ["sentinel-argument"],
         [file: "lib/handbean/json.ex", line: line]}
      ],
      context
    )
  end

  defp at(occurrence, time) do
    from(o in Occurrence, where: o.id == ^occurrence.id)
    |> Repo.update_all(set: [inserted_at: time])

    occurrence
  end
end
