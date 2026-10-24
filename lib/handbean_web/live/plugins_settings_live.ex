defmodule HandbeanWeb.PluginsSettingsLive do
  @moduledoc """
  Unified Plugins settings LiveView embedded in `HandbeanWeb.SettingsLive`.

  Manages Extensions, MCP servers, and Skills from their respective domain
  owners without keeping shadow state in the UI.
  """

  use HandbeanWeb, :live_view

  alias Handbean.ConversationStore
  alias Handbean.Extension.Settings, as: ExtensionSettings
  alias Handbean.MCP.OAuth
  alias Handbean.MCP.Settings, as: MCPSettings
  alias Handbean.Plugins.Catalog
  alias Handbean.Skills.Settings, as: SkillSettings
  alias Handbean.WorkspaceStore

  @impl true
  def mount(_params, session, socket) do
    workspaces = WorkspaceStore.list()
    workspace_id = session["workspace_id"]

    workspace =
      Enum.find(workspaces, &(&1["id"] == workspace_id)) || List.first(workspaces) || %{}

    workspace_root =
      session["workspace_root"] || workspace["path"] || File.cwd!()

    workspace_name =
      session["workspace_name"] || workspace["name"] || Path.basename(workspace_root)

    initial_mech =
      case session["initial_mech"] do
        mech when mech in ["all", "ext", "mcp", "skill"] -> mech
        _ -> "all"
      end

    socket =
      socket
      |> assign(:workspace_id, workspace_id || workspace["id"])
      |> assign(:workspace_name, workspace_name)
      |> assign(:workspace_root, workspace_root)
      |> assign(:workspaces, workspaces)
      |> assign(:mode, "installed")
      |> assign(:mech_filter, initial_mech)
      |> assign(:search_query, "")
      |> assign(:agent_prompt, "")
      |> assign(:extensions, [])
      |> assign(:servers, [])
      |> assign(:skills, [])
      |> assign(:catalog, [])
      |> assign(:load_error, nil)
      |> assign(:notice, nil)
      |> assign(:form, nil)
      |> assign(:form_error, nil)
      |> assign(:editing_transport, nil)
      |> assign(:testing, false)
      |> assign(:test_result, nil)
      |> assign(:test_generation, 0)
      |> assign(:delete_target, nil)
      |> assign(:inspect_modal, nil)
      |> assign(:import_modal, nil)
      |> reload_all()

    {:ok, socket}
  end

  # ── Navigation & Filtering Events ──

  @impl true
  def handle_event("switch_mode", %{"mode" => mode}, socket)
      when mode in ["installed", "discover"] do
    {:noreply, socket |> assign(:mode, mode) |> assign(:notice, nil)}
  end

  def handle_event("filter_mech", %{"mech" => mech}, socket)
      when mech in ["all", "ext", "mcp", "skill"] do
    {:noreply, assign(socket, :mech_filter, mech)}
  end

  def handle_event("search", %{"query" => query}, socket) do
    {:noreply, assign(socket, :search_query, String.trim(query))}
  end

  # ── Extension Events ──

  def handle_event("toggle_ext", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.extensions, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      ext ->
        case ExtensionSettings.set_enabled(id, not ext.enabled,
               project: socket.assigns.workspace_root
             ) do
          :ok ->
            {:noreply, socket |> assign(:load_error, nil) |> reload_all()}

          {:error, reason} ->
            {:noreply, assign(socket, :load_error, reason)}
        end
    end
  end

  def handle_event("inspect_ext", %{"id" => id}, socket) do
    case ExtensionSettings.inspect_extension(id, project: socket.assigns.workspace_root) do
      {:ok, %{item: item, code: code, diagnostic: diagnostic}} ->
        modal = %{
          kind: :view,
          title: item.name,
          diagnostic: diagnostic,
          code: code
        }

        {:noreply, assign(socket, :inspect_modal, modal)}

      {:error, reason} ->
        {:noreply, assign(socket, :load_error, reason)}
    end
  end

  # ── Skill Events ──

  def handle_event("toggle_skill", %{"name" => name}, socket) do
    case Enum.find(socket.assigns.skills, &(&1.name == name)) do
      nil ->
        {:noreply, socket}

      %{readonly: true} ->
        {:noreply, assign(socket, :notice, gettext("内置 Skill 不可直接修改"))}

      skill ->
        case SkillSettings.set_enabled(name, not skill.enabled,
               workspace: socket.assigns.workspace_root
             ) do
          :ok ->
            {:noreply, socket |> assign(:notice, nil) |> reload_all()}

          {:error, reason} ->
            {:noreply, assign(socket, :load_error, reason)}
        end
    end
  end

  def handle_event("inspect_skill", %{"name" => name}, socket) do
    case SkillSettings.inspect_skill(name, workspace: socket.assigns.workspace_root) do
      {:ok, %{item: item, content: content}} ->
        modal = %{
          kind: :view,
          title: item.name,
          diagnostic: nil,
          code: content
        }

        {:noreply, assign(socket, :inspect_modal, modal)}

      {:error, reason} ->
        {:noreply, assign(socket, :load_error, reason)}
    end
  end

  def handle_event("close_inspect", _params, socket) do
    {:noreply, assign(socket, :inspect_modal, nil)}
  end

  # ── Discover & Import Events ──

  def handle_event("open_mcp_preset", %{"id" => cat_id}, socket) do
    case Catalog.get(cat_id) do
      {:ok, %{mech: :mcp} = preset} ->
        form =
          socket.assigns.workspace_id
          |> MCPSettings.new_form()
          |> Map.merge(%{
            "name" => preset.name,
            "url" => preset.url,
            "auth" => preset.auth
          })

        {:noreply, socket |> assign(:editing_transport, :http) |> open_form(form)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("open_catalog_install", %{"id" => cat_id}, socket) do
    case Catalog.get(cat_id) do
      {:ok, item} when item.mech in [:skill, :ext] ->
        modal = %{
          kind: :install_catalog,
          id: item.id,
          title: gettext("安装 %{name}", name: item.name),
          diagnostic: nil,
          code: Map.get(item, :content) || Map.get(item, :entry_code, ""),
          scope: "workspace"
        }

        {:noreply, assign(socket, :inspect_modal, modal)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event(
        "confirm_catalog_install",
        %{"catalog_id" => cat_id, "scope" => scope},
        socket
      ) do
    case Catalog.install(cat_id, scope, project: socket.assigns.workspace_root) do
      {:ok, _name} ->
        {:noreply,
         socket
         |> assign(:inspect_modal, nil)
         |> assign(:mode, "installed")
         |> assign(:load_error, nil)
         |> reload_all()}

      {:error, reason} ->
        {:noreply, assign(socket, :load_error, reason)}
    end
  end

  def handle_event("open_import_modal", _params, socket) do
    {:noreply, assign(socket, :import_modal, %{path: "", scope: "workspace", error: nil})}
  end

  def handle_event("close_import_modal", _params, socket) do
    {:noreply, assign(socket, :import_modal, nil)}
  end

  def handle_event(
        "submit_import_dir",
        %{"import" => %{"path" => path, "scope" => scope}},
        socket
      ) do
    case Catalog.import_from_dir(path, scope, project: socket.assigns.workspace_root) do
      {:ok, {_mech, _name}} ->
        {:noreply,
         socket
         |> assign(:import_modal, nil)
         |> assign(:mode, "installed")
         |> assign(:load_error, nil)
         |> reload_all()}

      {:error, reason} ->
        {:noreply, assign(socket, :import_modal, %{path: path, scope: scope, error: reason})}
    end
  end

  def handle_event("agent_builder_submit", %{"prompt" => raw_prompt}, socket) do
    prompt = String.trim(raw_prompt)
    ws_id = socket.assigns.workspace_id
    ws_root = socket.assigns.workspace_root

    if prompt == "" or not is_binary(ws_id) do
      {:noreply, socket}
    else
      title = String.slice(prompt, 0, 48)

      case ConversationStore.create(ws_id,
             checkout_path: ws_root,
             title: title,
             title_source: "user"
           ) do
        {:ok, conv} ->
          draft = "/skill:developing-handbean-extensions " <> prompt
          query = URI.encode_query(%{"draft" => draft})
          {:noreply, push_navigate(socket, to: "/w/#{ws_id}/c/#{conv["id"]}?#{query}")}

        {:error, _reason} ->
          {:noreply, assign(socket, :load_error, gettext("无法创建工作区对话"))}
      end
    end
  end

  # ── MCP Events ──

  def handle_event("toggle_mcp", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.servers, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      server ->
        case MCPSettings.toggle_disabled(id, not server.disabled) do
          {:ok, _id} ->
            {:noreply, reload_all(socket)}

          {:error, reason} ->
            {:noreply, assign(socket, :load_error, reason)}
        end
    end
  end

  def handle_event("new", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_transport, :http)
     |> open_form(MCPSettings.new_form(socket.assigns.workspace_id))}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    case MCPSettings.edit(id) do
      {:ok, form} ->
        transport =
          case Enum.find(socket.assigns.servers, &(&1.id == id)) do
            nil -> :http
            server -> server.transport
          end

        {:noreply, socket |> assign(:editing_transport, transport) |> open_form(form)}

      {:error, reason} ->
        {:noreply, assign(socket, :load_error, reason)}
    end
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, socket |> assign(:form, nil) |> assign(:form_error, nil) |> invalidate_test()}
  end

  def handle_event("change", %{"server" => params}, socket) do
    form = merge_form(socket.assigns.form, params)
    {:noreply, socket |> assign(:form, form) |> assign(:form_error, nil) |> invalidate_test()}
  end

  def handle_event("save", %{"server" => params}, socket) do
    form = merge_form(socket.assigns.form, params)

    case MCPSettings.save(form) do
      {:ok, _id} ->
        {:noreply,
         socket
         |> assign(:form, nil)
         |> assign(:form_error, nil)
         |> assign(:mode, "installed")
         |> reload_all()}

      {:error, reason} ->
        {:noreply, socket |> assign(:form, form) |> assign(:form_error, reason)}
    end
  end

  def handle_event("test_connection", _params, socket) do
    form = socket.assigns.form
    generation = socket.assigns.test_generation + 1

    {:noreply,
     socket
     |> assign(:form, form)
     |> assign(:testing, true)
     |> assign(:test_result, nil)
     |> assign(:test_generation, generation)
     |> start_async({:test_connection, generation}, fn ->
       {generation, MCPSettings.test_connection(form)}
     end)}
  end

  def handle_event("confirm_delete", %{"id" => id}, socket) do
    {:noreply, assign(socket, :delete_target, id)}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :delete_target, nil)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case MCPSettings.delete(id) do
      :ok ->
        {:noreply,
         socket
         |> assign(:delete_target, nil)
         |> then(fn socket ->
           if socket.assigns.form && socket.assigns.form["id"] == id,
             do: assign(socket, :form, nil),
             else: socket
         end)
         |> reload_all()}

      {:error, reason} ->
        {:noreply, socket |> assign(:delete_target, nil) |> assign(:load_error, reason)}
    end
  end

  @impl true
  def handle_async({:test_connection, generation}, {:ok, {generation, result}}, socket) do
    if generation == socket.assigns.test_generation do
      {:noreply, socket |> assign(:testing, false) |> assign(:test_result, result)}
    else
      {:noreply, socket}
    end
  end

  def handle_async({:test_connection, generation}, {:exit, _reason}, socket) do
    if generation == socket.assigns.test_generation do
      {:noreply,
       socket
       |> assign(:testing, false)
       |> assign(:test_result, {:error, "Connection test failed or timed out"})}
    else
      {:noreply, socket}
    end
  end

  # ── View Helpers ──

  def filtered_extensions(extensions, query) do
    filter_by_query(extensions, query, &[&1.name, &1.description])
  end

  def filtered_servers(servers, query) do
    filter_by_query(servers, query, &[&1.name, &1.url || "", &1.description || ""])
  end

  def filtered_skills(skills, query) do
    filter_by_query(skills, query, &[&1.name, &1.description])
  end

  def filtered_catalog(catalog, mech, query) do
    catalog
    |> Enum.filter(&(&1.mech == mech))
    |> filter_by_query(query, &[&1.name, &1.description])
  end

  def show_section?(mech_filter, target) do
    mech_filter == "all" or mech_filter == target
  end

  def filter_active?(mech_filter, query) do
    mech_filter != "all" or String.trim(query || "") != ""
  end

  def section_visible?(mech_filter, target, items, filtering?) do
    show_section?(mech_filter, target) and (items != [] or not filtering?)
  end

  def ext_source_label(:project), do: gettext("工作区")
  def ext_source_label(:user), do: gettext("用户级")
  def ext_source_label(_), do: gettext("本地")

  def ext_status_badge(%{status: :enabled}), do: {"ok", gettext("已启用")}
  def ext_status_badge(%{status: :error}), do: {"err", gettext("编译错误")}
  def ext_status_badge(%{status: :untrusted_project}), do: {"", gettext("未信任工作区")}
  def ext_status_badge(_), do: {"", gettext("已禁用")}

  def ext_meta_label(ext) do
    parts =
      [
        if(ext.tool_count > 0, do: "#{ext.tool_count} 个工具"),
        if(ext.hook_count > 0, do: "#{ext.hook_count} 个 Hook")
      ]
      |> Enum.reject(&is_nil/1)

    case parts do
      [] -> "0 个工具"
      list -> Enum.join(list, " · ")
    end
  end

  def mcp_scope_label(server, workspace_id, workspace_name) do
    case server.workspace_access do
      %{"mode" => "all"} ->
        gettext("全部工作区")

      %{"mode" => "selected", "workspace_ids" => ids} when is_list(ids) ->
        cond do
          ids == [] ->
            gettext("未授权")

          ids == [workspace_id] ->
            gettext("仅 %{name}", name: workspace_name)

          true ->
            gettext("%{count} 个工作区", count: length(ids))
        end

      _ ->
        gettext("全部工作区")
    end
  end

  def mcp_status_badge(%{disabled: true}), do: {"", gettext("已禁用")}
  def mcp_status_badge(%{status: :connected}), do: {"ok", gettext("已连接")}
  def mcp_status_badge(_), do: {"", gettext("未连接")}

  def skill_source_label(:project), do: gettext("工作区")
  def skill_source_label(:user), do: gettext("用户级")
  def skill_source_label(:bundled), do: gettext("内置")
  def skill_source_label(_), do: gettext("本地")

  def skill_status_badge(%{enabled: true}), do: {"ok", gettext("已启用")}
  def skill_status_badge(_), do: {"", gettext("仅手动调用")}

  # ── Internal State Loaders ──

  defp reload_all(socket) do
    workspace_root = socket.assigns.workspace_root
    {:ok, extensions} = ExtensionSettings.list(project: workspace_root)
    {:ok, skills} = SkillSettings.list(workspace: workspace_root)

    {servers, load_error} =
      case MCPSettings.list() do
        {:ok, list} -> {Enum.map(list, &oauth_projection(&1, socket.assigns.workspace_id)), nil}
        {:error, reason} -> {[], reason}
      end

    installed_sets = %{
      mcp: MapSet.new(servers, &String.downcase(&1.name)),
      skill: MapSet.new(skills, &String.downcase(&1.name)),
      ext: MapSet.new(extensions, &String.downcase(&1.name))
    }

    socket
    |> assign(:extensions, extensions)
    |> assign(:servers, servers)
    |> assign(:skills, skills)
    |> assign(:catalog, Catalog.list(installed_sets))
    |> assign(:load_error, load_error)
  end

  defp oauth_projection(server, workspace_id) do
    status =
      cond do
        not Map.get(server, :oauth_configured, false) ->
          :not_configured

        not Handbean.Host.mcp?() ->
          :host_unavailable

        true ->
          case OAuth.config(workspace_id, server.id) do
            {:ok, config} -> OAuth.status(config)
            {:error, _reason} -> :unavailable
          end
      end

    Map.put(server, :oauth_status, status)
  end

  defp filter_by_query(items, "", _fields_fn), do: items

  defp filter_by_query(items, query, fields_fn) do
    q = String.downcase(query)

    Enum.filter(items, fn item ->
      item
      |> fields_fn.()
      |> Enum.any?(fn val ->
        is_binary(val) and String.contains?(String.downcase(val), q)
      end)
    end)
  end

  defp open_form(socket, form) do
    socket
    |> assign(:form, form)
    |> assign(:form_error, nil)
    |> assign(:delete_target, nil)
    |> invalidate_test()
  end

  defp invalidate_test(socket) do
    assign(socket,
      testing: false,
      test_result: nil,
      test_generation: socket.assigns.test_generation + 1
    )
  end

  defp merge_form(form, params) do
    params =
      params
      |> Map.put("disabled", Map.get(params, "disabled", "false") in ["true", "on"])
      |> Map.put("workspace_ids", Map.get(params, "workspace_ids", []) |> List.wrap())

    Map.merge(form, params)
  end
end
