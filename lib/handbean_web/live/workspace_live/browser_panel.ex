defmodule HandbeanWeb.WorkspaceLive.BrowserPanel do
  @moduledoc false

  use HandbeanWeb, :live_component

  alias Handbean.Browser.{InstallPrompt, UserSurface}

  @impl true
  def update(assigns, socket) do
    surface = Map.get(assigns, :surface)
    socket = assign(socket, Map.drop(assigns, [:surface]))
    socket = if is_map(surface), do: apply_surface(socket, surface), else: socket
    socket = assign_new(socket, :surface, fn -> empty_surface() end)
    socket = assign_new(socket, :url_input, fn -> "" end)
    socket = assign_new(socket, :error, fn -> nil end)
    socket = maybe_open(socket, assigns)
    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="browser-panel flex flex-col h-full min-h-0">
      <%= if UserSurface.available?() do %>
        <form
          id="browser-nav"
          phx-submit="browser_navigate"
          phx-change="browser_url"
          phx-target={@myself}
          class="flex items-center gap-1 border-b px-2 py-1.5"
        >
          <button
            type="button"
            id="browser-back"
            phx-click="browser_back"
            phx-target={@myself}
            class="text-xs text-tertiary px-1"
            aria-label={gettext("Back")}
          >←</button>
          <button
            type="button"
            id="browser-forward"
            phx-click="browser_forward"
            phx-target={@myself}
            class="text-xs text-tertiary px-1"
            aria-label={gettext("Forward")}
          >→</button>
          <button
            type="button"
            id="browser-reload"
            phx-click="browser_reload"
            phx-target={@myself}
            class="text-xs text-tertiary px-1"
            aria-label={gettext("Reload")}
          >↻</button>
          <label class="sr-only" for="browser-url">{gettext("URL")}</label>
          <input
            id="browser-url"
            name="url"
            value={@url_input}
            placeholder="https://"
            class="flex-1 min-w-0 text-xs bg-transparent border rounded px-2 py-1"
            autocomplete="off"
            spellcheck="false"
          />
          <button id="browser-go" type="submit" class="text-xs px-2 py-1 rounded border">{gettext(
            "Go"
          )}</button>
        </form>
        <div class="flex items-center gap-1 border-b px-2 py-1">
          <button
            type="button"
            id="browser-design"
            phx-click="browser_design"
            phx-target={@myself}
            phx-value-enabled={to_string(not @surface.design_mode)}
            class={[
              "text-xs px-2 py-1 rounded border",
              if(@surface.design_mode, do: "bg-surface-hover", else: "")
            ]}
          >
            {gettext("Design")}
          </button>
          <span id="browser-annotation-count" class="text-xs text-tertiary">
            {gettext("%{count} marked", count: @surface.annotation_count)}
          </span>
          <button
            type="button"
            id="browser-clear"
            phx-click="browser_clear"
            phx-target={@myself}
            class="text-xs text-tertiary px-2"
          >
            {gettext("Clear")}
          </button>
          <button
            type="button"
            id="browser-send"
            phx-click="browser_send"
            phx-target={@myself}
            disabled={
              not @surface.live or @surface.annotation_count == 0 or not is_binary(@conversation_id)
            }
            class="ml-auto text-xs px-2 py-1 rounded border disabled:opacity-40"
          >
            {gettext("Send to composer")}
          </button>
        </div>
        <p :if={@error || @surface.error} id="browser-error" class="text-xs text-error px-2 py-1">
          {@error || @surface.error}
        </p>
        <p
          :if={not is_binary(@conversation_id)}
          id="browser-no-conversation"
          class="text-xs text-tertiary px-2 py-1"
        >
          {gettext("Open a conversation before sending annotations.")}
        </p>
        <div
          id="browser-view"
          phx-hook="BrowserSurface"
          phx-target={@myself}
          data-design={to_string(@surface.design_mode)}
          class="browser-surface relative flex-1 min-h-0 bg-main"
        >
          <button
            type="button"
            id="browser-surface"
            phx-click={if(@surface.design_mode, do: "browser_mark")}
            phx-target={@myself}
            phx-value-x="12"
            phx-value-y="12"
            class="absolute inset-0 w-full h-full text-left"
          >
            <canvas id="browser-canvas" phx-update="ignore" class="block w-full h-full"></canvas>
          </button>
          <div id="browser-markers" phx-update="ignore" class="absolute inset-0 pointer-events-none">
          </div>
        </div>
      <% else %>
        <div id="browser-install" class="p-3 text-xs">
          <p class="text-primary">{gettext("Install agent-browser to use the browser")}</p>
          <code id="browser-install-command" class="mt-2 block font-mono break-all">{InstallPrompt.command()}</code>
        </div>
      <% end %>
    </div>
    """
  end

  @impl true
  def handle_event("browser_url", %{"url" => url}, socket) do
    {:noreply, assign(socket, :url_input, url)}
  end

  def handle_event("browser_navigate", %{"url" => url}, socket) do
    {:noreply,
     run(socket, fn -> UserSurface.navigate(socket.assigns.conversation_id, String.trim(url)) end)}
  end

  def handle_event("browser_back", _params, socket) do
    {:noreply, run(socket, fn -> UserSurface.back(socket.assigns.conversation_id) end)}
  end

  def handle_event("browser_forward", _params, socket) do
    {:noreply, run(socket, fn -> UserSurface.forward(socket.assigns.conversation_id) end)}
  end

  def handle_event("browser_reload", _params, socket) do
    {:noreply, run(socket, fn -> UserSurface.reload(socket.assigns.conversation_id) end)}
  end

  def handle_event("browser_design", %{"enabled" => enabled}, socket) do
    {:noreply,
     run(socket, fn ->
       UserSurface.set_design_mode(socket.assigns.conversation_id, enabled == "true")
     end)}
  end

  def handle_event("browser_mark", params, socket) do
    {:noreply,
     run(socket, fn ->
       UserSurface.mark(socket.assigns.conversation_id, number(params["x"]), number(params["y"]))
     end)}
  end

  def handle_event("browser_comment", %{"index" => index, "comment" => comment}, socket) do
    {:noreply,
     run(socket, fn ->
       UserSurface.comment(socket.assigns.conversation_id, parse_int(index), comment)
     end)}
  end

  def handle_event("browser_remove", %{"index" => index}, socket) do
    {:noreply,
     run(socket, fn -> UserSurface.remove(socket.assigns.conversation_id, parse_int(index)) end)}
  end

  def handle_event("browser_clear", _params, socket) do
    {:noreply, run(socket, fn -> UserSurface.clear(socket.assigns.conversation_id) end)}
  end

  def handle_event("browser_pointer", params, socket) do
    _ =
      UserSurface.pointer(
        socket.assigns.conversation_id,
        number(params["x"]),
        number(params["y"])
      )

    {:noreply, socket}
  end

  def handle_event("browser_key", %{"key" => key}, socket) do
    _ = UserSurface.key(socket.assigns.conversation_id, key)
    {:noreply, socket}
  end

  def handle_event("browser_wheel", params, socket) do
    _ =
      UserSurface.wheel(
        socket.assigns.conversation_id,
        number(params["delta_x"]),
        number(params["delta_y"])
      )

    {:noreply, socket}
  end

  def handle_event("browser_viewport", params, socket) do
    _ =
      UserSurface.set_viewport(
        socket.assigns.conversation_id,
        number(params["width"]),
        number(params["height"])
      )

    {:noreply, socket}
  end

  def handle_event("browser_send", _params, socket) do
    conversation_id = socket.assigns.conversation_id

    if is_binary(conversation_id) and socket.assigns.surface.annotation_count > 0 do
      token = System.unique_integer([:positive])
      send(self(), {:arm_browser_capture, token})

      case UserSurface.capture(conversation_id, token) do
        :ok -> {:noreply, assign(socket, :error, nil)}
        {:error, reason} -> {:noreply, assign(socket, :error, inspect(reason))}
      end
    else
      {:noreply,
       assign(socket, :error, gettext("Open a conversation before sending annotations."))}
    end
  end

  defp maybe_open(socket, assigns) do
    conversation_id = assigns[:conversation_id] || socket.assigns[:conversation_id]

    if UserSurface.available?() and is_binary(conversation_id) and
         socket.assigns[:opened_for] != conversation_id do
      case UserSurface.ensure(conversation_id, self()) do
        {:ok, summary} ->
          socket
          |> assign(:opened_for, conversation_id)
          |> apply_surface(summary)

        {:error, reason} ->
          assign(socket, :error, inspect(reason))
      end
    else
      socket
    end
  end

  defp apply_surface(socket, summary) do
    socket = assign(socket, :surface, summary)

    if summary.url != "" and summary.url != socket.assigns[:shown_url] do
      socket
      |> assign(:shown_url, summary.url)
      |> assign(:url_input, summary.url)
    else
      socket
    end
  end

  defp run(socket, fun) do
    if is_binary(socket.assigns.conversation_id) do
      case fun.() do
        {:ok, summary} ->
          socket |> assign(:error, nil) |> apply_surface(summary)

        {:error, reason} when is_binary(reason) ->
          assign(socket, :error, reason)

        {:error, reason} ->
          assign(socket, :error, inspect(reason))

        :ok ->
          socket
      end
    else
      assign(socket, :error, gettext("Open a conversation before sending annotations."))
    end
  end

  defp empty_surface do
    %{url: "", title: nil, design_mode: false, annotation_count: 0, live: false, error: nil}
  end

  defp number(value) when is_integer(value), do: value
  defp number(value) when is_float(value), do: value

  defp number(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, ""} -> parsed
      _ -> 0
    end
  end

  defp number(_), do: 0

  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> 0
    end
  end

  defp parse_int(_), do: 0
end
