defmodule Handbean.ConversationsCase do
  use ExUnit.CaseTemplate

  alias Handbean.ConversationStore

  using do
    quote do
      alias Handbean.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Handbean.DataCase
    end
  end

  setup tags do
    Handbean.DataCase.setup_sandbox(tags)

    old = System.get_env("HOME")
    home = Path.join(System.tmp_dir!(), "conversations-#{Ecto.UUID.generate()}")
    File.mkdir_p!(home)
    System.put_env("HOME", home)

    on_exit(fn ->
      System.put_env("HOME", old)
      File.rm_rf!(home)
    end)

    {:ok, source} = ConversationStore.create("ws", title: "Source")
    {:ok, target} = ConversationStore.create("ws", title: "目标")
    {:ok, foreign} = ConversationStore.create("other", title: "Secret")
    context = %{conversation_id: source["id"], workspace_id: "ws", run_id: "source-run"}

    %{
      source: source["id"],
      target: target["id"],
      foreign: foreign["id"],
      context: context,
      home: home
    }
  end
end
