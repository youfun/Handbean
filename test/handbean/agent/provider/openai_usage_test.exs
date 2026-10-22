defmodule Handbean.Agent.Provider.OpenAIUsageTest do
  use ExUnit.Case, async: false

  setup do
    Req.Test.stub(__MODULE__, nil)
    :ok
  end

  describe "openai usage cache writes" do
    # Parser contract:
    # - Responses: input_tokens_details.cache_write_tokens
    # - Chat Completions: prompt_tokens_details.cache_write_tokens
    # - input_tokens already includes reads and writes; do not add the write again
    # - an explicit 0 is kept; a missing field stays 0
    test "keeps GPT-5.6 cache writes without changing the inclusive input total" do
      responses =
        Handbean.Agent.Provider.openai_usage(%{
          "input_tokens" => 2600,
          "output_tokens" => 10,
          "input_tokens_details" => %{"cached_tokens" => 2000, "cache_write_tokens" => 400}
        })

      chat =
        Handbean.Agent.Provider.openai_usage(%{
          "prompt_tokens" => 2600,
          "completion_tokens" => 10,
          "prompt_tokens_details" => %{"cached_tokens" => 2000, "cache_write_tokens" => 400}
        })

      for usage <- [responses, chat] do
        assert usage.input_tokens == 2600
        assert usage.total_input_tokens == 2600
        assert usage.cache_read_input_tokens == 2000
        assert usage.cache_creation_input_tokens == 400
      end

      explicit_zero =
        Handbean.Agent.Provider.openai_usage(%{
          "input_tokens" => 10,
          "input_tokens_details" => %{"cached_tokens" => 0, "cache_write_tokens" => 0},
          "cache_creation_input_tokens" => 99
        })

      assert explicit_zero.cache_creation_input_tokens == 0

      missing =
        Handbean.Agent.Provider.openai_usage(%{
          "input_tokens" => 10,
          "input_tokens_details" => %{"cached_tokens" => 4}
        })

      assert missing.cache_creation_input_tokens == 0
    end
  end
end
