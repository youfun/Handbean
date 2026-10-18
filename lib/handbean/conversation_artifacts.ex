defmodule Handbean.ConversationArtifacts do
  @moduledoc """
  Filesystem owner for recoverable artifacts associated with a conversation.

  Transcript, metadata, receipts, and session snapshots do not live here; they
  are canonical SQLite data. This root is only for files such as large saved
  tool inputs, reversible change snapshots, and subagent descriptors.
  """

  @spec root() :: String.t()
  def root do
    Application.get_env(
      :handbean,
      :conversation_artifact_root,
      Path.join(Handbean.Host.data_dir(), ".handbean/conversation-artifacts")
    )
  end
end
