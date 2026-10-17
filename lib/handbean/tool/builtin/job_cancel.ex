defmodule Handbean.Tool.Builtin.JobCancel do
  @moduledoc "Idempotent cancellation; reports actual cleanup state, not presumed success."
  @behaviour Handbean.Agent.Tool

  @impl true
  def name, do: "job_cancel"
  @impl true
  def description do
    "Request cancellation of a Bash or BEAM job in this conversation/workspace. Idempotent. " <>
      "cancelling is not confirmation of termination: query job_status for the final state. " <>
      "Completed results are unchanged. May retry cleanup of a previous run, never resume it."
  end

  @impl true
  def input_schema,
    do: %{type: "object", properties: %{job_id: %{type: "string"}}, required: ["job_id"]}

  @impl true
  def concurrent?, do: true
  @impl true
  def max_result_chars, do: 105_000
  @impl true
  def execute(input, context),
    do: Handbean.Jobs.cancel(input["job_id"], context) |> Handbean.Jobs.format()
end
