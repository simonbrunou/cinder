defmodule Cinder.Indexers.SecretsTest do
  use ExUnit.Case, async: true

  alias Cinder.Indexers.{ConfiguredIndexer, Secrets}
  alias Cinder.SecretCodec

  # No type stores two secrets yet, so these cases name a second field to reach the rule that an
  # undecryptable row takes a secret save only when it sets or clears every field.
  @fields ["api_key", "passkey"]

  describe "merge/3 on secrets that do not decrypt" do
    test "a save that sets or clears every field writes those values" do
      assert Secrets.merge(:unreadable, %{"api_key" => "a", "passkey" => "p"}, @fields) ==
               {:changed, %{"api_key" => "a", "passkey" => "p"}, @fields}

      assert Secrets.merge(:unreadable, %{"api_key" => "a", "clear_passkey" => "true"}, @fields) ==
               {:changed, %{"api_key" => "a"}, @fields}

      assert Secrets.merge(
               :unreadable,
               %{"clear_api_key" => "on", "clear_passkey" => "1"},
               @fields
             ) == {:changed, %{}, @fields}
    end

    test "a save that sets or clears only some fields is refused" do
      for input <- [
            %{"api_key" => "a"},
            %{"clear_passkey" => "true"},
            %{"api_key" => "a", "passkey" => " "}
          ] do
        assert {input, Secrets.merge(:unreadable, input, @fields)} ==
                 {input, {:error, :unreadable}}
      end
    end

    test "an input that sets and clears nothing leaves them unchanged" do
      assert Secrets.merge(:unreadable, %{"api_key" => "", "clear_passkey" => "false"}, @fields) ==
               :unchanged

      assert Secrets.merge(:unreadable, %{}, @fields) == :unchanged
    end
  end

  describe "merge/3 on readable secrets" do
    test "merges the changed field and keeps the others" do
      stored = {:ok, %{"api_key" => "a", "passkey" => "p"}}

      assert Secrets.merge(stored, %{"passkey" => "q"}, @fields) ==
               {:changed, %{"api_key" => "a", "passkey" => "q"}, ["passkey"]}

      assert Secrets.merge(stored, %{"clear_api_key" => "true"}, @fields) ==
               {:changed, %{"passkey" => "p"}, ["api_key"]}
    end

    test "a value equal to the stored one counts as a set" do
      assert Secrets.merge({:ok, %{"api_key" => "a"}}, %{"api_key" => "a"}, @fields) ==
               {:changed, %{"api_key" => "a"}, ["api_key"]}
    end

    test "a blank and a clear of an absent field change nothing" do
      assert Secrets.merge({:ok, %{"api_key" => "a"}}, %{"passkey" => ""}, @fields) == :unchanged

      assert Secrets.merge({:ok, %{"api_key" => "a"}}, %{"clear_passkey" => "true"}, @fields) ==
               :unchanged
    end

    test "drops a stored field the type no longer declares on a secret save" do
      assert Secrets.merge({:ok, %{"old" => "x"}}, %{"api_key" => "a"}, @fields) ==
               {:changed, %{"api_key" => "a"}, ["api_key", "old"]}
    end

    test "takes atom keys as their string names" do
      assert Secrets.merge({:ok, %{}}, %{api_key: "a"}, @fields) ==
               {:changed, %{"api_key" => "a"}, ["api_key"]}
    end

    test "refuses an unknown field, a key that is neither a string nor an atom, an unknown clear flag and a value that is not text" do
      for input <- [
            %{"cookie" => "x"},
            %{{:api_key} => "x"},
            %{1 => "x"},
            %{"clear_cookie" => "true"},
            %{"api_key" => 1},
            %{"api_key" => <<0xFF, "key">>}
          ] do
        assert {input, Secrets.merge({:ok, %{}}, input, @fields)} == {input, {:error, :invalid}}
      end
    end
  end

  describe "seal/2 and open/1" do
    test "round-trip a row's values; no values seal to nil" do
      ciphertext = Secrets.seal(7, %{"api_key" => "a"})

      assert Secrets.open(%ConfiguredIndexer{id: 7, secrets_ciphertext: ciphertext}) ==
               {:ok, %{"api_key" => "a"}}

      assert Secrets.seal(7, %{}) == nil
      assert Secrets.open(%ConfiguredIndexer{id: 7, secrets_ciphertext: nil}) == {:ok, %{}}
    end

    test "another row's ciphertext opens as unreadable" do
      ciphertext = Secrets.seal(7, %{"api_key" => "a"})

      assert Secrets.open(%ConfiguredIndexer{id: 8, secrets_ciphertext: ciphertext}) ==
               :unreadable
    end

    test "an envelope with another key, a float id, or opened on a row with no id is unreadable" do
      seal = &SecretCodec.encode(Jason.encode!(&1))
      values = %{"api_key" => "a"}

      for envelope <- [
            %{"scope" => "indexer_secrets", "id" => 7, "values" => values, "extra" => 1},
            %{"scope" => "indexer_secrets", "id" => 7.0, "values" => values}
          ] do
        ciphertext = seal.(envelope)

        assert {envelope, Secrets.open(%ConfiguredIndexer{id: 7, secrets_ciphertext: ciphertext})} ==
                 {envelope, :unreadable}
      end

      ciphertext = seal.(%{"scope" => "indexer_secrets", "id" => nil, "values" => values})

      assert Secrets.open(%ConfiguredIndexer{id: nil, secrets_ciphertext: ciphertext}) ==
               :unreadable
    end
  end
end
