defmodule CinderWeb.ApiController do
  @moduledoc """
  The read-only `/api/v1` scope: two endpoints sized for a dashboard tile (Homepage, Homarr) or
  a household bot, nothing more.

  * `GET /api/v1/status` — the counts a tile renders.
  * `GET /api/v1/requests` — the request queue, `?limit=&offset=` paginated.

  Read-only on purpose. Creating a request over the API would reopen the approval gate that
  `Cinder.Requests` owns, and that deserves its own design.

  **The key is an admin credential, not a household-member one.** Responses carry no personal
  data — `/status` is aggregates, and `/requests` rows are stripped of requester identity and the
  admin's `denial_reason` — but the queue itself is the admin-only `/requests` view: a non-admin
  sees only their own requests at `/my-requests`, and a pending or denied title never reaches
  Discover. So a key pasted into a dashboard that household members can read tells them which
  titles were asked for and which were refused, minus who asked. The `/settings` copy says this;
  don't weaken it to "nothing a non-admin couldn't already see", which is not what the query does.

  Authentication is `CinderWeb.Plugs.ApiAuth`.
  """
  use CinderWeb, :controller

  alias Cinder.Catalog
  alias Cinder.Issues
  alias Cinder.Requests

  @default_limit 50
  @max_limit 100
  # `offset` needs a ceiling as much as `limit` needs one. Integer.parse/1 yields arbitrary
  # precision and Ecto casts :integer without a range check, so an offset past 2^63 reaches
  # exqlite's int64-only bind and raises: a valid key could turn a typo into a 500 plus a
  # stack trace in the log.
  @max_offset 1_000_000

  def status(conn, _params) do
    counts = Catalog.movie_status_counts()

    json(conn, %{
      pending_requests: Requests.count_pending(),
      open_issues: Issues.count_open(),
      active_downloads: Catalog.count_grabs_downloading(),
      movies_total: counts |> Map.values() |> Enum.sum(),
      movies_available: Map.get(counts, :available, 0),
      series_total: Catalog.count_series(),
      episodes_wanted: Catalog.count_wanted_episodes()
    })
  end

  def requests(conn, params) do
    limit = params |> integer_param("limit", @default_limit) |> max(1) |> min(@max_limit)
    offset = params |> integer_param("offset", 0) |> max(0) |> min(@max_offset)

    json(conn, %{
      requests: Requests.list_for_api(limit, offset),
      total: Requests.count_requests(),
      limit: limit,
      offset: offset
    })
  end

  # Query params are caller-controlled: anything that isn't a bare integer falls back to the
  # default rather than raising, so a typo'd widget config gets a page instead of a 500 (and
  # never a stack trace).
  defp integer_param(params, key, default) do
    with value when is_binary(value) <- params[key],
         {integer, ""} <- Integer.parse(value) do
      integer
    else
      _ -> default
    end
  end
end
