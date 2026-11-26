defmodule Cinder.ConfigCaseTest do
  # put_config/2 writes the application env, which other async modules read.
  use ExUnit.Case, async: false

  import Cinder.AnimeFixtures, only: [neutral_anime_policy: 1]

  alias Cinder.ConfigCase
  alias Cinder.Settings.Overlay

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

  # #823: the private copies these replaced read with `get_env`, so they either put `nil` back
  # for a key that was unset or deleted a key that was set to `nil`.
  describe "restoring :cinder env keys on exit" do
    @unset :config_case_test_unset
    @set :config_case_test_set
    @set_nil :config_case_test_set_nil

    # Registered first, so it runs after the test's own callbacks (ExUnit runs them last first).
    setup do
      Application.delete_env(:cinder, @unset)
      Application.put_env(:cinder, @set, :before)
      Application.put_env(:cinder, @set_nil, nil)
      on_exit(fn -> Enum.each([@unset, @set, @set_nil], &Application.delete_env(:cinder, &1)) end)
    end

    test "put_env/2 deletes an unset key and gives a set key back its value, nil included" do
      assert_restored_on_exit([@unset, @set, @set_nil])
      Enum.each([@unset, @set, @set_nil], &ConfigCase.put_env(&1, :during))

      assert Application.fetch_env(:cinder, @unset) == {:ok, :during}
    end

    test "put_env/1 restores each key on its own" do
      assert_restored_on_exit([@unset, @set, @set_nil])
      ConfigCase.put_env([{@unset, :during}, {@set, :during}, {@set_nil, :during}])

      assert Application.fetch_env(:cinder, @set_nil) == {:ok, :during}
    end

    test "put_env/2 twice on one key restores the value from before the first" do
      assert_restored_on_exit([@unset, @set])

      for key <- [@unset, @set], value <- [:first, :second], do: ConfigCase.put_env(key, value)
    end

    test "restore_env_on_exit/1 restores keys the test put or deleted itself" do
      assert_restored_on_exit([@unset, @set, @set_nil])
      ConfigCase.restore_env_on_exit([@unset, @set, @set_nil])

      Application.put_env(:cinder, @unset, :during)
      Application.put_env(:cinder, @set, :during)
      Application.delete_env(:cinder, @set_nil)
    end

    test "CinderWeb.ConnCase.reset_cinder_env/1 restores by the same rule" do
      # Three of its keys in the three states, each put back by the outer restore after the test.
      [unset, set, set_nil] = [:disk_stats_stub, :health_probe_timeout_ms, :disk_df_bin]
      ConfigCase.restore_env_on_exit([unset, set, set_nil])
      Application.delete_env(:cinder, unset)
      Application.put_env(:cinder, set, :before)
      Application.put_env(:cinder, set_nil, nil)

      on_exit(fn -> assert_restored(unset, set, set_nil) end)
      assert :ok = CinderWeb.ConnCase.reset_cinder_env(%{})

      Enum.each([unset, set, set_nil], &Application.put_env(:cinder, &1, :during))
    end
  end

  # Registers, before the helper under test does, a callback that runs after the helper's restore.
  defp assert_restored_on_exit(keys) do
    on_exit(fn ->
      for key <- keys, do: assert(Application.fetch_env(:cinder, key) == expected(key))
    end)
  end

  defp expected(:config_case_test_unset), do: :error
  defp expected(:config_case_test_set), do: {:ok, :before}
  defp expected(:config_case_test_set_nil), do: {:ok, nil}

  defp assert_restored(unset, set, set_nil) do
    assert Application.fetch_env(:cinder, unset) == :error
    assert Application.fetch_env(:cinder, set) == {:ok, :before}
    assert Application.fetch_env(:cinder, set_nil) == {:ok, nil}
  end

  describe "update_boot_capture/2" do
    @uncaptured :config_case_test_uncaptured
    @captured :config_case_test_captured

    defp capture_key(key), do: {Cinder.Settings, :base, key}

    setup do
      :persistent_term.put(capture_key(@captured), before: true)

      # Registered first, so it runs after the test's own callbacks (ExUnit runs them last first).
      on_exit(fn ->
        assert :persistent_term.get(capture_key(@uncaptured), :__none__) == :__none__
        assert :persistent_term.get(capture_key(@captured)) == [before: true]
        :persistent_term.erase(capture_key(@captured))
      end)
    end

    test "applies the function to the capture, then erases a capture the key did not have" do
      ConfigCase.update_boot_capture(@uncaptured, &Keyword.put(&1, :base_url, nil))

      assert Overlay.base(@uncaptured) == [base_url: nil]
    end

    test "applies the function to the capture, then puts the prior capture back" do
      ConfigCase.update_boot_capture(@captured, &Keyword.put(&1, :base_url, nil))

      assert Overlay.base(@captured) == [base_url: nil, before: true]
    end
  end

  test "neutral_anime_policy/1 refuses groups as put_config/2 does" do
    assert_raise ArgumentError, ~r/^neutral_anime_policy\/1: preferred_groups: /, fn ->
      neutral_anime_policy(preferred_groups: ["Trusted"])
    end

    assert neutral_anime_policy(blocked_groups: ["bad"]).blocked_groups == ["bad"]
  end
end
