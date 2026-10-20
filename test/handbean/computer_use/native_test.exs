defmodule Handbean.ComputerUse.NativeTest do
  use ExUnit.Case, async: false

  alias Handbean.ComputerUse.Native

  setup do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :line, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)
    token = Ecto.UUID.generate()

    old =
      Map.new([:computer_use_port, :computer_use_token], fn key ->
        {key, Application.fetch_env(:handbean, key)}
      end)

    Application.put_env(:handbean, :computer_use_port, port)
    Application.put_env(:handbean, :computer_use_token, token)

    on_exit(fn ->
      :gen_tcp.close(listener)

      Enum.each(old, fn
        {key, {:ok, value}} -> Application.put_env(:handbean, key, value)
        {key, :error} -> Application.delete_env(:handbean, key)
      end)
    end)

    %{listener: listener, token: token}
  end

  test "receives an entire maximum-sized screenshot response across TCP chunks", context do
    image = Base.encode64(:binary.copy(<<137, 80, 78, 71>>, 1_250_000))
    reply = %{"image" => image, "mime_type" => "image/png", "observation_id" => "fresh"}

    assert {:ok, ^reply} =
             exchange(context, fn id ->
               encoded = Handbean.JSON.encode!(%{id: id, result: reply}) <> "\n"
               <<first::binary-size(4096), second::binary-size(16384), rest::binary>> = encoded
               [first, second, rest]
             end)
  end

  test "rejects a complete JSON object without the required line terminator", context do
    assert {:error, :native_outcome_unknown} =
             exchange(context, fn id ->
               [Handbean.JSON.encode!(%{id: id, result: %{text: "incomplete frame"}})]
             end)
  end

  test "rejects an oversized line even if its prefix is valid JSON", context do
    assert {:error, :native_outcome_unknown} =
             exchange(context, fn id ->
               [
                 Handbean.JSON.encode!(%{id: id, result: %{text: "oversized"}}),
                 :binary.copy(" ", 7_100_001),
                 "\n"
               ]
             end)
  end

  test "rejects a correlated response whose result is not an object", context do
    assert {:error, :native_outcome_unknown} =
             exchange(context, fn id ->
               [Handbean.JSON.encode!(%{id: id, result: "invalid result"}) <> "\n"]
             end)
  end

  test "rejects a foreign response and does not retry the request", context do
    assert {:error, :native_outcome_unknown} =
             exchange(context, fn _id ->
               [
                 Handbean.JSON.encode!(%{id: Ecto.UUID.generate(), result: %{text: "foreign"}}) <>
                   "\n"
               ]
             end)
  end

  defp exchange(%{listener: listener, token: token}, response) do
    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 5_000)

        try do
          {:ok, line} = :gen_tcp.recv(socket, 0, 5_000)
          request = Handbean.JSON.decode!(line)
          assert request["token"] == token
          assert request["input"] == %{"action" => "observe"}

          Enum.reduce_while(response.(request["id"]), :ok, fn chunk, _ ->
            case :gen_tcp.send(socket, chunk) do
              :ok -> {:cont, :ok}
              {:error, :closed} -> {:halt, :ok}
              {:error, :econnreset} -> {:halt, :ok}
            end
          end)

          :gen_tcp.shutdown(socket, :write)
          assert {:error, :closed} = :gen_tcp.recv(socket, 0, 5_000)
        after
          :gen_tcp.close(socket)
        end
      end)

    result =
      Native.request(%{"action" => "observe"}, %{
        conversation_id: "transport-test",
        run_id: "run",
        timeout_ms: 5_000
      })

    Task.await(server, 10_000)
    result
  end
end
