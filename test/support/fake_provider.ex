defmodule Handbean.TestSupport.FakeProvider do
  @moduledoc """
   Fake provider for testing the agent loop without real API calls.

   Reference: `jido_ai/test/support/fake_req_llm.ex` — adapted for Handbean's
   `Handbean.Agent.Provider` behaviour without Jido/ReqLLM dependencies.

   ## Usage pattern

   1. Start a named Agent process that injects `__config__` into
      the ETS table or Process dictionary so the FakeProvider can read it
   2. Or: configure via `provider_config` key `:scenario`

   ## Scenarios

   Set `provider_config[:scenario]` to one of:
     - `:simple_answer` — one text response → :end_turn
     - `:tool_use_chain` — tool_use → tool_result → final answer
     - `:bash_git_status` — bash git status tool_use → tool_result → final answer
     - `{:bash_script, [input]}` — one bash tool_use per turn with each input, then final answer
     - `{:script, fun}` — `fun.(messages, tool_defs)` returns text or `{:tools, calls}`
     - `:multi_tool` — two tool calls → results → final answer
     - `:memory_learn_and_recall` — mem_learn → mem_recall → final answer
     - `:error_response` — provider error
     - `:transient_closed_once` — first call returns a retryable closed transport error
     - `:streaming_chunks` — streaming text chunks (for future use)
     - `:streaming_error_after_chunk` — emits a chunk, then returns retryable error
  """

  @behaviour Handbean.Agent.Provider

  alias Handbean.Agent.Message

  @impl true
  def context_editing?, do: true

  @impl true
  def complete(messages, tool_defs, config) do
    if config[:stream] && is_function(config[:on_chunk]) do
      stream(messages, tool_defs, config, config[:on_chunk])
    else
      scenario = Map.get(config, :scenario, :simple_answer)
      turn = Map.get(config, :turn, 0)
      notify = Map.get(config, :notify)

      if is_pid(notify) do
        send(notify, {:provider_config, config})
        send(notify, {:provider_messages, messages})
        send(notify, {:provider_tool_defs, tool_defs})
      end

      do_complete(messages, tool_defs, scenario, turn)
    end
  end

  @impl true
  def stream(messages, tool_defs, config, on_chunk) do
    scenario = Map.get(config, :scenario, :simple_answer)

    case scenario do
      :streaming_chunks ->
        Enum.each(["Hello", " from", " stream"], on_chunk)

        {:ok,
         %{
           stop_reason: :end_turn,
           messages: [Message.assistant("Hello from stream")],
           usage: %{input_tokens: 5, output_tokens: 8},
           response_metadata: %{id: "fake-stream-msg-001", model: "fake-model"}
         }}

      :streaming_partial_then_final_longer ->
        Enum.each(["Now I have a", " complete"], on_chunk)

        {:ok,
         %{
           stop_reason: :end_turn,
           messages: [Message.assistant("Now I have a complete picture of the codebase.")],
           usage: %{input_tokens: 5, output_tokens: 12},
           response_metadata: %{id: "fake-stream-msg-003", model: "fake-model"}
         }}

      :streaming_no_chunks ->
        {:ok,
         %{
           stop_reason: :end_turn,
           messages: [Message.assistant("Fallback streamed response")],
           usage: %{input_tokens: 5, output_tokens: 8},
           response_metadata: %{id: "fake-stream-msg-002", model: "fake-model"}
         }}

      :streaming_error_after_chunk ->
        on_chunk.("partial")
        {:error, "HTTP request failed: %Finch.TransportError{reason: :closed}"}

      :prompt_too_long_once ->
        do_complete(messages, tool_defs, :prompt_too_long_once, Map.get(config, :turn, 0))

      {:script, fun} when is_function(fun, 2) ->
        # LiveView runs with streaming: true. Emit the scripted text as one
        # chunk so the composer path and the non-streaming path share a result.
        result = do_complete(messages, tool_defs, scenario, Map.get(config, :turn, 0))
        emit_scripted_chunks(result, on_chunk)
        result

      _ ->
        complete(messages, tool_defs, Map.delete(config, :stream))
    end
  end

  defp emit_scripted_chunks({:ok, %{messages: messages}}, on_chunk) do
    messages
    |> Enum.filter(&match?(%Message{role: :assistant}, &1))
    |> Enum.each(fn message ->
      text = Message.text(message)
      if is_binary(text) and text != "", do: on_chunk.(text)
    end)
  end

  # ── Scenario dispatch ──

  defp do_complete(_messages, _tool_defs, :transient_closed_once, _turn) do
    key = {__MODULE__, :transient_closed_once}
    calls = Process.get(key, 0)
    Process.put(key, calls + 1)

    if calls == 0 do
      {:error, "HTTP request failed: %Finch.TransportError{reason: :closed}"}
    else
      {:ok,
       %{
         stop_reason: :end_turn,
         messages: [Message.assistant("Recovered after transient close.")],
         usage: %{input_tokens: 5, output_tokens: 8},
         response_metadata: %{id: "fake-msg-recovered", model: "fake-model"}
       }}
    end
  end

  defp do_complete(_messages, _tool_defs, :simple_answer, _turn) do
    {:ok,
     %{
       stop_reason: :end_turn,
       messages: [Message.assistant("Hello! I am a fake provider response.")],
       usage: %{input_tokens: 5, output_tokens: 8},
       response_metadata: %{id: "fake-msg-001", model: "fake-model"}
     }}
  end

  defp do_complete(messages, _tool_defs, :echo_last_user, _turn) do
    last_user =
      messages
      |> Enum.filter(&match?(%Message{role: :user}, &1))
      |> List.last()
      |> case do
        %Message{content: content} -> content
        _ -> "none"
      end

    {:ok,
     %{
       stop_reason: :end_turn,
       messages: [Message.assistant("echo: #{last_user}")],
       usage: %{input_tokens: 5, output_tokens: 8},
       response_metadata: %{id: "fake-msg-echo", model: "fake-model"}
     }}
  end

  defp do_complete(messages, tool_defs, :steer_after_tool, turn) do
    has_tool_result? = Enum.any?(messages, &match?(%Message{role: :tool_result}, &1))

    if has_tool_result? do
      do_complete(messages, tool_defs, :echo_last_user, turn)
    else
      tool_call = %{
        type: "tool_use",
        id: "toolu_steer_after_tool",
        name: "read",
        input: %{"file_path" => "test_file.txt"}
      }

      {:ok,
       %{
         stop_reason: :tool_use,
         messages: [Message.tool_use([tool_call])],
         usage: %{input_tokens: 10, output_tokens: 15},
         response_metadata: %{id: "fake-msg-steer-tool", model: "fake-model"}
       }}
    end
  end

  defp do_complete(messages, _tool_defs, :tool_use_chain, _turn) do
    has_tool_result? =
      Enum.any?(messages, fn
        %Message{role: :tool_result} -> true
        _ -> false
      end)

    if has_tool_result? do
      final_content =
        "I received the tool result. The file contains useful information. Task completed."

      {:ok,
       %{
         stop_reason: :end_turn,
         messages: [Message.assistant(final_content)],
         usage: %{input_tokens: 15, output_tokens: 20},
         response_metadata: %{id: "fake-msg-002", model: "fake-model"}
       }}
    else
      tool_call = %{
        type: "tool_use",
        id: "toolu_001",
        name: "read",
        input: %{"file_path" => "test_file.txt"}
      }

      {:ok,
       %{
         stop_reason: :tool_use,
         messages: [Message.tool_use([tool_call])],
         usage: %{input_tokens: 10, output_tokens: 15},
         response_metadata: %{id: "fake-msg-001-tool", model: "fake-model"}
       }}
    end
  end

  defp do_complete(messages, _tool_defs, :bash_git_status, _turn) do
    has_tool_result? =
      Enum.any?(messages, fn
        %Message{role: :tool_result} -> true
        _ -> false
      end)

    if has_tool_result? do
      {:ok,
       %{
         stop_reason: :end_turn,
         messages: [Message.assistant("git status completed without a cd prefix.")],
         usage: %{input_tokens: 15, output_tokens: 10},
         response_metadata: %{id: "fake-msg-bash-git-status-final", model: "fake-model"}
       }}
    else
      tool_call = %{
        type: "tool_use",
        id: "toolu_bash_git_status",
        name: "bash",
        input: %{"command" => "git status --short"}
      }

      {:ok,
       %{
         stop_reason: :tool_use,
         messages: [Message.tool_use([tool_call])],
         usage: %{input_tokens: 10, output_tokens: 12},
         response_metadata: %{id: "fake-msg-bash-git-status-tool", model: "fake-model"}
       }}
    end
  end

  # Test-scripted turns. `fun.(messages, tool_defs)` returns a final text or
  # `{:tools, [%{name: name, input: input}]}`. It runs in the Turn task, so it
  # may block on `receive` to hold a run open.
  defp do_complete(messages, tool_defs, {:script, fun}, _turn) when is_function(fun, 2) do
    case fun.(messages, tool_defs) do
      {:tools, calls, usage} when is_list(calls) and is_map(usage) ->
        script_tool_response(calls, usage)

      {:tools, calls} ->
        script_tool_response(calls, %{input_tokens: 3, output_tokens: 3})

      text when is_binary(text) ->
        {:ok,
         %{
           stop_reason: :end_turn,
           messages: [Message.assistant(text)],
           usage: %{input_tokens: 2, output_tokens: 2},
           response_metadata: %{id: "fake-msg-script-final", model: "fake-model"}
         }}
    end
  end

  # One bash call per turn, in order; the index is the number of tool results so far,
  # so an approval pause and resume continue with the same call.
  defp do_complete(messages, _tool_defs, {:bash_script, inputs}, _turn) do
    done = Enum.count(messages, &match?(%Message{role: :tool_result}, &1))

    case Enum.at(inputs, done) do
      nil ->
        {:ok,
         %{
           stop_reason: :end_turn,
           messages: [Message.assistant("bash script finished")],
           usage: %{input_tokens: 5, output_tokens: 5},
           response_metadata: %{id: "fake-msg-bash-script-final", model: "fake-model"}
         }}

      input ->
        tool_call = %{type: "tool_use", id: "toolu_bash_#{done}", name: "bash", input: input}

        {:ok,
         %{
           stop_reason: :tool_use,
           messages: [Message.tool_use([tool_call])],
           usage: %{input_tokens: 5, output_tokens: 5},
           response_metadata: %{id: "fake-msg-bash-script-#{done}", model: "fake-model"}
         }}
    end
  end

  defp do_complete(messages, _tool_defs, :multi_tool, _turn) do
    has_tool_result? =
      Enum.any?(messages, fn
        %Message{role: :tool_result} -> true
        _ -> false
      end)

    if has_tool_result? do
      {:ok,
       %{
         stop_reason: :end_turn,
         messages: [
           Message.assistant("Both tools completed. The results show the system is healthy.")
         ],
         usage: %{input_tokens: 25, output_tokens: 18},
         response_metadata: %{id: "fake-msg-003", model: "fake-model"}
       }}
    else
      tool_calls = [
        %{
          type: "tool_use",
          id: "toolu_001",
          name: "read",
          input: %{"file_path" => "a.txt"}
        },
        %{
          type: "tool_use",
          id: "toolu_002",
          name: "bash",
          input: %{"command" => "ls"}
        }
      ]

      {:ok,
       %{
         stop_reason: :tool_use,
         messages: [Message.tool_use(tool_calls)],
         usage: %{input_tokens: 12, output_tokens: 22},
         response_metadata: %{id: "fake-msg-001-multi", model: "fake-model"}
       }}
    end
  end

  defp do_complete(messages, _tool_defs, :prompt_too_long_once, _turn) do
    key = {__MODULE__, :prompt_too_long_once}
    calls = Process.get(key, 0)
    Process.put(key, calls + 1)

    if calls == 0 do
      {:error, "maximum context length exceeded"}
    else
      last_user =
        messages
        |> Enum.filter(&match?(%Message{role: :user}, &1))
        |> List.last()
        |> case do
          %Message{content: content} -> content
          _ -> "none"
        end

      {:ok,
       %{
         stop_reason: :end_turn,
         messages: [Message.assistant("Recovered after compaction: #{last_user}")],
         usage: %{input_tokens: 5, output_tokens: 8},
         response_metadata: %{id: "fake-msg-prompt-recovered", model: "fake-model"}
       }}
    end
  end

  defp do_complete(_messages, _tool_defs, :error_response, _turn) do
    {:error, "Fake provider simulated error"}
  end

  defp do_complete(messages, _tool_defs, :memory_learn_and_recall, _turn) do
    # Two-stage: first mem_learn, then mem_recall, then final answer
    has_recall_result? =
      Enum.any?(messages, fn
        %Message{role: :tool_result} = msg ->
          Enum.any?(msg.content, fn block ->
            String.contains?(block[:content] || "", "mem_recall") or
              (block[:tool_use_id] || "") =~ "mem_recall_"
          end)

        _ ->
          false
      end)

    has_learn_result? =
      Enum.any?(messages, fn
        %Message{role: :tool_result} -> true
        _ -> false
      end)

    cond do
      has_recall_result? ->
        {:ok,
         %{
           stop_reason: :end_turn,
           messages: [
             Message.assistant(
               "Based on memory recall, the user prefers snake_case. This matches what we just learned."
             )
           ],
           usage: %{input_tokens: 20, output_tokens: 18},
           response_metadata: %{id: "fake-msg-mem-final", model: "fake-model"}
         }}

      has_learn_result? ->
        tool_call = %{
          type: "tool_use",
          id: "mem_recall_001",
          name: "mem_recall",
          input: %{"query" => "naming"}
        }

        {:ok,
         %{
           stop_reason: :tool_use,
           messages: [Message.tool_use([tool_call])],
           usage: %{input_tokens: 15, output_tokens: 12},
           response_metadata: %{id: "fake-msg-mem-recall", model: "fake-model"}
         }}

      true ->
        tool_call = %{
          type: "tool_use",
          id: "mem_learn_001",
          name: "mem_learn",
          input: %{"content" => "User prefers snake_case naming", "kind" => "preference"}
        }

        {:ok,
         %{
           stop_reason: :tool_use,
           messages: [Message.tool_use([tool_call])],
           usage: %{input_tokens: 10, output_tokens: 10},
           response_metadata: %{id: "fake-msg-mem-learn", model: "fake-model"}
         }}
    end
  end

  defp script_tool_response(calls, usage) do
    tool_calls =
      Enum.map(calls, fn call ->
        %{
          type: "tool_use",
          id: "toolu_script_#{System.unique_integer([:positive])}",
          name: call.name,
          input: call.input
        }
      end)

    {:ok,
     %{
       stop_reason: :tool_use,
       messages: [Message.tool_use(tool_calls)],
       usage: usage,
       response_metadata: %{id: "fake-msg-script-tools", model: "fake-model"}
     }}
  end
end
