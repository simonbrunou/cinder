defmodule Cinder.Indexers.FlareSolverrUrlTest do
  # The one FlareSolverr URL setting (#1682): `flaresolverr_url`, saved only through
  # `Cinder.Indexers.FlareSolverrUrl.put/1`, which checks it as a base URL is checked.
  #
  # Not async: a settings save re-applies the global env.
  use Cinder.DataCase, async: false

  alias Cinder.Indexers.FlareSolverrUrl
  alias Cinder.Settings

  test "the setting is direct and has no input on the settings form" do
    definition = Enum.find(Settings.definitions(), &(&1.key == "flaresolverr_url"))
    assert %{save: :direct, render: :none, label: "FlareSolverr URL"} = definition
  end

  test "an http or https URL with a host saves, trimmed; a blank one clears it" do
    assert FlareSolverrUrl.get() == nil
    assert :ok = FlareSolverrUrl.put("  http://flaresolverr.lan:8191 ")
    assert FlareSolverrUrl.get() == "http://flaresolverr.lan:8191"
    assert Settings.get("flaresolverr_url") == "http://flaresolverr.lan:8191"

    assert :ok = FlareSolverrUrl.put("https://fs.example/base/")
    assert FlareSolverrUrl.get() == "https://fs.example/base/"

    assert :ok = FlareSolverrUrl.put("   ")
    assert FlareSolverrUrl.get() == nil
    assert Settings.get("flaresolverr_url") == nil
  end

  test "user info, a query, a fragment, another scheme, no host or a bad port are refused" do
    :ok = FlareSolverrUrl.put("http://kept.lan:8191")

    for url <- [
          "http://user:pass@fs.lan:8191",
          "http://user@fs.lan:8191",
          "http://fs.lan:8191/?token=x",
          "http://fs.lan:8191/#v1",
          "ftp://fs.lan:8191",
          "fs.lan:8191",
          "http://",
          "http://fs.lan:99999",
          "http://fs.lan:8191/\xff",
          "not a url"
        ] do
      assert FlareSolverrUrl.put(url) == {:error, :invalid_url}, url
    end

    assert FlareSolverrUrl.get() == "http://kept.lan:8191"
  end

  test "a value that is not text is refused" do
    assert FlareSolverrUrl.put(nil) == {:error, :invalid_url}
    assert FlareSolverrUrl.put(8191) == {:error, :invalid_url}
  end
end
