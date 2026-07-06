defmodule Cinder.Notifier.DiscordTest do
  # async: false — the "webhook unset" tests mutate and restore app env.
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Cinder.Notifier.Discord

  # Stub the webhook endpoint and forward the decoded POST body to the test process.
  defp expect_post do
    pid = self()

    Req.Test.stub(Cinder.DiscordStub, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(pid, {:posted, Jason.decode!(body)})
      Req.Test.json(conn, %{})
    end)
  end

  defp movie, do: %{title: "Dune", year: 2021, poster_path: "/dune.jpg"}

  test "movie_available posts a green embed with poster thumbnail" do
    expect_post()
    assert :ok = Discord.notify({:movie_available, movie()})

    assert_receive {:posted, %{"embeds" => [embed]}}
    assert embed["title"] == "🎬 Now available"
    assert embed["description"] == "Dune (2021)"
    assert embed["color"] == 0x2ECC71
    assert embed["thumbnail"]["url"] == "https://image.tmdb.org/t/p/w342/dune.jpg"
  end

  test "movie_failed posts a red embed with the reason" do
    expect_post()
    assert :ok = Discord.notify({:movie_failed, movie(), :no_match})

    assert_receive {:posted, %{"embeds" => [embed]}}
    assert embed["title"] == "Movie failed"
    assert embed["description"] =~ "Dune (2021)"
    assert embed["description"] =~ ":no_match"
    assert embed["color"] == 0xE74C3C
  end

  test "movie_upgrade_failed posts a red embed" do
    expect_post()
    assert :ok = Discord.notify({:movie_upgrade_failed, movie(), :revert})

    assert_receive {:posted, %{"embeds" => [embed]}}
    assert embed["title"] == "Upgrade failed"
    assert embed["color"] == 0xE74C3C
  end

  test "request_approved posts a green embed with the request title and poster" do
    expect_post()
    request = %{title: "Arrival", poster_path: "/arr.jpg", user_id: 3}
    assert :ok = Discord.notify({:request_approved, request})

    assert_receive {:posted, %{"embeds" => [embed]}}
    assert embed["title"] == "Request approved"
    assert embed["description"] == "Arrival"
    assert embed["color"] == 0x2ECC71
    assert embed["thumbnail"]["url"] == "https://image.tmdb.org/t/p/w342/arr.jpg"
  end

  test "episodes_available posts series title + episode codes with the series poster" do
    expect_post()

    episodes = [
      %{
        episode_number: 1,
        season: %{season_number: 2, series: %{title: "Severance", poster_path: "/sev.jpg"}}
      },
      %{
        episode_number: 2,
        season: %{season_number: 2, series: %{title: "Severance", poster_path: "/sev.jpg"}}
      }
    ]

    assert :ok = Discord.notify({:episodes_available, episodes})

    assert_receive {:posted, %{"embeds" => [embed]}}
    assert embed["title"] == "📺 Now available"
    assert embed["description"] == "Severance — S02E01, S02E02"
    assert embed["thumbnail"]["url"] == "https://image.tmdb.org/t/p/w342/sev.jpg"
  end

  test "grab_failed posts a red embed with no thumbnail" do
    expect_post()
    assert :ok = Discord.notify({:grab_failed, %{id: 7}, :timeout})

    assert_receive {:posted, %{"embeds" => [embed]}}
    assert embed["title"] == "TV grab #7 failed"
    assert embed["color"] == 0xE74C3C
    refute Map.has_key?(embed, "thumbnail")
  end

  test "an event with no poster_path omits the thumbnail" do
    expect_post()

    assert :ok =
             Discord.notify({:movie_available, %{title: "Tenet", year: 2020, poster_path: nil}})

    assert_receive {:posted, %{"embeds" => [embed]}}
    refute Map.has_key?(embed, "thumbnail")
  end

  test "an empty-string poster_path omits the thumbnail (no bare base URL)" do
    expect_post()

    assert :ok =
             Discord.notify({:movie_available, %{title: "Tenet", year: 2020, poster_path: ""}})

    assert_receive {:posted, %{"embeds" => [embed]}}
    refute Map.has_key?(embed, "thumbnail")
  end

  test "with no webhook configured it returns :ok and never posts" do
    original = Application.get_env(:cinder, Cinder.Notifier.Discord)
    on_exit(fn -> Application.put_env(:cinder, Cinder.Notifier.Discord, original) end)
    Application.put_env(:cinder, Cinder.Notifier.Discord, [])

    Req.Test.stub(Cinder.DiscordStub, fn _ -> flunk("should not POST with no webhook") end)

    assert :ok = Discord.notify({:movie_available, movie()})
    refute_receive {:posted, _}
  end

  test "a non-2xx response is swallowed (returns :ok, no raise)" do
    Req.Test.stub(Cinder.DiscordStub, fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)
    capture_log(fn -> assert :ok = Discord.notify({:movie_available, movie()}) end)
  end

  test "a transport error is swallowed (returns :ok, no raise)" do
    Req.Test.stub(Cinder.DiscordStub, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

    capture_log(fn -> assert :ok = Discord.notify({:movie_available, movie()}) end)
  end

  test "health/0 GETs the webhook (no message posted) and returns :ok on 2xx" do
    Req.Test.stub(Cinder.DiscordStub, fn conn ->
      assert conn.method == "GET"
      Req.Test.json(conn, %{"id" => "1", "token" => "t"})
    end)

    assert :ok = Discord.health()
  end

  test "health/0 returns {:error, :not_configured} with no webhook" do
    original = Application.get_env(:cinder, Cinder.Notifier.Discord)
    on_exit(fn -> Application.put_env(:cinder, Cinder.Notifier.Discord, original) end)
    Application.put_env(:cinder, Cinder.Notifier.Discord, [])

    assert {:error, :not_configured} = Discord.health()
  end
end
