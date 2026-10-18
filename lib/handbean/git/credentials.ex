defmodule Handbean.Git.Credentials do
  @moduledoc """
  Resolves opaque Git credential names at execution time, outside model input.

  Hosts configure `:handbean, :git_credentials` as a map of names to keyword
  lists containing `:endpoint`, `:password` and optional `:username`.
  Fresh authentication challenges must match the HTTPS endpoint. The CLI
  backend refuses a credential unless every actual destination is HTTPS
  on that host, including `url.*.insteadOf` / `pushInsteadOf` rewrites and
  every push URL. HTTP, including an HTTPS-to-HTTP downgrade, is rejected.
  Askpass replies only to Username/Password prompts for that host.
  The ExGit/libgit2 backend blocks cross-host redirects and HTTPS
  downgrades, but may reuse credentials on other HTTPS ports or paths of
  the same hostname. Configuration therefore trusts every HTTPS service on
  that hostname, not just one port or repository. Never load this map from
  agent-controlled workspace settings.
  """

  @spec resolve(String.t() | nil) :: {:ok, keyword()} | {:error, String.t()}
  def resolve(nil) do
    case Handbean.Git.Settings.default_account_id() do
      nil -> {:ok, []}
      name -> resolve(name)
    end
  end

  def resolve(name) when is_binary(name) do
    credentials = Application.get_env(:handbean, :git_credentials, %{})

    case Map.fetch(credentials, name) do
      {:ok, credential} ->
        validate(credential)

      :error ->
        case Handbean.Git.Settings.lookup(name) do
          {:ok, credential} -> validate(credential)
          :error -> {:error, "Git credential is not configured"}
        end
    end
  end

  def resolve(_), do: {:error, "credential must be a configured name"}

  defp validate(credential) when is_list(credential) do
    endpoint = credential[:endpoint]
    password = credential[:password]

    with true <- is_binary(endpoint) and is_binary(password) and password != "",
         %URI{scheme: "https", host: host, userinfo: nil, path: nil, query: nil, fragment: nil}
         when is_binary(host) and host != "" <- URI.parse(endpoint) do
      {:ok, [credential_endpoint: endpoint] ++ Keyword.take(credential, [:username, :password])}
    else
      _ -> {:error, "Git credential requires an HTTPS endpoint without a path and a password"}
    end
  end

  defp validate(_), do: {:error, "Invalid host Git credential configuration"}
end
