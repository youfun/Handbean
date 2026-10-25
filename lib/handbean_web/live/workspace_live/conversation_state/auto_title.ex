defmodule HandbeanWeb.WorkspaceLive.ConversationState.AutoTitle do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  require Logger

  alias HandbeanWeb.WorkspaceLive.ConversationSwitching
  alias HandbeanWeb.WorkspaceLive.ModelSelection

  def schedule(socket, message, conversation) when is_binary(message) do
    trigger(socket, message, conversation)
  end

  def schedule(socket, _message, _conversation), do: socket

  def maybe(socket, :completed, timeline, conversation) when is_function(conversation, 0) do
    first_user_msg =
      Enum.find_value(timeline, fn entry ->
        if entry["role"] == "user" and not is_nil(entry["content"]) do
          entry["content"]
        end
      end)

    if first_user_msg do
      trigger(socket, first_user_msg, conversation.())
    else
      Logger.debug(
        "[WorkspaceLive] maybe_auto_title skip — no user message found in timeline conv_id=#{socket.assigns.current_conversation_id}"
      )

      socket
    end
  end

  def maybe(socket, _status, _timeline, _conversation), do: socket

  def trigger(socket, message, conversation) when is_binary(message) do
    title = conversation_value(conversation, "title", "")
    title_source = conversation_value(conversation, "title_source", nil)
    conversation_id = socket.assigns.current_conversation_id

    Logger.debug(
      "[WorkspaceLive] maybe_auto_title entry conv_id=#{conversation_id} title=#{inspect(title)} title_source=#{inspect(title_source)}"
    )

    cond do
      titled?(title, title_source) ->
        Logger.debug(
          "[WorkspaceLive] maybe_auto_title skip — title already set conv_id=#{conversation_id} title=#{inspect(title)} title_source=#{inspect(title_source)}"
        )

        socket

      String.trim(message) == "" ->
        socket

      true ->
        socket = show_provisional(socket, conversation_id, message)

        case ModelSelection.resolve_auto_title_model(socket, conversation) do
          {:ok, provider_config, selected_model} ->
            provider_config = Map.put(provider_config, :notify_pid, self())

            case Handbean.ConversationTitleGenerator.maybe_generate(
                   conversation_id,
                   message,
                   provider_config
                 ) do
              {:ok, pid} ->
                Logger.debug(
                  "[WorkspaceLive] Triggered auto-title generation conv_id=#{conversation_id} model=#{inspect(selected_model)} task_pid=#{inspect(pid)}"
                )

              :skip ->
                Logger.debug(
                  "[WorkspaceLive] TitleGenerator.maybe_generate returned :skip conv_id=#{conversation_id}"
                )

              other ->
                Logger.debug(
                  "[WorkspaceLive] TitleGenerator.maybe_generate failed conv_id=#{conversation_id} result=#{inspect(other)}"
                )
            end

            socket

          {:error, reason, selected_model} ->
            Logger.debug(
              "[WorkspaceLive] Skipped model title model=#{inspect(selected_model)} reason=#{inspect(reason)}"
            )

            socket
        end
    end
  end

  def titled?(title, source) do
    not Handbean.ConversationTitleGenerator.default_title?(title) and source != "fallback"
  end

  def show_provisional(socket, conversation_id, message) do
    case Handbean.ConversationTitleGenerator.publish_provisional(conversation_id, message) do
      {:ok, title} ->
        socket
        |> ConversationSwitching.apply_sidebar_title(conversation_id, title, "fallback")
        |> patch_page_title(conversation_id, title)

      :skip ->
        socket
    end
  end

  def patch_page_title(socket, conv_id, title) do
    if socket.assigns.current_conversation_id == conv_id and is_binary(title) and title != "" do
      assign(socket, :page_title, title)
    else
      socket
    end
  end

  def patch_current_page_title(socket, conv_id) do
    title =
      socket.assigns.conversations_by_workspace
      |> Map.values()
      |> List.flatten()
      |> Enum.find_value(fn conversation ->
        if conversation_value(conversation, "id", nil) == conv_id do
          conversation_value(conversation, "title", nil)
        end
      end)

    patch_page_title(socket, conv_id, title)
  end

  defp conversation_value(conversation, key, default) do
    Handbean.Utils.SafeMap.get(conversation, key, default)
  end
end
