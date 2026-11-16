defmodule Cinder.ConfigCaseTest do
  # put_config/2 writes the application env, which other async modules read.
  use ExUnit.Case, async: false

  import Cinder.AnimeFixtures, only: [neutral_anime_policy: 1]

  alias Cinder.ConfigCase

  # #839: the policy compares a release's normalized group with the groups as stored, so a test
  # that set "Trusted" matched no release and passed with the group rule removed.
  describe "put_config/2 for :anime_preferences" do
    test "refuses preferred groups that Cinder.Settings would store otherwise" do
      assert_raise ArgumentError, ~r/preferred_groups: \["Trusted"\].*pass \["trusted"\]/, fn ->
        ConfigCase.put_config(:anime_preferences, preferred_groups: ["Trusted"])
      end
    end

    test "refuses blocked groups that Cinder.Settings would store otherwise" do
      for groups <- [[" bad"], ["bad", "bad"], ["bad", ""]] do
        assert_raise ArgumentError, ~r/blocked_groups: /, fn ->
          ConfigCase.put_config(:anime_preferences, blocked_groups: groups)
        end
      end
    end

    test "sets groups given as Cinder.Settings stores them" do
      ConfigCase.put_config(:anime_preferences, preferred_groups: ["trusted"], blocked_groups: [])

      env = Application.fetch_env!(:cinder, :anime_preferences)
      assert env[:preferred_groups] == ["trusted"]
      assert env[:blocked_groups] == []
    end

    test "sets other slots without reading the groups" do
      ConfigCase.put_config(:anime_preferences, group_fallback_delay: 60)

      assert Application.fetch_env!(:cinder, :anime_preferences)[:group_fallback_delay] == 60
    end
  end

  test "put_config/2 leaves other keys' groups alone" do
    original = Application.get_env(:cinder, Cinder.Catalog.UpgradeHunter, [])
    ConfigCase.put_config(Cinder.Catalog.UpgradeHunter, preferred_groups: ["Trusted"])

    assert Application.fetch_env!(:cinder, Cinder.Catalog.UpgradeHunter) ==
             Keyword.merge(original, preferred_groups: ["Trusted"])
  end

  test "neutral_anime_policy/1 refuses groups as put_config/2 does" do
    assert_raise ArgumentError, ~r/^neutral_anime_policy\/1: preferred_groups: /, fn ->
      neutral_anime_policy(preferred_groups: ["Trusted"])
    end

    assert neutral_anime_policy(blocked_groups: ["bad"]).blocked_groups == ["bad"]
  end
end
