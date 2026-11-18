defmodule Cinder.TestPartitionDatabaseTest do
  # Sets MIX_TEST_PARTITION for the length of a test, so no other test runs beside it.
  use ExUnit.Case, async: false

  # Each partition of a bare `mix test` needs its own SQLite file (#1473): one file shared by
  # several processes fails their writes with "database busy".
  test "config/test.exs names the database after MIX_TEST_PARTITION" do
    previous = System.get_env("MIX_TEST_PARTITION")
    on_exit(fn -> restore("MIX_TEST_PARTITION", previous) end)

    System.put_env("MIX_TEST_PARTITION", "3")
    assert Path.basename(database()) == "cinder_test3.db"

    System.delete_env("MIX_TEST_PARTITION")
    assert Path.basename(database()) == "cinder_test.db"
  end

  defp database do
    "config/test.exs"
    |> Config.Reader.read!(env: :test)
    |> get_in([:cinder, Cinder.Repo, :database])
  end

  defp restore(name, nil), do: System.delete_env(name)
  defp restore(name, value), do: System.put_env(name, value)
end
