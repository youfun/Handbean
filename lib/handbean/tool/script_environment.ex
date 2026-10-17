defmodule Handbean.Tool.ScriptEnvironment do
  @moduledoc """
  Curated script guidance, filtered by the current runtime's exported APIs.

  Availability is not a promise that arbitrary inputs, networking or native
  operations will succeed. Only the host may declare its HTTP configuration.
  """

  @capabilities [
    {:files, [{File, :read!, 1}, {File, :write!, 2}, {File, :cp!, 2}, {Path, :join, 1}],
     "Files: File.read!/1, File.write!/2, File.cp!/2 and Path.join/1,2. Create destination parents first; preserve input files."},
    {:text, [{String, :split, 1}, {Enum, :map, 2}],
     "Text and collections: String and Enum (split, trim, map, filter, reduce)."},
    {:regex, [{Regex, :run, 2}],
     "Regex: Regex.run(~r/(INFO|ERROR)/, text) returns [full_match, capture] or nil, not just [capture]."},
    {:json, [{Handbean.JSON, :encode!, 1}, {Handbean.JSON, :decode!, 1}],
     "JSON: Handbean.JSON.encode!/1 and Handbean.JSON.decode!/1 use the bundled OTP JSON implementation. Encode maps/lists before writing JSON files."},
    {:csv,
     [
       {NimbleCSV.RFC4180, :parse_string, 2},
       {NimbleCSV.RFC4180, :parse_stream, 2},
       {NimbleCSV.RFC4180, :dump_to_iodata, 1}
     ],
     "CSV: NimbleCSV.RFC4180 is installed. parse_string(csv, skip_headers: false) retains headers or headerless first rows; default skips the first row. There is no parse_string!. File.stream!(path) |> NimbleCSV.RFC4180.parse_stream(skip_headers: false) handles multiline CSV. File.write!(path, NimbleCSV.RFC4180.dump_to_iodata(rows)) exports escaped fields. Fields are strings; do not split CSV on commas or lines yourself."},
    {:http, [{Req, :get, 2}],
     "HTTPS: Req.get(url, receive_timeout: 15_000, retry: false) returns {:ok, response} or {:error, reason}. Check response.status. JSON response.body may already be a map/list: do not blindly decode it or File.write! it; use Handbean.JSON.encode!/1 to save JSON. Keep TLS verification enabled; send credentials only when authorized."},
    {:hash, [{:crypto, :hash, 2}],
     "SHA-256: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)."},
    {:zip, [{:zip, :create, 3}, {:zip, :extract, 2}],
     "ZIP memory roundtrip: {:ok, {_, zip}} = :zip.create(~c\"memory.zip\", [{~c\"note.txt\", content_binary}], [:memory]); {:ok, entries} = :zip.extract(zip, [:memory]). Entries contain filename charlists and file bytes. Without :memory, create writes to the archive filename; use an absolute workspace path converted with String.to_charlist. Never extract untrusted archive paths without validation."},
    {:gzip, [{:zlib, :gzip, 1}, {:zlib, :gunzip, 1}],
     "GZIP: :zlib.gzip(binary) and :zlib.gunzip(binary). Compare decompressed bytes; small inputs need not compress smaller."}
  ]

  @type snapshot :: %{
          elixir: String.t(),
          otp: String.t(),
          architecture: String.t(),
          available: %{atom() => boolean()},
          mix?: boolean(),
          hex?: boolean(),
          http_configured?: boolean()
        }

  @spec snapshot() :: snapshot()
  def snapshot do
    %{
      elixir: System.version(),
      otp: to_string(:erlang.system_info(:otp_release)),
      architecture: to_string(:erlang.system_info(:system_architecture)),
      available:
        Map.new(@capabilities, fn {key, apis, _text} ->
          {key, Enum.all?(apis, &available?/1)}
        end),
      mix?: mix_present?(),
      hex?: hex_present?(),
      http_configured?: Handbean.Host.get(:script_http) == :platform_dns_ca
    }
  end

  @spec describe() :: String.t()
  def describe, do: describe(snapshot())

  @spec describe(snapshot()) :: String.t()
  def describe(info) do
    capabilities =
      for {key, _apis, text} <- @capabilities, Map.fetch!(info.available, key), do: text

    http =
      if info.available.http and info.http_configured? do
        "The host has configured Req with platform DNS and CA certificates. Use its defaults; this does not guarantee reachability of any URL."
      else
        "No host-specific Req DNS/CA configuration is declared."
      end

    mix_install =
      if info.mix? do
        "Mix.install/2 is supported in this script for host-compatible pure Elixir/Erlang Hex packages. Call Mix.install at the top of the .exs before using those modules. Do not call mix deps.get or an external elixir command."
      else
        "Mix and Hex are not loaded in this runtime, so Mix.install is unavailable. Do not call Mix.install, mix deps.get or an external elixir command; reuse bundled dependencies."
      end

    """
    Embedded Elixir #{info.elixir}, OTP #{info.otp}, architecture #{info.architecture}.
    Runtime modules: Mix #{presence(info.mix?)}, Hex #{presence(info.hex?)}. #{mix_install} Missing capabilities must be reported, not guessed.

    Curated APIs available in this runtime (not a guarantee for every operation):
    #{Enum.join(capabilities, "\n")}
    #{http}

    Bindings: workspace is the current workspace's absolute path string; args is a list of strings. Tool paths are workspace-relative, but relative File paths are NOT automatically workspace-relative. Never hardcode device paths, use application priv directories, System.argv, File.cwd! or File.cd! to locate the workspace. Module functions do not capture bindings: pass workspace/base explicitly.
    Example: base = Path.join(workspace, "output"); File.mkdir_p!(base); path = Path.join([base, "result.txt"]); File.write!(path, "done"). Path.join/3 does not exist. Keep all generated files in the requested output directory.

    Write/edit the actual .exs before executing it. Request execution through this tool's approval flow, not just a prose permission request. Check outputs against expected values before claiming success. Errors may leave partial files; inspect the error, fix and rerun safely. Do not retry denied operations without permission or repeat ineffective diagnostics indefinitely. Report unresolved failures.
    This runs with full host BEAM privileges, not a sandbox: do not modify application processes, global configuration or cwd without authorization. Returns bounded UTF-8 stdout and an inspected return value.
    """
  end

  defp available?({module, function, arity}),
    do: Code.ensure_loaded?(module) and function_exported?(module, function, arity)

  defp mix_present? do
    case Handbean.Workspace.MixToolchain.info() do
      {:ok, info} -> info.mix?
      {:error, _} -> Code.ensure_loaded?(Mix)
    end
  end

  defp hex_present? do
    case Handbean.Workspace.MixToolchain.info() do
      {:ok, info} -> info.hex?
      {:error, _} -> Code.ensure_loaded?(Hex)
    end
  end

  defp presence(true), do: "present"
  defp presence(false), do: "absent"
end
