defmodule HandbeanProbe.NativeWorkspaceTree do
  @moduledoc """
  One-directory-at-a-time workspace listing. Expand loads a child dir.
  Entries are metadata only. File taps reuse NativeWorkspaceOpen.
  """

  use Gettext, backend: HandbeanProbe.Gettext
  import Mob.Socket, only: [assign: 3]
  import HandbeanProbe.NativeUI

  alias Handbean.WorkspaceFiles
  alias HandbeanProbe.NativeWorkspaceOpen

  def idle do
    %{
      workspace_id: nil,
      workspace_root: nil,
      workspace_name: nil,
      show_hidden: false,
      expanded: MapSet.new([""]),
      dirs: %{},
      epoch: 0,
      error: nil
    }
  end

  def for_workspace(workspace, previous \\ nil)
  def for_workspace(nil, previous), do: %{idle() | epoch: next_epoch(previous)}

  def for_workspace(%{"id" => id, "path" => path} = workspace, previous) do
    %{
      idle()
      | workspace_id: id,
        workspace_root: path,
        workspace_name: workspace["name"] || gettext("Workspace"),
        epoch: next_epoch(previous)
    }
  end

  def for_workspace(_, previous), do: %{idle() | epoch: next_epoch(previous)}

  def same_workspace?(%{workspace_id: id}, %{"id" => id}) when is_binary(id), do: true
  def same_workspace?(_, _), do: false

  def ensure(socket) do
    workspace = socket.assigns.workspace
    tree = socket.assigns[:workspace_tree] || idle()

    tree =
      if same_workspace?(tree, workspace) do
        tree
      else
        for_workspace(workspace, tree)
      end

    socket = assign(socket, :workspace_tree, tree)

    if tree.workspace_root && needs_list?(tree.dirs[""]) do
      request_lists(socket, [{"", 0}])
    else
      socket
    end
  end

  def handle(socket, %{op: op} = event) do
    tree = socket.assigns[:workspace_tree] || idle()

    if bound?(tree, event) do
      do_handle(socket, op, event)
    else
      socket
    end
  end

  def handle(socket, _), do: socket

  def handle_listed(socket, payload) when is_map(payload) do
    tree = socket.assigns[:workspace_tree] || idle()
    workspace = socket.assigns[:workspace]
    dir = tree.dirs[payload[:relative_dir]]

    cond do
      tree.epoch != payload[:epoch] ->
        socket

      payload[:workspace_id] != tree.workspace_id ->
        socket

      not same_workspace?(tree, workspace) ->
        socket

      dir == nil ->
        socket

      dir.request != payload[:request] ->
        socket

      dir.applied == payload[:request] ->
        socket

      true ->
        assign(socket, :workspace_tree, apply_listed(tree, payload))
    end
  end

  def handle_listed(socket, _), do: socket

  def render(tree) do
    node(:column, [weight: 1, fill_width: true, spacing: 0], [
      actions_row([
        button(
          if(tree.show_hidden, do: gettext("Hide hidden"), else: gettext("Show hidden")),
          event(tree, :toggle_hidden),
          text_size: 10,
          padding: 4
        ),
        button(gettext("Refresh"), event(tree, :refresh), text_size: 10, padding: 4)
      ]),
      notice(tree.error),
      scroll(dir_nodes(tree, "", 0), id: scroll_id(tree), retain_scroll: true)
    ])
  end

  defp do_handle(socket, :refresh, _event) do
    tree = socket.assigns.workspace_tree

    socket
    |> assign(:workspace_tree, %{tree | dirs: %{}, error: nil, epoch: tree.epoch + 1})
    |> request_expanded()
  end

  defp do_handle(socket, :toggle_hidden, _event) do
    tree = socket.assigns.workspace_tree

    socket
    |> assign(:workspace_tree, %{
      tree
      | show_hidden: !tree.show_hidden,
        dirs: %{},
        error: nil,
        epoch: tree.epoch + 1
    })
    |> request_expanded()
  end

  defp do_handle(socket, :toggle, %{relative_dir: relative_dir}) when is_binary(relative_dir) do
    tree = socket.assigns.workspace_tree
    expanded = tree.expanded || MapSet.new()

    if MapSet.member?(expanded, relative_dir) do
      assign(socket, :workspace_tree, %{tree | expanded: MapSet.delete(expanded, relative_dir)})
    else
      socket
      |> assign(:workspace_tree, %{tree | expanded: MapSet.put(expanded, relative_dir)})
      |> maybe_list(relative_dir)
    end
  end

  defp do_handle(socket, :load_more, %{relative_dir: relative_dir})
       when is_binary(relative_dir) do
    tree = socket.assigns.workspace_tree
    dir = tree.dirs[relative_dir]

    if dir && dir.truncated && not dir.loading do
      request_lists(socket, [{relative_dir, dir.next_offset}])
    else
      socket
    end
  end

  defp do_handle(socket, :retry, %{relative_dir: relative_dir}) when is_binary(relative_dir) do
    request_lists(socket, [{relative_dir, 0}])
  end

  defp do_handle(socket, :open, %{relative_path: relative_path} = event)
       when is_binary(relative_path) do
    NativeWorkspaceOpen.request(
      socket,
      NativeWorkspaceOpen.spec(:tree, relative_path, event[:workspace_id])
    )
  end

  defp do_handle(socket, _, _), do: socket

  defp request_expanded(socket) do
    tree = socket.assigns.workspace_tree
    dirs = ["" | MapSet.to_list(tree.expanded || MapSet.new())] |> Enum.uniq()
    request_lists(socket, Enum.map(dirs, &{&1, 0}))
  end

  defp maybe_list(socket, relative_dir) do
    tree = socket.assigns.workspace_tree

    if needs_list?(tree.dirs[relative_dir]) do
      request_lists(socket, [{relative_dir, 0}])
    else
      socket
    end
  end

  defp needs_list?(nil), do: true
  defp needs_list?(%{loading: true}), do: false
  defp needs_list?(%{error: error}) when not is_nil(error), do: true
  defp needs_list?(%{listed?: true}), do: false
  defp needs_list?(_), do: true

  defp request_lists(socket, requests) do
    tree = socket.assigns.workspace_tree

    if tree.workspace_root do
      {dirs, tokens} =
        Enum.reduce(requests, {tree.dirs, %{}}, fn {relative_dir, offset}, {acc, tokens} ->
          {next, token} = put_loading(acc, relative_dir, offset)
          {next, Map.put(tokens, relative_dir, token)}
        end)

      socket = assign(socket, :workspace_tree, %{tree | dirs: dirs, error: nil})

      Enum.reduce(requests, socket, fn {relative_dir, offset}, acc ->
        spawn_list(acc, relative_dir, offset, tokens[relative_dir])
      end)
    else
      assign(socket, :workspace_tree, %{tree | error: gettext("No workspace is open.")})
    end
  end

  defp spawn_list(socket, relative_dir, offset, request) do
    tree = socket.assigns.workspace_tree
    workspace_id = tree.workspace_id
    epoch = tree.epoch
    root = tree.workspace_root
    hidden = tree.show_hidden
    max = Application.get_env(:handbean_probe, :file_tree_max_entries, 256)

    payload = fn result ->
      {:file_tree_listed,
       %{
         epoch: epoch,
         workspace_id: workspace_id,
         relative_dir: relative_dir,
         offset: offset,
         request: request,
         result: result
       }}
    end

    run_io(
      socket,
      fn ->
        payload.(list_safe(root, relative_dir, hidden, max, offset))
      end,
      fn reason -> payload.({:error, reason}) end
    )
  end

  defp list_safe(root, relative_dir, hidden, max, offset) do
    try do
      list_fun().(root, relative_dir, show_hidden: hidden, max_entries: max, offset: offset)
    rescue
      error -> {:error, Exception.message(error)}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  defp apply_listed(tree, payload) do
    current = tree.dirs[payload.relative_dir]

    case payload.result do
      {:ok, listed} ->
        dir = merge_dir(current, listed, payload.offset)
        dir = %{dir | applied: payload.request, request: payload.request, error: nil}
        %{tree | dirs: Map.put(tree.dirs, payload.relative_dir, dir), error: nil}

      {:error, reason} ->
        message = list_error(reason)

        dir = %{
          current
          | loading: false,
            listed?: false,
            applied: payload.request,
            request: payload.request,
            error: message
        }

        %{tree | dirs: Map.put(tree.dirs, payload.relative_dir, dir), error: message}
    end
  end

  defp merge_dir(nil, listed, 0), do: from_listed(listed)

  defp merge_dir(%{entries: existing, listed?: true} = dir, listed, offset) when offset > 0 do
    %{
      dir
      | entries: existing ++ listed.entries,
        truncated: listed.truncated,
        next_offset: listed.next_offset,
        offset: listed.offset,
        loading: false,
        listed?: true
    }
  end

  defp merge_dir(_dir, listed, _), do: from_listed(listed)

  defp from_listed(listed) do
    %{
      entries: listed.entries,
      truncated: listed.truncated,
      next_offset: listed.next_offset,
      offset: listed.offset,
      loading: false,
      listed?: true,
      request: 0,
      applied: nil,
      error: nil
    }
  end

  defp idle_dir do
    %{
      entries: [],
      truncated: false,
      next_offset: 0,
      offset: 0,
      loading: false,
      listed?: false,
      request: 0,
      applied: nil,
      error: nil
    }
  end

  defp put_loading(dirs, relative_dir, offset) do
    current = Map.get(dirs, relative_dir, idle_dir())
    token = current.request + 1

    next = %{
      current
      | loading: true,
        offset: offset,
        request: token,
        error: nil
    }

    {Map.put(dirs, relative_dir, next), token}
  end

  defp dir_nodes(tree, relative_dir, depth) do
    dir = tree.dirs[relative_dir]
    expanded? = MapSet.member?(tree.expanded || MapSet.new(), relative_dir)

    cond do
      dir == nil ->
        [
          text(gettext("Loading…"),
            text_size: 12,
            text_color: color(:hint),
            padding_left: depth * 12
          )
        ]

      true ->
        entries = if expanded? or relative_dir == "", do: dir.entries, else: []

        children =
          Enum.flat_map(entries, fn entry ->
            row = entry_row(tree, entry, depth)

            if entry.kind == :directory and MapSet.member?(tree.expanded, entry.relative_path) do
              [row | dir_nodes(tree, entry.relative_path, depth + 1)]
            else
              [row]
            end
          end)

        empty =
          if (expanded? or relative_dir == "") and dir.listed? and entries == [] and
               not dir.loading and
               is_nil(dir.error) do
            [
              text(gettext("This folder is empty."),
                text_size: 12,
                text_color: color(:hint),
                padding: 8,
                padding_left: 8 + depth * 12
              )
            ]
          else
            []
          end

        err =
          if (expanded? or relative_dir == "") and dir.error do
            [
              text(dir.error,
                text_size: 12,
                text_color: color(:danger),
                padding: 8,
                padding_left: 8 + depth * 12
              ),
              button(gettext("Retry"), event(tree, :retry, %{relative_dir: relative_dir}),
                text_size: 11,
                padding: 6,
                padding_left: 8 + depth * 12
              )
            ]
          else
            []
          end

        more =
          if (expanded? or relative_dir == "") and dir.truncated do
            [
              button(
                gettext("Load more"),
                event(tree, :load_more, %{relative_dir: relative_dir}),
                text_size: 11,
                padding: 6,
                padding_left: depth * 12
              )
            ]
          else
            []
          end

        loading =
          if dir.loading do
            [text(gettext("Loading…"), text_size: 12, text_color: color(:hint))]
          else
            []
          end

        children ++ empty ++ err ++ more ++ loading
    end
  end

  defp entry_row(tree, %{kind: :directory} = entry, depth) do
    mark = if MapSet.member?(tree.expanded, entry.relative_path), do: "▾ ", else: "▸ "

    button(
      mark <> entry.name,
      event(tree, :toggle, %{relative_dir: entry.relative_path}),
      fill_width: true,
      style: :plain,
      text_size: 12,
      padding: 4,
      padding_left: 7 + depth * 12
    )
  end

  defp entry_row(tree, %{kind: :file} = entry, depth) do
    button(entry.name, event(tree, :open, %{relative_path: entry.relative_path}),
      fill_width: true,
      style: :plain,
      text_size: 12,
      padding: 4,
      padding_left: 20 + depth * 12
    )
  end

  defp entry_row(_tree, %{kind: :symlink} = entry, depth) do
    text(entry.name <> " · " <> gettext("symlink skipped"),
      text_size: 12,
      text_color: color(:muted),
      padding: 8,
      padding_left: 8 + depth * 12
    )
  end

  defp entry_row(_tree, entry, depth) do
    text(entry.name,
      text_size: 12,
      text_color: color(:muted),
      padding: 8,
      padding_left: 8 + depth * 12
    )
  end

  defp event(tree, op, extra \\ %{}) do
    {:file_tree,
     Map.merge(
       %{op: op, workspace_id: tree.workspace_id, epoch: tree.epoch},
       extra
     )}
  end

  defp bound?(tree, event) do
    event[:workspace_id] == tree.workspace_id and event[:epoch] == tree.epoch
  end

  defp next_epoch(%{epoch: epoch}) when is_integer(epoch), do: epoch + 1
  defp next_epoch(_), do: 1

  defp scroll_id(%{workspace_id: id, epoch: epoch}) when is_binary(id),
    do: "workspace-files-#{id}-#{epoch}"

  defp scroll_id(_), do: "workspace-files"

  defp list_fun do
    Application.get_env(:handbean_probe, :workspace_files_list) ||
      fn root, dir, opts -> WorkspaceFiles.list(root, dir, opts) end
  end

  defp run_io(socket, work, fail) do
    owner = self()

    starter =
      Application.get_env(:handbean_probe, :workspace_io_start) ||
        (&Task.Supervisor.start_child(HandbeanProbe.TaskSupervisor, &1))

    case starter.(fn ->
           try do
             send(owner, work.())
           rescue
             error -> send(owner, fail.(Exception.message(error)))
           catch
             kind, reason -> send(owner, fail.({kind, reason}))
           end
         end) do
      {:ok, _} ->
        socket

      {:error, reason} ->
        handle_listed_message(socket, fail.(reason))
    end
  end

  defp handle_listed_message(socket, {:file_tree_listed, payload}),
    do: handle_listed(socket, payload)

  defp handle_listed_message(socket, _), do: socket

  defp list_error(:enoent), do: gettext("This folder is gone.")
  defp list_error(:symlink), do: gettext("Symbolic links cannot be opened here.")
  defp list_error(:task_failed), do: gettext("Could not list this folder.")
  defp list_error(_), do: gettext("Could not list this folder.")
end
