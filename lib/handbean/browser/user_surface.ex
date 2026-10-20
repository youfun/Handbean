defmodule Handbean.Browser.UserSurface do
  @moduledoc """
  Per-conversation browser for the person at the keyboard.

  The session name is separate from the agent `browser` tool. The picture is
  a headless `agent-browser` stream. Marks live in this process, and the
  overlay the user sees is drawn by the LiveView, not by the page.

  A capture temporarily injects numbered badges so the screenshot matches the
  prompt, then removes them. The result is sent to the watching LiveView.
  Nothing is written to the composer from here.
  """

  use GenServer

  require Logger

  alias Handbean.Browser.{Cli, Policy, Registry, StreamClient, Supervisor}

  @slot "user"
  @idle_ms 10 * 60 * 1000
  @max_marks 20

  defstruct conversation_id: nil,
            session_name: nil,
            viewer: nil,
            viewer_ref: nil,
            idle_timer: nil,
            stream_pid: nil,
            stream_ref: nil,
            url: nil,
            title: nil,
            design_mode: false,
            annotations: [],
            scroll_x: 0.0,
            scroll_y: 0.0,
            viewport: %{width: 1280, height: 720, dpr: 1},
            error: nil,
            last_frame_at: 0,
            reconnect_timer: nil

  @spec desktop?() :: boolean()
  def desktop?, do: Handbean.Host.browser_backend() == :cli

  @spec available?() :: boolean()
  def available?, do: desktop?() and is_binary(executable())

  @spec executable() :: String.t() | nil
  def executable do
    opts = Application.get_env(:handbean, :user_browser_cli, [])
    find = Keyword.get(opts, :find_executable, &find_executable/1)
    find.("agent-browser")
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    conversation_id = Keyword.fetch!(opts, :conversation_id)

    case Registry.lookup(conversation_id, @slot) do
      {:ok, _pid} -> {:error, :already_exists}
      {:error, :not_found} -> GenServer.start_link(__MODULE__, opts)
    end
  end

  @spec ensure(String.t(), pid(), keyword()) :: {:ok, map()} | {:error, term()}
  def ensure(conversation_id, viewer, opts \\ [])
      when is_binary(conversation_id) and is_pid(viewer) do
    with :ok <- require_supervisor(),
         {:ok, pid} <- Supervisor.start_user_surface(conversation_id, opts) do
      GenServer.call(pid, {:watch, viewer})
    end
  end

  @spec navigate(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def navigate(conversation_id, url), do: call(conversation_id, {:navigate, url}, 20_000)

  @spec back(String.t()) :: {:ok, map()} | {:error, term()}
  def back(conversation_id), do: history(conversation_id, "back")

  @spec forward(String.t()) :: {:ok, map()} | {:error, term()}
  def forward(conversation_id), do: history(conversation_id, "forward")

  @spec reload(String.t()) :: {:ok, map()} | {:error, term()}
  def reload(conversation_id), do: history(conversation_id, "reload")

  @spec set_design_mode(String.t(), boolean()) :: {:ok, map()} | {:error, term()}
  def set_design_mode(conversation_id, enabled),
    do: call(conversation_id, {:design, enabled == true})

  @spec set_viewport(String.t(), number(), number()) :: :ok | {:error, term()}
  def set_viewport(conversation_id, width, height),
    do: call(conversation_id, {:viewport, width, height}, 8_000)

  @spec mark(String.t(), number(), number()) :: {:ok, map()} | {:error, term()}
  def mark(conversation_id, x, y), do: call(conversation_id, {:mark, x, y}, 12_000)

  @spec comment(String.t(), integer(), String.t()) :: {:ok, map()} | {:error, term()}
  def comment(conversation_id, index, text),
    do: call(conversation_id, {:comment, index, text})

  @spec remove(String.t(), integer()) :: {:ok, map()} | {:error, term()}
  def remove(conversation_id, index), do: call(conversation_id, {:remove, index})

  @spec clear(String.t()) :: {:ok, map()} | {:error, term()}
  def clear(conversation_id), do: call(conversation_id, :clear)

  @spec pointer(String.t(), number(), number()) :: :ok | {:error, term()}
  def pointer(conversation_id, x, y), do: call(conversation_id, {:pointer, x, y}, 12_000)

  @spec key(String.t(), String.t()) :: :ok | {:error, term()}
  def key(conversation_id, key_name), do: call(conversation_id, {:key, key_name}, 8_000)

  @spec wheel(String.t(), number(), number()) :: :ok | {:error, term()}
  def wheel(conversation_id, delta_x, delta_y),
    do: call(conversation_id, {:wheel, delta_x, delta_y}, 8_000)

  @spec capture(String.t(), term()) :: :ok | {:error, :not_started}
  def capture(conversation_id, token) when is_binary(conversation_id) do
    case Registry.lookup(conversation_id, @slot) do
      {:ok, pid} ->
        GenServer.cast(pid, {:capture, token})
        :ok

      {:error, :not_found} ->
        {:error, :not_started}
    end
  end

  @impl true
  def init(opts) do
    conversation_id = Keyword.fetch!(opts, :conversation_id)

    case Registry.register(conversation_id, @slot, self()) do
      :ok ->
        name = "u" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
        {:ok, %__MODULE__{conversation_id: conversation_id, session_name: name}}

      {:error, :already_exists} ->
        {:stop, :already_exists}
    end
  end

  @impl true
  def handle_call({:watch, viewer}, _from, state) do
    state = watch(state, viewer)
    {:reply, {:ok, summary(state)}, state}
  end

  def handle_call({:navigate, url}, _from, state) do
    if Policy.allowed_navigation_url?(url) do
      case run(state, ["open", url]) do
        {:ok, raw} ->
          observed = url_of(decode_map(raw)) || url

          state =
            state
            |> Map.put(:error, nil)
            |> Map.put(:url, observed)
            |> accept_url()
            |> refresh_title()
            |> connect_stream()
            |> push()

          {:reply, {:ok, summary(state)}, state}

        error ->
          reply_error(state, error)
      end
    else
      {:reply, {:error, "only http(s) URLs are allowed"}, state}
    end
  end

  def handle_call({:history, command}, _from, state)
      when command in ["back", "forward", "reload"] do
    case run(state, [command]) do
      {:ok, _raw} ->
        state = state |> refresh_url() |> refresh_title() |> connect_stream() |> push()
        {:reply, {:ok, summary(state)}, state}

      error ->
        reply_error(state, error)
    end
  end

  def handle_call({:design, enabled}, _from, state) do
    state = push(%{state | design_mode: enabled})
    {:reply, {:ok, summary(state)}, state}
  end

  def handle_call({:viewport, width, height}, _from, state) do
    with {:ok, width} <- dimension(width),
         {:ok, height} <- dimension(height) do
      unchanged = state.viewport.width == width and state.viewport.height == height

      state =
        if unchanged do
          state
        else
          _ =
            run(
              state,
              ["set", "viewport", Integer.to_string(width), Integer.to_string(height)],
              timeout_ms: 5_000
            )

          state
          |> Map.put(:viewport, %{state.viewport | width: width, height: height})
          |> connect_stream()
        end

      {:reply, :ok, state}
    else
      _ -> {:reply, :ok, state}
    end
  end

  def handle_call({:mark, x, y}, _from, state) do
    with true <- state.design_mode,
         true <- length(state.annotations) < @max_marks,
         {:ok, x} <- coord(x),
         {:ok, y} <- coord(y),
         {:ok, raw} <- run(state, ["eval", hit_script(x, y)], timeout_ms: 8_000),
         %{} = found <- eval_value(decode_map(raw)) do
      case build_mark(state, found) do
        {:ok, mark} ->
          state = push(%{state | annotations: state.annotations ++ [mark], error: nil})
          {:reply, {:ok, summary(state)}, state}

        :error ->
          reply_error(state, "could not mark an element")
      end
    else
      false ->
        reply_error(state, "could not mark an element")

      _ ->
        reply_error(state, "could not mark an element")
    end
  end

  def handle_call({:comment, index, text}, _from, state) when is_integer(index) do
    annotations =
      Enum.map(state.annotations, fn ann ->
        if ann.index == index, do: %{ann | comment: text}, else: ann
      end)

    state = push(%{state | annotations: annotations})
    {:reply, {:ok, summary(state)}, state}
  end

  def handle_call({:remove, index}, _from, state) when is_integer(index) do
    annotations =
      state.annotations
      |> Enum.reject(&(&1.index == index))
      |> Enum.with_index(1)
      |> Enum.map(fn {ann, next} -> %{ann | index: next} end)

    state = push(%{state | annotations: annotations, error: nil})
    {:reply, {:ok, summary(state)}, state}
  end

  def handle_call(:clear, _from, state) do
    state = push(%{state | annotations: [], error: nil})
    {:reply, {:ok, summary(state)}, state}
  end

  def handle_call({:pointer, _x, _y}, _from, %{design_mode: true} = state) do
    {:reply, :ok, state}
  end

  def handle_call({:pointer, x, y}, _from, state) do
    with {:ok, x} <- coord(x), {:ok, y} <- coord(y) do
      click_at(state, x, y)
    end

    {:reply, :ok, state}
  end

  def handle_call({:key, key}, _from, state) when is_binary(key) and byte_size(key) <= 32 do
    unless state.design_mode or String.contains?(key, ["\n", "\r"]) do
      args =
        if String.length(key) == 1 do
          ["keyboard", "type", key]
        else
          ["press", key]
        end

      _ = run(state, args, timeout_ms: 5_000)
    end

    {:reply, :ok, state}
  end

  def handle_call({:wheel, delta_x, delta_y}, _from, state) do
    unless state.design_mode do
      dx = delta_x |> num(0.0) |> round() |> Integer.to_string()
      dy = delta_y |> num(0.0) |> round() |> Integer.to_string()
      _ = run(state, ["mouse", "wheel", dy, dx], timeout_ms: 5_000)
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:capture, _token}, %{annotations: []} = state) do
    {:noreply, state}
  end

  def handle_cast({:capture, token}, state) do
    {:noreply, do_capture(state, token)}
  end

  @impl true
  def handle_info({:browser_stream_frame, text}, state) when is_binary(text) do
    state =
      case Handbean.JSON.decode(text) do
        {:ok, %{"type" => "frame", "metadata" => meta} = frame} when is_map(meta) ->
          state = %{
            state
            | scroll_x: num(meta["scrollOffsetX"], state.scroll_x),
              scroll_y: num(meta["scrollOffsetY"], state.scroll_y)
          }

          forward_frame(state, frame)

        {:ok, %{"type" => "frame"} = frame} ->
          forward_frame(state, frame)

        _ ->
          state
      end

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{viewer_ref: ref} = state) do
    timer = Process.send_after(self(), :idle_close, @idle_ms)
    {:noreply, %{state | viewer: nil, viewer_ref: nil, idle_timer: timer}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{stream_ref: ref} = state) do
    state = %{state | stream_pid: nil, stream_ref: nil}

    state =
      if is_pid(state.viewer) and is_binary(state.url) do
        schedule_reconnect(state)
      else
        state
      end

    {:noreply, state}
  end

  def handle_info(:reconnect_stream, state) do
    {:noreply, connect_stream(%{state | reconnect_timer: nil})}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  def handle_info(:idle_close, %{viewer: nil} = state), do: {:stop, :normal, state}
  def handle_info(:idle_close, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if is_pid(state.stream_pid), do: Process.exit(state.stream_pid, :shutdown)

    if is_binary(state.conversation_id) and Process.whereis(Registry) do
      Registry.unregister(state.conversation_id, @slot)
    end

    if is_binary(state.session_name) do
      _ = run(state, ["close"], timeout_ms: 3_000)
    end

    :ok
  end

  defp history(conversation_id, command), do: call(conversation_id, {:history, command}, 15_000)

  defp call(conversation_id, message, timeout \\ 10_000) do
    case Registry.lookup(conversation_id, @slot) do
      {:ok, pid} -> GenServer.call(pid, message, timeout)
      {:error, :not_found} -> {:error, :not_started}
    end
  end

  defp require_supervisor do
    if Supervisor.running?() and Process.whereis(Registry) do
      :ok
    else
      {:error, :not_started}
    end
  end

  defp watch(state, viewer) do
    if is_reference(state.viewer_ref), do: Process.demonitor(state.viewer_ref, [:flush])
    if is_reference(state.idle_timer), do: Process.cancel_timer(state.idle_timer)

    state = %{
      state
      | viewer: viewer,
        viewer_ref: Process.monitor(viewer),
        idle_timer: nil
    }

    push(state)
  end

  defp push(state) do
    if is_pid(state.viewer) do
      send(state.viewer, {:browser_surface_state, state.conversation_id, summary(state)})
      send(state.viewer, {:browser_markers, state.conversation_id, marker_payload(state)})
    end

    state
  end

  defp summary(state) do
    %{
      url: state.url || "",
      title: state.title,
      design_mode: state.design_mode,
      annotation_count: length(state.annotations),
      live: is_binary(state.url),
      error: state.error
    }
  end

  defp marker_payload(state) do
    Enum.map(state.annotations, fn ann ->
      %{
        index: ann.index,
        page_x: ann.page_x,
        page_y: ann.page_y,
        width: ann.width,
        height: ann.height,
        comment: ann.comment || ""
      }
    end)
  end

  defp reply_error(state, error) do
    message = format_error(error)
    state = push(%{state | error: message})
    {:reply, {:error, message}, state}
  end

  defp accept_url(state) do
    if Policy.allowed_navigation_url?(state.url || ""), do: state, else: blank(state)
  end

  defp blank(state) do
    _ = run(state, ["open", "about:blank"], timeout_ms: 5_000)
    %{state | url: nil, error: "navigation left http(s) and was cleared"}
  end

  defp refresh_url(state) do
    case run(state, ["get", "url"], timeout_ms: 5_000) do
      {:ok, raw} ->
        case url_of(decode_map(raw)) do
          url when is_binary(url) -> accept_url(%{state | url: url})
          _ -> state
        end

      _ ->
        state
    end
  end

  defp refresh_title(state) do
    case run(state, ["get", "title"], timeout_ms: 3_000) do
      {:ok, raw} ->
        case title_of(decode_map(raw)) do
          title when is_binary(title) and title != "" -> %{state | title: title}
          _ -> state
        end

      _ ->
        state
    end
  end

  defp connect_stream(state), do: state |> close_stream() |> open_stream()

  defp schedule_reconnect(state) do
    if is_reference(state.reconnect_timer), do: Process.cancel_timer(state.reconnect_timer)
    %{state | reconnect_timer: Process.send_after(self(), :reconnect_stream, 200)}
  end

  defp close_stream(%{stream_pid: pid} = state) when is_pid(pid) do
    if is_reference(state.stream_ref), do: Process.demonitor(state.stream_ref, [:flush])
    if Process.alive?(pid), do: Process.exit(pid, :shutdown)
    %{state | stream_pid: nil, stream_ref: nil}
  end

  defp close_stream(state), do: state

  defp open_stream(state) do
    case run(state, ["stream", "status"], timeout_ms: 5_000) do
      {:ok, raw} ->
        case port_of(decode_map(raw)) do
          port when is_integer(port) and port > 0 and port < 65_536 ->
            case StreamClient.start_link(port, self()) do
              {:ok, pid} ->
                Process.unlink(pid)
                %{state | stream_pid: pid, stream_ref: Process.monitor(pid)}

              other ->
                Logger.warning("user browser stream failed port=#{port} result=#{inspect(other)}")
                state
            end

          _ ->
            Logger.warning("user browser stream has no port")
            state
        end

      _ ->
        state
    end
  end

  defp forward_frame(state, frame) do
    now = System.monotonic_time(:millisecond)
    # Monotonic time is often negative, so a zero stamp is "never sent", not the epoch.
    due = state.last_frame_at == 0 or now - state.last_frame_at >= 100

    if is_pid(state.viewer) and due do
      send(state.viewer, {
        :browser_frame,
        state.conversation_id,
        %{"data" => frame["data"], "metadata" => frame["metadata"] || %{}}
      })

      %{state | last_frame_at: now}
    else
      state
    end
  end

  defp click_at(state, x, y) do
    if is_pid(state.stream_pid) and Process.alive?(state.stream_pid) do
      Enum.each(["mousePressed", "mouseReleased"], fn event ->
        payload = %{
          "type" => "input_mouse",
          "eventType" => event,
          "x" => x,
          "y" => y,
          "button" => "left",
          "clickCount" => 1
        }

        _ = StreamClient.send_text(state.stream_pid, Handbean.JSON.encode!(payload))
      end)
    else
      xi = x |> round() |> Integer.to_string()
      yi = y |> round() |> Integer.to_string()
      _ = run(state, ["mouse", "move", xi, yi], timeout_ms: 5_000)
      _ = run(state, ["mouse", "down", "left"], timeout_ms: 5_000)
      _ = run(state, ["mouse", "up", "left"], timeout_ms: 5_000)
    end

    :ok
  end

  defp do_capture(state, token) do
    elements = Enum.map(state.annotations, &capture_element(&1, state))
    marks = Enum.map(elements, fn el -> %{"index" => el.index, "selector" => el.selector} end)
    _ = run(state, ["eval", badge_script(marks)], timeout_ms: 500)

    path =
      Path.join(
        System.tmp_dir!(),
        "handbean-annotation-#{System.unique_integer([:positive])}.jpg"
      )

    shot =
      run(
        state,
        ["--screenshot-format", "jpeg", "--screenshot-quality", "60", "screenshot", path],
        timeout_ms: 15_000
      )

    _ = run(state, ["eval", remove_badge_script()], timeout_ms: 500)
    file = screenshot_file(shot, path)

    payload = %{
      "url" => state.url,
      "title" => state.title,
      "viewport" => %{
        "width" => state.viewport.width,
        "height" => state.viewport.height,
        "dpr" => state.viewport.dpr
      },
      "elements" => Enum.map(elements, &element_payload/1),
      "captured_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "screenshot" => is_binary(file)
    }

    case Handbean.BrowserAnnotation.from_untrusted(payload) do
      {:ok, built} ->
        if is_pid(state.viewer) do
          send(
            state.viewer,
            {:browser_annotation_ready, state.conversation_id, token, built, file}
          )
        end

        %{state | error: nil}

      {:error, _reason} ->
        %{state | error: "annotation payload was rejected"}
    end
  end

  defp capture_element(ann, state) do
    %{
      ann
      | rect: %{
          x: max(ann.page_x - state.scroll_x, 0),
          y: max(ann.page_y - state.scroll_y, 0),
          width: max(ann.width, 0),
          height: max(ann.height, 0)
        }
    }
  end

  defp element_payload(ann) do
    %{
      "selector" => ann.selector,
      "tag" => ann.tag,
      "text" => ann.text,
      "rect" => %{
        "x" => ann.rect.x,
        "y" => ann.rect.y,
        "width" => ann.rect.width,
        "height" => ann.rect.height
      },
      "source" => source_payload(ann.source),
      "comment" => ann.comment
    }
  end

  defp source_payload(%{"file" => file, "line" => line} = source)
       when is_binary(file) and is_integer(line) and line > 0 do
    base = %{"file" => file, "line" => line}

    case source["column"] do
      column when is_integer(column) and column > 0 -> Map.put(base, "column", column)
      _ -> base
    end
  end

  defp source_payload(%{file: file, line: line} = source)
       when is_binary(file) and is_integer(line) do
    source_payload(%{"file" => file, "line" => line, "column" => source[:column]})
  end

  defp source_payload(_), do: nil

  defp build_mark(state, found) do
    rect = found["rect"] || %{}
    selector = found["selector"]
    tag = found["tag"]

    if is_binary(selector) and selector != "" and is_binary(tag) and tag != "" and is_map(rect) do
      x = num(rect["x"], 0.0)
      y = num(rect["y"], 0.0)

      {:ok,
       %{
         index: length(state.annotations) + 1,
         selector: selector,
         tag: tag,
         text: found["text"],
         source: found["source"],
         comment: nil,
         rect: %{x: x, y: y, width: num(rect["width"], 0.0), height: num(rect["height"], 0.0)},
         page_x: x + state.scroll_x,
         page_y: y + state.scroll_y,
         width: num(rect["width"], 0.0),
         height: num(rect["height"], 0.0)
       }}
    else
      :error
    end
  end

  defp screenshot_file({:ok, raw}, path) do
    reported =
      case decode_map(raw)["data"] do
        %{"path" => reported} when is_binary(reported) -> reported
        _ -> nil
      end

    Enum.find([reported, path], &jpeg_within_limit?/1)
  end

  defp screenshot_file(_error, path) do
    if jpeg_within_limit?(path), do: path
  end

  defp jpeg_within_limit?(path) when is_binary(path) do
    case File.stat(path) do
      {:ok, %{type: :regular, size: size}} when size > 0 and size <= 5_000_000 -> true
      _ -> false
    end
  end

  defp jpeg_within_limit?(_), do: false

  defp run(state, args, extra \\ []) do
    opts =
      [session_name: state.session_name, timeout_ms: 15_000, find_executable: &find_executable/1]
      |> Keyword.merge(Application.get_env(:handbean, :user_browser_cli, []))
      |> Keyword.merge(extra)

    Cli.run(args, opts)
  end

  defp decode_map(%{stdout: stdout}) when is_binary(stdout) do
    case Handbean.JSON.decode(String.trim(stdout)) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp decode_map(_), do: %{}

  defp url_of(map) when is_map(map) do
    data = map["data"]

    cond do
      is_map(data) and is_binary(data["url"]) -> data["url"]
      is_binary(map["url"]) -> map["url"]
      is_binary(data) and Policy.allowed_navigation_url?(data) -> data
      true -> nil
    end
  end

  defp title_of(map) when is_map(map) do
    data = map["data"]

    cond do
      is_map(data) and is_binary(data["title"]) -> data["title"]
      is_binary(map["title"]) -> map["title"]
      is_binary(data) -> data
      true -> nil
    end
  end

  defp port_of(map) when is_map(map) do
    data = map["data"]

    cond do
      is_map(data) and is_integer(data["port"]) -> data["port"]
      is_integer(map["port"]) -> map["port"]
      true -> nil
    end
  end

  defp eval_value(map) when is_map(map) do
    data = map["data"] || %{}
    raw = if is_map(data), do: data["result"] || data["value"], else: nil
    raw = raw || map["result"]

    cond do
      is_map(raw) ->
        raw

      is_binary(raw) ->
        case Handbean.JSON.decode(raw) do
          {:ok, decoded} when is_map(decoded) -> decoded
          _ -> nil
        end

      true ->
        nil
    end
  end

  defp coord(value) when is_integer(value) and value >= 0 and value <= 100_000,
    do: {:ok, :erlang.float(value)}

  defp coord(value) when is_float(value) and value >= 0 and value <= 100_000 and value == value,
    do: {:ok, value}

  defp coord(_), do: :error

  defp dimension(value) when is_integer(value) and value >= 200 and value <= 4_000,
    do: {:ok, value}

  defp dimension(value) when is_float(value) and value >= 200 and value <= 4_000,
    do: {:ok, round(value)}

  defp dimension(_), do: :error

  defp num(value, _default) when is_integer(value), do: :erlang.float(value)
  defp num(value, _default) when is_float(value) and value == value, do: value
  defp num(_value, default), do: default

  defp find_executable(name) when is_binary(name) do
    case Handbean.Platform.WorkspaceEnvironment.find_executable(name, nil) do
      {:ok, executable} -> executable
      {:error, _reason} -> nil
    end
  end

  defp format_error({:error, :missing_binary, _binary}), do: "agent-browser is not installed"
  defp format_error({:error, reason}) when is_binary(reason), do: reason
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(other), do: inspect(other)

  defp hit_script(x, y) do
    x = format_num(x)
    y = format_num(y)

    """
    (() => {
      const el = document.elementFromPoint(#{x}, #{y});
      if (!el || el === document.documentElement || el === document.body) return JSON.stringify(null);
      const cssPath = (node) => {
        if (node.id && /^[A-Za-z][\\w-]*$/.test(node.id)) return "#" + CSS.escape(node.id);
        const testid = node.getAttribute("data-testid");
        if (testid) return '[data-testid="' + testid.replace(/"/g, "") + '"]';
        const parts = [];
        let current = node;
        while (current && current.nodeType === 1 && current !== document.documentElement && parts.length < 8) {
          let part = current.tagName.toLowerCase();
          const parent = current.parentElement;
          if (parent) {
            const same = Array.from(parent.children).filter((child) => child.tagName === current.tagName);
            if (same.length > 1) part += ":nth-of-type(" + (same.indexOf(current) + 1) + ")";
          }
          parts.unshift(part);
          current = parent;
        }
        return parts.join(" > ");
      };
      const readSource = (node) => {
        let current = node;
        for (let i = 0; i < 6 && current; i += 1) {
          const file = current.getAttribute("data-source") || current.getAttribute("data-inspector-file");
          if (file) {
            const line = Number(current.getAttribute("data-inspector-line") || current.getAttribute("data-source-line") || "");
            const column = Number(current.getAttribute("data-inspector-column") || "");
            if (!Number.isInteger(line) || line <= 0) return null;
            const source = {file, line};
            if (Number.isInteger(column) && column > 0) source.column = column;
            return source;
          }
          current = current.parentElement;
        }
        return null;
      };
      const rect = el.getBoundingClientRect();
      const text = (el.innerText || el.textContent || "").replace(/\\s+/g, " ").trim().slice(0, 240);
      return JSON.stringify({
        selector: cssPath(el),
        tag: el.tagName.toLowerCase(),
        text,
        rect: {x: rect.x, y: rect.y, width: rect.width, height: rect.height},
        source: readSource(el)
      });
    })()
    """
  end

  defp badge_script(marks) do
    json = Handbean.JSON.encode!(marks)

    """
    (() => {
      const previous = document.querySelector("handbean-annotation-badges");
      if (previous) previous.remove();
      const host = document.createElement("handbean-annotation-badges");
      host.style.setProperty("position", "fixed", "important");
      host.style.setProperty("inset", "0", "important");
      host.style.setProperty("z-index", "2147483646", "important");
      host.style.setProperty("pointer-events", "none", "important");
      const root = host.attachShadow({mode: "closed"});
      const marks = #{json};
      for (const mark of marks) {
        let el = null;
        try { el = document.querySelector(mark.selector); } catch (_error) { el = null; }
        if (!el) continue;
        const rect = el.getBoundingClientRect();
        const badge = document.createElement("div");
        badge.textContent = String(mark.index);
        badge.style.setProperty("position", "fixed", "important");
        badge.style.setProperty("left", Math.max(0, rect.x) + "px", "important");
        badge.style.setProperty("top", Math.max(0, rect.y) + "px", "important");
        badge.style.setProperty("min-width", "22px", "important");
        badge.style.setProperty("height", "22px", "important");
        badge.style.setProperty("padding", "0 6px", "important");
        badge.style.setProperty("border-radius", "999px", "important");
        badge.style.setProperty("background", "#6d28d9", "important");
        badge.style.setProperty("color", "white", "important");
        badge.style.setProperty("font", "700 12px sans-serif", "important");
        badge.style.setProperty("display", "flex", "important");
        badge.style.setProperty("align-items", "center", "important");
        badge.style.setProperty("justify-content", "center", "important");
        root.appendChild(badge);
      }
      document.documentElement.appendChild(host);
      return "ok";
    })()
    """
  end

  defp remove_badge_script do
    """
    (() => {
      const host = document.querySelector("handbean-annotation-badges");
      if (host) host.remove();
      return "ok";
    })()
    """
  end

  defp format_num(value) when is_integer(value), do: Integer.to_string(value)

  defp format_num(value) when is_float(value) do
    :erlang.float_to_binary(value, [:compact, decimals: 2])
  end
end
