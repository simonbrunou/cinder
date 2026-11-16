defmodule Cinder.Library.UpgradeRulesTest do
  # Rewrites the release-rule `:cinder` env keys, which other test modules read.
  use ExUnit.Case, async: false

  alias Cinder.Catalog.{Episode, Movie}
  alias Cinder.ConfigCase
  alias Cinder.Library.Upgrade
  alias Cinder.Settings.Registry

  # The env key comes from each definition's target, never from a template, so a renamed slot or
  # key fails here instead of leaving a reader on a key nothing writes.
  defp put_rule(kind, slot, value) do
    %{target: {:env, env_key}} = Registry.one!(group: :releases, kind: kind, slot: slot)
    ConfigCase.put_env(env_key, value)
  end

  test "the preferred lists come from each video kind's own definitions" do
    for kind <- [:movies, :tv] do
      put_rule(kind, :preferred_resolutions, ["#{kind}-res"])
      put_rule(kind, :preferred_sources, ["#{kind}-src"])

      assert Upgrade.preferred_resolutions(kind) == ["#{kind}-res"]
      assert Upgrade.preferred_sources(kind) == ["#{kind}-src"]
    end
  end

  # 2160p is outside `Scorer.default_preferred/0`, so the cutoff is met only when both the cutoff
  # and the preferred list are read from the kind's own keys.
  test "cutoff_met?/2 reads the cutoff and the preferred list of the record's kind" do
    for {kind, record} <- [
          movies: %Movie{imported_resolution: "2160p"},
          tv: %Episode{imported_resolution: "2160p"}
        ] do
      put_rule(kind, :preferred_resolutions, ["2160p", "1080p"])
      put_rule(kind, :upgrade_cutoff, "2160p")

      assert Upgrade.cutoff_met?(record, kind)

      put_rule(kind, :upgrade_cutoff, nil)
      refute Upgrade.cutoff_met?(record, kind)
    end
  end
end
