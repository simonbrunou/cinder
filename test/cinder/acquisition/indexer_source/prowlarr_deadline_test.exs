defmodule Cinder.Acquisition.IndexerSource.ProwlarrDeadlineTest do
  # Not async: one test changes the shared Prowlarr config.
  use ExUnit.Case, async: false

  alias Cinder.Acquisition.IndexerSource.Prowlarr
  alias Cinder.Test.{RequestDeadlines, SilentServer}

  # A receive_timeout under `HTTPPolicy.bounded_request/2`'s 60 s default leaves the total deadline
  # at 60 s, and the receive timeout itself ends a server that never answers (#1414).
  test "a search ends at the receive_timeout the configured req_options set" do
    Cinder.ConfigCase.put_config(Prowlarr,
      base_url: SilentServer.start!(),
      req_options: [receive_timeout: 200, retry: false]
    )

    started = System.monotonic_time(:millisecond)

    assert {:error, %Req.TransportError{reason: :timeout}} = Prowlarr.search("tt0000001")
    # The match is the check: the 60 s deadline would end the call on
    # `{:error, :request_timeout}`. The bound only keeps the call well under that deadline
    # (testing.md, the `SilentServer` bullet).
    assert System.monotonic_time(:millisecond) - started < 30_000
  end

  test "every search's total deadline is its 90 s receive_timeout, and health/0 keeps the default" do
    Req.Test.stub(Cinder.ProwlarrStub, fn conn ->
      case conn.request_path do
        "/api/v1/health" -> Plug.Conn.send_resp(conn, 200, "")
        "/api/v1/search" -> Req.Test.json(conn, [])
      end
    end)

    searches = [
      {"search/1", fn -> Prowlarr.search("tt0000001") end, 1},
      {"search_tv/3 with a TVDB id", fn -> Prowlarr.search_tv(81_189, "Show", 1) end, 2},
      {"search_tv/3 without a TVDB id", fn -> Prowlarr.search_tv(nil, "Show", 1) end, 1},
      {"search_movie_query/2", fn -> Prowlarr.search_movie_query("Film", []) end, 1},
      {"search_tv_query/2", fn -> Prowlarr.search_tv_query("Show", []) end, 1},
      {"search_ebook/3", fn -> Prowlarr.search_ebook("Author", "Title", []) end, 1},
      {"search_ebook_query/2", fn -> Prowlarr.search_ebook_query("Title", []) end, 1},
      {"search_audiobook/3", fn -> Prowlarr.search_audiobook("Author", "Title", []) end, 1},
      {"search_audiobook_query/2", fn -> Prowlarr.search_audiobook_query("Title", []) end, 1}
    ]

    for {name, search, requests} <- searches do
      {result, deadlines} = RequestDeadlines.capture(search)
      assert result == {:ok, []}, name
      assert deadlines == List.duplicate({"/api/v1/search", 90_000}, requests), name
    end

    # health/0 sets a 3 s receive_timeout, so the deadline stays at the 60 s default.
    assert {:ok, [{"/api/v1/health", 60_000}]} = RequestDeadlines.capture(&Prowlarr.health/0)
  end
end
