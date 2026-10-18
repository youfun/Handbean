defmodule Handbean.Tool.Deferred do
  @moduledoc """
  Deferred tools stay out of the provider request until a conversation loads them.

  `tool_search` ranks the deferred catalog and appends the hits to that
  conversation. The next provider request declares those tools, in load order,
  after the stable eager list.
  """

  alias Handbean.ConversationStore
  alias Handbean.MCP.Access
  alias Handbean.Tool.Registry

  @max_matches 5

  @doc "Deferred tools this run is allowed to load."
  @spec candidates(map(), [String.t()]) :: [map()]
  def candidates(context, authorized) when is_map(context) and is_list(authorized) do
    allowed = MapSet.new(authorized)

    Registry.deferred_catalog()
    |> Access.filter(context)
    |> Enum.filter(&MapSet.member?(allowed, &1.name))
  end

  @spec any?(map(), [String.t()]) :: boolean()
  def any?(context, authorized) when is_map(context) and is_list(authorized) do
    candidates(context, authorized) != []
  end

  @doc "Up to five deferred tools, best match first."
  @spec search(String.t() | nil, [map()]) :: [map()]
  def search(query, entries) when is_list(entries) do
    needle = query |> to_string() |> String.trim() |> String.downcase()

    if needle == "" do
      []
    else
      tokens = tokenize(needle)

      entries
      |> Enum.map(fn entry -> {score(needle, tokens, entry), entry} end)
      |> Enum.filter(fn {points, _entry} -> points > 0 end)
      |> Enum.sort_by(fn {points, entry} -> {-points, entry.name} end)
      |> Enum.take(@max_matches)
      |> Enum.map(fn {_points, entry} -> entry end)
    end
  end

  @spec loaded_names(String.t() | nil) :: [String.t()]
  def loaded_names(conversation_id) when is_binary(conversation_id) and conversation_id != "" do
    case ConversationStore.get_meta(conversation_id) do
      {:ok, %{"loaded_tools" => names}} when is_list(names) ->
        Enum.filter(names, &is_binary/1)

      _ ->
        []
    end
  end

  def loaded_names(_conversation_id), do: []

  @spec loaded?(String.t(), String.t() | nil) :: boolean()
  def loaded?(name, conversation_id) when is_binary(name) do
    name in loaded_names(conversation_id)
  end

  @doc """
  Append newly matched tools without reordering tools loaded earlier.

  Does not change the conversation's `updated_at`.
  """
  @spec remember(String.t(), [map()]) :: :ok | {:error, term()}
  def remember(conversation_id, hits)
      when is_binary(conversation_id) and conversation_id != "" and is_list(hits) do
    fresh =
      hits
      |> Enum.map(& &1.name)
      |> Enum.reject(&loaded?(&1, conversation_id))

    if fresh == [] do
      :ok
    else
      case ConversationStore.append_loaded_tools(conversation_id, fresh) do
        {:ok, _names} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def remember(_conversation_id, _hits), do: {:error, :no_conversation}

  @spec format_hits([map()], String.t()) :: String.t()
  def format_hits(hits, conversation_id) when is_list(hits) do
    loaded = MapSet.new(loaded_names(conversation_id))
    {fresh, already} = Enum.split_with(hits, &(not MapSet.member?(loaded, &1.name)))

    sections =
      [{"Loaded", fresh}, {"Already available", already}]
      |> Enum.flat_map(fn
        {_title, []} ->
          []

        {title, entries} ->
          lines = Enum.map(entries, &"- #{&1.name}: #{&1.description}")
          [title <> "\n" <> Enum.join(lines, "\n")]
      end)

    body = Enum.join(sections, "\n\n")

    if fresh == [] do
      body
    else
      body <> "\n\nCall a loaded tool by name on your next step."
    end
  end

  @doc "One line per deferred server for the system prompt."
  @spec prompt_section(keyword()) :: String.t()
  def prompt_section(opts) when is_list(opts) do
    if Keyword.get(opts, :chat_scope) == :free do
      ""
    else
      context = Keyword.get(opts, :context, %{})

      case server_lines(opts, context) do
        [] ->
          ""

        lines ->
          """

          ## Deferred tools

          These servers are available, but their tools are not declared yet. Call `tool_search` with the capability you need. Matching tools become callable on the next step.

          #{Enum.join(lines, "\n")}
          """
      end
    end
  end

  defp server_lines(opts, context) do
    allowed = Keyword.get(opts, :allowed_tools)
    session_id = Keyword.get(opts, :conversation_id) || Keyword.get(opts, :session_id)
    active = if is_binary(session_id), do: Registry.active_for_session(session_id)

    Registry.deferred_catalog()
    |> Access.filter(context)
    |> Enum.filter(fn entry ->
      (is_nil(allowed) or entry.name in allowed) and (is_nil(active) or entry.name in active)
    end)
    |> Enum.group_by(&(&1.server || "tools"))
    |> Enum.sort_by(fn {server, _entries} -> server end)
    |> Enum.map(fn {server, entries} ->
      summary =
        entries
        |> Enum.find_value(& &1.server_description)
        |> case do
          text when is_binary(text) and text != "" -> text
          _ -> entries |> List.first() |> Map.get(:description) |> to_string()
        end

      "- #{server}: #{truncate(summary)}"
    end)
  end

  defp truncate(text) do
    text = String.trim(text)

    if String.length(text) > 160 do
      String.slice(text, 0, 157) <> "..."
    else
      text
    end
  end

  defp score(needle, tokens, entry) do
    name = String.downcase(entry.name || "")

    haystack =
      String.downcase(Enum.join([entry.name, entry.description, property_text(entry)], " "))

    token_points =
      Enum.reduce(tokens, 0, fn token, acc ->
        cond do
          String.contains?(name, token) -> acc + 3
          String.contains?(haystack, token) -> acc + 1
          true -> acc
        end
      end)

    cond do
      String.contains?(name, needle) -> token_points + 10
      String.contains?(haystack, needle) -> token_points + 4
      true -> token_points
    end
  end

  defp property_text(entry) do
    props =
      case entry.input_schema do
        %{"properties" => properties} when is_map(properties) -> properties
        %{properties: properties} when is_map(properties) -> properties
        _ -> %{}
      end

    Enum.map_join(props, " ", fn {key, spec} ->
      description =
        if is_map(spec), do: spec["description"] || spec[:description] || "", else: ""

      "#{key} #{description}"
    end)
  end

  defp tokenize(needle) do
    needle
    |> String.split(~r/[^\p{L}\p{N}_]+/u, trim: true)
    |> Enum.uniq()
    |> Enum.filter(&(String.length(&1) >= 2))
  end
end
