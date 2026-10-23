defmodule Handbean.Documents.XML do
  @moduledoc false
  @behaviour Saxy.Handler

  def parse(bytes) do
    if String.valid?(bytes) and :binary.match(bytes, ["<!DOCTYPE", "<!ENTITY"]) == :nomatch do
      state = %{stack: [], root: nil, nodes: 0, depth: 0, text_bytes: 0}

      case Saxy.parse_string(bytes, __MODULE__, state,
             expand_entity: {__MODULE__, :reject_entity, []}
           ) do
        {:ok, %{root: root, stack: []}} when not is_nil(root) -> {:ok, root}
        _ -> {:error, "Malformed or oversized Office XML"}
      end
    else
      {:error, "Office XML must be UTF-8 without DTD or entity declarations"}
    end
  catch
    :unsupported_xml_entity -> {:error, "Office XML custom entities are unsupported"}
  end

  def reject_entity(_name), do: throw(:unsupported_xml_entity)

  @impl true
  def handle_event(:start_element, {name, attrs}, state) do
    if state.depth >= 64 or state.nodes >= 100_000 or length(attrs) > 64 do
      {:stop, :xml_limit}
    else
      node = {local(name), attrs, []}

      {:ok,
       %{state | stack: [node | state.stack], depth: state.depth + 1, nodes: state.nodes + 1}}
    end
  end

  def handle_event(:end_element, _name, %{stack: [{name, attrs, children} | rest]} = state) do
    node = {name, attrs, Enum.reverse(children)}
    state = %{state | depth: state.depth - 1}

    case rest do
      [] ->
        {:ok, %{state | root: node, stack: []}}

      [{parent, attrs, children} | tail] ->
        {:ok, %{state | stack: [{parent, attrs, [node | children]} | tail]}}
    end
  end

  def handle_event(:characters, text, %{stack: [{name, attrs, children} | rest]} = state) do
    used = state.text_bytes + byte_size(text)

    if used > 8 * 1024 * 1024 or state.nodes >= 100_000 do
      {:stop, :xml_limit}
    else
      {:ok,
       %{
         state
         | text_bytes: used,
           nodes: state.nodes + 1,
           stack: [{name, attrs, [text | children]} | rest]
       }}
    end
  end

  def handle_event(_event, _data, state), do: {:ok, state}

  def relationship_id({_name, attrs, _children}),
    do:
      Enum.find_value(attrs, fn {name, value} -> if String.ends_with?(name, ":id"), do: value end)

  def local(name), do: name |> String.split(":") |> List.last()

  def attr({_name, attrs, _children}, key),
    do: Enum.find_value(attrs, fn {name, value} -> if local(name) == key, do: value end)

  def children({_name, _attrs, children}), do: Enum.filter(children, &is_tuple/1)
  def children(node, name), do: Enum.filter(children(node), &(elem(&1, 0) == name))
  def text(text) when is_binary(text), do: text
  def text({_name, _attrs, children}), do: Enum.map_join(children, &text/1)

  def descendants(node, name) do
    Enum.flat_map(children(node), fn child ->
      if elem(child, 0) == name, do: [child], else: descendants(child, name)
    end)
  end
end
