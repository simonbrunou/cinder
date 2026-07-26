defmodule Cinder.CodeHealthTest do
  @moduledoc """
  Guards against a single `lib/` file regrowing into an unreviewable mega-module
  (the trigger for the 2026-07-26 `Cinder.Catalog` split into
  `Cinder.Catalog.{Discovery,Grabs,SeriesCatalog,SceneNumbering,SeriesRefresh}`).
  """
  use ExUnit.Case, async: true

  @max_lines 1500

  test "no lib/ file exceeds #{@max_lines} lines" do
    offenders =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.map(fn path -> {path, path |> File.read!() |> String.split("\n") |> length()} end)
      |> Enum.filter(fn {_path, lines} -> lines > @max_lines end)

    assert offenders == [],
           "the following file(s) exceed #{@max_lines} lines — split it — see the " <>
             "Catalog.Grabs/Discovery/SeriesCatalog precedent:\n" <>
             Enum.map_join(offenders, "\n", fn {path, lines} -> "  #{path} (#{lines} lines)" end)
  end
end
