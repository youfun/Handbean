defmodule Handbean.Tool.Builtin.Grep.Collector do
  @moduledoc false

  defstruct hits: [], kept: 0, shown: %{}, more: %{}, wanted: 0, cap: nil

  @type hit :: %{required(:path) => String.t(), required(:line) => pos_integer()}
  @opaque t :: %__MODULE__{
            hits: [hit()],
            kept: non_neg_integer(),
            shown: %{optional(String.t()) => non_neg_integer()},
            more: %{optional(String.t()) => pos_integer()},
            wanted: pos_integer(),
            cap: pos_integer() | nil
          }

  @spec new(pos_integer(), pos_integer() | nil) :: t()
  def new(wanted, cap), do: %__MODULE__{wanted: wanted, cap: cap}

  @spec full?(t()) :: boolean()
  def full?(%__MODULE__{kept: kept, wanted: wanted}), do: kept >= wanted

  @spec add(t(), hit()) :: t()
  def add(%__MODULE__{cap: cap} = collector, hit) do
    case Map.get(collector.shown, hit.path, 0) do
      shown when is_integer(cap) and shown >= cap ->
        %{collector | more: Map.update(collector.more, hit.path, 1, &(&1 + 1))}

      shown ->
        %{
          collector
          | hits: [hit | collector.hits],
            kept: collector.kept + 1,
            shown: Map.put(collector.shown, hit.path, shown + 1)
        }
    end
  end

  @spec ordered_hits(t()) :: [hit()]
  def ordered_hits(%__MODULE__{hits: hits}), do: Enum.reverse(hits)

  @spec capped_files([hit()], t()) :: %{optional(String.t()) => pos_integer()}
  def capped_files(page, %__MODULE__{cap: cap, more: more}) do
    page
    |> Enum.frequencies_by(& &1.path)
    |> Enum.flat_map(fn {path, count} ->
      if count == cap and Map.has_key?(more, path), do: [{path, Map.fetch!(more, path)}], else: []
    end)
    |> Map.new()
  end
end
