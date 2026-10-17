defmodule Handbean.ErrorTrackerFilterTest do
  use ExUnit.Case, async: true

  alias Handbean.ErrorTrackerFilter

  test "drops request and LiveView payloads while redacting retained context" do
    context = %{
      "live_view.event" => "submit_message",
      "live_view.event_params" => %{"message" => "private prompt"},
      "request.params" => %{"attachment" => "private contents"},
      "request.headers" => %{"authorization" => "Bearer secret"},
      "request.path" => "/w/workspace/c/conversation"
    }

    assert ErrorTrackerFilter.sanitize(context) == %{
             "live_view.event" => "submit_message",
             "request.headers" => %{"authorization" => "[REDACTED]"},
             "request.path" => "/w/workspace/c/conversation"
           }
  end
end
