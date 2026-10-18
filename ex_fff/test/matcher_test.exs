defmodule ExFff.MatcherTest do
  use ExUnit.Case, async: false

  alias ExFff.Matcher

  describe "tokenize/1" do
    test "splits on path separators" do
      tokens = Matcher.tokenize("lib/user_controller")
      # Should contain trigrams from "lib", "user", "controller"
      assert "lib" in tokens
      assert "use" in tokens
      assert "ser" in tokens
    end

    test "splits camelCase into separate words" do
      # UserController → user, controller
      tokens = Matcher.split_camel_case("UserController")
      assert tokens == ["user", "controller"]
    end

    test "splits PascalCase multi-word" do
      tokens = Matcher.split_camel_case("SchemaValidator")
      assert tokens == ["schema", "validator"]
    end

    test "handles single word" do
      tokens = Matcher.split_camel_case("schema")
      assert tokens == ["schema"]
    end

    test "handles empty string" do
      tokens = Matcher.split_camel_case("")
      assert tokens == []
    end

    test "handles acronyms (ABC)" do
      tokens = Matcher.split_camel_case("ABC")
      assert tokens == ["abc"]
    end

    test "returns unique trigrams" do
      tokens = Matcher.tokenize("aaa")
      unique = Enum.uniq(tokens)
      assert tokens == unique
    end

    test "skips tokens shorter than 3 characters" do
      tokens = Matcher.tokenize("a/b/c")
      assert tokens == []
    end

    test "generates trigrams for tokens >= 3 chars" do
      tokens = Matcher.tokenize("schema")
      # "schema" trigrams: sch, che, hem, ema
      assert "sch" in tokens
      assert "che" in tokens
      assert "hem" in tokens
      assert "ema" in tokens
    end
  end

  describe "compute_frecency/2" do
    test "adds a unit boost and caps unbounded growth" do
      assert Matcher.compute_frecency(0) == 1.0
      assert Matcher.compute_frecency(31) == 32.0
      assert Matcher.compute_frecency(985) == 32.0
    end

    test "decays with a 7-day half-life before boosting" do
      half_life = 7 * 24 * 60 * 60
      assert Matcher.compute_frecency(10, half_life) == 6.0
    end

    test "compresses legacy unbounded scores without reordering them" do
      high = Matcher.normalize_stored_frecency(985)
      low = Matcher.normalize_stored_frecency(100)
      assert high > low
      assert high <= 32.0
      assert Matcher.normalize_stored_frecency(8) == 8.0
    end
  end

  describe "match/4" do
    setup do
      suffix = System.unique_integer([:positive])

      # Create fresh ETS tables for this test
      trigram_name = Module.concat(ExFff.MatcherTest, String.to_atom("Trigrams_#{suffix}"))
      files_name = Module.concat(ExFff.MatcherTest, String.to_atom("Files_#{suffix}"))
      frecency_name = Module.concat(ExFff.MatcherTest, String.to_atom("Frecency_#{suffix}"))

      trigram_tab = :ets.new(trigram_name, [:named_table, :public, :duplicate_bag])
      files_tab = :ets.new(files_name, [:named_table, :public, :set])
      frecency_tab = :ets.new(frecency_name, [:named_table, :public, :ordered_set])

      # Populate with test data
      files = [
        {"lib/user.ex", %{mtime: ~U[2024-01-01 00:00:00Z], size: 100}},
        {"lib/user_controller.ex", %{mtime: ~U[2024-01-02 00:00:00Z], size: 200}},
        {"test/user_test.exs", %{mtime: ~U[2024-01-03 00:00:00Z], size: 300}},
        {"lib/post.ex", %{mtime: ~U[2024-01-04 00:00:00Z], size: 150}},
        {"priv/static/app.js", %{mtime: ~U[2024-01-05 00:00:00Z], size: 500}}
      ]

      for {path, meta} <- files do
        :ets.insert(files_tab, {path, meta})

        trigrams = Matcher.tokenize(path)
        for t <- trigrams, do: :ets.insert(trigram_tab, {t, path})
      end

      on_exit(fn ->
        for name <- [trigram_name, files_name, frecency_name] do
          try do
            if :ets.info(name) != :undefined, do: :ets.delete(name)
          catch
            _, _ -> :ok
          end
        end
      end)

      {:ok, trigram_tab: trigram_tab, files_tab: files_tab, frecency_tab: frecency_tab}
    end

    test "finds files matching single term", ctx do
      query = ExFff.Query.parse("user")
      results = Matcher.match(query, ctx.files_tab, ctx.trigram_tab, ctx.frecency_tab)

      paths = Enum.map(results, & &1.path)
      assert "lib/user.ex" in paths
      assert "lib/user_controller.ex" in paths
      assert "test/user_test.exs" in paths
    end

    test "ranks by score descending", ctx do
      query = ExFff.Query.parse("user")
      results = Matcher.match(query, ctx.files_tab, ctx.trigram_tab, ctx.frecency_tab)

      scores = Enum.map(results, & &1.score)
      assert scores == Enum.sort(scores, :desc)
    end

    test "applies include pattern filter", ctx do
      query = ExFff.Query.parse("user *.ex")
      results = Matcher.match(query, ctx.files_tab, ctx.trigram_tab, ctx.frecency_tab)

      paths = Enum.map(results, & &1.path)
      Enum.each(paths, fn p -> assert String.ends_with?(p, ".ex") end)
    end

    test "applies exclude pattern filter", ctx do
      query = ExFff.Query.parse("user !test/")
      results = Matcher.match(query, ctx.files_tab, ctx.trigram_tab, ctx.frecency_tab)

      paths = Enum.map(results, & &1.path)
      refute Enum.any?(paths, &String.contains?(&1, "test/"))
    end

    test "respects limit", ctx do
      query = %{ExFff.Query.parse("user") | limit: 2}
      results = Matcher.match(query, ctx.files_tab, ctx.trigram_tab, ctx.frecency_tab)

      assert length(results) <= 2
    end

    test "frecency boosts score within the same tier", ctx do
      # Add frecency for lib/user.ex
      :ets.insert(ctx.frecency_tab, {{500, "lib/user.ex"}, true})

      query = ExFff.Query.parse("user")
      results = Matcher.match(query, ctx.files_tab, ctx.trigram_tab, ctx.frecency_tab)

      # lib/user.ex should be top result due to frecency among filename matches
      assert hd(results).path == "lib/user.ex"
    end

    test "a stale frecency score decays below a recent touch", ctx do
      now = System.system_time(:second)
      eight_half_lives = 8 * 7 * 24 * 60 * 60

      :ets.insert(ctx.frecency_tab, {{32.0, "lib/user_controller.ex"}, now - eight_half_lives})
      :ets.insert(ctx.frecency_tab, {{1.0, "lib/user.ex"}, now})

      query = ExFff.Query.parse("user")
      results = Matcher.match(query, ctx.files_tab, ctx.trigram_tab, ctx.frecency_tab)

      assert hd(results).path == "lib/user.ex"
    end

    test "high frecency cannot outrank a higher match tier", ctx do
      :ets.insert(
        ctx.files_tab,
        {"lib/user_extra.ex", %{mtime: ~U[2024-01-06 00:00:00Z], size: 1}}
      )

      for trigram <- Matcher.tokenize("lib/user_extra.ex") do
        :ets.insert(ctx.trigram_tab, {trigram, "lib/user_extra.ex"})
      end

      :ets.insert(ctx.frecency_tab, {{10_000.0, "lib/user_extra.ex"}, true})

      query = ExFff.Query.parse("user.ex")
      results = Matcher.match(query, ctx.files_tab, ctx.trigram_tab, ctx.frecency_tab)

      assert hd(results).path == "lib/user.ex"
      assert Enum.find_index(results, &(&1.path == "lib/user_extra.ex")) > 0
    end

    test "multi-term AND search", ctx do
      query = ExFff.Query.parse("user controller")
      results = Matcher.match(query, ctx.files_tab, ctx.trigram_tab, ctx.frecency_tab)

      paths = Enum.map(results, & &1.path)
      assert "lib/user_controller.ex" in paths
    end
  end
end
