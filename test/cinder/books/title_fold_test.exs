defmodule Cinder.Books.TitleFoldTest do
  use ExUnit.Case, async: true

  alias Cinder.Books.TitleFold

  describe "tokens/1" do
    test "folds diacritics so accented and unaccented spellings compare equal" do
      assert TitleFold.tokens("Les Misérables") == TitleFold.tokens("Les Miserables")
    end

    test "drops apostrophes rather than splitting on them" do
      assert TitleFold.tokens("Ender's Game") == ["enders", "game"]
    end

    test "nil folds to no tokens" do
      assert TitleFold.tokens(nil) == []
    end

    test "malformed UTF-8 does not raise" do
      assert is_list(TitleFold.tokens(<<0xFF, 0xFE>> <> "Beloved"))
    end
  end

  describe "lossy?/1" do
    # This guard is the whole reason the fold and its check live together: BookScorer once had
    # the fold WITHOUT this, and two unrelated volume-numbered works both folded to ["1"].
    test "non-Latin script is lossy" do
      assert TitleFold.lossy?("ノルウェイの森 1")
      assert TitleFold.lossy?("Война и мир")
      assert TitleFold.lossy?("Straße")
    end

    test "combining marks are not lossy — they are what the fold is meant to drop" do
      refute TitleFold.lossy?("Les Misérables")
      refute TitleFold.lossy?("Beloved")
    end

    test "nil is not lossy" do
      refute TitleFold.lossy?(nil)
    end

    test "two different non-Latin titles fold to the same residue" do
      # The concrete failure the guard exists to prevent.
      assert TitleFold.tokens("ノルウェイの森 1") == TitleFold.tokens("海辺のカフカ 1")
      assert TitleFold.lossy?("ノルウェイの森 1")
    end
  end

  describe "drop_article/1" do
    test "drops one leading article" do
      assert TitleFold.drop_article(["the", "little", "prince"]) == ["little", "prince"]
    end

    test "drops at most one" do
      assert TitleFold.drop_article(["the", "a", "team"]) == ["a", "team"]
    end

    test "never drops the only token" do
      assert TitleFold.drop_article(["the"]) == ["the"]
    end

    test "leaves a non-article alone" do
      assert TitleFold.drop_article(["dune"]) == ["dune"]
    end
  end
end
