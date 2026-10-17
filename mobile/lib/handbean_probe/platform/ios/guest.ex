defmodule HandbeanProbe.Platform.IOS.Guest do
  @moduledoc """
  In-process iSH guest boundary for the iOS host.

  The guest is a static library inside the one Mach-O. It is not a second
  process and it does not replace the host BEAM. Commands run only after the
  native boot path is linked; until then this module reports that the guest
  is absent.
  """

  @type result :: %{
          required(:exit_code) => integer(),
          required(:output) => String.t(),
          optional(:error_output) => String.t()
        }

  @doc """
  Run one command in the already-booted guest.

  `root` is the extracted Alpine fakefs. A missing native implementation is
  `:guest_not_linked`, not a host shell.
  """
  @spec exec(String.t(), String.t(), timeout :: pos_integer()) ::
          {:ok, result()}
          | {:error, :guest_not_linked | :guest_not_booted | :guest_exec_failed | :invalid_command}
  def exec(command, root, timeout_ms)
      when is_binary(command) and command != "" and is_binary(root) and is_integer(timeout_ms) and
             timeout_ms > 0 do
    if linked?() do
      native_exec(timeout_ms, root, command)
    else
      {:error, :guest_not_linked}
    end
  end

  def exec(_, _, _), do: {:error, :invalid_command}

  @doc "True only when this binary was linked with the iSH static archives."
  @spec linked?() :: boolean()
  def linked? do
    Application.get_env(:handbean_probe, :ios_guest_linked, false) == true or nif_linked?()
  end

  defp nif_linked? do
    Code.ensure_loaded?(:handbean_ios) and function_exported?(:handbean_ios, :guest_linked, 0) and
      :handbean_ios.guest_linked() == :ok
  rescue
    _ -> false
  end

  defp native_exec(timeout_ms, root, command) do
    case :handbean_ios.guest_exec(timeout_ms, root, command) do
      {:ok, exit_code, output} when is_integer(exit_code) and is_list(output) ->
        {:ok, %{exit_code: exit_code, output: to_string(output)}}

      {:error, reason} when is_atom(reason) ->
        {:error, reason}

      _ ->
        {:error, :guest_exec_failed}
    end
  rescue
    UndefinedFunctionError -> {:error, :guest_not_linked}
  end
end
