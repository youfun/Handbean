# Reach architecture policy for Handbean
# See https://github.com/elixir-vibe/reach for full reference
#
# Known accepted trade-offs:
#   agent ↔ pubsub cycle — PubSub.Session manages Agent.CandidateQueue directly.
#     Accepted: they run in the same BEAM process tree and share runtime state.
#     Session already holds queue_pid (Agent exposes it intentionally).

[
  # ── Architecture Layers ──
  layers: [
    web: "HandbeanWeb.*",

    # Runtime = Agent + Tool + PubSub, tightly coupled by design
    runtime: ["Handbean.Agent.*", "Handbean.Tool.*", "Handbean.PubSub.*"],
    mcp: "Handbean.MCP.*",
    memory: "Handbean.Memory.*",
    delivery: "Handbean.Delivery*",
    store: ["Handbean.SessionStore*", "Handbean.ConversationTranscriptStore*"],
    extension: "Handbean.Extension.*",
    log: "Handbean.Log.*",
    security: "Handbean.Security.*",
    utils: "Handbean.Utils*",
    mix_tasks: "Handbean.Mix.Tasks.*",
    csv: ["Handbean.Csv*", "Handbean.CsvProfile*"],
    permissions: "Handbean.Permissions*",
    settings: "Handbean.Settings*",
    skills: "Handbean.Skills*"
  ],

  # ── Dependency Rules ──
  deps: [
    forbidden: [
      # Core layers must NOT depend on web (web is a projection, not the owner)
      {:runtime, :web},
      {:memory, :web},
      {:mcp, :web},
      {:delivery, :web},
      {:security, :web},
      {:log, :web},

      # Delivery is outbound only — must not drive agent logic
      {:delivery, :runtime},

      # Memory should stay focused on storage, not runtime orchestration
      {:memory, :runtime}
    ]
  ],

  # ── Source Restrictions ──
  source: [
    forbidden_modules: []
  ],

  # ── Call Restrictions ──
  calls: [
    forbidden: [
      # Runtime must not do raw IO (use Logger instead)
      {"Handbean.Agent.*", ["IO.puts", "IO.inspect"]},
      {"Handbean.Tool.*", ["IO.puts", "IO.inspect"]},

      # Web layer must not touch database directly
      {"HandbeanWeb.*", ["Handbean.Repo"]},

      # PubSub must not access database directly
      {"Handbean.PubSub.*", "Handbean.Repo"},

      # Delivery must not access database directly
      {"Handbean.Delivery*", "Handbean.Repo"}
    ]
  ],

  # ── Test Hints ──
  tests: [
    hints: [
      {"lib/handbean/agent/**", ["test/handbean/agent/*_test.exs"]},
      {"lib/handbean/tool/**", ["test/handbean/tool/*_test.exs"]},
      {"lib/handbean/mcp/**", ["test/handbean/mcp/*_test.exs"]},
      {"lib/handbean_web/**", ["test/handbean_web/*_test.exs"]}
    ]
  ]
]
