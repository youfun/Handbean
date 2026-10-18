defmodule Handbean.ComputerUse.Native do
  @moduledoc "Authenticated, correlated, bounded loopback transport to the owning macOS app. No input retry."
  @max_reply 7_100_000

  def request(input, context) do
    port = Application.get_env(:handbean, :computer_use_port)
    token = Application.get_env(:handbean, :computer_use_token)
    timeout = if input["action"] == "stop", do: 1_000, else: remaining(context)
    id = Ecto.UUID.generate()

    with true <- is_integer(port) and is_binary(token),
         {:ok, socket} <-
           :gen_tcp.connect(
             {127, 0, 0, 1},
             port,
             [:binary, active: false, packet: :line, packet_size: @max_reply],
             min(timeout, 1_000)
           ) do
      try do
        session = "#{context[:conversation_id]}:#{context[:run_id]}"

        request = %{
          id: id,
          token: token,
          session: session,
          deadline_ms: System.system_time(:millisecond) + timeout,
          input: input
        }

        with :ok <- :gen_tcp.send(socket, Handbean.JSON.encode!(request) <> "\n"),
             {:ok, line} <- :gen_tcp.recv(socket, 0, timeout),
             {:ok, %{"id" => ^id, "result" => reply}} <- Handbean.JSON.decode(line) do
          {:ok, reply}
        else
          _ -> {:error, :native_outcome_unknown}
        end
      after
        :gen_tcp.close(socket)
      end
    else
      _ -> {:error, :native_host_unavailable}
    end
  end

  defp remaining(context) do
    case context[:run_deadline] do
      deadline when is_integer(deadline) ->
        min(60_000, max(1, deadline - System.monotonic_time(:millisecond)))

      _ ->
        60_000
    end
  end
end
