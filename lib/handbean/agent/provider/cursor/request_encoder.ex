defmodule Handbean.Agent.Provider.Cursor.RequestEncoder do
  @moduledoc """
  Builds initial Cursor run requests and follow-up user actions.

  The returned consumed-user ledger is data for the session owner to install
  only after the run request has been written successfully.
  """

  alias Handbean.Agent.Message
  alias Handbean.Agent.Provider.Cursor.{HistoryEncoder, Proto}

  def encode(
        messages,
        model,
        config,
        blobs,
        cursor_conversation_id,
        uuid_fun \\ &Ecto.UUID.generate/0
      )
      when is_list(messages) and is_function(uuid_fun, 0) do
    {history, action_users} = split_action_users(messages)
    {first, extra_users} = first_action(action_users, uuid_fun)

    {root_ids, turn_ids, blobs} =
      HistoryEncoder.encode(history, config[:system_prompt], blobs, uuid_fun)

    conversation_state = Proto.encode_conversation_state(root_ids, turn_ids)

    run =
      Proto.encode_run_request(
        conversation_state: conversation_state,
        action: user_action(first, uuid_fun),
        conversation_id: cursor_conversation_id,
        requested_model: encode_requested_model(model, config)
      )

    {ids, nils} = consumed_sets(history ++ [first])

    %{
      payload: Proto.encode_client(%{run_request: run}),
      blobs: blobs,
      consumed_user_ids: ids,
      consumed_nil_users: nils,
      extra_users: extra_users
    }
  end

  def user_action(%Message{} = message, uuid_fun \\ &Ecto.UUID.generate/0)
      when is_function(uuid_fun, 0) do
    message_id = message.id || uuid_fun.()
    user_message = Proto.encode_user_message(HistoryEncoder.text(message.content), message_id)
    Proto.encode_user_action(user_message)
  end

  defp first_action([first | extra_users], _uuid_fun), do: {first, extra_users}

  defp first_action([], uuid_fun) do
    {%Message{role: :user, content: "", id: uuid_fun.()}, []}
  end

  defp encode_requested_model(model, config) do
    routing = get_in(config, [:model_meta, "cursorRequestedModel"]) || %{}

    Proto.encode_requested_model(
      routing["modelId"] || model,
      max_mode: routing["maxMode"] == true,
      parameters: routing["parameters"] || []
    )
  end

  defp split_action_users(messages) do
    {suffix, prefix} =
      messages
      |> Enum.reverse()
      |> Enum.split_while(&(&1.role == :user))

    {Enum.reverse(prefix), Enum.reverse(suffix)}
  end

  defp consumed_sets(messages) do
    users = Enum.filter(messages, &(&1.role == :user))
    ids = users |> Enum.map(& &1.id) |> Enum.filter(&is_binary/1) |> MapSet.new()
    nils = Enum.count(users, &is_nil(&1.id))
    {ids, nils}
  end
end
