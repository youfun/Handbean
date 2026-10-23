defmodule Handbean.DocumentFixtures do
  @moduledoc false
  @relationship "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"

  def read(name), do: File.read!(Path.join([File.cwd!(), "test/fixtures/documents", name]))

  def docx(body, extras \\ []) do
    zip(
      [
        {"[Content_Types].xml", "<Types/>"},
        {"_rels/.rels", relationships([{"main", "officeDocument", "word/document.xml"}])},
        {"word/document.xml",
         "<w:document xmlns:w=\"urn:test\"><w:body>#{body}</w:body></w:document>"}
      ] ++ extras
    )
  end

  def relationships(items) do
    nodes =
      Enum.map_join(items, fn {id, type, target} ->
        ~s(<Relationship Id="#{id}" Type="#{@relationship}#{type}" Target="#{target}"/>)
      end)

    "<Relationships>#{nodes}</Relationships>"
  end

  def zip(entries) do
    {:ok, {_, bytes}} =
      :zip.create(
        ~c"fixture.zip",
        Enum.map(entries, fn {name, data} -> {String.to_charlist(name), data} end),
        [:memory]
      )

    bytes
  end

  def rewrite_zip(bytes, fun) do
    {:ok, entries} = :zip.extract(bytes, [:memory])
    entries |> Enum.map(fn {name, data} -> fun.(List.to_string(name), data) end) |> zip()
  end

  # Adversarial size metadata is deliberately inconsistent with the actual
  # deflate output. Both local and central headers lie in the same way.
  def lying_zip(name, actual, declared_size, opts \\ []) do
    z = :zlib.open()
    :ok = :zlib.deflateInit(z, :default, :deflated, -15, 8, :default)
    compressed = z |> :zlib.deflate(actual, :finish) |> IO.iodata_to_binary()
    :ok = :zlib.deflateEnd(z)
    :zlib.close(z)

    compressed =
      if Keyword.get(opts, :truncate, false),
        do: binary_part(compressed, 0, byte_size(compressed) - 1),
        else: compressed

    length = byte_size(name)
    size = byte_size(compressed)
    crc = :erlang.crc32(actual)
    descriptor = Keyword.get(opts, :descriptor, false)
    flags = if descriptor, do: 8, else: 0

    {local_crc, local_size, local_declared} =
      if descriptor, do: {0, 0, 0}, else: {crc, size, declared_size}

    local =
      <<0x04034B50::little-32, 20::little-16, flags::little-16, 8::little-16, 0::little-32,
        local_crc::little-32, local_size::little-32, local_declared::little-32, length::little-16,
        0::little-16, name::binary, compressed::binary>>

    local =
      case descriptor do
        :signed ->
          local <>
            <<0x08074B50::little-32, crc::little-32, size::little-32, declared_size::little-32>>

        :unsigned ->
          local <> <<crc::little-32, size::little-32, declared_size::little-32>>

        false ->
          local
      end

    central =
      <<0x02014B50::little-32, 20::little-16, 20::little-16, flags::little-16, 8::little-16,
        0::little-32, crc::little-32, size::little-32, declared_size::little-32,
        length::little-16, 0::little-16, 0::little-16, 0::little-16, 0::little-16, 0::little-32,
        0::little-32, name::binary>>

    ending =
      <<0x06054B50::little-32, 0::little-16, 0::little-16, 1::little-16, 1::little-16,
        byte_size(central)::little-32, byte_size(local)::little-32, 0::little-16>>

    local <> central <> ending
  end

  def pdf(content, opts \\ []) do
    compressed? = Keyword.get(opts, :compressed, false)
    filter = if compressed?, do: "/Filter /FlateDecode", else: ""

    streams =
      Enum.map(Keyword.get(opts, :streams, [content]), fn content ->
        stream = if compressed?, do: :zlib.compress(content), else: content
        "<< /Length #{byte_size(stream)} #{filter} >>\nstream\n#{stream}\nendstream"
      end)

    refs = streams |> Enum.with_index(5) |> Enum.map_join(" ", fn {_, id} -> "#{id} 0 R" end)
    cmap = Keyword.get(opts, :cmap)
    font_cmap = if cmap, do: "/ToUnicode #{length(streams) + 5} 0 R", else: ""

    extra =
      if cmap, do: ["<< /Length #{byte_size(cmap)} >>\nstream\n#{cmap}\nendstream"], else: []

    objects =
      [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents [#{refs}] >>",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding #{font_cmap} >>"
      ] ++ streams ++ extra

    {parts, offsets, position} =
      Enum.reduce(Enum.with_index(objects, 1), {["%PDF-1.7\n"], [0], 9}, fn {body, number},
                                                                            {parts, offsets,
                                                                             offset} ->
        object = "#{number} 0 obj\n#{body}\nendobj\n"
        {[object | parts], [offset | offsets], offset + byte_size(object)}
      end)

    xref =
      offsets
      |> Enum.reverse()
      |> Enum.with_index()
      |> Enum.map_join(fn {offset, index} ->
        "#{String.pad_leading(Integer.to_string(offset), 10, "0")} #{if index == 0, do: "65535 f", else: "00000 n"} \n"
      end)

    IO.iodata_to_binary(Enum.reverse(parts)) <>
      "xref\n0 #{length(objects) + 1}\n#{xref}trailer\n<< /Size #{length(objects) + 1} /Root 1 0 R >>\nstartxref\n#{position}\n%%EOF\n"
  end
end
