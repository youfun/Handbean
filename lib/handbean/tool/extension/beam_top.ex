defmodule Handbean.Tool.Extension.Beam.Top do
  @moduledoc """
  List top BEAM processes by resource usage, like a process manager.

  Shows process name/MFA, PID, memory, message queue length, reductions,
  and current function. Use to find memory leaks, overloaded mailboxes,
  or busy processes.
  """

  @behaviour Handbean.Agent.Tool

  @default_limit 15

  @impl true
  def name, do: "ext__beam__top"

  @impl true
  def description do
    "List top BEAM processes by resource usage. " <>
      "Shows PID, memory, reductions, message queue length, and current function. " <>
      "Sort by: memory (default), reductions, message_queue_len."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        limit: %{
          type: "integer",
          description: "Number of processes to show (default: #{@default_limit})"
        },
        sort: %{
          type: "string",
          description: "Sort by: memory (default), reductions, message_queue_len"
        }
      },
      required: []
    }
  end

  @impl true
  def execute(input, _context) do
    limit = Map.get(input, "limit", @default_limit)
    sort = Map.get(input, "sort", "memory")

    procs =
      Process.list()
      |> Enum.map(&get_proc_info/1)
      |> Enum.reject(&is_nil/1)
      |> sort_procs(sort)
      |> Enum.take(limit)

    output = format_table(procs, sort)
    {:ok, output}
  end

  defp get_proc_info(pid) do
    case Process.info(pid, [
           :memory,
           :reductions,
           :message_queue_len,
           :current_function,
           :registered_name,
           :status
         ]) do
      nil ->
        nil

      info ->
        name = format_proc_name(info[:registered_name], info[:current_function])

        %{
          pid: inspect(pid),
          name: name,
          memory: info[:memory] || 0,
          reductions: info[:reductions] || 0,
          message_queue_len: info[:message_queue_len] || 0,
          current_function: format_mfa(info[:current_function]),
          status: info[:status]
        }
    end
  end

  defp format_proc_name([], {:current_function, m, f, a}) do
    "#{inspect(m)}.#{f}/#{a}"
  end

  defp format_proc_name(name, _mfa) when is_atom(name), do: to_string(name)
  defp format_proc_name(name, _mfa), do: inspect(name)

  defp format_mfa({m, f, a}), do: "#{inspect(m)}.#{f}/#{a}"
  defp format_mfa(nil), do: "(terminated)"
  defp format_mfa(other), do: inspect(other)

  defp sort_procs(procs, "reductions"), do: Enum.sort_by(procs, & &1.reductions, :desc)

  defp sort_procs(procs, "message_queue_len"),
    do: Enum.sort_by(procs, & &1.message_queue_len, :desc)

  defp sort_procs(procs, _), do: Enum.sort_by(procs, & &1.memory, :desc)

  defp format_table(procs, sort) do
    header = "PID                 Memory     Reds       MsgQ  Status   Name/Function"
    sep = String.duplicate("-", String.length(header))

    rows =
      Enum.map(procs, fn p ->
        pid = String.pad_trailing(p.pid, 20)
        mem = format_bytes(p.memory) |> String.pad_leading(8)
        reds = format_num(p.reductions) |> String.pad_leading(8)
        msgq = Integer.to_string(p.message_queue_len) |> String.pad_leading(8)
        status = p.status |> to_string |> String.pad_trailing(8)
        "#{pid} #{mem}  #{reds}  #{msgq}  #{status}#{trunc_str(p.name, 50)}"
      end)

    info = "Sort: #{sort} | Showing #{length(procs)} of #{length(Process.list())} processes"

    [header, sep, rows, "", info]
    |> List.flatten()
    |> Enum.join("\n")
  end

  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes}B"
  defp format_bytes(bytes) when bytes < 1_048_576, do: "#{div(bytes, 1024)}KB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / 1_048_576, 1)}MB"

  defp format_num(n) when n < 1000, do: Integer.to_string(n)
  defp format_num(n) when n < 1_000_000, do: "#{div(n, 1000)}K"
  defp format_num(n), do: "#{Float.round(n / 1_000_000, 1)}M"

  defp trunc_str(s, max_value) when byte_size(s) <= max_value, do: s
  defp trunc_str(s, max_value), do: String.slice(s, 0, max_value - 3) <> "..."
end
