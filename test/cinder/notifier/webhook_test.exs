defmodule Cinder.Notifier.WebhookTest do
  # async: false — every test configures the transport through global Application env.
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Cinder.Accounts.User
  alias Cinder.Books.BookTarget
  alias Cinder.Books.Work
  alias Cinder.Notifier.Discord
  alias Cinder.Notifier.Webhook

  @url "https://hooks.test/cinder"

  setup do
    original = Application.get_env(:cinder, Webhook, [])
    on_exit(fn -> Application.put_env(:cinder, Webhook, original) end)
    :ok
  end

  defp configure(opts) do
    :cinder
    |> Application.get_env(Webhook, [])
    |> Keyword.merge(opts)
    |> then(&Application.put_env(:cinder, Webhook, &1))
  end

  # Stub the endpoint and forward the decoded POST body + request headers to the test process.
  defp expect_post do
    pid = self()

    Req.Test.stub(Cinder.WebhookStub, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(pid, {:posted, Jason.decode!(body), conn.req_headers})
      Req.Test.json(conn, %{})
    end)
  end

  defp movie, do: %{title: "Dune", year: 2021, poster_path: "/dune.jpg"}

  defp book_target(attrs) do
    %BookTarget{id: 7, work_id: 42, work: %Work{title: "Dune"}}
    |> Map.merge(Map.new(attrs))
  end

  test "posts the event as JSON under a stable event discriminator" do
    configure(url: @url)
    expect_post()

    assert :ok = Webhook.notify({:movie_available, movie()})

    assert_receive {:posted, body, _headers}
    assert body == %{"event" => "movie_available", "title" => "Dune", "year" => 2021}
  end

  test "a failure event carries its reason" do
    configure(url: @url)
    expect_post()

    assert :ok = Webhook.notify({:movie_failed, movie(), :no_match})
    assert_receive {:posted, %{"event" => "movie_failed", "reason" => "no_match"}, _}

    assert :ok = Webhook.notify({:grab_failed, %{id: 7}, {:http_status, 500}})
    assert_receive {:posted, %{"event" => "grab_failed", "id" => 7, "reason" => reason}, _}
    assert reason == "{:http_status, 500}"
  end

  test "the maintenance events name the operation, and exhausted searches list the episodes" do
    configure(url: @url)
    expect_post()

    assert :ok = Webhook.notify({:maintenance_completed, :movie_pipeline})
    assert_receive {:posted, %{"event" => "maintenance_completed", "name" => "movie_pipeline"}, _}

    assert :ok = Webhook.notify({:episodes_search_exhausted, [episode()]})
    assert_receive {:posted, %{"event" => "episodes_search_exhausted", "episodes" => [ep]}, _}
    assert ep == %{"id" => 11, "episode_number" => 2, "season_number" => 1}
  end

  test "sends nothing for an event of an unrecognised shape" do
    configure(url: @url)
    expect_post()

    assert :ok = Webhook.notify(:not_a_typed_event)
    refute_receive {:posted, _, _}
  end

  test "sends nothing when no URL is configured" do
    configure(url: nil)
    expect_post()

    assert :ok = Webhook.notify({:movie_available, movie()})
    refute_receive {:posted, _, _}
  end

  test "sends nothing when the URL is blank" do
    configure(url: "   ")
    expect_post()

    assert :ok = Webhook.notify({:movie_available, movie()})
    refute_receive {:posted, _, _}
  end

  test "attaches the configured Authorization header, and none when it is unset" do
    configure(url: @url, auth_header: "Bearer tk_abc")
    expect_post()

    assert :ok = Webhook.notify({:movie_available, movie()})
    assert_receive {:posted, _body, headers}
    assert {"authorization", "Bearer tk_abc"} in headers

    configure(auth_header: "")
    assert :ok = Webhook.notify({:movie_available, movie()})
    assert_receive {:posted, _body, headers}
    refute List.keyfind(headers, "authorization", 0)
  end

  test "book_available carries the work title, ids, and media kind for an eBook" do
    configure(url: @url)
    expect_post()

    target = book_target(media_kind: :ebook)
    assert :ok = Webhook.notify({:book_available, target})

    assert_receive {:posted, body, _headers}

    assert body == %{
             "event" => "book_available",
             "id" => 7,
             "work_id" => 42,
             "title" => "Dune",
             "media_kind" => "ebook"
           }
  end

  test "book_available carries the work title, ids, and media kind for an audiobook" do
    configure(url: @url)
    expect_post()

    target = book_target(media_kind: :audiobook)
    assert :ok = Webhook.notify({:book_available, target})

    assert_receive {:posted, body, _headers}

    assert body == %{
             "event" => "book_available",
             "id" => 7,
             "work_id" => 42,
             "title" => "Dune",
             "media_kind" => "audiobook"
           }
  end

  test "book_target_held carries the sanitized hold reason alongside the title and ids" do
    configure(url: @url)
    expect_post()

    target = book_target(media_kind: :audiobook, hold_reason: "invalid_audio")
    assert :ok = Webhook.notify({:book_target_held, target})

    assert_receive {:posted, body, _headers}

    assert body == %{
             "event" => "book_target_held",
             "id" => 7,
             "work_id" => 42,
             "title" => "Dune",
             "media_kind" => "audiobook",
             "hold_reason" => "invalid_audio"
           }
  end

  test "book_target_held for an eBook carries its own hold reason" do
    configure(url: @url)
    expect_post()

    target = book_target(media_kind: :ebook, hold_reason: "no_match")
    assert :ok = Webhook.notify({:book_target_held, target})

    assert_receive {:posted, body, _headers}
    assert body["media_kind"] == "ebook"
    assert body["hold_reason"] == "no_match"
  end

  test "never sends a requester email or a user's free text" do
    configure(url: @url)
    expect_post()

    report = %{
      id: 4,
      title: "Arrival",
      category: :audio,
      detail: "the french dub is out of sync",
      user_id: 3,
      user: %User{id: 3, email: "kim@example.com", plex_username: "kim"}
    }

    assert :ok = Webhook.notify({:issue_reported, report})

    assert_receive {:posted, body, _headers}
    assert body["event"] == "issue_reported"
    assert body["category"] == "audio"
    assert body["user_id"] == 3
    encoded = Jason.encode!(body)
    refute encoded =~ "kim@example.com"
    refute encoded =~ "out of sync"
  end

  test "a non-2xx response is logged and swallowed" do
    configure(url: @url)
    Req.Test.stub(Cinder.WebhookStub, &Plug.Conn.send_resp(&1, 500, "nope"))

    log = capture_log(fn -> assert :ok = Webhook.notify({:movie_available, movie()}) end)

    assert log =~ "Webhook notify failed"
    assert log =~ "500"
  end

  # The done-when: everything Discord renders an embed for also reaches the webhook. Both
  # transports are driven off one event list so the two can't drift apart silently.
  test "every event that reaches Discord also reaches the webhook as JSON" do
    configure(url: @url)
    expect_post()
    pid = self()

    Req.Test.stub(Cinder.DiscordStub, fn conn ->
      {:ok, _body, conn} = Plug.Conn.read_body(conn)
      send(pid, :discord_posted)
      Req.Test.json(conn, %{})
    end)

    for event <- discord_events() do
      name = event |> elem(0) |> Atom.to_string()

      assert :ok = Discord.notify(event)
      assert_receive :discord_posted, 500, "Discord did not post #{name}"

      assert :ok = Webhook.notify(event)
      assert_receive {:posted, %{"event" => ^name}, _headers}
    end
  end

  defp discord_events do
    [
      {:request_approved, request()},
      {:request_created, request()},
      {:request_denied, request(), "already in the library"},
      {:issue_reported, %{id: 4, title: "Arrival", category: :audio, user_id: 3}},
      {:user_registered, %User{id: 9, email: "kim@example.com"}},
      {:movie_available, movie()},
      {:movie_failed, movie(), :no_match},
      {:movie_upgrade_failed, movie(), :revert},
      {:season_available, %{title: "Frieren", season_number: 1, poster_path: nil}},
      {:grab_failed, %{id: 7}, :stalled},
      {:operator_hold, %{id: 7}, :needs_mapping},
      {:episodes_search_exhausted, [episode()]},
      {:maintenance_completed, :movie_pipeline},
      {:maintenance_failed, :scan_movies, :unavailable},
      {:book_available, book_target(media_kind: :ebook)},
      {:book_target_held, book_target(media_kind: :audiobook, hold_reason: "invalid_audio")}
    ]
  end

  defp request do
    %{
      id: 5,
      title: "Arrival",
      year: 2016,
      poster_path: nil,
      user_id: 3,
      user: %User{id: 3, email: "kim@example.com", plex_username: "kim"},
      target_type: "movie",
      season_number: nil
    }
  end

  defp episode do
    %{
      id: 11,
      episode_number: 2,
      season: %{season_number: 1, series: %{title: "Frieren", poster_path: nil}}
    }
  end
end
