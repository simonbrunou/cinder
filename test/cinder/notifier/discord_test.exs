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

  test "maintenance_completed posts a green embed with the operation name" do
    expect_post()
    assert :ok = Discord.notify({:maintenance_completed, :movie_pipeline})

    assert_receive {:posted, %{"embeds" => [embed]}}
    assert embed["title"] == "Maintenance completed"
    assert embed["description"] == "Movie pipeline"
    assert embed["color"] == 0x2ECC71
  end

  test "maintenance_failed posts a red embed with the technical reason" do
    expect_post()
    assert :ok = Discord.notify({:maintenance_failed, :scan_movies, :unavailable})

    assert_receive {:posted, %{"embeds" => [embed]}}
    assert embed["title"] == "Maintenance failed"
    assert embed["description"] == "Movie library scan — :unavailable"
    assert embed["color"] == 0xE74C3C
  end

  test "maintenance events safely render an unknown action key" do
    expect_post()
    assert :ok = Discord.notify({:maintenance_completed, :unknown_action})

    assert_receive {:posted, %{"embeds" => [embed]}}
    assert embed["description"] == ":unknown_action"
  end

  test "request_approved posts a green embed naming the requester" do
    expect_post()

    request = %{
      title: "Arrival",
      year: 2016,
      poster_path: "/arr.jpg",
      user_id: 3,
      user: %{email: "kim@example.com"},
      target_type: "movie",
      season_number: nil
    }

    assert :ok = Discord.notify({:request_approved, request})

    assert_receive {:posted, %{"embeds" => [embed]}}
    assert embed["title"] == "✅ Request approved"
    assert embed["description"] == "Arrival (2016) — for kim@example.com"
    assert embed["color"] == 0x2ECC71
    assert embed["thumbnail"]["url"] == "https://image.tmdb.org/t/p/w342/arr.jpg"
  end

  # The auto-approve paths hand the notifier a struct built from a bare insert, so :user is
  # %NotLoaded{}. That must degrade to the id, not raise — Cinder.Notifier.notify/1 swallows
  # raises, so a raise here would read as "Discord silently stopped working".
  test "request_approved falls back to the user id when :user is not loaded" do
    expect_post()

    request = %{
      title: "Arrival",
      year: 2016,
      poster_path: nil,
      user_id: 3,
      user: %Ecto.Association.NotLoaded{},
      target_type: "movie",
      season_number: nil
    }

    assert :ok = Discord.notify({:request_approved, request})

    assert_receive {:posted, %{"embeds" => [embed]}}
    assert embed["description"] == "Arrival (2016) — for user #3"
  end

  test "request_approved for a season names the season, not just the series" do
    expect_post()

    request = %{
      title: "Severance",
      year: 2022,
      poster_path: nil,
      user_id: 3,
      user: %{email: "kim@example.com"},
      target_type: "season",
      season_number: 2
    }

    assert :ok = Discord.notify({:request_approved, request})

    assert_receive {:posted, %{"embeds" => [embed]}}
    assert embed["description"] == "Severance (2022) — Season 2 — for kim@example.com"
  end

  test "request_created posts a blue awaiting-approval embed naming the requester" do
    expect_post()

    request = %{
      title: "Arrival",
      year: 2016,
      poster_path: "/arr.jpg",
      user_id: 3,
      user: %{email: "kim@example.com"},
      target_type: "movie",
      season_number: nil
    }

    assert :ok = Discord.notify({:request_created, request})

    assert_receive {:posted, %{"embeds" => [embed]}}
    assert embed["title"] == "🙋 Request awaiting approval"
    assert embed["description"] == "Arrival (2016) — from kim@example.com"
    assert embed["color"] == 0x3498DB
  end

  # Registration is public and the email format check only forbids `@ , ;` and whitespace, so
  # markdown metacharacters are registerable. Both of Discord's link syntaxes must die: the
  # masked `[x](url)` form and the bare `<url>` auto-link form. Dropping `:` and `/` is what
  # makes this hold for any syntax, rather than the ones we happened to think of.
  test "an attacker-chosen email cannot put a link in the admin's channel" do
    for evil <- [
          "[click](https://evil.tld)x@a.tld",
          "<https://evil.tld>x@a.tld",
          "`x`@a.tld",
          "**x**@a.tld"
        ] do
      expect_post()
      assert :ok = Discord.notify({:user_registered, %{id: 9, email: evil}})

      assert_receive {:posted, %{"embeds" => [embed]}}
      description = embed["description"]

      refute description =~ "https://", "a URL scheme survived for #{inspect(evil)}"

      for char <- ["[", "]", "(", ")", "<", ">", "`", "*"] do
        refute String.contains?(description, char),
               "#{inspect(char)} survived for #{inspect(evil)}"
      end
    end
  end

  test "the requester's email is sanitized in a request embed too" do
    expect_post()

    request = %{
      title: "Arrival",
      year: 2016,
      poster_path: nil,
      user_id: 3,
      user: %{email: "<https://evil.tld>@a.tld"},
      target_type: "movie",
      season_number: nil
    }

    assert :ok = Discord.notify({:request_created, request})

    assert_receive {:posted, %{"embeds" => [embed]}}
    refute embed["description"] =~ "https://"
    refute embed["description"] =~ "<"
  end

  test "an ordinary address is left readable" do
    expect_post()
    assert :ok = Discord.notify({:user_registered, %{id: 9, email: "kim.o'neil+tv@example.com"}})

    assert_receive {:posted, %{"embeds" => [embed]}}
    assert embed["description"] =~ "kim.o'neil+tv@example.com"
  end

  test "user_registered posts a blue awaiting-activation embed with no thumbnail" do
    expect_post()
    assert :ok = Discord.notify({:user_registered, %{id: 9, email: "kim@example.com"}})

    assert_receive {:posted, %{"embeds" => [embed]}}
    assert embed["title"] == "👤 Account awaiting activation"
    assert embed["description"] =~ "kim@example.com"
    assert embed["color"] == 0x3498DB
    refute Map.has_key?(embed, "thumbnail")
  end

  test "season_available posts the series title and season with the series poster" do
    expect_post()

    season = %{title: "Severance", season_number: 2, poster_path: "/sev.jpg"}
    assert :ok = Discord.notify({:season_available, season})

    assert_receive {:posted, %{"embeds" => [embed]}}
    assert embed["title"] == "📺 Season now available"
    assert embed["description"] == "Severance — Season 2"
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

  test "notify/1 does not forward an embed across redirects" do
    parent = self()

    for status <- [301, 302, 303, 307, 308] do
      Req.Test.stub(Cinder.DiscordStub, fn conn ->
        if conn.host == "attacker.test" do
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(parent, {:attacker_called, body})
          Req.Test.json(conn, %{})
        else
          conn
          |> Plug.Conn.put_resp_header("location", "https://attacker.test/hook")
          |> Plug.Conn.send_resp(status, "")
        end
      end)

      capture_log(fn -> assert :ok = Discord.notify({:movie_available, movie()}) end)
      refute_received {:attacker_called, _}
    end
  end

  test "health/0 rejects an oversized JSON response" do
    Req.Test.stub(Cinder.DiscordStub, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"padding":"#{String.duplicate("x", 4 * 1024 * 1024)}"}))
    end)

    assert {:error, :response_too_large} = Discord.health()
  end
end
