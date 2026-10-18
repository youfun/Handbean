defmodule Handbean.Agent.CliAgent.Session do
  @moduledoc """
  Process handle for one CLI-agent session.

  Callers may read `backend`, `cwd`, and `session_id`. They must not
  pattern-match on backend protocol fields; those stay in `private`.
  """

  @enforce_keys [:backend, :cwd]
  defstruct [:backend, :cwd, :session_id, :pid, :port, private: %{}]

  @type t :: %__MODULE__{
          backend: String.t(),
          cwd: String.t(),
          session_id: String.t() | nil,
          pid: pid() | nil,
          port: port() | nil,
          private: map()
        }
end
