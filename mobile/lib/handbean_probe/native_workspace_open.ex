defmodule HandbeanProbe.NativeWorkspaceOpen do
  @moduledoc """
  Unified user open for chat artifacts and the workspace tree.

  Validates the current workspace (and conversation for timeline taps).
  Text/image go to NativeFileViewer metadata. PDF and other external
  names reuse NativeArtifactDelivery export → open_snapshot.

  Open requests are correlated by the `:workspace_open` scope of
  `HandbeanProbe.PendingRequests` (via `HomeScreen.Requests`): `request/2` and
  `close/1` bump it, `handle_ready/3` and the viewer identity compare against
  it. A composer reset never touches this scope, so an opened file does not
  become stale when a message is sent.
  """

  use Gettext, backend: HandbeanProbe.Gettext
  import Mob.Socket, only: [assign: 2, assign: 3]
  import HandbeanProbe.NativeUI

  alias HandbeanProbe.HomeScreen.{Notice, Requests}
  alias HandbeanProbe.{NativeArtifactDelivery, NativeFileViewer}

  @scope :workspace_open

  @doc "Current `:workspace_open` generation."
  def generation(socket), do: Requests.generation(socket, @scope)

  def spec(source, relative_path, workspace_id, conversation_id \\ nil) do
    %{
      source: source,
      relative_path: relative_path,
      workspace_id: workspace_id,
      conversation_id: conversation_id
    }
  end

  def request(socket, spec) when is_map(spec) do
    {generation, socket} = Requests.bump(socket, @scope)

    socket =
      socket
      |> assign(file_viewer: NativeFileViewer.new())
      |> Notice.clear()

    case authorize(socket, spec) do
      {:ok, attrs} ->
        run_io(socket, generation, fn ->
          {:workspace_open_ready, generation, NativeFileViewer.prepare(attrs)}
        end)

      {:error, reason} ->
        Notice.put_error(socket, human_error(reason))
    end
  end

  def request(socket, _), do: Notice.put_error(socket, human_error(:invalid_path))

  def handle_ready(socket, generation, result) do
    if not Requests.current?(socket, @scope, generation) do
      socket
    else
      case result do
        {:ok, %{status: :external, identity: identity} = state} ->
          touch_file(identity)

          socket
          |> assign(:file_viewer, NativeFileViewer.close(state))
          |> NativeArtifactDelivery.start_file_action(:open_file, identity.relative_path)

        {:ok, %{status: :ready, identity: identity} = state} ->
          touch_file(identity)
          socket |> assign(:file_viewer, state) |> Notice.clear()

        {:ok, %{status: :error} = state} ->
          socket |> assign(:file_viewer, state) |> Notice.put_error(human_error(state.error))

        {:error, reason} ->
          Notice.put_error(socket, human_error(reason))

        _ ->
          Notice.put_error(socket, human_error(:file_unavailable))
      end
    end
  end

  def close(socket) do
    viewer = socket.assigns[:file_viewer] || NativeFileViewer.new()
    {_generation, socket} = Requests.bump(socket, @scope)

    socket
    |> assign(file_viewer: NativeFileViewer.close(viewer))
    |> Notice.clear()
  end

  def system_open(socket) do
    case current_identity(socket) do
      {:ok, identity} ->
        NativeArtifactDelivery.start_file_action(
          socket,
          :open_file,
          spec(:tree, identity.relative_path, identity.workspace_id)
        )

      {:error, reason} ->
        Notice.put_error(socket, human_error(reason))
    end
  end

  def share(socket) do
    case current_identity(socket) do
      {:ok, identity} ->
        NativeArtifactDelivery.start_file_action(
          socket,
          :share_file,
          spec(:tree, identity.relative_path, identity.workspace_id)
        )

      {:error, reason} ->
        Notice.put_error(socket, human_error(reason))
    end
  end

  def overlay?(%{file_viewer: %{status: status}}) when status in [:ready, :error], do: true
  def overlay?(_), do: false

  def render_overlay(a) do
    viewer = a.file_viewer
    name = viewer.identity && viewer.identity.display_name

    page(
      [
        row([
          icon("back", :close_file_viewer),
          text(name || gettext("File"), text_size: 14, weight: 1, font_weight: "bold")
        ]),
        notice(Notice.text(Map.get(a, :notice))),
        actions_row([
          button(gettext("Open in another app"), :file_viewer_open_external,
            text_size: 11,
            padding: 6
          ),
          button(gettext("Share"), :file_viewer_share, text_size: 11, padding: 6)
        ]),
        NativeFileViewer.viewer_node(viewer)
      ],
      back_target: inspect(:close_file_viewer)
    )
  end

  defp current_identity(socket) do
    case identity(socket) do
      %NativeFileViewer.Identity{} = identity ->
        workspace = socket.assigns[:workspace]

        cond do
          not match?(%{"id" => _}, workspace) ->
            {:error, :stale_workspace}

          identity.workspace_id != workspace["id"] ->
            {:error, :stale_workspace}

          identity.generation != generation(socket) ->
            {:error, :stale_request}

          true ->
            {:ok, identity}
        end

      _ ->
        {:error, :file_unavailable}
    end
  end

  defp identity(%{assigns: %{file_viewer: %{identity: %NativeFileViewer.Identity{} = identity}}}),
    do: identity

  defp identity(_), do: nil

  defp touch_file(%NativeFileViewer.Identity{} = identity) do
    path = Path.join(identity.workspace_root, identity.relative_path)
    _ = Handbean.Search.touch(identity.workspace_root, path)
    :ok
  end

  defp authorize(socket, spec) do
    workspace = socket.assigns[:workspace]
    chat = socket.assigns[:chat]
    # `spec/4` terms round-trip through Mob tap targets unchanged: atom keys only.
    source = Map.get(spec, :source)
    relative = Map.get(spec, :relative_path)
    workspace_id = Map.get(spec, :workspace_id)
    conversation_id = Map.get(spec, :conversation_id)

    with :ok <- match_workspace(workspace, workspace_id),
         :ok <- match_conversation(source, chat, conversation_id),
         {:ok, rel} <- file_target(relative, workspace["path"]),
         request_id <- Ecto.UUID.generate() do
      {:ok,
       %{
         workspace_id: workspace["id"],
         workspace_root: workspace["path"],
         relative_path: rel,
         request_id: request_id,
         # Viewer identity follows the open request, not the composer:
         # a composer reset (send / conversation switch) must not make an
         # already opened file stale. `request/2` bumps this before authorize.
         generation: generation(socket)
       }}
    end
  end

  defp match_workspace(%{"id" => id, "path" => path}, workspace_id)
       when is_binary(id) and is_binary(path) and id != "" and path != "" do
    if is_binary(workspace_id) and workspace_id == id do
      :ok
    else
      {:error, :stale_workspace}
    end
  end

  defp match_workspace(_, _), do: {:error, :stale_workspace}

  defp match_conversation(:timeline, %{conversation: %{"id" => id}}, conversation_id)
       when is_binary(id) do
    if conversation_id == id, do: :ok, else: {:error, :stale_conversation}
  end

  defp match_conversation(:timeline, _, _), do: {:error, :stale_conversation}

  defp match_conversation(source, _, _) when source in [:tree, :attachments], do: :ok

  defp match_conversation(_, _, _), do: {:error, :invalid_source}

  defp file_target(path, workspace) do
    case NativeArtifactDelivery.workspace_file_target(path, workspace) do
      {:ok, rel} -> {:ok, rel}
      _ -> {:error, :invalid_path}
    end
  end

  defp run_io(socket, generation, work) do
    owner = self()

    starter =
      Application.get_env(:handbean_probe, :workspace_io_start) ||
        (&Task.Supervisor.start_child(HandbeanProbe.TaskSupervisor, &1))

    case starter.(fn ->
           try do
             send(owner, work.())
           rescue
             error ->
               send(
                 owner,
                 {:workspace_open_ready, generation, {:error, Exception.message(error)}}
               )
           catch
             kind, reason ->
               send(owner, {:workspace_open_ready, generation, {:error, {kind, reason}}})
           end
         end) do
      {:ok, _} ->
        socket

      {:error, reason} ->
        handle_ready(socket, generation, {:error, reason})
    end
  end

  defp human_error(:stale_workspace),
    do: gettext("This file is not in the current workspace.")

  defp human_error(:stale_conversation),
    do: gettext("This message is no longer in the open conversation.")

  defp human_error(:invalid_path),
    do: gettext("That path is not a file in this workspace.")

  defp human_error(:invalid_source),
    do: gettext("That path is not a file in this workspace.")

  defp human_error(:enoent),
    do: gettext("The file is gone.")

  defp human_error(:symlink),
    do: gettext("Symbolic links cannot be opened here.")

  defp human_error(:file_unavailable),
    do: gettext("The file could not be opened.")

  defp human_error(:stale_request),
    do: gettext("This file is no longer the open request.")

  defp human_error(reason) when is_atom(reason),
    do: gettext("The file could not be opened.") <> " (#{reason})"

  defp human_error(_),
    do: gettext("The file could not be opened.")
end
