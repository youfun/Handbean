defmodule HandbeanProbe.NativeWorkspaces do
  @moduledoc "Native workspace list, create, add, drafts, and selection restore."

  use Gettext, backend: HandbeanProbe.Gettext
  import HandbeanProbe.NativeUI

  alias Handbean.{ConversationStore, WorkspaceStore}
  alias Handbean.Security.PathValidator
  alias HandbeanProbe.{NativeApproval, NativeFolderBrowser, NativeWorkspaceImport}

  def empty_state do
    %{
      mode: :list,
      name: "",
      error: nil,
      notice: nil,
      items: [],
      browser: nil,
      import: NativeWorkspaceImport.idle(),
      creating?: false,
      expanded_paths: MapSet.new()
    }
  end

  def load(current) do
    %{empty_state() | items: items(current && current["id"])}
  end

  def items(current_id) do
    WorkspaceStore.list()
    |> Enum.sort_by(& &1["last_opened_at"], :desc)
    |> Enum.map(fn workspace ->
      %{
        id: workspace["id"],
        name: workspace["name"] || gettext("Workspace"),
        path: workspace["path"],
        path_summary: path_summary(workspace["path"]),
        source: source_label(workspace),
        current?: workspace["id"] == current_id,
        default?: workspace["default"] == true
      }
    end)
  end

  def canonicalize(path) when is_binary(path) do
    case PathValidator.canonicalize(path) do
      {:ok, canonical} -> canonical
      {:error, _} -> Path.expand(path)
    end
  end

  def canonicalize(_), do: nil

  def create_empty(name, opts \\ []) do
    display = name |> to_string() |> String.trim()

    cond do
      display == "" ->
        {:error, :blank_name}

      true ->
        root = created_root()
        File.mkdir_p!(root)
        dir = Path.join(root, generated_dir_id())

        if File.exists?(dir) do
          {:error, :exists}
        else
          case File.mkdir(dir) do
            :ok -> register_created(dir, display, opts)
            {:error, reason} -> {:error, reason}
          end
        end
    end
  end

  def add_accessible(raw_path) do
    path = raw_path |> to_string() |> String.trim()

    cond do
      path == "" ->
        {:error, :blank_path}

      uri_path?(path) ->
        {:error, :not_posix}

      true ->
        canonical = canonicalize(path)

        case find_by_canonical(canonical) do
          %{} = existing ->
            {:ok, touch!(existing)}

          nil ->
            WorkspaceStore.add(canonical, name: Path.basename(canonical))
        end
    end
  end

  defp resolve_saved_conversation(_workspace, nil), do: nil
  defp resolve_saved_conversation(workspace, id), do: resolve_conversation(workspace, id)

  def resolve_conversation(workspace, preferred_id \\ nil) do
    conversations = ConversationStore.list_for_workspace(workspace["id"])

    cond do
      is_binary(preferred_id) ->
        case ConversationStore.get(preferred_id) do
          {:ok, conversation} ->
            if conversation["workspace_id"] == workspace["id"],
              do: conversation,
              else: List.first(conversations)

          _ ->
            List.first(conversations)
        end

      true ->
        List.first(conversations)
    end
  end

  def restore(default_workspace) do
    pref = read_pref()
    workspace = restore_workspace(pref["workspace_id"], default_workspace)

    conversation =
      if workspace do
        conversations = Map.get(pref, "conversations", %{})

        cond do
          Map.has_key?(conversations, workspace["id"]) ->
            resolve_saved_conversation(workspace, conversations[workspace["id"]])

          true ->
            resolve_conversation(workspace, pref["conversation_id"])
        end
      end

    if workspace, do: persist(workspace, conversation)
    {workspace, conversation}
  end

  def persist(workspace, conversation) do
    prev = read_pref()
    conversations = Map.get(prev, "conversations", %{})

    conversations =
      if workspace["id"] do
        Map.put(conversations, workspace["id"], conversation && conversation["id"])
      else
        conversations
      end

    write_pref(%{
      "workspace_id" => workspace["id"],
      "conversation_id" => conversation && conversation["id"],
      "conversations" => conversations
    })
  end

  def put_draft(drafts, workspace, chat, text) do
    Map.put(drafts || %{}, draft_key(workspace, chat && chat.conversation), text || "")
  end

  def get_draft(drafts, workspace, conversation) do
    Map.get(drafts || %{}, draft_key(workspace, conversation), "")
  end

  def clear_draft(drafts, workspace, conversation) do
    Map.put(drafts || %{}, draft_key(workspace, conversation), "")
  end

  def selection(workspace, conversation) do
    workspace = touch!(workspace)

    %{
      workspace: workspace,
      conversation: conversation,
      conversations: ConversationStore.list_for_workspace(workspace["id"]),
      permission_mode: NativeApproval.mode(conversation)
    }
  end

  def action({:change_name, value}, state, _current) do
    %{state | name: value, error: nil}
  end

  def action({:toggle_path, id}, state, _current) do
    expanded = state.expanded_paths || MapSet.new()

    expanded =
      if MapSet.member?(expanded, id),
        do: MapSet.delete(expanded, id),
        else: MapSet.put(expanded, id)

    %{state | expanded_paths: expanded}
  end

  def action(:open_create, state, _current) do
    %{state | mode: :create, name: "", error: nil, notice: nil, creating?: false}
  end

  def action(:open_list, state, current) do
    %{load(current) | notice: state.notice, import: state.import}
  end

  def action(:create, %{creating?: true} = state, _current), do: state

  def action(:create, state, current) do
    state = %{state | creating?: true, error: nil}

    case create_empty(state.name) do
      {:ok, workspace} ->
        {:switch, workspace, nil, %{load(current) | notice: gettext("Workspace created")}}

      {:error, reason} ->
        %{state | creating?: false, error: create_error(reason)}
    end
  end

  def action(:open_browse, state, _current) do
    %{state | mode: :browse, browser: NativeFolderBrowser.start(nil, lazy: true), error: nil}
  end

  def action({:browse, browse_action}, state, current) do
    case NativeFolderBrowser.action(browse_action, state.browser) do
      {:select, path} ->
        case add_accessible(path) do
          {:ok, workspace} ->
            {:switch, workspace, resolve_conversation(workspace),
             %{load(current) | notice: gettext("Workspace added")}}

          {:error, reason} ->
            %{state | error: add_error(reason)}
        end

      browser ->
        %{state | browser: browser, error: nil}
    end
  end

  def action(:start_import, state, _current) do
    case NativeWorkspaceImport.start(state.import) do
      {:ok, import} ->
        %{state | mode: :importing, import: import, error: nil, notice: nil}

      {:error, :unavailable} ->
        %{
          state
          | mode: :list,
            error:
              gettext(
                "System folder import is only available on the Android app. It copies into the app workspace; edits do not write back to the original folder."
              )
        }

      {:error, reason} ->
        %{state | error: import_error(reason)}
    end
  end

  def action(:cancel_import, state, current) do
    %{
      load(current)
      | import: NativeWorkspaceImport.cancel(state.import),
        notice: gettext("Import cancelled")
    }
  end

  def action({:files, :cancelled}, state, current) do
    case NativeWorkspaceImport.handle_cancelled(state.import) do
      {:ignored, import} ->
        %{state | import: import}

      {:cancelled, import} ->
        %{load(current) | import: import, notice: gettext("Import cancelled")}
    end
  end

  def action({:files, :picked, items}, state, current) do
    case NativeWorkspaceImport.handle_picked(state.import, items) do
      {:ok, workspace, import} ->
        {:switch, workspace, resolve_conversation(workspace),
         %{load(current) | import: import, notice: gettext("Workspace imported")}}

      {:ignored, import} ->
        %{state | import: import}

      {:error, reason, import} ->
        %{load(current) | import: import, error: import_error(reason)}
    end
  end

  def action(_action, state, _current), do: state

  @doc "Install directory entries listed off-process for the browser at `path`."
  def put_browser_entries(%{mode: :browse, browser: browser} = state, path, entries)
      when is_map(browser) do
    %{state | browser: NativeFolderBrowser.put_entries(browser, path, entries)}
  end

  def put_browser_entries(state, _path, _entries), do: state

  def render(state, current) do
    node(:column, [weight: 1, fill_width: true], [
      notice(state.error),
      notice(state.notice),
      case state.mode do
        :create -> create_form(state)
        :browse -> browse_form(state)
        :importing -> import_form(state)
        _ -> list_form(state, current)
      end
    ])
  end

  def created_root, do: Path.join(data_dir(), "created_workspaces")
  def imported_root, do: Path.join(data_dir(), "imported_workspaces")
  def pref_path, do: Path.join(data_dir(), ".handbean/native_ui.json")

  defp list_form(state, _current) do
    scroll(
      [
        settings_caption(
          gettext("Switching projects keeps running work in the previous conversation.")
        ),
        settings_group([
          settings_nav_row(gettext("Browse current workspace files"), "", {:page, :files}),
          settings_nav_row(gettext("Create empty workspace"), "", :open_create),
          settings_nav_row(gettext("Add accessible folder"), "", :open_browse),
          settings_nav_row(gettext("Import Android folder copy"), "", :start_import)
        ]),
        settings_caption(
          gettext(
            "Import copies into the app workspace. Edits do not write back to the original folder."
          )
        )
      ] ++ Enum.map(state.items, &workspace_row(&1, state))
    )
  end

  defp workspace_row(item, state) do
    expanded? = MapSet.member?(state.expanded_paths || MapSet.new(), item.id)

    settings_group([
      settings_value_row(item.name, if(item.current?, do: gettext("Current"), else: "")),
      settings_value_row(
        item.source,
        if(expanded?, do: item.path, else: item.path_summary)
      ),
      settings_nav_row(
        if(expanded?, do: gettext("Hide full path"), else: gettext("Show full path")),
        "",
        {:toggle_path, item.id}
      ),
      if(not item.current?,
        do: settings_nav_row(gettext("Switch"), "", {:workspace, item.id})
      )
    ])
  end

  defp create_form(state) do
    scroll([
      settings_section(gettext("Create empty workspace")),
      settings_caption(
        gettext("The display name is not a filesystem path. The app creates a private folder.")
      ),
      settings_group([
        field(gettext("Display name"), state.name, :workspace_name)
      ]),
      settings_group([
        settings_nav_row(gettext("Create and open"), "", :create_workspace),
        settings_nav_row(gettext("Back"), "", :workspace_list, quiet: true)
      ])
    ])
  end

  defp browse_form(state) do
    browser = state.browser

    scroll(
      [
        settings_section(gettext("Add accessible folder")),
        settings_caption(
          gettext(
            "Only folders the app can already read. This is not the system Downloads picker."
          )
        ),
        settings_caption(browser.path),
        settings_group([
          settings_nav_row(gettext("Use this folder"), "", {:browse, :select}),
          settings_nav_row(gettext("Up"), "", {:browse, :up}),
          settings_nav_row(gettext("Back"), "", :workspace_list, quiet: true)
        ]),
        settings_section(gettext("Folders"))
      ] ++
        Enum.map(browser.entries, fn entry ->
          settings_group([
            settings_nav_row(entry.name, "", {:browse, {:enter, entry.name}})
          ])
        end) ++
        cond do
          NativeFolderBrowser.loading?(browser) -> [settings_caption(gettext("Loading…"))]
          browser.entries == [] -> [settings_caption(gettext("No subfolders"))]
          true -> []
        end
    )
  end

  defp import_form(state) do
    scroll([
      settings_section(gettext("Import Android folder copy")),
      settings_caption(
        gettext("Copying into the app workspace. Edits do not write back to the original folder.")
      ),
      settings_caption(gettext("Importing…")),
      if(state.import.request_id, do: settings_caption(state.import.request_id)),
      settings_group([
        settings_nav_row(gettext("Cancel import"), "", :cancel_import, danger: true)
      ])
    ])
  end

  defp register_created(dir, display, opts) do
    register =
      Keyword.get(opts, :register, fn path, add_opts -> WorkspaceStore.add(path, add_opts) end)

    case register.(dir, name: display) do
      {:ok, workspace} ->
        {:ok, workspace}

      {:error, reason} ->
        rollback_owned(dir, created_root())
        {:error, reason}
    end
  end

  defp rollback_owned(dir, root) do
    if owned_path?(dir, root) do
      File.rm_rf(dir)
    end

    :ok
  end

  def owned_path?(path, root) do
    canonical = canonicalize(path)
    root = canonicalize(root)
    is_binary(canonical) and is_binary(root) and Path.dirname(canonical) == root
  end

  defp generated_dir_id do
    "ws_" <>
      Integer.to_string(System.os_time(:millisecond)) <>
      "_" <>
      Integer.to_string(:erlang.unique_integer([:positive]))
  end

  defp find_by_canonical(nil), do: nil

  defp find_by_canonical(canonical) do
    Enum.find(WorkspaceStore.list(), fn workspace ->
      canonicalize(workspace["path"]) == canonical
    end)
  end

  defp touch!(workspace) do
    case WorkspaceStore.touch(workspace["id"]) do
      {:ok, updated} -> updated
      _ -> workspace
    end
  end

  defp restore_workspace(id, default) when is_binary(id) do
    case WorkspaceStore.get(id) do
      {:ok, workspace} ->
        if File.dir?(workspace["path"]), do: workspace, else: default

      _ ->
        default
    end
  end

  defp restore_workspace(_, default), do: default

  defp read_pref do
    path = pref_path()

    case File.read(path) do
      {:ok, content} ->
        case Handbean.JSON.decode(content) do
          {:ok, data} when is_map(data) -> data
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp write_pref(data) do
    path = pref_path()
    File.mkdir_p!(Path.dirname(path))

    case Handbean.JSON.encode(data) do
      {:ok, json} -> File.write(path, json)
      _ -> :error
    end
  end

  defp draft_key(nil, nil), do: {:empty, :free}
  defp draft_key(workspace, nil), do: {:empty, workspace["id"]}
  defp draft_key(_workspace, conversation), do: {:conversation, conversation["id"]}

  defp uri_path?("content://" <> _), do: true
  defp uri_path?("file://" <> _), do: true
  defp uri_path?(_), do: false

  defp path_summary(nil), do: ""

  defp path_summary(path) do
    parts = Path.split(path)

    if length(parts) > 3 do
      Path.join(["…"] ++ Enum.take(parts, -3))
    else
      path
    end
  end

  defp source_label(workspace) do
    path = workspace["path"] || ""

    cond do
      workspace["default"] == true -> gettext("Default")
      owned_path?(path, created_root()) -> gettext("Private empty workspace")
      owned_path?(path, imported_root()) -> gettext("Imported copy")
      true -> gettext("Accessible folder")
    end
  end

  defp data_dir, do: Handbean.Host.data_dir()

  defp create_error(:blank_name), do: gettext("Enter a display name")
  defp create_error(:exists), do: gettext("Could not create the workspace folder. Try again.")
  defp create_error(_), do: gettext("Could not create the workspace. Check available storage.")

  defp add_error(:blank_path), do: gettext("Choose a folder")
  defp add_error(:not_posix), do: gettext("This is not a readable app folder path.")

  defp add_error(reason) when is_binary(reason) do
    cond do
      String.contains?(reason, "does not exist") ->
        gettext("That folder is gone or not readable.")

      String.contains?(reason, "must be a directory") ->
        gettext("Choose a folder, not a file.")

      String.contains?(reason, "Cannot read") ->
        gettext("That folder is gone or not readable.")

      String.contains?(reason, "cannot be added") ->
        gettext("That location cannot be added as a workspace.")

      true ->
        gettext("Could not add that folder.")
    end
  end

  defp add_error(_), do: gettext("Could not add that folder.")

  defp import_error(:cancelled), do: gettext("Import cancelled")
  defp import_error(:too_large), do: gettext("This folder is too large to import.")
  defp import_error(:unsafe_name), do: gettext("A file name in that folder is not allowed.")
  defp import_error(:enospc), do: gettext("Not enough storage to import this folder.")

  defp import_error(:copy_failed),
    do: gettext("Import failed. The original folder was not changed.")

  defp import_error(reason) when is_binary(reason), do: add_error(reason)
  defp import_error(_), do: gettext("Import failed. The original folder was not changed.")
end
