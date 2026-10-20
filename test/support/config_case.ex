defmodule Cinder.ConfigCase do
  @moduledoc """
  Helper for tests that temporarily override an `:cinder` application-env key and
  restore it on exit.

  Test functions within a module run sequentially (ExUnit only parallelizes across
  async modules), so an override scoped to the test that owns the config key can't
  race another test.
  """

  @doc """
  Merges `overrides` onto the current `Application.get_env(:cinder, key)` and
  restores the original value when the test exits.
  """
  def put_config(key, overrides) do
    original = Application.get_env(:cinder, key)
    ExUnit.Callbacks.on_exit(fn -> Application.put_env(:cinder, key, original) end)
    Application.put_env(:cinder, key, Keyword.merge(original, overrides))
  end

  @doc """
  Sets `key` to `value` and restores the original value when the test exits, deleting the key
  when it was unset. For a value that is not a keyword list to merge into.
  """
  def put_env(key, value) do
    original = Application.fetch_env(:cinder, key)

    ExUnit.Callbacks.on_exit(fn ->
      case original do
        {:ok, original} -> Application.put_env(:cinder, key, original)
        :error -> Application.delete_env(:cinder, key)
      end
    end)

    Application.put_env(:cinder, key, value)
  end
end
