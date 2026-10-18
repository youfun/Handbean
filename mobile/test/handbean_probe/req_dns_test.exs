defmodule HandbeanProbe.ReqDNSTest do
  use ExUnit.Case, async: true

  test "attach prepends a request step that keeps the request" do
    request =
      Req.new(url: "https://example.invalid/path")
      |> HandbeanProbe.ReqDNS.attach()

    assert is_function(request.request_steps[:mob_dns], 1)
    assert %Req.Request{} = request.request_steps[:mob_dns].(request)
  end
end
