defmodule Handbean.Tool.Extension.Beam.SupTree do
  @moduledoc """
  Show the supervision tree of the running application.

  Returns a tree of supervisors and their children with PIDs,
  restart strategies, and child types.
  """

  @behaviour Handbean.Agent.Tool

  @impl true
  def name, do: "ext__beam__sup_tree"

  @impl true
  def description do
    "Show the supervision tree of the running application. " <>
      "Returns a tree of supervisors and their children with PIDs, restart strategies, and child types."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        root: %{
          type: "string",
          description:
            "Root supervisor module (default: auto-detected application supervisor). e.g. MyApp.Supervisor"
        },
        depth: %{
          type: "integer",
          description: "Maximum tree depth to display (default: unlimited)"
        }
      },
      required: []
    }
  end

  @impl true
  def execute(input, _context) do
    root_str = Map.get(input, "root")
    depth = Map.get(input, "depth")

    root =
      case root_str do
        nil -> auto_detect_root()
        name -> try_module(name)
      end

    case root do
      {:ok, mod} ->
        tree = build_tree(mod, depth)
        {:ok, format_tree(tree)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp auto_detect_root do
    app = :handbean

    case Application.spec(app, :mod) do
      {mod, _args} ->
        # Handbean.Application is the root supervisor
        {:ok, mod}

      _ ->
        {:error, "Cannot auto-detect root supervisor"}
    end
  end

  defp try_module(name) when is_binary(name) do
    if String.match?(name, ~r/^[A-Z][A-Za-z0-9]*(\.[A-Z][A-Za-z0-9]*)*$/) do
      mod = Module.concat(["Elixir" | String.split(name, ".")])

      case Code.ensure_loaded(mod) do
        {:module, mod} -> {:ok, mod}
        {:error, _} -> {:error, "Module #{name} not found"}
      end
    else
      {:error, "Module #{name} not found"}
    end
  end

  defp try_module(_name), do: {:error, "Module not found"}

  defp build_tree(mod, max_depth) do
    do_build_tree(mod, 0, max_depth)
  end

  defp do_build_tree(_mod, depth, max_depth) when is_integer(max_depth) and depth > max_depth do
    %{name: "...", type: :max_depth, children: []}
  end

  defp do_build_tree(mod, depth, _max_depth) do
    children = get_children(mod)
    name = inspect(mod)

    child_nodes =
      Enum.map(children, fn child ->
        case child do
          {_child_name, _pid, :supervisor, [mod]} when is_atom(mod) ->
            do_build_tree(mod, depth + 1, nil)

          {child_name, pid, :worker, _mod} ->
            %{name: "#{inspect(child_name)} (#{inspect(pid)})", type: :worker, children: []}

          child_name when is_atom(child_name) ->
            do_build_tree(child_name, depth + 1, nil)

          {_id, _pid, _type, _modules} ->
            desc = format_child(child)
            %{name: desc, type: :worker, children: []}

          other ->
            %{name: inspect(other), type: :unknown, children: []}
        end
      end)

    %{name: name, type: :supervisor, children: child_nodes}
  end

  defp get_children(mod) do
    pid = Process.whereis(mod)

    if pid && Process.alive?(pid) do
      Supervisor.which_children(mod)
    else
      []
    end
  end

  defp format_tree(tree) do
    lines = do_format(tree, "", true)
    Enum.join(lines, "\n")
  end

  defp do_format(%{name: name, type: type, children: children}, prefix, _is_last) do
    label = "#{type_icon(type)} #{name}"
    [label | format_children(children, prefix)]
  end

  defp type_icon(:supervisor), do: "📁"
  defp type_icon(:worker), do: "⚙️"
  defp type_icon(:max_depth), do: "📁 ... (max depth)"
  defp type_icon(_), do: "❓"

  defp format_children([], _prefix), do: []

  defp format_children(children, prefix) do
    {all_but_last, [last]} = Enum.split(children, -1)

    pre_last =
      Enum.flat_map(all_but_last, fn child ->
        lines = do_format(child, prefix <> "├─ ", false)

        case lines do
          [first | rest] ->
            [prefix <> "├─ " <> first | Enum.map(rest, fn l -> prefix <> "│  " <> l end)]

          [] ->
            []
        end
      end)

    last_lines = do_format(last, prefix <> "└─ ", true)

    post_last =
      case last_lines do
        [first | rest] ->
          [prefix <> "└─ " <> first | Enum.map(rest, fn l -> prefix <> "   " <> l end)]

        [] ->
          []
      end

    pre_last ++ post_last
  end

  defp format_child({name, _pid, type, modules}) do
    mod_list = Enum.map_join(modules, ", ", &inspect/1)
    "#{inspect(name)} (#{type}, #{mod_list})"
  end
end
