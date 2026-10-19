defmodule HandbeanWeb.WorkspaceLive.WidgetCommands do
  @moduledoc false

  @max_payload_bytes 8 * 1024
  @max_identifier_bytes 256
  @max_selections 100
  @max_label_length 200
  @max_string_value_length 2_000

  @type reason ::
          :entry_not_found
          | :incomplete_entry
          | :invalid_entry
          | :invalid_fence_index
          | :invalid_payload
          | :invalid_request
          | :payload_too_large
          | :unknown_command

  @spec prefill_text(map(), map() | nil, String.t()) ::
          {:ok, String.t()} | {:error, reason()}
  def prefill_text(params, entry, conversation_id) do
    with :ok <- validate_request(params),
         :ok <- validate_command(params),
         :ok <- validate_entry(entry, params, conversation_id),
         :ok <- validate_fence(entry["content"], params["fence_index"]),
         {:ok, payload} <- validate_payload(params["payload"]) do
      {:ok, format_prefill(payload)}
    end
  end

  defp validate_request(
         %{
           "request_id" => request_id,
           "entry_id" => entry_id,
           "fence_index" => fence_index,
           "command" => command,
           "payload" => payload
         } = params
       )
       when map_size(params) == 5 and is_binary(request_id) and request_id != "" and
              byte_size(request_id) <= @max_identifier_bytes and is_binary(entry_id) and
              entry_id != "" and byte_size(entry_id) <= @max_identifier_bytes and
              is_integer(fence_index) and fence_index >= 0 and is_binary(command) and
              is_map(payload),
       do: :ok

  defp validate_request(_params), do: {:error, :invalid_request}

  defp validate_command(%{"command" => "prefill_follow_up"}), do: :ok
  defp validate_command(_params), do: {:error, :unknown_command}

  defp validate_entry(nil, _params, _conversation_id), do: {:error, :entry_not_found}

  defp validate_entry(entry, %{"entry_id" => entry_id}, conversation_id)
       when is_map(entry) and is_binary(conversation_id) do
    cond do
      entry["id"] != entry_id or entry["conversation_id"] != conversation_id ->
        {:error, :invalid_entry}

      entry["role"] != "assistant" or entry["content_type"] != "assistant_msg" ->
        {:error, :invalid_entry}

      entry["status"] != "completed" ->
        {:error, :incomplete_entry}

      not is_binary(entry["content"]) ->
        {:error, :invalid_entry}

      true ->
        :ok
    end
  end

  defp validate_entry(_entry, _params, _conversation_id), do: {:error, :invalid_entry}

  defp validate_fence(content, fence_index) do
    if fence_index < closed_widget_fence_count(content),
      do: :ok,
      else: {:error, :invalid_fence_index}
  end

  defp closed_widget_fence_count(content) do
    content
    |> String.split("\n")
    |> Enum.reduce({nil, 0}, fn line, {open_fence, count} ->
      scan_fence(String.trim_trailing(line, "\r"), open_fence, count)
    end)
    |> elem(1)
  end

  defp scan_fence(line, nil, count) do
    case opening_fence(line) do
      nil -> {nil, count}
      fence -> {fence, count}
    end
  end

  defp scan_fence(
         line,
         %{marker: marker, length: length, quote_depth: quote_depth, widget?: widget?} = fence,
         count
       ) do
    if closing_fence?(line, marker, length, quote_depth) do
      {nil, if(widget?, do: count + 1, else: count)}
    else
      {fence, count}
    end
  end

  defp opening_fence(line) do
    {quote_depth, body} = split_blockquote(line)

    case Regex.run(~r/^ {0,3}(`{3,}|~{3,})(.*)$/u, body, capture: :all_but_first) do
      [run, info] ->
        marker = String.first(run)

        if marker == "`" and String.contains?(info, "`") do
          nil
        else
          %{
            marker: marker,
            length: String.length(run),
            quote_depth: quote_depth,
            widget?: widget_info?(info)
          }
        end

      _ ->
        nil
    end
  end

  defp closing_fence?(line, marker, opening_length, opening_quote_depth) do
    {quote_depth, body} = split_blockquote(line)

    case Regex.run(~r/^ {0,3}(`+|~+)[ \t]*$/u, body, capture: :all_but_first) do
      [run] ->
        quote_depth == opening_quote_depth and String.first(run) == marker and
          String.length(run) >= opening_length

      _ ->
        false
    end
  end

  defp split_blockquote(line), do: split_blockquote(line, 0)

  defp split_blockquote(line, depth) do
    case Regex.run(~r/^ {0,3}>[ \t]?(.*)$/u, line, capture: :all_but_first) do
      [rest] -> split_blockquote(rest, depth + 1)
      _ -> {depth, line}
    end
  end

  defp widget_info?(info) do
    case info |> String.trim() |> String.split(~r/\s+/u, parts: 2) do
      [language | _rest] -> String.downcase(language) in ["html", "widget"]
      [] -> false
    end
  end

  defp validate_payload(payload) do
    with {:ok, encoded} <- Handbean.JSON.encode(payload),
         :ok <- validate_payload_size(encoded),
         :ok <- validate_payload_shape(payload) do
      {:ok, payload}
    else
      {:error, :payload_too_large} = error -> error
      _ -> {:error, :invalid_payload}
    end
  end

  defp validate_payload_size(encoded) when byte_size(encoded) <= @max_payload_bytes, do: :ok
  defp validate_payload_size(_encoded), do: {:error, :payload_too_large}

  defp validate_payload_shape(payload) do
    allowed_keys =
      if Map.has_key?(payload, "selections"), do: ~w(prompt selections), else: ["prompt"]

    with true <- Map.keys(payload) |> Enum.sort() == Enum.sort(allowed_keys),
         prompt when is_binary(prompt) <- payload["prompt"],
         true <- String.trim(prompt) != "",
         selections when is_list(selections) <- Map.get(payload, "selections", []),
         true <- length(selections) <= @max_selections,
         true <- Enum.all?(selections, &valid_selection?/1) do
      :ok
    else
      _ -> {:error, :invalid_payload}
    end
  end

  defp valid_selection?(%{"label" => label, "value" => value} = selection)
       when map_size(selection) == 2 and is_binary(label) do
    String.trim(label) != "" and String.length(label) <= @max_label_length and
      valid_selection_value?(value)
  end

  defp valid_selection?(_selection), do: false

  defp valid_selection_value?(value) when is_binary(value),
    do: String.length(value) <= @max_string_value_length

  defp valid_selection_value?(value) when is_number(value), do: true
  defp valid_selection_value?(value) when is_boolean(value), do: true
  defp valid_selection_value?(_value), do: false

  defp format_prefill(%{"prompt" => prompt, "selections" => selections})
       when selections != [] do
    items =
      Enum.map_join(selections, "\n", fn %{"label" => label, "value" => value} ->
        "- #{Handbean.JSON.encode!(label)}: #{Handbean.JSON.encode!(value)}"
      end)

    prompt <> "\n\nSelections:\n" <> items
  end

  defp format_prefill(%{"prompt" => prompt, "selections" => []}), do: prompt
  defp format_prefill(%{"prompt" => prompt}), do: prompt
end
