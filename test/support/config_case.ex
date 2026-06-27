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
end
