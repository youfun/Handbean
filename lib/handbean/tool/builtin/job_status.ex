defmodule Handbean.Tool.Builtin.JobStatus do
  @moduledoc "Scoped job queries and bounded recovery of handles whose launch reply was lost."
  @behaviour Handbean.Agent.Tool

  @impl true
  def name, do: "job_status"
  @impl true
  def description do
    "Query a Bash or BEAM job's state and bounded incremental output using its byte cursor. " <>
      "Pass the returned cursor to the next query. A query returns early when new decodable output " <>
      "or a terminal state arrives; otherwise it waits up to wait_ms. Omit job_id to recover the " <>
      "most recent 32 handles in this conversation/workspace. Wait is capped at 30s and half the " <>
      "tool timeout. Empty output does not establish a stall; use state, elapsed_ms, output_idle_ms, " <>
      "and remaining_ms together. Do not launch a Bash sleep command just to wait for another job. " <>
      "Query completion before ending the run; unfinished jobs are cancelled at run end. Later runs " <>
      "can inspect retained results, not resume execution. cancelling with cleanup_error means " <>
      "termination is not yet confirmed."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        job_id: %{type: "string"},
        cursor: %{type: "integer", minimum: 0, default: 0},
        wait_ms: %{type: "integer", minimum: 0, maximum: 30_000, default: 1_000}
      }
    }
  end

  @impl true
  def concurrent?, do: true
  @impl true
  def max_result_chars, do: 105_000
  @impl true
  def execute(input, context) do
    job_id = if input["job_id"] == "", do: nil, else: input["job_id"]

    Handbean.Jobs.status(
      job_id,
      Map.get(input, "cursor", 0),
      Map.get(input, "wait_ms", 1_000),
      context
    )
    |> Handbean.Jobs.format()
  end
end
