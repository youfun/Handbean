defmodule Handbean.Tool.Extension.BeamIntrospectionTest do
  use Handbean.DataCase, async: true

  defmodule NoResultRepo do
    def query("UPDATE example SET value = ?", ["updated"]) do
      {:ok, %{columns: nil, rows: nil, num_rows: 1}}
    end
  end

  setup do
    # Register all beam tools before each test
    Enum.each(beam_tool_modules(), &Handbean.Tool.Registry.register/1)

    %{}
  end

  defp beam_tool_modules do
    [
      Handbean.Tool.Extension.Beam.Eval,
      Handbean.Tool.Extension.Beam.Docs,
      Handbean.Tool.Extension.Beam.Source,
      Handbean.Tool.Extension.Beam.DbSchema,
      Handbean.Tool.Extension.Beam.Sql,
      Handbean.Tool.Extension.Beam.Schemas,
      Handbean.Tool.Extension.Beam.SupTree,
      Handbean.Tool.Extension.Beam.Top,
      Handbean.Tool.Extension.Beam.ProcessInfo
    ]
  end

  defp build_context do
    %{working_directory: File.cwd!()}
  end

  describe "ext__beam__eval" do
    test "evaluates simple Elixir expression" do
      {:ok, output} =
        Handbean.Tool.Extension.Beam.Eval.execute(
          %{"code" => "1 + 2"},
          build_context()
        )

      assert output =~ "3"
    end

    test "evaluates multi-line code" do
      {:ok, output} =
        Handbean.Tool.Extension.Beam.Eval.execute(
          %{"code" => "xs = [1, 2, 3]\nEnum.sum(xs)"},
          build_context()
        )

      assert output =~ "6"
    end

    test "returns error for syntax error" do
      result =
        Handbean.Tool.Extension.Beam.Eval.execute(
          %{"code" => "1 +"},
          build_context()
        )

      assert match?({:error, _}, result)
    end

    test "returns error for runtime error" do
      {:error, reason} =
        Handbean.Tool.Extension.Beam.Eval.execute(
          %{"code" => "raise \"boom\""},
          build_context()
        )

      assert reason =~ "RuntimeError" and reason =~ "boom"
    end

    test "code is required" do
      {:error, reason} =
        Handbean.Tool.Extension.Beam.Eval.execute(
          %{},
          build_context()
        )

      assert reason =~ "code"
    end

    test "timeout kills long-running code" do
      {:error, reason} =
        Handbean.Tool.Extension.Beam.Eval.execute(
          %{"code" => "Process.sleep(10_000)", "timeout" => 500},
          build_context()
        )

      assert reason =~ "timed out"
    end

    test "rejects :rpc calls" do
      {:error, reason} =
        Handbean.Tool.Extension.Beam.Eval.execute(
          %{"code" => ":rpc.call(node(), Kernel, :+, [1, 1])"},
          build_context()
        )

      assert reason == ":rpc is not allowed in ext__beam__eval"
    end

    test "rejects File write" do
      path =
        Path.join(System.tmp_dir!(), "sigil_eval_write_#{System.unique_integer([:positive])}")

      {:error, reason} =
        Handbean.Tool.Extension.Beam.Eval.execute(
          %{"code" => "File.write!(#{inspect(path)}, \"owned\")"},
          build_context()
        )

      refute File.exists?(path)
      assert reason == "File is not allowed in ext__beam__eval"
    end

    test "rejects System.cmd" do
      {:error, reason} =
        Handbean.Tool.Extension.Beam.Eval.execute(
          %{"code" => "System.cmd(\"echo\", [\"hi\"])"},
          build_context()
        )

      assert reason == "System is not allowed in ext__beam__eval"
    end

    test "has proper tool metadata" do
      assert Handbean.Tool.Extension.Beam.Eval.name() == "ext__beam__eval"
      assert is_binary(Handbean.Tool.Extension.Beam.Eval.description())
      assert is_map(Handbean.Tool.Extension.Beam.Eval.input_schema())
    end
  end

  describe "ext__beam__docs" do
    test "gets docs for a known module" do
      {:ok, output} =
        Handbean.Tool.Extension.Beam.Docs.execute(
          %{"reference" => "Enum"},
          build_context()
        )

      assert output =~ "Enum"
    end

    test "gets docs for a known function" do
      {:ok, output} =
        Handbean.Tool.Extension.Beam.Docs.execute(
          %{"reference" => "Enum.map/2"},
          build_context()
        )

      assert output =~ "map"
      assert output =~ "Enum"
    end

    test "returns error for unknown module" do
      {:error, reason} =
        Handbean.Tool.Extension.Beam.Docs.execute(
          %{"reference" => "NonExistent.Module.XYZ"},
          build_context()
        )

      assert reason =~ "not found"
    end

    test "resolves a nested module function instead of treating the first segment as the module" do
      {:ok, output} =
        Handbean.Tool.Extension.Beam.Docs.execute(
          %{"reference" => "Handbean.ConversationTitleGenerator.maybe_generate/3"},
          build_context()
        )

      assert output =~ "maybe_generate"
    end

    test "reference is required" do
      {:error, reason} =
        Handbean.Tool.Extension.Beam.Docs.execute(
          %{},
          build_context()
        )

      assert reason =~ "reference"
    end

    test "has proper tool metadata" do
      assert Handbean.Tool.Extension.Beam.Docs.name() == "ext__beam__docs"
      assert is_binary(Handbean.Tool.Extension.Beam.Docs.description())
    end
  end

  describe "ext__beam__source" do
    test "locates source file for a known module" do
      {:ok, output} =
        Handbean.Tool.Extension.Beam.Source.execute(
          %{"reference" => "Enum"},
          build_context()
        )

      assert output =~ "Enum"
      # Should include file path or "could not determine"
    end

    test "locates source for function with arity" do
      {:ok, output} =
        Handbean.Tool.Extension.Beam.Source.execute(
          %{"reference" => "Enum.map/2"},
          build_context()
        )

      assert output =~ "Enum.map"
    end

    test "reference is required" do
      {:error, reason} =
        Handbean.Tool.Extension.Beam.Source.execute(
          %{},
          build_context()
        )

      assert reason =~ "reference"
    end

    test "returns an error instead of crashing on a truncated function reference" do
      {:error, reason} =
        Handbean.Tool.Extension.Beam.Source.execute(
          %{"reference" => "Handbean.ConversationTitleGenerator.maybe_"},
          build_context()
        )

      assert reason =~ "not found" or reason =~ "Cannot parse"
    end

    test "locates a nested module function without arity" do
      {:ok, output} =
        Handbean.Tool.Extension.Beam.Source.execute(
          %{"reference" => "Handbean.ConversationTitleGenerator.maybe_generate"},
          build_context()
        )

      assert output =~ "maybe_generate"
      assert output =~ "conversation_title_generator.ex"
    end
  end

  describe "ext__beam__sql" do
    test "executes a simple SQL query" do
      {:ok, output} =
        Handbean.Tool.Extension.Beam.Sql.execute(
          %{"query" => "SELECT 1 AS num"},
          build_context()
        )

      assert output =~ "num" or output =~ "1"
    end

    test "passes parameters to the selected configured repo" do
      {:ok, output} =
        Handbean.Tool.Extension.Beam.Sql.execute(
          %{
            "query" => "SELECT ? AS number, ? AS label",
            "params" => [42, "bound value"],
            "repo" => "Handbean.Repo"
          },
          build_context()
        )

      assert output =~ "42"
      assert output =~ "bound value"
    end

    test "formats successful statements without a result set" do
      context = Map.put(build_context(), :repo, NoResultRepo)

      assert {:ok, output} =
               Handbean.Tool.Extension.Beam.Sql.execute(
                 %{"query" => "UPDATE example SET value = ?", "params" => ["updated"]},
                 context
               )

      assert output =~ "Repo: Handbean.Tool.Extension.BeamIntrospectionTest.NoResultRepo"
      assert output =~ "Query completed. 1 row(s) affected."
    end

    test "rejects non-list parameters" do
      assert {:error, "params must be an array"} =
               Handbean.Tool.Extension.Beam.Sql.execute(
                 %{"query" => "SELECT 1", "params" => nil},
                 build_context()
               )
    end

    test "query is required" do
      {:error, reason} =
        Handbean.Tool.Extension.Beam.Sql.execute(
          %{},
          build_context()
        )

      assert reason =~ "query"
    end

    test "has proper tool metadata" do
      assert Handbean.Tool.Extension.Beam.Sql.name() == "ext__beam__sql"
      assert is_binary(Handbean.Tool.Extension.Beam.Sql.description())
      assert Handbean.Tool.Extension.Beam.Sql.description() =~ "requires approval"
    end
  end

  describe "ext__beam__db_schema" do
    test "reports the configured repo and its runtime dialect" do
      assert {:ok, output} =
               Handbean.Tool.Extension.Beam.DbSchema.execute(
                 %{"operation" => "list_repos"},
                 build_context()
               )

      assert {:ok, decoded} = Handbean.JSON.decode(output)
      assert [repo] = decoded["repos"]
      assert repo["repo"] == "Handbean.Repo"
      assert repo["adapter"] == "Ecto.Adapters.SQLite3"
      assert repo["dialect"] == "sqlite"
      assert repo["parameter_style"] == "?"
    end

    test "lists SQLite tables without caller-supplied metadata SQL" do
      assert {:ok, output} =
               Handbean.Tool.Extension.Beam.DbSchema.execute(
                 %{"operation" => "list_tables"},
                 build_context()
               )

      assert {:ok, decoded} = Handbean.JSON.decode(output)
      assert decoded["database"]["dialect"] == "sqlite"
      assert Enum.any?(decoded["tables"], &(&1["name"] == "schema_migrations"))
    end

    test "describes a SQLite table with bound identifiers" do
      assert {:ok, output} =
               Handbean.Tool.Extension.Beam.DbSchema.execute(
                 %{"operation" => "describe_table", "table" => "schema_migrations"},
                 build_context()
               )

      assert {:ok, decoded} = Handbean.JSON.decode(output)
      assert Enum.any?(decoded["columns"], &(&1["name"] == "version"))
    end

    test "lists SQLite indexes and foreign keys" do
      for operation <- ["list_indexes", "list_foreign_keys"] do
        assert {:ok, output} =
                 Handbean.Tool.Extension.Beam.DbSchema.execute(
                   %{"operation" => operation, "table" => "schema_migrations"},
                   build_context()
                 )

        assert {:ok, decoded} = Handbean.JSON.decode(output)
        assert decoded["operation"] == operation
        assert decoded["database"]["dialect"] == "sqlite"
      end
    end

    test "requires the table argument for table-specific operations" do
      assert {:error, reason} =
               Handbean.Tool.Extension.Beam.DbSchema.execute(
                 %{"operation" => "describe_table"},
                 build_context()
               )

      assert reason =~ "table argument"
    end

    test "has proper read-only tool metadata" do
      assert Handbean.Tool.Extension.Beam.DbSchema.name() == "ext__beam__db_schema"
      assert Handbean.Tool.Extension.Beam.DbSchema.description() =~ "without writing"
    end
  end

  # ── P1 tools ──

  describe "ext__beam__schemas" do
    test "lists Ecto schemas including project modules" do
      {:ok, output} = Handbean.Tool.Extension.Beam.Schemas.execute(%{}, build_context())
      assert output =~ "Engram" or output =~ "Synapse"
    end
  end

  describe "ext__beam__sup_tree" do
    test "shows supervision tree for Handbean app" do
      result = Handbean.Tool.Extension.Beam.SupTree.execute(%{}, build_context())
      assert match?({:ok, _}, result)
    end

    test "returns an error for an unknown root instead of crashing" do
      assert {:error, reason} =
               Handbean.Tool.Extension.Beam.SupTree.execute(
                 %{"root" => "Not.A.Real.Supervisor"},
                 build_context()
               )

      assert reason =~ "not found"
    end
  end

  describe "ext__beam__top" do
    test "lists top processes sorted by memory" do
      {:ok, output} = Handbean.Tool.Extension.Beam.Top.execute(%{"limit" => 5}, build_context())
      assert output =~ "PID"
      assert output =~ "Memory"
    end

    test "can sort by reductions" do
      {:ok, output} =
        Handbean.Tool.Extension.Beam.Top.execute(
          %{"sort" => "reductions", "limit" => 3},
          build_context()
        )

      assert output =~ "PID"
      assert output =~ "Sort: reductions"
    end

    test "has proper tool metadata" do
      assert Handbean.Tool.Extension.Beam.Top.name() == "ext__beam__top"
    end
  end

  describe "ext__beam__process_info" do
    test "gets info for Tool.Registry process" do
      {:ok, output} =
        Handbean.Tool.Extension.Beam.ProcessInfo.execute(
          %{"process" => "Handbean.Tool.Registry"},
          build_context()
        )

      assert output =~ "Handbean.Tool.Registry"
      assert output =~ "GenServer State"
    end

    test "process argument is required" do
      {:error, reason} = Handbean.Tool.Extension.Beam.ProcessInfo.execute(%{}, build_context())
      assert reason =~ "process"
    end

    test "returns an error for a malformed process name instead of crashing" do
      {:error, reason} =
        Handbean.Tool.Extension.Beam.ProcessInfo.execute(
          %{"process" => "Not a module!!"},
          build_context()
        )

      assert reason =~ "Cannot parse"
    end

    test "returns error for nonexistent process" do
      {:error, reason} =
        Handbean.Tool.Extension.Beam.ProcessInfo.execute(
          %{"process" => "NonExistent.Process.XYZ"},
          build_context()
        )

      assert reason =~ "No process registered" or reason =~ "Cannot parse"
    end
  end
end
