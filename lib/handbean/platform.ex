defmodule Handbean.Platform do
  @moduledoc """
  Cross-platform detection and environment helpers.

  Provides os-type detection without shell commands,
  and env-var key normalization for Windows/Unix differences.
  """

  @doc """
  Returns true on Windows (win32).
  """
  @spec windows?() :: boolean()
  def windows? do
    match?({:win32, _}, :os.type())
  end

  @doc """
  Returns true on Unix-like systems (including macOS).
  """
  @spec unix?() :: boolean()
  def unix? do
    match?({:unix, _}, :os.type())
  end

  @doc """
  Returns the raw os.type tuple.
  """
  @spec os_type() :: {:unix | :win32, atom()}
  def os_type do
    :os.type()
  end

  @doc """
  Returns the PATH environment variable key for the current env.

  Windows may use `Path` or `path`; Unix uses `PATH`.
  Tries `PATH` → `Path` → `path` → `PATH` (fallback).
  """
  @spec path_env_key(map()) :: String.t()
  def path_env_key(env \\ System.get_env()) do
    cond do
      Map.has_key?(env, "PATH") -> "PATH"
      Map.has_key?(env, "Path") -> "Path"
      Map.has_key?(env, "path") -> "path"
      true -> "PATH"
    end
  end

  @doc """
  Returns the value of the PATH environment variable.
  """
  @spec path_env(map()) :: String.t()
  def path_env(env \\ System.get_env()) do
    Map.get(env, path_env_key(env), "")
  end
end
