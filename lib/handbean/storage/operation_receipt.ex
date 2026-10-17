defmodule Handbean.Storage.OperationReceipt do
  @moduledoc false

  use Ecto.Schema

  @timestamps_opts [type: :utc_datetime_usec]

  schema "operation_receipts" do
    field :scope_kind, :string
    field :scope_id, :string
    field :request_id, :string
    field :fingerprint, :string
    field :status, :string
    field :receipt, :map

    timestamps()
  end
end
