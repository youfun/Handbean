defmodule Handbean.Storage.ConversationEditorState do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:conversation_id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "conversation_editor_states" do
    field :editor_files, :string, default: "[]"
    field :active_file, :string
    field :file_preview_error, :string
    timestamps()
  end
end
