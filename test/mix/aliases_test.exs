defmodule Cinder.MixAliasesTest do
  # `mix test` is the only "done" gate, and `mix test.unchecked` is the same run without its
  # gates, for red runs and mutation checks (docs/agents/testing.md). What each alias does was
  # checked by hand on #851; these tests pin the definitions that behaviour rests on.
  use ExUnit.Case, async: true

  alias Mix.Tasks.Test

  test "the test alias runs its three gates before ExUnit" do
    assert Mix.Project.config()[:aliases][:test] |> Enum.take(3) == [
             "compile --warnings-as-errors",
             "format --check-formatted",
             "credo --strict"
           ]

    assert List.last(Mix.Project.config()[:aliases][:test]) == "test --warnings-as-errors"
  end

  test "test.unchecked runs no gate and calls the ExUnit task itself" do
    entries = Mix.Project.config()[:aliases][:"test.unchecked"]
    tasks = for entry <- entries, is_binary(entry), do: entry |> OptionParser.split() |> hd()

    # A "test" entry would resolve to the gated alias, gates included.
    assert tasks == ["ecto.create", "ecto.migrate"]
    assert List.last(entries) == (&Test.run/1)
  end

  test "test.unchecked runs in the test env without MIX_ENV" do
    assert Mix.Project.get!().cli()[:preferred_envs][:"test.unchecked"] == :test
  end
end
