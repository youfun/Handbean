defmodule HandbeanWeb.ErrorDiagnosticsController do
  use HandbeanWeb, :controller
  use Gettext, backend: Handbean.Gettext

  alias Handbean.Diagnostics.ErrorExport

  def download(conn, params) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    case ErrorExport.build(params) do
      {:ok, document} ->
        send_download(conn, {:binary, Handbean.JSON.encode!(document)},
          filename: "handbean-error-diagnostics.json",
          content_type: "application/json"
        )

      {:error, :invalid_filters} ->
        conn
        |> put_flash(:error, gettext("Choose a valid diagnostic time range and status."))
        |> redirect(to: ~p"/settings?tab=local_webgpu")

      {:error, _reason} ->
        conn
        |> put_flash(:error, gettext("Could not export error diagnostics. Please try again."))
        |> redirect(to: ~p"/settings?tab=local_webgpu")
    end
  end
end
