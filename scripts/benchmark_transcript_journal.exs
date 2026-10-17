# Run with: mix run --no-start scripts/benchmark_transcript_journal.exs [entry_count] [updates]
alias Handbean.ConversationTranscriptStore.Journal

{:ok, _supervisor} = Supervisor.start_link([Journal], strategy: :one_for_one)

count = String.to_integer(Enum.at(System.argv(), 0, "10000"))
updates = String.to_integer(Enum.at(System.argv(), 1, "500"))

dir =
  Path.join(System.tmp_dir!(), "handbean-transcript-bench-#{System.unique_integer([:positive])}")

File.mkdir_p!(dir)
snapshot_path = Path.join(dir, "rewrite.jsonl")
journal_path = Path.join(dir, "journal.jsonl")
entries = for i <- 1..count, do: %{"id" => "m#{i}", "content" => "initial", "sequence" => i}
target = "m#{count}"
:ok = Journal.replace(journal_path, entries)
:ok = Journal.replace(snapshot_path, entries)

{rewrite_us, _} =
  :timer.tc(fn ->
    Enum.reduce(1..updates, entries, fn _, current ->
      current =
        Enum.map(
          current,
          &if(&1["id"] == target,
            do: Map.update!(&1, "content", fn value -> value <> "x" end),
            else: &1
          )
        )

      :ok = Journal.replace(snapshot_path, current)
      current
    end)
  end)

{journal_us, _} =
  :timer.tc(fn ->
    Enum.each(1..updates, fn _ ->
      {:ok, _} =
        Journal.update(
          journal_path,
          target,
          %{"content" => %{"$append" => "x"}},
          DateTime.utc_now() |> DateTime.to_iso8601()
        )
    end)
  end)

IO.puts("entries=#{count} updates=#{updates}")
IO.puts("simulated full-snapshot rewrite baseline: #{Float.round(rewrite_us / 1_000, 1)} ms")
IO.puts("append journal: #{Float.round(journal_us / 1_000, 1)} ms")
IO.puts("speedup: #{Float.round(rewrite_us / journal_us, 1)}x")
File.rm_rf!(dir)
