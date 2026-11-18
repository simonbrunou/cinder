defmodule Cinder.Download.SourceRemovalTest do
  # The behaviour of these functions is tested where their callers drive them, mostly in
  # `Cinder.Download.MoveOnImportTest`. This file pins where they live (#1447): callers call
  # `Cinder.Download.SourceRemoval` directly, and `Cinder.Download` keeps no copy or delegate.
  use ExUnit.Case, async: true

  alias Cinder.Download.SourceRemoval

  @moved [
    remove_after_import: 3,
    remove_after_import: 4,
    move_on_import_removal?: 1,
    fallback_remove: 2,
    fallback_remove: 3,
    retire_book_grab: 1,
    release_imported_book_grab: 1,
    best_effort_delete_source: 1,
    best_effort_remove: 2
  ]

  test "Cinder.Download.SourceRemoval defines every source-removal function" do
    exported = SourceRemoval.__info__(:functions)
    assert Enum.reject(@moved, &(&1 in exported)) == []
  end

  test "Cinder.Download keeps no source-removal function, delegate or not" do
    exported = Cinder.Download.__info__(:functions)
    names = @moved |> Keyword.keys() |> Enum.uniq()
    assert Enum.filter(exported, fn {name, _arity} -> name in names end) == []
  end
end
