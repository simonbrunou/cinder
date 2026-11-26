defmodule Cinder.Indexers.Parity.PicksTest do
  use ExUnit.Case, async: true

  alias Cinder.Acquisition.Release
  alias Cinder.Indexers.Parity.Picks

  describe "key/2" do
    test "a release's key reads a missing size as 0" do
      nil_size = Picks.key({:ok, %Release{title: "Dune.2021.1080p.WEB-DL-AAA", size: nil}}, [])
      assert {:release, {"Dune.2021.1080p.WEB-DL-AAA", 0, _rank}} = nil_size
    end

    test "books: the multiset of accepted {title, size} and the first accepted" do
      a = %{title: "A", size: 1}
      b = %{title: "B", size: nil}

      assert Picks.key({:books, [a, b]}, []) == {:books, [{"A", 1}, {"B", 0}], {"A", 1}}
      # The same set with another top differs, and so does another set with the same top.
      refute Picks.key({:books, [b, a]}, []) == Picks.key({:books, [a, b]}, [])
      refute Picks.key({:books, [a, a]}, []) == Picks.key({:books, [a, b]}, [])
      assert Picks.key({:books, []}, []) == {:books, [], nil}
    end

    test "a group wait compares its episodes and its end to the second" do
      wait = fn ids, at -> {:waiting_for_preferred_group, %{episode_ids: ids, retry_at: at}} end
      at = ~U[2026-11-25 10:00:00Z]
      micro = ~U[2026-11-25 10:00:00.000000Z]

      assert Picks.key(wait.([2, 1], at), []) == {:waiting, {[1, 2], at}}
      assert Picks.key(wait.([1], at), []) == Picks.key(wait.([1], micro), [])
      refute Picks.key(wait.([1], at), []) == Picks.key(wait.([1], DateTime.add(at, 1)), [])
      refute Picks.key(wait.([1], at), []) == Picks.key(wait.([2], at), [])
    end

    test "an error keeps only its closed tag" do
      assert Picks.key({:error, {:http_status, 401}}, []) == {:error, {:http_status, 401}}
      assert Picks.key({:error, {:raw, "https://x?apikey=k"}}, []) == {:error, :raw}
      assert Picks.key({:error, "https://x?apikey=k"}, []) == {:error, :other}
    end
  end

  describe "tag/1" do
    test "keeps an atom and an {atom, integer} pair, the leading atom of another tuple, else :other" do
      assert Picks.tag(:timeout) == :timeout
      assert Picks.tag({:http_status, 503}) == {:http_status, 503}
      assert Picks.tag({:http_status, "503"}) == :http_status
      assert Picks.tag({:failed, :timeout, "x"}) == :failed
      assert Picks.tag({"x", 1}) == :other
      assert Picks.tag(%{reason: :x}) == :other
    end
  end
end
