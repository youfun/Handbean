defmodule Handbean.Agent.Subagent.ProfileRegistry do
  @moduledoc """
  Merges builtin, user (`~/.handbean/agents/*.md`), and workspace
  (`<workspace>/.handbean/agents/*.md`) subagent profiles.

  Files are re-read on every lookup; they are small and this keeps edits live
  without a watcher. Workspace profiles are untrusted repository content: an
  override may change its prompt and narrow an existing trusted profile. New
  workspace profiles use the read-only researcher profile as their permission
  ceiling. User profiles under `~/.handbean` are trusted configuration.
  """

  require Logger

  alias Handbean.Agent.Subagent.Profile

  @doc "Merged profiles for a workspace. Later sources override earlier names."
  @spec list(String.t() | nil, keyword()) :: [Profile.t()]
  def list(workspace_path, opts \\ []) do
    home = Keyword.get_lazy(opts, :home, &Handbean.Home.path/0)

    merge([
      Profile.builtin(),
      read_dir(user_dir(home), :user),
      read_dir(workspace_dir(workspace_path), :workspace)
    ])
  end

  @spec fetch(String.t() | nil, String.t(), keyword()) ::
          {:ok, Profile.t()} | {:error, String.t()}
  def fetch(workspace_path, name, opts \\ []) when is_binary(name) do
    case Enum.find(list(workspace_path, opts), &(&1.name == name)) do
      nil -> {:error, "Unknown subagent_type #{inspect(name)}"}
      profile -> {:ok, profile}
    end
  end

  @doc """
  Profiles the parent run can actually start, with tools narrowed to the
  parent's authorization and the host.
  """
  @spec available(String.t() | nil, [String.t()], keyword()) :: [Profile.t()]
  def available(workspace_path, authorized_tools, opts \\ []) do
    host = [shell?: Handbean.Host.shell?(), git?: git_repo?(workspace_path)]
    host = Keyword.merge(host, Keyword.take(opts, [:shell?, :git?]))

    workspace_path
    |> list(opts)
    |> Enum.filter(&Profile.available?(&1, host))
    |> Enum.map(fn profile ->
      %{
        profile
        | tools: profile |> Profile.intersect_tools(authorized_tools) |> Profile.host_tools(host)
      }
    end)
  end

  @doc """
  Merge profile sources in priority order. Pure; exposed for the permission
  ceiling failure list.
  """
  @spec merge([[Profile.t()]]) :: [Profile.t()]
  def merge(sources) do
    builtin = Map.new(Profile.builtin(), &{&1.name, &1})

    sources
    |> List.flatten()
    |> Enum.reduce({%{}, builtin}, fn profile, {profiles, trusted} ->
      merged = cap_override(profile, trusted[profile.name])

      trusted =
        if profile.source == :workspace, do: trusted, else: Map.put(trusted, profile.name, merged)

      {Map.put(profiles, profile.name, merged), trusted}
    end)
    |> elem(0)
    |> Map.values()
    |> Enum.sort_by(& &1.name)
  end

  defp cap_override(%Profile{source: :builtin} = profile, _ceiling), do: profile
  defp cap_override(%Profile{source: :user} = profile, nil), do: profile

  defp cap_override(%Profile{source: :workspace} = profile, ceiling) do
    profile
    |> cap_to(ceiling || Profile.researcher())
    |> cap_to(Profile.researcher())
  end

  defp cap_override(profile, ceiling), do: cap_to(profile, ceiling)

  defp cap_to(profile, ceiling) do
    %{
      profile
      | tools: Profile.intersect_tools(profile, ceiling.tools),
        mode: ceiling.mode,
        isolation: ceiling.isolation
    }
  end

  @doc false
  def git_repo?(nil), do: false

  def git_repo?(path) do
    File.dir?(Path.join(path, ".git")) or File.regular?(Path.join(path, ".git"))
  end

  defp read_dir(nil, _source), do: []

  defp read_dir(dir, source) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.sort()
        |> Enum.flat_map(&read_file(Path.join(dir, &1), source))

      _ ->
        []
    end
  end

  defp read_file(path, source) do
    with {:ok, content} <- File.read(path),
         {:ok, profile, warnings} <- Profile.parse(content, source: source) do
      Enum.each(warnings, &Logger.warning("[Subagent.Profile] #{path}: #{&1}"))
      [profile]
    else
      {:error, reason} ->
        Logger.warning("[Subagent.Profile] rejected #{path}: #{inspect(reason)}")
        []
    end
  end

  defp user_dir(nil), do: nil
  defp user_dir(home), do: Path.join([Path.expand(home), ".handbean", "agents"])

  defp workspace_dir(nil), do: nil
  defp workspace_dir(path), do: Path.join([path, ".handbean", "agents"])
end
