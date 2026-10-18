defmodule Handbean.JsonSafeTest do
  use ExUnit.Case, async: true

  alias Handbean.JsonSafe
  alias Handbean.Memory.Engram

  test "converts tuples and structs into JSON-encodable values" do
    value = %{
      details: %{
        count: 1,
        range: {0, 0},
        results: [
          %Engram{
            id: 4,
            content: "User likes Cantonese food",
            kind: :preference,
            short_term: true,
            expires_at: ~U[2026-05-22 12:34:08Z],
            metadata: %{scope: "workspace"},
            source_synapses: [],
            target_synapses: []
          }
        ]
      }
    }

    safe = JsonSafe.normalize(value)

    assert safe["details"]["range"] == [0, 0]

    assert [%{"content" => "User likes Cantonese food", "kind" => "preference"}] =
             safe["details"]["results"]

    assert {:ok, _json} = Jason.encode(safe)
  end

  test "replaces invalid UTF-8 in runtime binaries" do
    safe = JsonSafe.normalize(%{output: <<"valid", 0xFF, "tail">>})

    assert safe["output"] == "valid�tail"
    assert {:ok, _json} = Handbean.JSON.encode(safe)
  end
end
