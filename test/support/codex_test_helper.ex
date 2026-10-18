defmodule Handbean.CodexTestHelper do
  @moduledoc false

  def token(account \\ "account-a") do
    claims = %{"https://api.openai.com/auth" => %{"chatgpt_account_id" => account}}
    "header." <> Base.url_encode64(Jason.encode!(claims), padding: false) <> ".signature"
  end

  def credential(account \\ "account-a") do
    %{
      type: "oauth",
      access: token(account),
      refresh: "test-refresh",
      expires: System.system_time(:millisecond) + 3_600_000
    }
  end

  defmodule ReqMock do
    @moduledoc false

    def post(url, opts), do: Req.post(url, Keyword.put(opts, :plug, {Req.Test, __MODULE__}))
    def get(url, opts), do: Req.get(url, Keyword.put(opts, :plug, {Req.Test, __MODULE__}))
  end
end
