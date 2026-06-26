defmodule Cinder.Library.UpgradeTest do
  use ExUnit.Case, async: true
  alias Cinder.Library.Upgrade

  @pref ["2160p", "1080p", "720p"]
  defp q(res, size, lang), do: %{resolution: res, size: size, language: lang}

  test "nil baseline is always an upgrade" do
    assert Upgrade.better?(q("720p", 1, "en"), q(nil, nil, nil), nil, @pref)
  end

  test "language upgrade beats lower resolution (the French case)" do
    assert Upgrade.better?(q(nil, 1_000, "FRENCH"), q("1080p", 9_000, "HUNGARIAN"), "fr", @pref)
  end

  test "language downgrade is blocked" do
    refute Upgrade.better?(
             q("2160p", 9_000, "HUNGARIAN"),
             q("1080p", 1_000, "FRENCH"),
             "fr",
             @pref
           )
  end

  test "nil target falls to quality only" do
    assert Upgrade.better?(q("2160p", 1, "x"), q("1080p", 9_000, "y"), nil, @pref)
    refute Upgrade.better?(q("720p", 9_000, "x"), q("1080p", 1, "y"), nil, @pref)
  end

  test "better resolution wins; nil resolution never out-ranks a known one" do
    assert Upgrade.better?(q("1080p", 1, "en"), q("720p", 9_000, "en"), nil, @pref)
    refute Upgrade.better?(q(nil, 9_000, "en"), q("1080p", 1, "en"), nil, @pref)
  end

  test "equal resolution: larger size wins (documented weak proxy)" do
    assert Upgrade.better?(q("1080p", 9_000, "en"), q("1080p", 1_000, "en"), nil, @pref)
    refute Upgrade.better?(q("1080p", 1_000, "en"), q("1080p", 9_000, "en"), nil, @pref)
  end

  test "nil preferred falls back to scorer defaults without crashing" do
    assert Upgrade.better?(q("1080p", 1, "en"), q("720p", 1, "en"), nil, nil)
  end
end
