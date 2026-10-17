defmodule ExFff.Config do
  @moduledoc """
  Configuration struct for ExFff file indexing.

  ## Fields

  - `:root_path` — project root directory to scan
  - `:max_files` — max files to index (default 100_001, one beyond the backend-switch threshold)
  - `:ignore_patterns` — regex patterns for paths to exclude. Defaults also cover
    build-product directories pruned by name (`build/`, `_build/`, `deps/`,
    `.git/`, `node_modules/`, `.gradle/`, `target/`, `cover/`, and editor caches).
  """

  defstruct root_path: nil,
            max_files: 100_001,
            ignore_patterns: nil,
            path_filter: nil

  @type t :: %__MODULE__{
          root_path: String.t() | nil,
          max_files: pos_integer(),
          ignore_patterns: [Regex.t()],
          path_filter: (String.t() -> boolean()) | nil
        }

  @default_ignored_dirs ~w(
    _build build deps .git node_modules .gradle .elixir_ls target .zig-cache
    zig-out .cxx cover tmp artifacts .handbean .local-archive mix_toolchain
    .idea .vscode .hg .svn .amp .build .cache .pytest_cache .mypy_cache
    .ruff_cache .tox .venv .next .nuxt .svelte-kit .parcel-cache .turbo
    .dart_tool
  )

  @default_ignore_patterns Enum.map(@default_ignored_dirs, fn dir ->
                             Regex.compile!("(^|/)#{Regex.escape(dir)}/")
                           end)

  @doc """
  Build a Config struct from a keyword list.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    merged = Keyword.merge([ignore_patterns: @default_ignore_patterns], opts)
    struct!(__MODULE__, merged)
  end

  @doc """
  Returns true if the given path matches any ignore pattern.
  """
  @spec ignored?(t(), String.t()) :: boolean()
  def ignored?(%__MODULE__{ignore_patterns: patterns}, path) do
    Enum.any?(patterns, &String.match?(path, &1))
  end

  @doc false
  def allowed?(%__MODULE__{path_filter: nil}, _path), do: true
  def allowed?(%__MODULE__{path_filter: filter}, path), do: filter.(path)

  @doc false
  def default_ignored_dir?(name), do: name in @default_ignored_dirs

  @doc false
  def rg_exclude_globs, do: Enum.map(@default_ignored_dirs, &"!**/#{&1}/**")
end
