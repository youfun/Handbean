defmodule HandbeanWeb.FeatureCase do
  @moduledoc """
  This module defines the test case to be used by
  PhoenixTest feature tests.

  Uses PhoenixTest for unified feature testing regardless of
  whether pages are LiveView or static.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use HandbeanWeb, :verified_routes

      import HandbeanWeb.FeatureCase
      import PhoenixTest

      @endpoint HandbeanWeb.Endpoint
    end
  end

  setup tags do
    Handbean.DataCase.setup_sandbox(tags)

    conn =
      Phoenix.ConnTest.build_conn()
      |> Map.put(:host, "localhost")
      |> HandbeanWeb.ConnCase.authenticate()

    {:ok, conn: conn}
  end
end
