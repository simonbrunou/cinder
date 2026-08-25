defmodule Cinder.Notifier.DiscordTest do
  # async: false — the "webhook unset" tests mutate and restore app env.
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Cinder.Accounts.User
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

  # A movie request whose requester has the given (attacker-controlled) Plex username. The email
  # is set to prove it never reaches the payload — display_name/1 renders plex_username, not it.
  defp request_with(plex_username) do
    %{
      title: "Arrival",
      year: 2016,
      poster_path: nil,
      user_id: 3,
      user: %User{id: 3, email: "kim@example.com", plex_username: plex_username},
      target_type: "movie",
      season_number: nil
    }
  end

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

  test "request_approved posts a green embed naming the requester (no email)" do
    expect_post()

    request = %{
      title: "Arrival",
      year: 2016,
      poster_path: "/arr.jpg",
      user_id: 3,
      user: %User{id: 3, email: "kim@example.com", plex_username: "kimwatches"},
      target_type: "movie",
      season_number: nil
    }

    assert :ok = Discord.notify({:request_approved, request})

    assert_receive {:posted, %{"embeds" => [embed]}}
    assert embed["title"] == "✅ Request approved"
    assert embed["description"] == "Arrival (2016) — for kimwatches"
    refute embed["description"] =~ "kim@example.com"
    assert embed["color"] == 0x2ECC71
    assert embed["thumbnail"]["url"] == "https://image.tmdb.org/t/p/w342/arr.jpg"
  end

  test "request_approved names a Jellyfin-linked requester by their Jellyfin username" do
    expect_post()

    request = %{
      title: "Arrival",
      year: 2016,
      poster_path: nil,
      user_id: 4,
      user: %User{
        id: 4,
        email: "kim-jf-9@jellyfin.invalid",
        jellyfin_username: "kimjellies"
      },
      target_type: "movie",
      season_number: nil
    }

    assert :ok = Discord.notify({:request_approved, request})

    assert_receive {:posted, %{"embeds" => [embed]}}
    assert embed["description"] == "Arrival (2016) — for kimjellies"
    refute embed["description"] =~ "jellyfin.invalid"
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
      user: %User{id: 3, email: "kim@example.com", plex_username: "kimwatches"},
      target_type: "season",
      season_number: 2
    }

    assert :ok = Discord.notify({:request_approved, request})

    assert_receive {:posted, %{"embeds" => [embed]}}
    assert embed["description"] == "Severance (2022) — Season 2 — for kimwatches"
    refute embed["description"] =~ "kim@example.com"
  end

  test "request_approved for a book names the format, not just the work" do
    expect_post()

    request = %{
      title: "Dune",
      year: 1965,
      poster_path: nil,
      user_id: 3,
      user: %User{id: 3, email: "kim@example.com", plex_username: "kimwatches"},
      target_type: "book",
      season_number: nil,
      media_kind: :audiobook
    }

    assert :ok = Discord.notify({:request_approved, request})

    assert_receive {:posted, %{"embeds" => [embed]}}
    assert embed["description"] == "Dune (1965) — Audiobook — for kimwatches"
  end

  test "request_denied posts a red embed naming the requester and reason (no email)" do
    expect_post()

    assert :ok =
             Discord.notify(
               {:request_denied, request_with("kimwatches"), "not for the household"}
             )

    assert_receive {:posted, %{"embeds" => [embed]}}
    assert embed["title"] == "🚫 Request denied"
    assert embed["description"] == "Arrival (2016) — for kimwatches (not for the household)"
    refute embed["description"] =~ "kim@example.com"
    assert embed["color"] == 0xE74C3C
  end

  test "request_denied omits the parenthetical when no reason was given" do
    expect_post()

    assert :ok = Discord.notify({:request_denied, request_with("kimwatches"), ""})

    assert_receive {:posted, %{"embeds" => [embed]}}
    assert embed["description"] == "Arrival (2016) — for kimwatches"
  end

  test "request_created posts a blue awaiting-approval embed naming the requester (no email)" do
    expect_post()

    request = %{
      title: "Arrival",
      year: 2016,
      poster_path: "/arr.jpg",
      user_id: 3,
      user: %User{id: 3, email: "kim@example.com", plex_username: "kimwatches"},
      target_type: "movie",
      season_number: nil
    }

    assert :ok = Discord.notify({:request_created, request})

    assert_receive {:posted, %{"embeds" => [embed]}}
    assert embed["title"] == "🙋 Request awaiting approval"
    assert embed["description"] == "Arrival (2016) — from kimwatches"
    refute embed["description"] =~ "kim@example.com"
    assert embed["color"] == 0x3498DB
  end

  # A plex_username is externally sourced (from the linked Plex account) and Discord renders embed
  # text as markdown, so both of Discord's link syntaxes must die: the masked `[x](url)` form and
  # the bare `<url>` auto-link form. Dropping `:` and `/` is what makes this hold for any syntax,
  # rather than the ones we happened to think of.
  test "an attacker-chosen plex username cannot put a link in the admin's channel" do
    for evil <- [
          "[click](https://evil.tld)x",
          "<https://evil.tld>x",
          "`x`",
          "**x**"
        ] do
      expect_post()
      assert :ok = Discord.notify({:request_created, request_with(evil)})

      assert_receive {:posted, %{"embeds" => [embed]}}
      # Assert on the requester portion only — the title's "Arrival (2016)" has its own parens.
      [_title, name] = String.split(embed["description"], " — from ", parts: 2)

      refute name =~ "https://", "a URL scheme survived for #{inspect(evil)}"

      for char <- ["[", "]", "(", ")", "<", ">", "`", "*"] do
        refute String.contains?(name, char),
               "#{inspect(char)} survived for #{inspect(evil)}"
      end
    end
  end

  # The approval path sanitizes the requester's plex_username too (not only the created path).
  test "the requester's plex username is sanitized in a request embed" do
    expect_post()

    assert :ok = Discord.notify({:request_approved, request_with("<https://evil.tld>x")})

    assert_receive {:posted, %{"embeds" => [embed]}}
    refute embed["description"] =~ "https://"
    refute embed["description"] =~ "<"
  end

  # A plex_username like "@everyone" survives the whitelist. It is inert in an embed only because
  # Discord does not resolve mentions there — the zero-width space keeps it inert if the text is
  # ever moved into `content`.
  test "a mention-shaped plex username cannot become a channel ping" do
    for {username, banned} <- [{"@everyone", "@everyone"}, {"@here", "@here"}] do
      expect_post()
      assert :ok = Discord.notify({:request_created, request_with(username)})

      assert_receive {:posted, %{"embeds" => [embed]}}
      refute embed["description"] =~ banned
    end
  end

  # No word boundary in the neutralising regex (Discord matches the substring, so "@everyone"
  # inside "@everyones" would still ping). A username that merely starts with "@here" therefore
  # gains an invisible zero-width space; it must still READ correctly to the admin.
  test "a plex username beginning with '@here' still reads correctly" do
    expect_post()
    assert :ok = Discord.notify({:request_created, request_with("@herefordshire")})

    assert_receive {:posted, %{"embeds" => [embed]}}
    assert String.replace(embed["description"], "​", "") =~ "@herefordshire"
  end

  # The boundary-less form is the point: a keyword followed by more word characters must not
  # slip through, since Discord would resolve the substring.
  test "a mention keyword followed by more characters is still neutralised" do
    expect_post()
    assert :ok = Discord.notify({:request_created, request_with("@everyones")})

    assert_receive {:posted, %{"embeds" => [embed]}}
    refute embed["description"] =~ "@everyone"
  end

  # Belt and braces: even if some future embed carried an unsanitised string, Discord is told
  # not to resolve mentions in this payload at all.
  test "the payload disables mention parsing outright" do
    expect_post()
    assert :ok = Discord.notify({:movie_available, movie()})

    assert_receive {:posted, payload}
    assert payload["allowed_mentions"] == %{"parse" => []}
  end

  test "an ordinary plex username is left readable" do
    expect_post()
    assert :ok = Discord.notify({:request_created, request_with("kim.o'neil")})

    assert_receive {:posted, %{"embeds" => [embed]}}
    assert embed["description"] =~ "kim.o'neil"
  end

  test "user_registered posts a blue awaiting-activation embed (user id, no email) and no thumbnail" do
    expect_post()

    assert :ok =
             Discord.notify(
               {:user_registered, %User{id: 9, email: "kim@example.com", plex_username: nil}}
             )

    assert_receive {:posted, %{"embeds" => [embed]}}
    assert embed["title"] == "👤 Account awaiting activation"
    assert embed["description"] =~ "user #9"
    refute embed["description"] =~ "kim@example.com"
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
