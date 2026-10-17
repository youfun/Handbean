defmodule Handbean.Browser.WebViewSession do
  @moduledoc """
  OTP owner of one on-device browser session.

  Display is a projection. Hide does not destroy the instance.
  Commands are serial and carry session_id, request_id, and generation.
  """

  use GenServer

  alias Handbean.Browser.{Display, Engine, Scripts}

  @default_timeout 20_000
  @write_actions ~w(open eval click fill back close)
  @dom_actions ~w(snapshot eval click fill)

  defstruct session_id: nil,
            conversation_id: nil,
            generation: 1,
            visible: false,
            control: :agent,
            url: nil,
            title: nil,
            pending: nil,
            nav: :idle,
            refs_gen: 0,
            needs_recovery: false,
            closed?: false

  @type result ::
          {:ok, String.t(), map()}
          | {:error, String.t()}
          | {:error, String.t(), map()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: via(session_id))
  end

  @spec call(String.t(), map(), keyword()) :: result()
  def call(session_id, input, opts \\ []) when is_binary(session_id) and is_map(input) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout) + 1_000
    GenServer.call(via(session_id), {:command, input, opts}, timeout)
  end

  @spec deliver(String.t(), map()) :: :ok
  def deliver(session_id, payload) when is_binary(session_id) and is_map(payload) do
    GenServer.cast(via(session_id), {:engine_result, payload})
  end

  @spec user_takeover(String.t()) :: :ok | {:error, term()}
  def user_takeover(session_id), do: GenServer.call(via(session_id), :user_takeover)

  @spec user_handback(String.t()) :: :ok | {:error, term()}
  def user_handback(session_id), do: GenServer.call(via(session_id), :user_handback)

  @spec snapshot_state(String.t()) :: map()
  def snapshot_state(session_id), do: GenServer.call(via(session_id), :snapshot_state)

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    conversation_id = Keyword.get(opts, :conversation_id)
    generation = Keyword.get(opts, :generation, 1)

    if is_binary(conversation_id) do
      {:ok, _} =
        Registry.register(
          Handbean.Browser.WebViewRegistry,
          {:conversation, conversation_id},
          %{session_id: session_id, generation: generation}
        )
    end

    state = %__MODULE__{
      session_id: session_id,
      conversation_id: conversation_id,
      generation: generation
    }

    _ =
      Engine.command(%{
        op: :create,
        session_id: session_id,
        owner: :browser,
        conversation_id: conversation_id,
        generation: generation,
        caller: self()
      })

    {:ok, state}
  end

  @impl true
  def handle_call({:command, input, opts}, from, %{closed?: true} = state) do
    _ = {input, opts, from}
    {:reply, {:error, "browser session is closed"}, state}
  end

  def handle_call({:command, input, opts}, from, state) do
    action = action_name(input)

    cond do
      action == "close" ->
        close_session(state, from)

      action == "show" ->
        {reply, state} = show(state, input)
        {:reply, reply, state}

      action == "hide" ->
        {reply, state} = hide(state)
        {:reply, reply, state}

      blocked_write?(state, action) ->
        {:reply, write_blocked(state, action), state}

      state.needs_recovery and action in @dom_actions ->
        {:reply, recovery_needed(state), state}

      state.pending != nil ->
        {:reply, {:error, "browser session is busy"}, state}

      state.nav == :navigating and action in @dom_actions ->
        {:reply, {:error, "navigation in progress"}, state}

      true ->
        dispatch(action, input, opts, from, state)
    end
  end

  def handle_call(:user_takeover, _from, state) do
    state = %{state | control: :user, refs_gen: state.refs_gen + 1}
    _ = maybe_show(state, user?: true)
    {:reply, :ok, state}
  end

  def handle_call(:user_handback, _from, state) do
    state = %{state | control: :agent, refs_gen: state.refs_gen + 1, needs_recovery: false}
    {:reply, :ok, state}
  end

  def handle_call(:snapshot_state, _from, state) do
    {:reply, public_state(state), state}
  end

  @impl true
  def handle_cast({:engine_result, payload}, state) do
    {:noreply, accept_result(state, payload)}
  end

  def handle_info({:engine_result, payload}, state) do
    {:noreply, accept_result(state, payload)}
  end

  @impl true
  def handle_info({:request_timeout, request_id}, state) do
    {:noreply, timeout_pending(state, request_id)}
  end

  def handle_info({:late_result, payload}, state) do
    {:noreply, accept_result(state, payload)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp dispatch("open", input, opts, from, state) do
    url = get_field(input, "url")

    case validate_http_url(url) do
      {:ok, url} ->
        request_id = next_request_id()
        cmd = engine_cmd(state, request_id, :load, url: url)

        case Engine.command(cmd, opts) do
          {:ok, result} ->
            state = %{state | url: url, nav: :idle, refs_gen: state.refs_gen + 1}
            {:reply, ok_result(state, "open", result), state}

          {:error, :async} ->
            {:noreply, park(state, from, request_id, "open", opts, navigating: true, url: url)}

          {:error, reason} ->
            {:reply, {:error, format_reason(reason)}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp dispatch("snapshot", input, opts, from, state) do
    eval_command("snapshot", Scripts.snapshot_js(), input, opts, from, state, keep_refs?: false)
  end

  defp dispatch("eval", input, opts, from, state) do
    js = get_field(input, "js") || ""
    eval_command("eval", Scripts.wrap_eval(js), input, opts, from, state, keep_refs?: true)
  end

  defp dispatch("click", input, opts, from, state) do
    with {:ok, ref} <- fetch_ref(input, state) do
      eval_command("click", Scripts.click_js(ref), input, opts, from, state,
        keep_refs?: true,
        may_navigate?: true
      )
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp dispatch("fill", input, opts, from, state) do
    with {:ok, ref} <- fetch_ref(input, state) do
      value = get_field(input, "value") || get_field(input, "text") || ""

      eval_command("fill", Scripts.fill_js(ref, value), input, opts, from, state,
        keep_refs?: true
      )
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp dispatch("back", _input, opts, from, state) do
    request_id = next_request_id()
    cmd = engine_cmd(state, request_id, :back)

    case Engine.command(cmd, opts) do
      {:ok, result} ->
        state = %{state | refs_gen: state.refs_gen + 1}
        {:reply, ok_result(state, "back", result), state}

      {:error, :async} ->
        {:noreply, park(state, from, request_id, "back", opts, navigating: true)}

      {:error, reason} ->
        {:reply, {:error, format_reason(reason)}, state}
    end
  end

  defp dispatch(other, _input, _opts, _from, state) do
    {:reply, {:error, "unsupported browser action: #{other}"}, state}
  end

  defp eval_command(action, js, _input, opts, from, state, extra) do
    request_id = next_request_id()
    cmd = engine_cmd(state, request_id, :eval, js: js)

    case Engine.command(cmd, opts) do
      {:ok, result} ->
        state = after_eval(state, action, extra)
        {:reply, decode_eval(state, action, result), state}

      {:error, :async} ->
        {:noreply,
         park(state, from, request_id, action, opts,
           navigating: extra[:may_navigate?] == true,
           extra: extra
         )}

      {:error, reason} ->
        {:reply, {:error, format_reason(reason)}, state}
    end
  end

  defp after_eval(state, "snapshot", _extra), do: %{state | refs_gen: state.refs_gen + 1}

  defp after_eval(state, _action, extra) do
    if extra[:keep_refs?], do: state, else: %{state | refs_gen: state.refs_gen + 1}
  end

  defp park(state, from, request_id, action, opts, extra) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout)
    timer = Process.send_after(self(), {:request_timeout, request_id}, timeout)

    pending = %{
      request_id: request_id,
      generation: state.generation,
      action: action,
      from: from,
      timer: timer,
      extra: extra
    }

    nav = if extra[:navigating], do: :navigating, else: state.nav
    url = extra[:url] || state.url
    %{state | pending: pending, nav: nav, url: url}
  end

  defp accept_result(%{pending: nil} = state, _payload), do: state

  defp accept_result(%{pending: pending} = state, payload) do
    request_id = Handbean.Utils.SafeMap.get_any(payload, :request_id, "request_id")
    generation = Handbean.Utils.SafeMap.get_any(payload, :generation, "generation")
    session_id = Handbean.Utils.SafeMap.get_any(payload, :session_id, "session_id")

    cond do
      session_id && session_id != state.session_id ->
        state

      generation && to_string(generation) != to_string(state.generation) ->
        state

      request_id && request_id != pending.request_id ->
        state

      true ->
        cancel_timer(pending.timer)

        state =
          %{state | pending: nil, nav: :idle, needs_recovery: false}
          |> maybe_bump_refs(pending.action)
          |> maybe_put_url(payload)

        reply = finish_pending(state, pending, payload)
        GenServer.reply(pending.from, reply)
        state
    end
  end

  defp timeout_pending(%{pending: %{request_id: request_id} = pending} = state, request_id) do
    recovery? = pending.action in ["open", "click", "back", "fill"] or state.nav == :navigating

    details = %{
      session_id: state.session_id,
      request_id: request_id,
      generation: state.generation,
      timed_out: true,
      side_effects_unknown: true
    }

    GenServer.reply(
      pending.from,
      {:error, "browser timed out waiting for #{pending.action}", details}
    )

    %{state | pending: nil, nav: :idle, needs_recovery: recovery?}
  end

  defp timeout_pending(state, _request_id), do: state

  defp finish_pending(state, pending, payload) do
    case Handbean.Utils.SafeMap.get_any(payload, :error, "error") do
      nil ->
        decode_eval(
          state,
          pending.action,
          Handbean.Utils.SafeMap.get_any(payload, :result, "result") || payload
        )

      reason ->
        {:error, format_reason(reason), base_details(state, pending.action)}
    end
  end

  defp decode_eval(state, action, result) when action in ["snapshot", "eval", "click", "fill"] do
    map =
      cond do
        is_map(result) -> stringify(result)
        is_binary(result) -> Scripts.decode_eval_result(result)
        true -> %{"raw" => inspect(result)}
      end

    content =
      if action == "snapshot" do
        Scripts.format_snapshot(map)
      else
        Scripts.format_reply(map)
      end

    details =
      base_details(state, action)
      |> Map.put(:raw, map)
      |> maybe_needs_user(map)

    if match?(%{"ok" => false}, map) do
      {:error, map["error"] || content, details}
    else
      {:ok, content, details}
    end
  end

  defp decode_eval(state, action, result) do
    {:ok, Scripts.format_reply(result), base_details(state, action)}
  end

  defp ok_result(state, action, result) do
    {:ok, Scripts.format_reply(result), base_details(state, action)}
  end

  defp base_details(state, action) do
    %{
      backend: "webview",
      action: action,
      session_id: state.session_id,
      generation: state.generation,
      visible: state.visible,
      control: Atom.to_string(state.control),
      url: state.url,
      refs_gen: state.refs_gen,
      profile: "shared"
    }
  end

  defp maybe_needs_user(details, %{"needs_user" => true} = map) do
    Map.merge(details, %{
      needs_user: true,
      reason: map["reason"] || "user takeover required"
    })
  end

  defp maybe_needs_user(details, _), do: details

  defp blocked_write?(state, action) do
    state.control in [:user, :waiting_user] and action in @write_actions
  end

  defp write_blocked(state, action) do
    {:error, "browser is under user control; #{action} rejected",
     Map.merge(base_details(state, action), %{needs_user: true, control: "user"})}
  end

  defp recovery_needed(state) do
    {:error, "browser session needs recovery after uncertain navigation",
     Map.merge(base_details(state, "snapshot"), %{needs_recovery: true})}
  end

  defp show(state, input) do
    reason = get_field(input, "reason")
    takeover? = get_field(input, "takeover") in [true, "true"]

    if takeover? do
      state = %{state | control: :waiting_user}

      details =
        base_details(state, "show")
        |> Map.merge(%{needs_user: true, reason: reason || "user takeover required"})

      {{:ok, "waiting for user takeover", details}, state}
    else
      meta = %{
        conversation_id: state.conversation_id,
        url: state.url,
        control: state.control,
        agent_operating?: state.control == :agent,
        reason: reason
      }

      case Display.show(:browser, state.session_id, meta) do
        :ok ->
          state = %{state | visible: true}
          _ = overlay_command(:show, state)
          {{:ok, "shown", base_details(state, "show")}, state}

        {:error, :other_conversation_takeover} ->
          {{:error, "another conversation is under user control",
            Map.merge(base_details(state, "show"), %{notified?: true})}, state}

        {:error, :not_configured} ->
          state = %{state | visible: true}
          {{:ok, "shown", Map.put(base_details(state, "show"), :native, false)}, state}

        {:error, reason} ->
          {{:error, format_reason(reason)}, state}
      end
    end
  end

  defp hide(state) do
    _ = Display.hide(:browser, state.session_id)
    state = %{state | visible: false}
    _ = overlay_command(:hide, state)
    {{:ok, "hidden", base_details(state, "hide")}, state}
  end

  defp overlay_command(op, state) do
    Handbean.NativeDisplay.command(%{
      op: op,
      owner: :browser,
      id: state.session_id,
      url: state.url,
      conversation_id: state.conversation_id,
      generation: state.generation,
      control: Atom.to_string(state.control)
    })
  end

  defp maybe_show(state, user?: true) do
    Display.show(:browser, state.session_id, %{
      conversation_id: state.conversation_id,
      url: state.url,
      control: :user,
      agent_operating?: false
    })
  end

  defp close_session(state, _from) do
    request_id = next_request_id()
    _ = Engine.command(engine_cmd(state, request_id, :destroy), [])
    _ = Display.hide(:browser, state.session_id)

    if state.pending do
      cancel_timer(state.pending.timer)

      GenServer.reply(
        state.pending.from,
        {:error, "browser session closed before result",
         %{stale?: true, request_id: state.pending.request_id}}
      )
    end

    {:stop, :normal, {:ok, "closed", base_details(state, "close")},
     %{state | closed?: true, pending: nil}}
  end

  defp fetch_ref(input, state) do
    ref = get_field(input, "ref")
    refs_gen = get_field(input, "refs_gen")

    cond do
      not is_binary(ref) or ref == "" ->
        {:error, "ref is required"}

      is_integer(refs_gen) and refs_gen != state.refs_gen ->
        {:error, "stale DOM ref"}

      true ->
        {:ok, ref}
    end
  end

  defp validate_http_url(url) when is_binary(url) do
    uri = URI.parse(url)

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" do
      {:ok, url}
    else
      {:error, "only http(s) URLs are allowed"}
    end
  end

  defp validate_http_url(_), do: {:error, "url is required"}

  defp engine_cmd(state, request_id, op, extra \\ []) do
    Map.merge(
      %{
        op: op,
        session_id: state.session_id,
        request_id: request_id,
        generation: state.generation,
        conversation_id: state.conversation_id,
        caller: self()
      },
      Map.new(extra)
    )
  end

  defp maybe_bump_refs(state, action) when action in ["open", "snapshot", "back"] do
    %{state | refs_gen: state.refs_gen + 1}
  end

  defp maybe_bump_refs(state, _action), do: state

  defp maybe_put_url(state, payload) do
    case Handbean.Utils.SafeMap.get_any(payload, :url, "url") do
      url when is_binary(url) -> %{state | url: url}
      _ -> state
    end
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)

  defp next_request_id do
    "req_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
  end

  defp action_name(input), do: get_field(input, "action") || "unknown"

  defp get_field(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, known_atom(key))
  end

  defp known_atom("action"), do: :action
  defp known_atom("url"), do: :url
  defp known_atom("js"), do: :js
  defp known_atom("ref"), do: :ref
  defp known_atom("value"), do: :value
  defp known_atom("text"), do: :text
  defp known_atom("reason"), do: :reason
  defp known_atom("takeover"), do: :takeover
  defp known_atom("refs_gen"), do: :refs_gen
  defp known_atom(_), do: nil

  defp stringify(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp public_state(state) do
    %{
      session_id: state.session_id,
      conversation_id: state.conversation_id,
      generation: state.generation,
      visible: state.visible,
      control: state.control,
      url: state.url,
      refs_gen: state.refs_gen,
      needs_recovery: state.needs_recovery,
      pending?: state.pending != nil
    }
  end

  defp via(session_id) do
    {:via, Registry, {Handbean.Browser.WebViewRegistry, session_id}}
  end
end
