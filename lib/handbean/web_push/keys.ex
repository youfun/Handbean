defmodule Handbean.WebPush.Keys do
  @moduledoc "Stable application-server identity shared by browser push subscriptions."

  use Ecto.Schema

  import Ecto.Changeset

  alias Handbean.Repo
  alias Handbean.Storage.WriteTransaction
  alias Handbean.WebPush.Protocol

  @primary_key {:id, :string, autogenerate: false}
  schema "web_push_keys" do
    field :public_key, :string
    field :private_key, :string, redact: true
  end

  @doc "Create the VAPID identity once; concurrent callers reuse the winning database row."
  def ensure do
    case Repo.get(__MODULE__, "vapid", log: false) do
      nil -> create()
      keys -> {:ok, keys}
    end
  end

  defp create do
    pair = Protocol.generate_key_pair()

    WriteTransaction.run(fn ->
      case %__MODULE__{id: "vapid"}
           |> change(public_key: pair.public_key, private_key: pair.private_key)
           |> Repo.insert(on_conflict: :nothing, conflict_target: :id, log: false) do
        {:ok, _} -> Repo.get!(__MODULE__, "vapid", log: false)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end
end
