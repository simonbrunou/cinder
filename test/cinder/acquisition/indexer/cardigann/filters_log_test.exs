defmodule Cinder.Acquisition.Indexer.Cardigann.FiltersLogTest do
  # `async: false`: the test lets `:debug` lines of `Filters` through the Logger, which is
  # process-global (docs/agents/testing.md).
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  require Logger

  alias Cinder.Acquisition.Indexer.Cardigann.Filters

  setup do
    Logger.put_module_level(Filters, :debug)
    on_exit(fn -> Logger.delete_module_level(Filters) end)
  end

  test "hexdump and strdump log nothing, so nothing of their input, a passkey included" do
    secret = "Zx9passkeyQ"
    filters = [%{name: "hexdump", args: nil}, %{name: "strdump", args: "tag"}]

    log =
      capture_log([level: :debug], fn ->
        assert Filters.apply(secret, filters, %{}, ~U[2026-11-25 19:45:30Z]) == {:ok, secret}
      end)

    assert log == ""
  end

  test "a :debug line of a module let through reaches the captured log" do
    Logger.put_module_level(__MODULE__, :debug)
    on_exit(fn -> Logger.delete_module_level(__MODULE__) end)

    assert capture_log([level: :debug], fn -> Logger.debug("control line") end) =~
             "control line"
  end
end
