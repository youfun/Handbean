defmodule HandbeanProbe.ConversationBean do
  @moduledoc """
  Pixel bean for a native history row, drawn with `Mob.Canvas` so Android and
  iOS share one picture.

  Idle is the leaf stem. Running walks, looks around, then walks again on the
  same 7.6 second cycle as the web sidebar. Waiting holds the standing pose.

  The node keeps the web 24×26 viewBox, drawn 1:1. Android does not
  scale a smaller box, so shrinking it to the CSS 20×22 slot would clip
  the walk. Idle is only the stem, and that stem sits at the same x as
  the web sprite. Do not shift it left to meet the folder stroke: the
  web slot centers both icons and leaves the stem inset.
  """

  import Bitwise

  alias Mob.Canvas

  # Web viewBox, also the on-screen canvas. Do not shrink this: the
  # Android renderer treats draw coordinates as dp inside `width`/`height`.
  @width 24
  @height 26
  @frame_ms 125
  @cycle_ms 7600
  @colors HandbeanProbe.NativeUI.bean_colors()
  @outline_mix HandbeanProbe.NativeUI.color(:bean_outline)
  @highlight_mix HandbeanProbe.NativeUI.color(:bean_highlight)
  @eyes HandbeanProbe.NativeUI.color(:bean_eyes)
  @cheek HandbeanProbe.NativeUI.color(:bean_cheek)
  @shadow HandbeanProbe.NativeUI.color(:bean_shadow)

  @leaf_outline "M11 5h1v3h-1zM11 3h1v3h-1zM12 2h4v1h1v1h-1v1h-4V4h-1V3h1z"
  @body_outline "M9 8h6v1h2v1h1v1h1v10h-1v1h-1v1H7v-1H6v-1H5V11h1v-1h1V9h2z"
  @body_fill "M9 9h6v1h2v1h1v10h-1v1H7v-1H6V11h1v-1h2z"
  @body_highlight "M9 9h6v1h-1v1h-2v1H8v1H7v-2h1v-1h1z"
  @body_shade "M17 17h1v4h-1v1H7v-1h8v-1h1v-1h1z"

  def frame_ms, do: @frame_ms

  @doc "Canvas node for `conversation_id` in `:idle`, `:running`, or `:waiting`."
  def canvas(conversation_id, activity, opts \\ []) when is_binary(conversation_id) do
    frame = Keyword.get(opts, :frame, 0)

    HandbeanProbe.NativeUI.node(:canvas,
      id: "conversation-bean-#{conversation_id}",
      width: @width,
      height: @height,
      padding_right: 4,
      draw: draw(conversation_id, activity, frame)
    )
  end

  @doc "Palette color shared with the web sidebar hash."
  def color(conversation_id) when is_binary(conversation_id) do
    Enum.at(@colors, rem(hash(conversation_id), length(@colors)))
  end

  defp draw(id, :idle, _frame) do
    palette = palette(color(id))

    rects(shift(pixels(@leaf_outline), 0, 7), palette.outline) ++
      rects(shift(pixels("M12 3h4v1h-4z"), 0, 7), palette.fill) ++
      rects(shift(pixels("M13 2h2v1h-2z"), 0, 7), palette.highlight)
  end

  defp draw(id, activity, frame) when activity in [:running, :waiting] do
    palette = palette(color(id))
    pose = if(activity == :running, do: pose(frame), else: standing())

    rects(pixels("M6 24h12v1H6z"), palette.shadow, 0.18) ++
      rects(shift(pixels("M8 21h2v3H7v-1h1z"), 0, pose.hop + pose.left_y), palette.outline) ++
      rects(shift(pixels("M15 21h2v2h1v1h-3z"), 0, pose.hop + pose.right_y), palette.outline) ++
      rects(shift(pixels("M4 16h1v4H4z"), pose.upper_x, pose.hop + pose.left_y), palette.outline) ++
      rects(shift(pixels("M3 19h2v2H3z"), pose.upper_x, pose.hop + pose.left_y), palette.fill) ++
      rects(
        shift(pixels("M19 16h1v4h-1z"), pose.upper_x, pose.hop + pose.right_y),
        palette.outline
      ) ++
      rects(shift(pixels("M19 19h2v2h-2z"), pose.upper_x, pose.hop + pose.right_y), palette.fill) ++
      rects(shift(pixels(@leaf_outline), pose.upper_x + pose.sway, pose.hop), palette.outline) ++
      rects(shift(pixels("M12 3h4v1h-4z"), pose.upper_x + pose.sway, pose.hop), palette.fill) ++
      rects(shift(pixels("M13 2h2v1h-2z"), pose.upper_x + pose.sway, pose.hop), palette.highlight) ++
      rects(shift(pixels(@body_outline), pose.upper_x, pose.hop), palette.outline) ++
      rects(shift(pixels(@body_fill), pose.upper_x, pose.hop), palette.fill) ++
      rects(shift(pixels(@body_highlight), pose.upper_x, pose.hop), palette.highlight) ++
      rects(shift(pixels(@body_shade), pose.upper_x, pose.hop), palette.shade) ++
      rects(
        shift(pixels("M8 14h2v2H8zM14 14h2v2h-2z"), pose.upper_x + pose.eyes_x, pose.hop),
        palette.eyes
      ) ++
      rects(shift(pixels("M7 17h1v1H7zM16 17h1v1h-1z"), pose.upper_x, pose.hop), palette.cheek)
  end

  defp draw(_id, _activity, _frame), do: []

  defp standing do
    %{hop: 0, left_y: 0, right_y: 0, upper_x: 0, sway: 0, eyes_x: 0}
  end

  defp pose(frame) when is_integer(frame) and frame >= 0 do
    time = rem(frame * @frame_ms, @cycle_ms) / 1000

    cond do
      time < 2 -> walk(time)
      time < 5.6 -> look(time - 2)
      true -> walk(time - 5.6)
    end
  end

  defp walk(local) do
    step = rem(floor(local * 8), 8)

    %{
      hop: if(rem(step, 4) >= 2, do: -1, else: 0),
      left_y: if(step < 4, do: -1, else: 0),
      right_y: if(step < 4, do: 0, else: -1),
      sway: if(rem(step, 4) >= 2, do: 1, else: 0),
      upper_x: 0,
      eyes_x: 0
    }
  end

  defp look(local) do
    p = local / 3.6

    %{
      hop: 0,
      left_y: 0,
      right_y: 0,
      upper_x:
        if(p >= 0.20 and p < 0.44, do: -1, else: if(p >= 0.64 and p < 0.88, do: 1, else: 0)),
      sway: if(p >= 0.24 and p < 0.44, do: -1, else: if(p >= 0.68 and p < 0.88, do: 1, else: 0)),
      eyes_x:
        cond do
          p < 0.12 -> 0
          p < 0.20 -> -1
          p < 0.44 -> -2
          p < 0.56 -> 0
          p < 0.64 -> 1
          p < 0.88 -> 2
          true -> 0
        end
    }
  end

  defp palette(base) do
    %{
      fill: base,
      outline: mix(base, @outline_mix, 0.45),
      highlight: mix(base, @highlight_mix, 0.65),
      shade: mix(base, @outline_mix, 0.75),
      eyes: @eyes,
      cheek: @cheek,
      shadow: @shadow
    }
  end

  defp mix(left, right, weight) do
    {r1, g1, b1} = parse(left)
    {r2, g2, b2} = parse(right)

    format(
      round(r1 * weight + r2 * (1 - weight)),
      round(g1 * weight + g2 * (1 - weight)),
      round(b1 * weight + b2 * (1 - weight))
    )
  end

  defp parse("#" <> hex) do
    {rgb, ""} = Integer.parse(hex, 16)
    {Bitwise.bsr(rgb, 16), Bitwise.band(Bitwise.bsr(rgb, 8), 0xFF), Bitwise.band(rgb, 0xFF)}
  end

  defp format(r, g, b) do
    "#" <>
      Enum.map_join([r, g, b], fn channel ->
        channel |> Integer.to_string(16) |> String.pad_leading(2, "0")
      end)
  end

  defp hash(id) do
    id
    |> String.to_charlist()
    |> Enum.reduce(2_166_136_261, fn codepoint, acc ->
      band(bxor(acc, codepoint) * 16_777_619, 0xFFFFFFFF)
    end)
    |> mix_bits()
  end

  defp mix_bits(hash) do
    hash = band(bxor(hash, bsr(hash, 16)) * 0x85EBCA6B, 0xFFFFFFFF)
    hash = band(bxor(hash, bsr(hash, 13)) * 0xC2B2AE35, 0xFFFFFFFF)
    band(bxor(hash, bsr(hash, 16)), 0xFFFFFFFF)
  end

  defp pixels(path) do
    path
    |> tokenize()
    |> subpaths()
    |> Enum.reduce(MapSet.new(), fn polygon, filled ->
      MapSet.union(filled, fill(polygon))
    end)
  end

  defp tokenize(path) do
    Regex.scan(~r/[MHVZmhvz]|-?\d+/, path)
    |> Enum.map(&hd/1)
  end

  defp subpaths(tokens), do: subpaths(tokens, [], nil, [])

  defp subpaths(["M", x, y | rest], polygons, _pos, current) do
    pos = {int(x), int(y)}
    subpaths(rest, flush(polygons, current), pos, [pos])
  end

  defp subpaths(["h", dx | rest], polygons, {x, y}, current) do
    pos = {x + int(dx), y}
    subpaths(rest, polygons, pos, current ++ [pos])
  end

  defp subpaths(["v", dy | rest], polygons, {x, y}, current) do
    pos = {x, y + int(dy)}
    subpaths(rest, polygons, pos, current ++ [pos])
  end

  defp subpaths(["H", x | rest], polygons, {_x, y}, current) do
    pos = {int(x), y}
    subpaths(rest, polygons, pos, current ++ [pos])
  end

  defp subpaths(["V", y | rest], polygons, {x, _y}, current) do
    pos = {x, int(y)}
    subpaths(rest, polygons, pos, current ++ [pos])
  end

  defp subpaths(["z" | rest], polygons, _pos, current) do
    subpaths(rest, flush(polygons, current), nil, [])
  end

  defp subpaths([], polygons, _pos, current), do: flush(polygons, current)

  defp flush(polygons, []), do: polygons
  defp flush(polygons, points), do: polygons ++ [points]

  defp int(value), do: String.to_integer(value)

  defp fill(polygon) do
    {xs, ys} = Enum.unzip(polygon)
    min_x = Enum.min(xs)
    max_x = Enum.max(xs) - 1
    min_y = Enum.min(ys)
    max_y = Enum.max(ys) - 1

    for y <- min_y..max_y,
        x <- min_x..max_x,
        inside?({x + 0.5, y + 0.5}, polygon),
        into: MapSet.new(),
        do: {x, y}
  end

  defp inside?({px, py}, polygon) do
    polygon
    |> Stream.cycle()
    |> Stream.take(length(polygon) + 1)
    |> Stream.chunk_every(2, 1, :discard)
    |> Enum.reduce(false, fn [{x1, y1}, {x2, y2}], crossed ->
      if y1 > py != y2 > py do
        x_at = (x2 - x1) * (py - y1) / (y2 - y1) + x1
        if px < x_at, do: not crossed, else: crossed
      else
        crossed
      end
    end)
  end

  defp shift(pixels, dx, dy) do
    MapSet.new(pixels, fn {x, y} -> {x + dx, y + dy} end)
  end

  defp rects(pixels, color, opacity \\ nil) do
    pixels
    |> Enum.group_by(&elem(&1, 1))
    |> Enum.sort()
    |> Enum.flat_map(fn {y, cells} ->
      cells
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()
      |> runs()
      |> Enum.map(fn {x, width} ->
        opts = [color: color, fill: true]
        opts = if opacity, do: Keyword.put(opts, :opacity, opacity), else: opts
        Canvas.rect(x, y, width, 1, opts)
      end)
    end)
  end

  defp runs([]), do: []

  defp runs([first | rest]) do
    {spans, start, prev} =
      Enum.reduce(rest, {[], first, first}, fn x, {spans, start, prev} ->
        if x == prev + 1, do: {spans, start, x}, else: {[{start, prev - start + 1} | spans], x, x}
      end)

    Enum.reverse([{start, prev - start + 1} | spans])
  end
end
