defmodule Cinder.Indexers.Definitions.LoaderAtomTest do
  # The atom count is VM-wide, so this module runs alone, after the async modules. A warm-up
  # load first loads every module the loader calls, which adds atoms of their own.
  use ExUnit.Case, async: false

  alias Cinder.Indexers.Definitions.Loader

  @base """
  ---
  id: cindertest
  name: Cinder Test
  description: Written for Cinder's tests
  language: en-US
  type: public
  encoding: UTF-8
  links:
    - https://tracker.invalid/
  caps:
    modes:
      search: [q]
    categorymappings:
      - {id: 1, cat: Movies}
  search:
    rows:
      selector: tr
    fields:
      title:
        selector: a
  """

  # Each case's keys and values hold names no other code in the VM uses, built from a unique
  # integer so that this file's source holds none of them either.
  defp unseen(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}_zq"

  defp loads do
    key = unseen("key")
    value = unseen("value")

    [
      {@base <>
         """
         #{key}: #{value}
         settings:
           - {name: #{unseen("setting")}, type: #{unseen("type")}, default: #{unseen("default")}}
         login: {method: #{unseen("method")}}
         """, :ok},
      {String.replace(
         @base,
         "    title:\n",
         "    #{unseen("field")}:\n      selector: x\n    title:\n"
       ), :ok},
      {@base <> "#{unseen("anchor")}: &#{unseen("name")} 1\n", :yaml_anchor},
      {@base <> "#{unseen("alias")}: *#{unseen("name")}\n", :yaml_alias},
      {@base <> "#{unseen("tag")}: !#{unseen("tag")} x\n", :yaml_tag},
      {"%#{unseen("directive")} x\n" <> @base, :yaml_directive},
      {"%TAG !h#{System.unique_integer([:positive])}zq! tag:#{unseen("prefix")}:\n" <> @base,
       :yaml_directive}
    ]
  end

  test "no load adds an atom, whether it loads or refuses the file" do
    for {text, _outcome} <- loads(), do: Loader.load(text)

    for {text, outcome} <- loads() do
      before = :erlang.system_info(:atom_count)
      result = Loader.load(text)
      after_load = :erlang.system_info(:atom_count)

      case outcome do
        :ok -> assert {:ok, _definition} = result
        reason -> assert result == {:error, reason}
      end

      assert {text, after_load - before} == {text, 0}
    end
  end
end
