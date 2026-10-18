defmodule Handbean.CsvProfile.Error do
  @moduledoc "Structured CSV profiling errors."

  defexception [:code, :message, :path]

  @impl true
  def exception(opts) do
    code = Keyword.fetch!(opts, :code)
    message = Keyword.fetch!(opts, :message)
    path = Keyword.get(opts, :path)
    %__MODULE__{code: code, message: message, path: path}
  end
end
