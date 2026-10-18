defmodule Handbean.E2E.HostGitTest do
  @moduledoc """
  A host-injected Git backend is called from a live run. The backend is a
  stub; the tool registration, transcript, and finished run are real.

  Run: mix test --include e2e test/handbean/e2e/host_git_test.exs
  """

  use ExUnit.Case, async: false

  alias Handbean.Agent.Coordinator
  alias Handbean.ConversationStore
  alias Handbean.PubSub.Session
  alias Handbean.TestSupport.E2EHarness

  @moduletag :e2e

  defmodule FakeGit do
    @behaviour Handbean.Git.Backend

    def available, do: :ok
    def init(path), do: {:ok, %{path: path}}
    def open(path, _opts), do: {:ok, %{path: path}}
    def workdir(%{path: path}), do: {:ok, path}

    def status(_repo) do
      {:ok, %{branch: "main", entries: [%{path: "lib/demo.ex", staged: :new, unstaged: nil}]}}
    end

    def diff(_repo, _opts), do: {:ok, ""}
    def add(_repo, _paths), do: :ok
    def reset(_repo, _type, _target), do: :ok
    def reset_paths(_repo, _paths), do: :ok
    def commit(_repo, _message, _opts), do: {:ok, "abc123"}
    def log(_repo, _opts), do: {:ok, []}
    def branches(_repo), do: {:ok, []}
    def create_branch(_repo, _name, _opts), do: :ok
    def checkout(_repo, _target, _opts), do: :ok
    def clone(_url, path, _opts), do: {:ok, %{path: path}}
    def fetch(_repo, _opts), do: :ok
    def pull(_repo, _opts), do: :up_to_date
    def push(_repo, _opts), do: :ok
    def remotes(_repo), do: {:ok, []}
    def remote_add(_repo, _name, _url), do: :ok
    def remote_set_url(_repo, _name, _url), do: :ok
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Handbean.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Handbean.Repo, {:shared, self()})
    :ok
  end

  test "a run calls the injected git backend and records status" do
    %{workspace: workspace} = E2EHarness.isolate_home!("host-git")
    E2EHarness.with_host!(%{git_backend: FakeGit})
    :ok = E2EHarness.register_tool!(Handbean.Tool.Builtin.Git)

    {:ok, conversation} = ConversationStore.create("git-ws")
    id = conversation["id"]
    :ok = Session.subscribe(id)
    ExUnit.Callbacks.on_exit(fn -> E2EHarness.cancel!(id) end)

    script = fn messages, _tools ->
      if Enum.any?(messages, &(&1.role == :tool_result)) do
        "Git status recorded"
      else
        {:tools, [%{name: "git", input: %{"action" => "status"}}]}
      end
    end

    assert {:ok, %{action: :started}} =
             Coordinator.add_message(id, "Show git status",
               workspace_path: workspace,
               model: "fake-model",
               provider: Handbean.TestSupport.FakeProvider,
               provider_config: %{scenario: {:script, script}},
               tools: Handbean.Agent.default_tools() ++ [Handbean.Tool.Builtin.Git],
               source: :cli,
               streaming: false
             )

    payload = E2EHarness.await_run_end(id)
    assert payload[:status] in ["completed", :completed]

    entries = E2EHarness.transcript(id)
    assert Enum.any?(entries, &(&1["tool_name"] == "git" and &1["output"] =~ "lib/demo.ex"))

    assert Enum.any?(
             entries,
             &(&1["role"] == "assistant" and &1["content"] == "Git status recorded")
           )
  end
end
