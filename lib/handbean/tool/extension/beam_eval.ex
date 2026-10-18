defmodule Handbean.Tool.Extension.Beam.Eval do
  @moduledoc """
  Evaluate Elixir code in the running application.

  Runs code inside the BEAM with full access to project modules, deps,
  Ecto repos, and IEx helpers. Use this instead of bash for anything
  Elixir — test functions, introspect modules, manipulate ASTs,
  read docs with h(), list exports with exports(), inspect values with i().
  """

  @behaviour Handbean.Agent.Tool

  @default_timeout 30_000
  @max_result_chars 50_000

  @impl true
  def name, do: "ext__beam__eval"

  @impl true
  def description do
    "Evaluate Elixir code in the running application. " <>
      "Runs inside the BEAM with full access to project modules, deps, " <>
      "Ecto repos, and IEx helpers."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        code: %{type: "string", description: "Elixir code to evaluate"},
        timeout: %{
          type: "integer",
          description: "Timeout in ms (default: 30000)",
          default: @default_timeout
        }
      },
      required: ["code"]
    }
  end

  @impl true
  def max_result_chars, do: @max_result_chars

  @impl true
  def concurrent?, do: false

  @impl true
  def execute(%{"code" => code} = input, _context) do
    timeout = Map.get(input, "timeout", @default_timeout)

    parent = self()
    ref = make_ref()

    task =
      spawn(fn ->
        result = safe_eval(code)
        send(parent, {ref, result})
      end)

    receive do
      {^ref, result} ->
        result
    after
      timeout ->
        Process.exit(task, :kill)
        {:error, "Code evaluation timed out after #{div(timeout, 1000)}s"}
    end
  end

  def execute(_input, _context) do
    {:error, "code is required"}
  end

  @blocked_remote [":rpc", ":net_adm", ":os", "System", "File", "IO", "Port", "Code"]

  defp safe_eval(code) do
    try do
      case Code.string_to_quoted(code) do
        {:ok, ast} ->
          case forbidden_call(ast) do
            nil ->
              {result, _bindings} = Code.eval_string(code, [], __ENV__)
              formatted = format_result(result)
              {:ok, formatted}

            name ->
              {:error, "#{name} is not allowed in ext__beam__eval"}
          end

        {:error, {line, error, token}} ->
          {:error, "Syntax error at line #{line}: #{error} #{inspect(token)}"}
      end
    rescue
      e ->
        {:error, "#{inspect(e.__struct__)}: #{Exception.message(e)}"}
    end
  end

  defp forbidden_call(ast) do
    ast
    |> Macro.prewalk(nil, fn
      {{:., _, [remote, _fun]}, _, _} = node, acc ->
        {node, acc || remote_name(remote)}

      {:__aliases__, _, parts} = node, acc ->
        name = Enum.map_join(parts, ".", &to_string/1)
        {node, acc || if(name in @blocked_remote, do: name)}

      other, acc ->
        {other, acc}
    end)
    |> elem(1)
  end

  defp remote_name({:__aliases__, _, parts}) do
    name = Enum.map_join(parts, ".", &to_string/1)
    if name in @blocked_remote, do: name
  end

  defp remote_name(atom) when is_atom(atom) do
    name = inspect(atom)
    if name in @blocked_remote, do: name
  end

  defp remote_name(_), do: nil

  defp format_result(result) do
    str = inspect(result, pretty: true, limit: :infinity, width: 120)

    if byte_size(str) > @max_result_chars do
      head = binary_part(str, 0, @max_result_chars)
      "#{head}\n\n[Output truncated at #{@max_result_chars} bytes]"
    else
      str
    end
  end
end
