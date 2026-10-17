defmodule Handbean.MCP.ConfigLoaderTest do
  @moduledoc """
  Tests for MCP Config Loader.
  Covers: JSON parse, user+project merge, disabled filter, env:VAR, invalid JSON, name validation.
  """
  use ExUnit.Case, async: false
  alias Handbean.MCP.ConfigLoader

  @tmp_base Path.join(System.tmp_dir!(), "sigil_mcp_cfg_#{System.unique_integer([:positive])}")

  setup do
    File.mkdir_p!(@tmp_base)
    on_exit(fn -> File.rm_rf!(@tmp_base) end)
    {:ok, tmp: @tmp_base}
  end

  defp write_json(dir, filename, content) do
    File.mkdir_p!(dir)
    path = Path.join(dir, filename)
    File.write!(path, Jason.encode!(content) <> "\n")
    path
  end

  describe "parse" do
    test "parses .mcp.json in project directory" do
      project = Path.join(@tmp_base, "proj1")

      write_json(project, ".mcp.json", %{
        "mcpServers" => %{"filesystem" => %{"command" => "npx", "args" => ["-y", "server"]}}
      })

      {:ok, config} = ConfigLoader.load(user_config_path: nil, project: project)
      assert config.servers["filesystem"].command == "npx"
      assert config.servers["filesystem"].disabled == false
    end

    test "parses .handbean/mcp.json in project" do
      project = Path.join(@tmp_base, "proj2")

      write_json(Path.join(project, ".handbean"), "mcp.json", %{
        "mcpServers" => %{"srv" => %{"command" => "node", "args" => ["s.js"]}}
      })

      {:ok, config} = ConfigLoader.load(user_config_path: nil, project: project)
      assert Map.has_key?(config.servers, "srv")
    end

    test "returns empty config for missing files" do
      {:ok, config} =
        ConfigLoader.load(user_config_path: nil, project: Path.join(@tmp_base, "empty"))

      assert config.servers == %{}
      assert config.diagnostics == []
    end
  end

  describe "user + project merge" do
    test "loads default user config from ~/.handbean/mcp.json", %{tmp: tmp} do
      home = Path.join(tmp, "home")
      project_dir = Path.join(tmp, "default-user-proj")

      write_json(Path.join(home, ".handbean"), "mcp.json", %{
        "mcpServers" => %{"global" => %{"command" => "global-cmd", "args" => []}}
      })

      write_json(project_dir, ".mcp.json", %{
        "mcpServers" => %{"project" => %{"command" => "project-cmd", "args" => []}}
      })

      {:ok, config} = ConfigLoader.load(user_home: home, project: project_dir)

      assert config.servers["global"].command == "global-cmd"
      assert config.servers["project"].command == "project-cmd"
    end

    test "project overrides user for same server name" do
      user_dir = Path.join(@tmp_base, "user")
      project_dir = Path.join(@tmp_base, "proj")

      write_json(user_dir, "mcp.json", %{
        "mcpServers" => %{
          "shared" => %{"command" => "user-cmd", "args" => ["--user"]},
          "user-only" => %{"command" => "user-cmd", "args" => []}
        }
      })

      write_json(project_dir, ".mcp.json", %{
        "mcpServers" => %{
          "shared" => %{"command" => "project-cmd", "args" => ["--project"]},
          "project-only" => %{"command" => "proj-cmd", "args" => []}
        }
      })

      {:ok, config} =
        ConfigLoader.load(user_config_path: Path.join(user_dir, "mcp.json"), project: project_dir)

      assert config.servers["shared"].command == "project-cmd"
      assert config.servers["user-only"].command == "user-cmd"
      assert config.servers["project-only"].command == "proj-cmd"
    end

    test "explicit nil user_config_path disables default user config", %{tmp: tmp} do
      home = Path.join(tmp, "nil-user-home")
      project_dir = Path.join(tmp, "nil-user-proj")

      write_json(Path.join(home, ".handbean"), "mcp.json", %{
        "mcpServers" => %{"global" => %{"command" => "global-cmd", "args" => []}}
      })

      write_json(project_dir, ".mcp.json", %{
        "mcpServers" => %{"project" => %{"command" => "project-cmd", "args" => []}}
      })

      {:ok, config} =
        ConfigLoader.load(user_config_path: nil, user_home: home, project: project_dir)

      refute Map.has_key?(config.servers, "global")
      assert config.servers["project"].command == "project-cmd"
    end
  end

  describe "disabled filtering" do
    test "disabled: true servers not in active" do
      project = Path.join(@tmp_base, "dis")

      write_json(project, ".mcp.json", %{
        "mcpServers" => %{
          "active" => %{"command" => "echo"},
          "inactive" => %{"command" => "echo", "disabled" => true}
        }
      })

      {:ok, config} = ConfigLoader.load(user_config_path: nil, project: project)
      assert Map.has_key?(config.servers, "active")
      refute Map.has_key?(config.servers, "inactive")
    end
  end

  describe "env:VAR" do
    test "resolves env:VAR to runtime config" do
      System.put_env("HANDBEAN_TEST_TOKEN", "secret-value")
      project = Path.join(@tmp_base, "env1")

      write_json(project, ".mcp.json", %{
        "mcpServers" => %{
          "api" => %{
            "command" => "node",
            "env" => %{"TOKEN" => "env:HANDBEAN_TEST_TOKEN", "PLAIN" => "static"}
          }
        }
      })

      {:ok, config} = ConfigLoader.load(user_config_path: nil, project: project)
      assert config.servers["api"].runtime_env["TOKEN"] == "secret-value"
      assert config.servers["api"].runtime_env["PLAIN"] == "static"
      System.delete_env("HANDBEAN_TEST_TOKEN")
    end

    test "missing var becomes empty" do
      project = Path.join(@tmp_base, "env2")

      write_json(project, ".mcp.json", %{
        "mcpServers" => %{
          "m" => %{"command" => "e", "env" => %{"T" => "env:HANDBEAN_MISSING_XYZ"}}
        }
      })

      {:ok, config} = ConfigLoader.load(user_config_path: nil, project: project)
      assert config.servers["m"].runtime_env["T"] == ""
    end
  end

  describe "diagnostic safety" do
    test "invalid JSON returns diagnostic" do
      project = Path.join(@tmp_base, "bad")
      File.mkdir_p!(project)
      File.write!(Path.join(project, ".mcp.json"), "{not json")
      {:ok, config} = ConfigLoader.load(user_config_path: nil, project: project)
      assert length(config.diagnostics) >= 1
      assert hd(config.diagnostics).type == :error
    end

    test "diagnostics do not leak env values" do
      System.put_env("HANDBEAN_SECRET", "do-not-leak")
      project = Path.join(@tmp_base, "secret")

      write_json(project, ".mcp.json", %{
        "mcpServers" => %{"s" => %{"command" => "n", "env" => %{"K" => "env:HANDBEAN_SECRET"}}}
      })

      {:ok, config} = ConfigLoader.load(user_config_path: nil, project: project)

      for d <- config.diagnostics do
        refute inspect(d) =~ "do-not-leak"
      end

      System.delete_env("HANDBEAN_SECRET")
    end
  end

  describe "name validation" do
    test "valid names: lower, digits, hyphens, underscores" do
      project = Path.join(@tmp_base, "vn")

      write_json(project, ".mcp.json", %{
        "mcpServers" => %{
          "valid-name" => %{"command" => "e"},
          "valid_name" => %{"command" => "e"},
          "valid123" => %{"command" => "e"}
        }
      })

      {:ok, config} = ConfigLoader.load(user_config_path: nil, project: project)
      assert Map.has_key?(config.servers, "valid-name")
      assert Map.has_key?(config.servers, "valid_name")
      assert Map.has_key?(config.servers, "valid123")
    end

    test "empty server name returns diagnostic" do
      project = Path.join(@tmp_base, "en")
      write_json(project, ".mcp.json", %{"mcpServers" => %{"" => %{"command" => "e"}}})
      {:ok, config} = ConfigLoader.load(user_config_path: nil, project: project)
      refute Map.has_key?(config.servers, "")
      assert length(config.diagnostics) >= 1
    end

    test "missing command gets diagnostic" do
      project = Path.join(@tmp_base, "nc")
      write_json(project, ".mcp.json", %{"mcpServers" => %{"no-cmd" => %{"args" => ["x"]}}})
      {:ok, config} = ConfigLoader.load(user_config_path: nil, project: project)
      assert length(config.diagnostics) >= 1
    end
  end

  describe ".mcp.json + .handbean/mcp.json coexistence" do
    test ".handbean/mcp.json overrides .mcp.json for same server" do
      project = Path.join(@tmp_base, "coexist")

      write_json(project, ".mcp.json", %{
        "mcpServers" => %{
          "shared" => %{"command" => "from-mcp-json", "args" => ["a"]},
          "only-in-mcp" => %{"command" => "c1"}
        }
      })

      write_json(Path.join(project, ".handbean"), "mcp.json", %{
        "mcpServers" => %{
          "shared" => %{"command" => "from-handbean-json", "args" => ["b"]},
          "only-in-sigil" => %{"command" => "c2"}
        }
      })

      {:ok, config} = ConfigLoader.load(user_config_path: nil, project: project)

      assert config.servers["shared"].command == "from-handbean-json"
      assert config.servers["shared"].args == ["b"]
      assert Map.has_key?(config.servers, "only-in-mcp")
      assert Map.has_key?(config.servers, "only-in-sigil")
    end
  end

  describe "field validation edge cases" do
    test "uppercase server name is rejected" do
      project = Path.join(@tmp_base, "uc")
      write_json(project, ".mcp.json", %{"mcpServers" => %{"BadName" => %{"command" => "e"}}})
      {:ok, config} = ConfigLoader.load(user_config_path: nil, project: project)
      refute Map.has_key?(config.servers, "BadName")
      assert length(config.diagnostics) >= 1
      assert hd(config.diagnostics).type == :error
    end

    test "server name with space is rejected" do
      project = Path.join(@tmp_base, "sp")
      write_json(project, ".mcp.json", %{"mcpServers" => %{"bad name" => %{"command" => "e"}}})
      {:ok, config} = ConfigLoader.load(user_config_path: nil, project: project)
      refute Map.has_key?(config.servers, "bad name")
    end

    test "unknown fields are preserved in raw without blocking load" do
      project = Path.join(@tmp_base, "uf")

      write_json(project, ".mcp.json", %{
        "mcpServers" => %{
          "srv" => %{
            "command" => "echo",
            "custom_field" => "hello",
            "nested" => %{"key" => "val"}
          }
        }
      })

      {:ok, config} = ConfigLoader.load(user_config_path: nil, project: project)
      assert Map.has_key?(config.servers, "srv")
      assert config.servers["srv"].raw["custom_field"] == "hello"
      assert config.servers["srv"].raw["nested"] == %{"key" => "val"}
    end

    test "args non-list is rejected with diagnostic" do
      project = Path.join(@tmp_base, "ba")

      write_json(project, ".mcp.json", %{
        "mcpServers" => %{"b" => %{"command" => "e", "args" => "not-a-list"}}
      })

      {:ok, config} = ConfigLoader.load(user_config_path: nil, project: project)
      refute Map.has_key?(config.servers, "b")
      assert length(config.diagnostics) >= 1
      assert hd(config.diagnostics).type == :error
    end
  end

  describe "http / sse server configs" do
    test "url-based server is accepted without command" do
      project = Path.join(@tmp_base, "http1")

      write_json(project, ".mcp.json", %{
        "mcpServers" => %{
          "stepsearch" => %{
            "url" => "https://api.stepfun.com/step_plan/v1/mcp/web_search/mcp",
            "headers" => %{"Authorization" => "Bearer env:STEPFUN_API_KEY"}
          }
        }
      })

      {:ok, config} = ConfigLoader.load(user_config_path: nil, project: project)
      assert Map.has_key?(config.servers, "stepsearch")

      assert config.servers["stepsearch"].url ==
               "https://api.stepfun.com/step_plan/v1/mcp/web_search/mcp"

      assert config.servers["stepsearch"].command == nil
    end

    test "url server with env:VAR in headers resolves correctly" do
      System.put_env("HANDBEAN_HTTP_TOKEN", "http-token-value")
      project = Path.join(@tmp_base, "http2")

      write_json(project, ".mcp.json", %{
        "mcpServers" => %{
          "remote" => %{
            "url" => "http://localhost:4000/mcp",
            "headers" => %{"Authorization" => "Bearer env:HANDBEAN_HTTP_TOKEN"}
          }
        }
      })

      {:ok, config} = ConfigLoader.load(user_config_path: nil, project: project)
      assert config.servers["remote"].url == "http://localhost:4000/mcp"
      assert config.servers["remote"].headers["Authorization"] == "Bearer env:HANDBEAN_HTTP_TOKEN"
      System.delete_env("HANDBEAN_HTTP_TOKEN")
    end

    test "defaults exposure to deferred, accepts direct, and keeps nested as deferred" do
      project = Path.join(@tmp_base, "exposure_ok")

      write_json(project, ".mcp.json", %{
        "mcpServers" => %{
          "hidden" => %{"command" => "echo", "description" => "Search the docs"},
          "shown" => %{"command" => "printf", "exposure" => "direct"},
          "legacy" => %{"command" => "true", "exposure" => "nested"}
        }
      })

      {:ok, config} = ConfigLoader.load(user_config_path: nil, project: project)
      assert config.servers["hidden"].exposure == "deferred"
      assert config.servers["hidden"].description == "Search the docs"
      assert config.servers["shown"].exposure == "direct"
      assert config.servers["legacy"].exposure == "deferred"
      refute Map.has_key?(config.servers["hidden"].raw, "exposure")
      refute Map.has_key?(config.servers["hidden"].raw, "description")
    end

    test "invalid exposure fails config load" do
      project = Path.join(@tmp_base, "exposure_bad")

      write_json(project, ".mcp.json", %{
        "mcpServers" => %{"bad" => %{"command" => "echo", "exposure" => "public"}}
      })

      {:ok, config} = ConfigLoader.load(user_config_path: nil, project: project)
      refute Map.has_key?(config.servers, "bad")
      assert Enum.any?(config.diagnostics, &(&1.type == :error and &1.message =~ "exposure"))
    end

    test "server without command or url is rejected" do
      project = Path.join(@tmp_base, "no_transport")
      write_json(project, ".mcp.json", %{"mcpServers" => %{"neither" => %{"disabled" => false}}})
      {:ok, config} = ConfigLoader.load(user_config_path: nil, project: project)
      refute Map.has_key?(config.servers, "neither")
      assert length(config.diagnostics) >= 1
      assert hd(config.diagnostics).type == :error
    end

    test "http server diagnostics do not leak header values" do
      System.put_env("HANDBEAN_HTTP_SECRET", "do-not-leak")
      project = Path.join(@tmp_base, "http_leak")

      write_json(project, ".mcp.json", %{
        "mcpServers" => %{
          "s" => %{
            "url" => "http://localhost:4000/mcp",
            "headers" => %{"Authorization" => "Bearer env:HANDBEAN_HTTP_SECRET"}
          }
        }
      })

      {:ok, config} = ConfigLoader.load(user_config_path: nil, project: project)

      for d <- config.diagnostics do
        refute inspect(d) =~ "do-not-leak"
      end

      assert config.servers["s"].headers["Authorization"] == "Bearer env:HANDBEAN_HTTP_SECRET"
      System.delete_env("HANDBEAN_HTTP_SECRET")
    end
  end

  describe "mcpServers edge cases" do
    test "mcpServers not a map returns error diagnostic" do
      project = Path.join(@tmp_base, "nm")
      write_json(project, ".mcp.json", %{"mcpServers" => [1, 2, 3]})
      {:ok, config} = ConfigLoader.load(user_config_path: nil, project: project)
      assert config.servers == %{}
      assert length(config.diagnostics) >= 1
      assert hd(config.diagnostics).type == :error
    end

    test "diagnostics never include runtime_env values" do
      System.put_env("HANDBEAN_RT", "sensitive-rt")
      project = Path.join(@tmp_base, "rt")

      write_json(project, ".mcp.json", %{
        "mcpServers" => %{"s" => %{"command" => "n", "env" => %{"K" => "env:HANDBEAN_RT"}}}
      })

      {:ok, config} = ConfigLoader.load(user_config_path: nil, project: project)

      # diagnostics should never reference runtime_env values
      for d <- config.diagnostics do
        refute inspect(d) =~ "sensitive-rt"
      end

      # runtime_env should still be correct on the server config
      assert config.servers["s"].runtime_env["K"] == "sensitive-rt"
      System.delete_env("HANDBEAN_RT")
    end
  end
end
