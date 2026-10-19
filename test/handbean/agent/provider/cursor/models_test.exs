defmodule Handbean.Agent.Provider.Cursor.ModelsTest do
  use ExUnit.Case, async: false

  alias Handbean.Agent.Auth.Storage
  alias Handbean.Agent.Provider.Cursor.{Models, Proto}

  defmodule FakeTransport do
    def connect(_opts), do: {:ok, %{}}

    def get_usable_models(transport, token, _opts) do
      send(Process.get(:models_test_pid), {:models_token, token})

      model =
        Proto.finish(
          Proto.encode_string(1, "composer-2.5") ++ Proto.encode_string(4, "Composer 2.5")
        )

      {:ok, transport, Proto.finish(Proto.encode_message(1, model))}
    end

    def available_models(transport, _token, _opts), do: {:ok, transport, <<>>}

    def close(t), do: t
  end

  defmodule EmptyTransport do
    def connect(_opts), do: {:ok, %{}}
    def get_usable_models(transport, _token, _opts), do: {:ok, transport, <<>>}
    def available_models(transport, _token, _opts), do: {:ok, transport, <<>>}
    def close(t), do: t
  end

  defmodule PricedTransport do
    alias Handbean.Agent.Provider.Cursor.Proto

    def connect(_opts), do: {:ok, %{}}

    def get_usable_models(transport, _token, _opts) do
      model =
        Proto.finish(
          Proto.encode_string(1, "gpt-5.3-codex-low-fast") ++
            Proto.encode_string(4, "Codex 5.3 Low Fast")
        )

      {:ok, transport, Proto.finish(Proto.encode_message(1, model))}
    end

    def available_models(transport, _token, _opts), do: {:ok, transport, <<>>}

    def close(t), do: t
  end

  defmodule ContextTransport do
    alias Handbean.Agent.Provider.Cursor.Proto

    def connect(_opts), do: {:ok, %{}}

    def get_usable_models(transport, _token, _opts) do
      models = [
        {"claude-opus-5-high", "Claude Opus 5 1M High"},
        {"claude-sonnet-5-high", "Claude Sonnet 5 1M"},
        {"gpt-5.5-medium", "GPT-5.5 1M"},
        {"grok-4.7-medium", "Grok 4.7 Medium"}
      ]

      body =
        models
        |> Enum.map(fn {id, name} ->
          model = Proto.finish(Proto.encode_string(1, id) ++ Proto.encode_string(4, name))
          Proto.encode_message(1, model)
        end)
        |> Proto.finish()

      {:ok, transport, body}
    end

    def available_models(transport, _token, _opts), do: {:ok, transport, <<>>}

    def close(t), do: t
  end

  defmodule FastVariantTransport do
    alias Handbean.Agent.Provider.Cursor.Proto

    def connect(_opts), do: {:ok, %{}}
    def get_usable_models(transport, _token, _opts), do: {:ok, transport, <<>>}

    def available_models(transport, _token, _opts) do
      plain = variant("false", "")
      fast = variant("true", "")
      already_named = variant("true", "Composer 2.5 Fast")

      composer =
        Proto.finish(
          Proto.encode_string(1, "composer-2.5") ++
            Proto.encode_string(17, "Composer 2.5") ++
            Proto.encode_message(30, plain) ++
            Proto.encode_message(30, fast)
        )

      named =
        Proto.finish(
          Proto.encode_string(1, "composer-2.5-named") ++
            Proto.encode_string(17, "Composer 2.5") ++
            Proto.encode_message(30, already_named)
        )

      {:ok, transport,
       Proto.finish(Proto.encode_message(2, composer) ++ Proto.encode_message(2, named))}
    end

    def close(t), do: t

    defp variant(fast, outside_picker_name) do
      Proto.finish(
        Proto.encode_message(1, parameter("fast", fast)) ++
          Proto.encode_string(8, outside_picker_name)
      )
    end

    defp parameter(id, value) do
      Proto.finish(Proto.encode_string(1, id) ++ Proto.encode_string(2, value))
    end
  end

  defmodule ParameterizedTransport do
    alias Handbean.Agent.Provider.Cursor.Proto

    def connect(_opts), do: {:ok, %{}}
    def get_usable_models(transport, _token, _opts), do: {:ok, transport, <<>>}

    def available_models(transport, _token, _opts) do
      default = variant(false, "272k", "high")
      one_million = variant(true, "1m", "high")

      model =
        Proto.finish(
          Proto.encode_string(1, "gpt-5.6-luna") ++
            Proto.encode_bool(10, true) ++
            Proto.encode_bool(14, true) ++
            Proto.encode_uint32(15, 272_000) ++
            Proto.encode_uint32(16, 1_000_000) ++
            Proto.encode_string(17, "GPT-5.6 Luna") ++
            Proto.encode_message(30, default) ++
            Proto.encode_message(30, one_million)
        )

      {:ok, transport, Proto.finish(Proto.encode_message(2, model))}
    end

    def close(t), do: t

    defp variant(max_mode, context, reasoning) do
      Proto.finish(
        Proto.encode_message(1, parameter("context", context)) ++
          Proto.encode_message(1, parameter("reasoning", reasoning)) ++
          Proto.encode_message(1, parameter("fast", "false")) ++
          Proto.encode_bool(3, max_mode)
      )
    end

    defp parameter(id, value) do
      Proto.finish(Proto.encode_string(1, id) ++ Proto.encode_string(2, value))
    end
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "cursor_models_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    auth_path = Path.join(tmp, "auth.json")
    Process.put(:models_test_pid, self())

    :ok =
      Storage.put(
        "cursor",
        %{
          "type" => "oauth",
          "access" => "tok",
          "refresh" => "ref",
          "expires" => System.system_time(:millisecond) + 60_000
        },
        auth_path: auth_path
      )

    on_exit(fn -> File.rm_rf(tmp) end)
    {:ok, auth_path: auth_path}
  end

  test "discover maps account models without inventing cost 0", %{auth_path: auth_path} do
    assert {:ok, models} =
             Models.discover(auth_path: auth_path, transport_mod: FakeTransport)

    assert [%{"id" => "composer-2.5", "name" => "Composer 2.5"}] = models
    refute Map.has_key?(hd(models), "cost")
    assert_received {:models_token, "tok"}
    assert Models.preferred_id(models) == "composer-2.5"
  end

  test "discover returns models without waiting on a price catalog", %{auth_path: auth_path} do
    assert {:ok, models} =
             Models.discover(auth_path: auth_path, transport_mod: PricedTransport)

    assert [%{"id" => "gpt-5.3-codex-low-fast"}] = models
    refute Map.has_key?(hd(models), "cost")
  end

  test "discover leaves limits unset when Cursor does not report them", %{
    auth_path: auth_path
  } do
    assert {:ok, models} =
             Models.discover(auth_path: auth_path, transport_mod: ContextTransport)

    assert Enum.map(models, &{&1["id"], &1["name"], &1["contextWindow"]}) == [
             {"claude-opus-5-high", "Claude Opus 5 1M High", nil},
             {"claude-sonnet-5-high", "Claude Sonnet 5 1M", nil},
             {"gpt-5.5-medium", "GPT-5.5 1M", nil},
             {"grok-4.7-medium", "Grok 4.7 Medium", nil}
           ]

    assert Enum.all?(models, &is_map(&1["upstream"]))
    refute Enum.any?(models, &Map.has_key?(&1, "maxTokens"))
  end

  test "empty catalog is an explicit error", %{auth_path: auth_path} do
    assert {:error, message} =
             Models.discover(auth_path: auth_path, transport_mod: EmptyTransport)

    assert message =~ "no usable models"
  end

  test "discover keeps fast variants distinct when Cursor reuses the display name", %{
    auth_path: auth_path
  } do
    assert {:ok, models} =
             Models.discover(auth_path: auth_path, transport_mod: FastVariantTransport)

    assert Enum.map(models, &{&1["id"], &1["name"]}) == [
             {"composer-2.5", "Composer 2.5"},
             {"composer-2.5-fast", "Composer 2.5 Fast"},
             {"composer-2.5-named-fast", "Composer 2.5 Fast"}
           ]
  end

  test "discover persists AvailableModels routing for default and 1M variants", %{
    auth_path: auth_path
  } do
    assert {:ok, models} =
             Models.discover(auth_path: auth_path, transport_mod: ParameterizedTransport)

    default = Enum.find(models, &(&1["id"] == "gpt-5.6-luna-high"))
    one_million = Enum.find(models, &(&1["id"] == "gpt-5.6-luna-1m-high"))

    assert default["contextWindow"] == 272_000
    assert default["cursorRequestedModel"]["maxMode"] == false

    assert one_million["contextWindow"] == 1_000_000

    assert one_million["cursorRequestedModel"] == %{
             "modelId" => "gpt-5.6-luna",
             "maxMode" => true,
             "parameters" => [
               %{"id" => "context", "value" => "1m"},
               %{"id" => "reasoning", "value" => "high"},
               %{"id" => "fast", "value" => "false"}
             ]
           }
  end
end
