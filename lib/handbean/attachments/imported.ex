defmodule Handbean.Attachments.Imported do
  @moduledoc """
  Controlled import descriptor. No external URI, no base64, conversation optional.
  """

  @enforce_keys [
    :attachment_id,
    :source,
    :display_name,
    :canonical_type,
    :size_bytes,
    :controlled_path
  ]
  defstruct [
    :attachment_id,
    :source,
    :display_name,
    :canonical_type,
    :source_mime,
    :size_bytes,
    :controlled_path,
    :relative_path,
    state: :staged
  ]

  @type source :: :picker | :photo | :camera | :share | :test
  @type t :: %__MODULE__{
          attachment_id: String.t(),
          source: source() | String.t(),
          display_name: String.t(),
          canonical_type: String.t(),
          source_mime: String.t() | nil,
          size_bytes: non_neg_integer(),
          controlled_path: String.t(),
          relative_path: String.t() | nil,
          state: atom()
        }

  def new(attrs) when is_map(attrs) do
    struct!(
      __MODULE__,
      Map.take(attrs, [
        :attachment_id,
        :source,
        :display_name,
        :canonical_type,
        :source_mime,
        :size_bytes,
        :controlled_path,
        :relative_path,
        :state
      ])
    )
  end
end
