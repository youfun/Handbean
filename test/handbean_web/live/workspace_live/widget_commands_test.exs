defmodule HandbeanWeb.WorkspaceLive.WidgetCommandsTest do
  use ExUnit.Case, async: true

  alias HandbeanWeb.WorkspaceLive.WidgetCommands

  @conversation_id "conversation-1"

  test "formats a prompt and typed selections as visible Markdown" do
    params =
      params(%{
        "prompt" => "Move the selected files after I review this draft.",
        "selections" => [
          %{"label" => "README.md", "value" => true},
          %{"label" => "Priority", "value" => 2},
          %{"label" => "Destination", "value" => "archive/docs"}
        ]
      })

    assert {:ok, text} = WidgetCommands.prefill_text(params, entry(), @conversation_id)

    assert text ==
             """
             Move the selected files after I review this draft.

             Selections:
             - "README.md": true
             - "Priority": 2
             - "Destination": "archive/docs"
             """
             |> String.trim_trailing()
  end

  test "accepts only zero-based indexes of closed html or widget fences" do
    content = """
    ```javascript
    console.log("ignored")
    ```

    ```html
    <button>one</button>
    ```

    ~~~~widget title=two
    <button>two</button>
    ~~~~

    ```html
    <button>unfinished</button>
    """

    valid_entry = entry(%{"content" => content})

    assert {:ok, "Follow up"} =
             WidgetCommands.prefill_text(
               params(%{"prompt" => "Follow up"}),
               valid_entry,
               @conversation_id
             )

    assert {:ok, "Follow up"} =
             WidgetCommands.prefill_text(
               params(%{"prompt" => "Follow up"}, %{"fence_index" => 1}),
               valid_entry,
               @conversation_id
             )

    assert {:error, :invalid_fence_index} =
             WidgetCommands.prefill_text(
               params(%{"prompt" => "Follow up"}, %{"fence_index" => 2}),
               valid_entry,
               @conversation_id
             )
  end

  test "ordinary untyped fences around a widget do not crash or affect its index" do
    content = """
    ```
    ordinary before
    ```

    ```widget
    <button>Continue</button>
    ```

    ```
    ordinary after
    ```
    """

    valid_entry = entry(%{"content" => content})

    assert {:ok, "Follow up"} =
             WidgetCommands.prefill_text(
               params(%{"prompt" => "Follow up"}),
               valid_entry,
               @conversation_id
             )

    assert {:error, :invalid_fence_index} =
             WidgetCommands.prefill_text(
               params(%{"prompt" => "Follow up"}, %{"fence_index" => 1}),
               valid_entry,
               @conversation_id
             )
  end

  test "counts closed widget fences inside nested blockquotes" do
    content = """
    > ~~~~HTML
    > <p>Quoted widget</p>
    > ~~~
    > ~~~~

    > > ```widget
    > > <button>Nested widget</button>
    > > ```
    """

    valid_entry = entry(%{"content" => content})

    for fence_index <- 0..1 do
      assert {:ok, "Follow up"} =
               WidgetCommands.prefill_text(
                 params(%{"prompt" => "Follow up"}, %{"fence_index" => fence_index}),
                 valid_entry,
                 @conversation_id
               )
    end

    assert {:error, :invalid_fence_index} =
             WidgetCommands.prefill_text(
               params(%{"prompt" => "Follow up"}, %{"fence_index" => 2}),
               valid_entry,
               @conversation_id
             )
  end

  test "rejects mismatched blockquote depth when closing a widget fence" do
    content = """
    > ```html
    > <p>Still open</p>
    ```
    """

    assert {:error, :invalid_fence_index} =
             WidgetCommands.prefill_text(
               params(%{"prompt" => "Follow up"}),
               entry(%{"content" => content}),
               @conversation_id
             )
  end

  test "rejects entries outside the current completed main assistant message" do
    params = params(%{"prompt" => "Follow up"})

    assert {:error, :entry_not_found} =
             WidgetCommands.prefill_text(params, nil, @conversation_id)

    assert {:error, :invalid_entry} =
             WidgetCommands.prefill_text(
               params,
               entry(%{"conversation_id" => "another-conversation"}),
               @conversation_id
             )

    assert {:error, :invalid_entry} =
             WidgetCommands.prefill_text(
               params,
               entry(%{"role" => "user", "content_type" => "user_msg"}),
               @conversation_id
             )

    assert {:error, :invalid_entry} =
             WidgetCommands.prefill_text(
               params,
               entry(%{"content_type" => "subagent_report"}),
               @conversation_id
             )

    assert {:error, :incomplete_entry} =
             WidgetCommands.prefill_text(
               params,
               entry(%{"status" => "streaming"}),
               @conversation_id
             )
  end

  test "requires an exact bounded request envelope" do
    payload = %{"prompt" => "Follow up"}

    assert {:error, :invalid_request} =
             WidgetCommands.prefill_text(
               params(payload, %{"unexpected" => true}),
               entry(),
               @conversation_id
             )

    assert {:error, :invalid_request} =
             WidgetCommands.prefill_text(
               params(payload, %{"request_id" => String.duplicate("r", 257)}),
               entry(),
               @conversation_id
             )

    assert {:error, :invalid_request} =
             WidgetCommands.prefill_text(
               params(payload, %{"entry_id" => String.duplicate("e", 257)}),
               entry(),
               @conversation_id
             )

    request_id = String.duplicate("r", 256)
    entry_id = String.duplicate("e", 256)

    assert {:ok, "Follow up"} =
             WidgetCommands.prefill_text(
               params(payload, %{"request_id" => request_id, "entry_id" => entry_id}),
               entry(%{"id" => entry_id}),
               @conversation_id
             )
  end

  test "rejects unknown commands" do
    assert {:error, :unknown_command} =
             WidgetCommands.prefill_text(
               params(%{"prompt" => "Follow up"}, %{"command" => "open_external"}),
               entry(),
               @conversation_id
             )
  end

  test "enforces the encoded 8 KiB payload limit" do
    overhead = byte_size(Handbean.JSON.encode!(%{"prompt" => ""}))
    exact_prompt = String.duplicate("a", 8 * 1024 - overhead)

    assert byte_size(Handbean.JSON.encode!(%{"prompt" => exact_prompt})) == 8 * 1024

    assert {:ok, ^exact_prompt} =
             WidgetCommands.prefill_text(
               params(%{"prompt" => exact_prompt}),
               entry(),
               @conversation_id
             )

    assert {:error, :payload_too_large} =
             WidgetCommands.prefill_text(
               params(%{"prompt" => exact_prompt <> "a"}),
               entry(),
               @conversation_id
             )
  end

  test "rejects fields and selection values outside the payload schema" do
    assert {:error, :invalid_payload} =
             WidgetCommands.prefill_text(
               params(%{"prompt" => "Follow up", "hidden" => "model payload"}),
               entry(),
               @conversation_id
             )

    assert {:error, :invalid_payload} =
             WidgetCommands.prefill_text(
               params(%{
                 "prompt" => "Follow up",
                 "selections" => [%{"label" => "Item", "value" => nil}]
               }),
               entry(),
               @conversation_id
             )

    assert {:error, :invalid_payload} =
             WidgetCommands.prefill_text(
               params(%{
                 "prompt" => "Follow up",
                 "selections" => List.duplicate(%{"label" => "Item", "value" => true}, 101)
               }),
               entry(),
               @conversation_id
             )
  end

  defp params(payload, overrides \\ %{}) do
    Map.merge(
      %{
        "request_id" => "request-1",
        "entry_id" => "assistant-1",
        "fence_index" => 0,
        "command" => "prefill_follow_up",
        "payload" => payload
      },
      overrides
    )
  end

  defp entry(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "assistant-1",
        "conversation_id" => @conversation_id,
        "role" => "assistant",
        "content_type" => "assistant_msg",
        "status" => "completed",
        "content" => """
        ```html
        <button>Continue</button>
        ```
        """
      },
      overrides
    )
  end
end
