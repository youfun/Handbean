defmodule Handbean.ConversationTitleGenerator do
  @moduledoc """
  Auto-generates conversation titles using the current LLM.

  Follows the Qwen Code session-title design pattern:
  - Fire-and-forget async as soon as the first user message is known
  - Never overwrites a manually-set title
  - 3-7 word, sentence-case title, like a git commit subject

  ## Integration

  Call `publish_provisional/2` and `maybe_generate/3` as soon as the first
  user message is known for a conversation that still has the default
  "New chat" title. The provisional title is the message summary and is
  written immediately, so the sidebar does not wait on the model. The model
  call has a hard deadline and may replace that summary; it must not wait for
  the agent run to finish.
  """

  require Logger

  alias Handbean.Agent.{Message, ProviderGateway}

  @system_prompt """
  Generate a extremely concise title for the given AI coding conversation.

  Rules:
  - Focus on the core topic, technologies, or error names mentioned.
  - Output should be 2 to 5 words.
  - Use the SAME language as the user's message (e.g. Chinese if the user speaks Chinese, English if English).
  - Do NOT include any prefix like "Title:", "About:", "The user wants to", "User asks", "How to", "How do I", etc.
  - Reply with ONLY the title: no quotes, no punctuation, no explanations.

  Examples:
  - Message: "How do I fix a connection timeout in Phoenix with SQLite?"
    Title: Phoenix SQLite Timeout
  - Message: "我想用 Elixir 写一个读取 CSV 文件的脚本"
    Title: Elixir CSV 读取器
  - Message: "Explain the difference between git reset and git revert"
    Title: Git Reset vs Revert
  """

  @doc """
  Fire-and-forget auto title generation for a conversation.

  ## Parameters

    - `conversation_id` — the conversation to update
    - `first_user_message` — the first user message content
    - `provider_config` — a map with `:api_key`, `:model`, `:base_url`, etc.
       (from `Handbean.Agent.ModelConfig.provider_config/1`)

  ## Returns

    - `{:ok, pid}` when a Task is started
    - `:skip` when the conversation already has a non-default title

  ## Guard conditions (from Qwen Code design)

    1. Conversation already has a non-default title → skip
    2. No API key → skip
  """
  @spec maybe_generate(
          String.t(),
          String.t(),
          map()
        ) :: {:ok, pid()} | :skip
  def maybe_generate(conversation_id, first_user_message, provider_config)
      when is_binary(conversation_id) and is_binary(first_user_message) do
    Logger.debug(
      "[TitleGenerator] maybe_generate entry conv_id=#{conversation_id} has_api_key=#{Map.has_key?(provider_config, :api_key)}"
    )

    case Handbean.ConversationStore.get(conversation_id) do
      {:ok, meta} when is_map(meta) ->
        title = meta["title"]
        source = meta["title_source"]

        if generatable_title?(title, source) do
          Logger.debug(
            "[TitleGenerator] Starting async generation conv_id=#{conversation_id} title=#{inspect(title)} source=#{inspect(source)}"
          )

          start_async_generate(conversation_id, first_user_message, provider_config)
        else
          Logger.debug(
            "[TitleGenerator] Skipping — title already set for #{conversation_id}: #{inspect(title)}"
          )

          :skip
        end

      {:error, :not_found} ->
        Logger.debug("[TitleGenerator] Conversation not found: #{conversation_id}")
        :skip
    end
  end

  @doc false
  @spec build_title_prompt(String.t()) :: String.t()
  def build_title_prompt(first_user_message) do
    truncated = String.slice(first_user_message, 0, 200)

    "#{@system_prompt}\n\nUser's first message: #{truncated}"
  end

  @doc false
  @spec extract_title(String.t()) :: {:ok, String.t()} | {:error, :empty}
  def extract_title(response_text) do
    cleaned =
      response_text
      |> String.trim()
      |> String.trim("\"")
      |> String.trim("'")
      |> String.trim("`")
      |> String.trim(".")
      |> String.trim()
      |> String.slice(0, 80)

    stripped = strip_generic_prefixes(cleaned)

    cond do
      stripped == "" ->
        {:error, :empty}

      true ->
        {:ok, sentence_case(stripped)}
    end
  end

  # ── Private ──

  @title_timeout_ms 20_000

  @doc """
  Write a message-summary title immediately when the conversation is still
  "New chat".

  This is what the sidebar should show before the model responds. A later
  model title may replace it. A manual or already generated title is left
  alone.
  """
  @spec publish_provisional(String.t(), String.t()) :: {:ok, String.t()} | :skip
  def publish_provisional(conversation_id, first_user_message)
      when is_binary(conversation_id) and is_binary(first_user_message) do
    title = fallback_title(first_user_message)

    if title == "" do
      :skip
    else
      case Handbean.ConversationStore.get_meta(conversation_id) do
        {:ok, %{"title" => current}} ->
          if default_title?(current) do
            write_title(conversation_id, title, "fallback")
            {:ok, title}
          else
            :skip
          end

        {:ok, %{}} ->
          write_title(conversation_id, title, "fallback")
          {:ok, title}

        _ ->
          :skip
      end
    end
  end

  @doc false
  @spec default_title?(term()) :: boolean()
  def default_title?(title) when is_binary(title), do: String.starts_with?(title, "New chat")
  def default_title?(_title), do: true

  defp broadcast_title_updated(conversation_id, title) do
    Handbean.ConversationStore.broadcast_title_updated(conversation_id, title)
  end

  @doc false
  @spec title_provider_config(map()) :: map()
  def title_provider_config(provider_config) when is_map(provider_config) do
    # Title calls must not inherit the chat turn's reasoning budget, session,
    # or multi-minute receive timeout. A thinking model otherwise spends the
    # whole agent run (or its own long timeout) before the sidebar can update.
    provider_config
    |> Map.drop([
      :reasoning,
      :reasoning_effort,
      :thinking,
      :output_config,
      :extended_thinking,
      :conversation_id,
      :provider_state,
      :include
    ])
    |> Map.put(:max_tokens, 64)
    |> Map.put(:temperature, 0.3)
    |> Map.put(:stream, false)
    |> Map.put(:max_retries, 0)
    |> Map.put(:retry_count, 0)
    |> Map.put(:receive_timeout, @title_timeout_ms)
    |> Map.update(:req_options, [receive_timeout: @title_timeout_ms], fn
      opts when is_list(opts) -> Keyword.put(opts, :receive_timeout, @title_timeout_ms)
      _ -> [receive_timeout: @title_timeout_ms]
    end)
  end

  defp start_async_generate(conversation_id, first_user_message, provider_config) do
    api_key = Map.get(provider_config, :api_key) || System.get_env("OPENAI_API_KEY")

    if is_nil(api_key) or api_key == "" do
      Logger.debug("[TitleGenerator] Skipping — no API key configured conv_id=#{conversation_id}")
      :skip
    else
      config =
        provider_config
        |> title_provider_config()
        |> Map.put(:api_key, api_key)

      Logger.debug(
        "[TitleGenerator] Starting async task conv_id=#{conversation_id} api=#{inspect(Map.get(config, :api))} provider=#{inspect(Map.get(config, :provider))} model=#{inspect(Map.get(config, :model))}"
      )

      Task.Supervisor.start_child(Handbean.AgentRunTaskSupervisor, fn ->
        run_exclusive(conversation_id, fn ->
          do_generate(conversation_id, first_user_message, config)
        end)
      end)
    end
  end

  defp run_exclusive(conversation_id, fun) do
    name = {:handbean_title_gen, conversation_id}

    case :global.register_name(name, self()) do
      :yes ->
        try do
          fun.()
        after
          :global.unregister_name(name)
        end

      :no ->
        Logger.debug(
          "[TitleGenerator] Skipping — generation already in flight conv_id=#{conversation_id}"
        )

        :skip
    end
  end

  @doc false
  @spec do_generate(String.t(), String.t(), map()) :: :ok | no_return()
  def do_generate(conversation_id, first_user_message, config) do
    Process.put(:title_notify_pid, Map.get(config, :notify_pid))
    prompt = build_title_prompt(first_user_message)

    Logger.debug(
      "[TitleGenerator] do_generate start conv_id=#{conversation_id} provider=#{inspect(Map.get(config, :provider))} api=#{inspect(Map.get(config, :api))} model=#{inspect(Map.get(config, :model))}"
    )

    messages = [
      %Message{role: :user, content: prompt}
    ]

    provider = resolve_provider(config)

    Logger.debug("[TitleGenerator] resolved provider module=#{inspect(provider)}")

    result = complete_within(provider, messages, config)

    case result do
      {:ok, %{stop_reason: :end_turn, messages: [%Message{content: title_text}]}}
      when is_binary(title_text) ->
        Logger.debug(
          "[TitleGenerator] got text response conv_id=#{conversation_id} text_len=#{byte_size(title_text)}"
        )

        update_title_from_text(conversation_id, title_text, first_user_message)

      {:ok, %{stop_reason: :end_turn, messages: [%Message{content: blocks}]}}
      when is_list(blocks) ->
        Logger.debug(
          "[TitleGenerator] got blocks response conv_id=#{conversation_id} blocks_count=#{length(blocks)} inspect=#{inspect(blocks)}"
        )

        case title_text_from_blocks(blocks) do
          text when is_binary(text) and text != "" ->
            update_title_from_text(conversation_id, text, first_user_message)

          _ ->
            Logger.debug(
              "[TitleGenerator] Empty text title response, falling back to message truncation"
            )

            apply_fallback_title(conversation_id, first_user_message)
        end

      {:error, reason} ->
        Logger.warning(fn ->
          "[TitleGenerator] Failed to generate title: #{inspect(reason)}, falling back to message truncation"
        end)

        apply_fallback_title(conversation_id, first_user_message)

      other ->
        Logger.warning(fn ->
          "[TitleGenerator] Unexpected response: #{inspect(other)}, falling back to message truncation"
        end)

        apply_fallback_title(conversation_id, first_user_message)
    end
  end

  defp update_title_from_text(conversation_id, title_text, first_user_message) do
    case extract_title(title_text) do
      {:ok, clean_title} ->
        save_title(conversation_id, clean_title)

      {:error, :empty} ->
        Logger.debug("[TitleGenerator] Empty title response, falling back to message truncation")
        apply_fallback_title(conversation_id, first_user_message)
    end
  end

  defp save_title(conversation_id, title) do
    case Handbean.ConversationStore.get_meta(conversation_id) do
      {:ok, %{"title_source" => "manual", "title" => current}}
      when is_binary(current) and not is_nil(current) ->
        if String.starts_with?(current, "New chat") do
          write_auto_title(conversation_id, title)
        else
          Logger.debug(
            "[TitleGenerator] Skipping save — manual title for #{conversation_id}: #{current}"
          )
        end

      _ ->
        write_auto_title(conversation_id, title)
    end
  end

  defp write_auto_title(conversation_id, title) do
    write_title(conversation_id, title, "auto")
  end

  defp write_title(conversation_id, title, source) do
    case Handbean.ConversationStore.update_meta(conversation_id,
           title: title,
           title_source: source
         ) do
      {:ok, _meta} ->
        Logger.debug("[TitleGenerator] Set auto-title: #{title}")
        broadcast_title_updated(conversation_id, title)
        notify_title_ready(conversation_id, title)

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        Logger.warning(fn -> "[TitleGenerator] Failed to update meta: #{inspect(reason)}" end)
    end
  end

  defp notify_title_ready(conversation_id, title) do
    case Process.get(:title_notify_pid) do
      pid when is_pid(pid) -> send(pid, {:conversation_title_ready, conversation_id, title})
      _ -> :ok
    end
  end

  defp apply_fallback_title(conversation_id, first_user_message) do
    title = fallback_title(first_user_message)
    save_title(conversation_id, title)
  end

  defp complete_within(provider, messages, config) do
    timeout = title_timeout(config)
    parent = self()
    ref = make_ref()

    pid =
      spawn(fn ->
        result =
          try do
            ProviderGateway.complete(provider, messages, [], Map.put(config, :stream, false))
          catch
            kind, reason -> {:error, {kind, reason}}
          end

        send(parent, {ref, result})
      end)

    receive do
      {^ref, result} ->
        result
    after
      timeout ->
        Process.exit(pid, :kill)

        Logger.warning(fn ->
          "[TitleGenerator] Title request exceeded #{timeout}ms, using message summary"
        end)

        {:error, :timeout}
    end
  end

  defp title_timeout(config) do
    case Map.get(config, :title_timeout_ms) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _ -> @title_timeout_ms
    end
  end

  defp generatable_title?(title, source) do
    default_title?(title) or source == "fallback"
  end

  @doc false
  @spec fallback_title(String.t()) :: String.t()
  def fallback_title(first_user_message) do
    first_user_message
    |> String.trim()
    |> String.replace(~r/[\r\n\t\s]+/, " ")
    |> then(fn msg ->
      if String.length(msg) > 30 do
        String.slice(msg, 0, 27) <> "..."
      else
        msg
      end
    end)
  end

  defp title_text_from_blocks(blocks) do
    blocks
    |> Enum.filter(fn block ->
      type = block_value(block, :type)
      type == "text"
    end)
    |> Enum.map_join(" ", fn block ->
      block_value(block, :text) || ""
    end)
    |> String.trim()
  end

  @prefixes [
    "the user wants to ",
    "the user is asking to ",
    "the user is asking for ",
    "the user is asking about ",
    "the user requested to ",
    "the user requested for ",
    "the user wants ",
    "the user asks for ",
    "the user asks ",
    "the user needs ",
    "the user requested ",
    "the user is asking ",
    "user wants to ",
    "user is asking to ",
    "user is asking for ",
    "user is asking about ",
    "user requested to ",
    "user requested for ",
    "user wants ",
    "user asks for ",
    "user asks ",
    "user needs ",
    "user requested ",
    "user is asking ",
    "this conversation is about ",
    "this conversation covers ",
    "this conversation ",
    "the conversation ",
    "this request is for ",
    "this request is to ",
    "this request ",
    "the request is for ",
    "the request is to ",
    "the request ",
    "request to ",
    "request for "
  ]

  defp strip_generic_prefixes(title) do
    trimmed_title = String.trim(title)
    lower_title = String.downcase(trimmed_title)

    matching_prefix =
      Enum.find(@prefixes, fn prefix ->
        String.starts_with?(lower_title, prefix)
      end)

    if matching_prefix do
      len = String.length(matching_prefix)
      {_, rest} = String.split_at(trimmed_title, len)
      strip_generic_prefixes(rest)
    else
      trimmed_title
    end
  end

  defp sentence_case(""), do: ""

  defp sentence_case(str) do
    {first, rest} = String.split_at(str, 1)
    String.upcase(first) <> rest
  end

  defp block_value(block, key) when is_map(block) do
    Map.get(block, key) || Map.get(block, Atom.to_string(key))
  end

  defp block_value(_block, _key), do: nil

  @doc false
  @spec resolve_provider(map()) :: module()
  def resolve_provider(config) do
    # Allow mock provider injection for testing
    case Map.get(config, :provider_module) do
      mod when is_atom(mod) and mod != nil -> mod
      _ -> resolve_from_config(config)
    end
  end

  defp resolve_from_config(config) do
    api = Map.get(config, :api, :openai)
    provider = Map.get(config, :provider)
    Handbean.Agent.Config.resolve_provider_from_api(api, nil, provider)
  end
end
