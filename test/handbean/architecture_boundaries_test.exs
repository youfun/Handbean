defmodule Handbean.ArchitectureBoundariesTest do
  use ExUnit.Case, async: true

  test "core sources do not depend on HandbeanWeb" do
    violations =
      "lib/handbean/**/*.ex"
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        path
        |> File.stream!()
        |> Stream.with_index(1)
        |> Enum.flat_map(fn {line, line_number} ->
          if String.contains?(line, "HandbeanWeb") do
            ["#{path}:#{line_number}: #{String.trim(line)}"]
          else
            []
          end
        end)
      end)

    assert violations == [],
           "core-to-Web dependencies found:\n#{Enum.join(violations, "\n")}"
  end
end
