defmodule Handbean.Agent.Provider.OpenAITestSupport do
  # --- Helpers ---

  def response_payload(output, usage \\ %{}) do
    base = %{
      "id" => "resp_test",
      "object" => "response",
      "status" => "completed",
      "output" => output
    }

    if usage == %{}, do: base, else: Map.put(base, "usage", usage)
  end

  def assistant_text_item(text) do
    %{
      "id" => "msg_test",
      "type" => "message",
      "role" => "assistant",
      "content" => [%{"type" => "output_text", "text" => text}]
    }
  end

  def function_call_item(call_id, name, arguments) do
    %{
      "id" => "fc_test",
      "type" => "function_call",
      "call_id" => call_id,
      "name" => name,
      "arguments" => arguments
    }
  end

  def sse_response_output_text_delta(text) do
    "event: response.output_text.delta\ndata: #{Jason.encode!(%{"type" => "response.output_text.delta", "delta" => text})}\n\n"
  end

  def sse_response_completed(output_items, usage) do
    "event: response.completed\ndata: #{Jason.encode!(%{"type" => "response.completed", "response" => response_payload(output_items, usage)})}\n\n"
  end

  def config_with_response(owner, response) do
    %{
      api_key: "sk-test-key",
      provider_key: "openai",
      api: :openai_responses,
      model: "gpt-5.2",
      max_tokens: 4096,
      req_options: [plug: {Req.Test, owner}, retry: false]
    }
    |> tap(fn _ ->
      Req.Test.stub(owner, fn conn ->
        Plug.Conn.send_resp(conn, response.status, response.body)
      end)
    end)
  end

  def config_that_captures_request(owner) do
    test_pid = self()

    %{
      api_key: "sk-test-key",
      provider_key: "openai",
      api: :openai_responses,
      model: "gpt-5.2",
      max_tokens: 4096,
      req_options: [plug: {Req.Test, owner}, retry: false]
    }
    |> tap(fn _ ->
      Req.Test.stub(owner, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, body})

        Plug.Conn.send_resp(
          conn,
          200,
          Jason.encode!(response_payload([assistant_text_item("ok")]))
        )
      end)
    end)
  end

  def config_with_sse_stream(owner, chunks) do
    %{
      api_key: "sk-test-key",
      provider_key: "openai",
      api: :openai_responses,
      model: "gpt-5.2",
      max_tokens: 4096,
      req_options: [plug: {Req.Test, owner}, retry: false]
    }
    |> tap(fn _ -> Req.Test.stub(owner, sse_chunks_plug(chunks)) end)
  end

  def config_with_sse_error_stream(owner, status, body) do
    %{
      api_key: "sk-test-key",
      provider_key: "openai",
      api: :openai_responses,
      model: "gpt-5.2",
      max_tokens: 4096,
      req_options: [plug: {Req.Test, owner}, retry: false]
    }
    |> tap(fn _ -> Req.Test.stub(owner, sse_error_plug(status, body)) end)
  end

  def sse_chunks_plug(chunks) do
    fn conn ->
      conn = Plug.Conn.send_chunked(conn, 200)

      Enum.reduce(chunks, conn, fn chunk, conn ->
        {:ok, conn} = Plug.Conn.chunk(conn, chunk)
        conn
      end)
    end
  end

  def sse_error_plug(status, body) do
    fn conn ->
      conn = Plug.Conn.send_chunked(conn, status)
      {:ok, conn} = Plug.Conn.chunk(conn, body)
      conn
    end
  end

  def collect_chunks(chunks) do
    receive do
      {:chunk, chunk} -> collect_chunks([chunk | chunks])
    after
      0 -> Enum.reverse(chunks)
    end
  end
end
