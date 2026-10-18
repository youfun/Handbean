defmodule Handbean.Storage.ConversationRunUsage do
  @moduledoc false

  use Ecto.Schema

  @timestamps_opts [type: :utc_datetime_usec]

  schema "conversation_run_usage" do
    field :conversation_id, :string
    field :run_id, :string
    field :source, :string
    field :input_tokens, :integer, default: 0
    field :output_tokens, :integer, default: 0
    field :cache_read_tokens, :integer, default: 0
    field :cache_write_tokens, :integer, default: 0
    field :total_input_tokens, :integer, default: 0
    field :usage_incomplete, :boolean, default: false
    timestamps()
  end
end
