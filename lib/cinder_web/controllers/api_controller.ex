defmodule CinderWeb.ApiController do
  @moduledoc """
  The household `/api/v1` scope for dashboard widgets and trusted automation.

  * `GET /api/v1/status` — the counts a tile renders.
  * `GET /api/v1/requests` — the request queue, `?limit=&offset=` paginated.
  * `POST /api/v1/requests` — create through the normal request/approval gate.
  * `POST /api/v1/requests/:id/approve` — approve a pending request.
  * `POST /api/v1/requests/:id/deny` — deny a pending request.
  * `DELETE /api/v1/requests/:id` — delete a request without deleting its catalog title.

  **The key is an admin credential, not a household-member one.** Mutations use the first active
  admin by database id as their deterministic audit actor. Request creation defaults to that admin
  (and therefore auto-approves); `requester_id` may select any active household account so its
  normal quota and approval-gate rules apply. Responses omit requester identity and denial prose.

  Approve/deny are deliberately not idempotent: repeating either returns `409 not_pending`.
  Repeating delete returns `404 not_found`; deleting a request never deletes its catalog title.

  Authentication is `CinderWeb.Plugs.ApiAuth`.
  """
  use CinderWeb, :controller

  alias Cinder.Accounts
  alias Cinder.Acquisition.Language
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
  @max_id 9_223_372_036_854_775_807
  @create_keys ~w(media_profile preferred_language requester_id season_number target_id target_type)

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

  def create_request(conn, params) do
    with {:ok, attrs, requester_id} <- create_attrs(params),
         {:ok, admin} <- Accounts.fetch_active_admin(),
         {:ok, requester} <- requester(admin, requester_id),
         {:ok, request} <- Requests.create_request(requester, attrs) do
      conn
      |> put_status(:created)
      |> json(Requests.for_api(request))
    else
      {:error, reason} -> api_error(conn, reason)
    end
  end

  def approve_request(conn, %{"id" => raw_id} = params) do
    with :ok <- only_keys(params, ["id", "media_profile"]),
         {:ok, id} <- route_id(raw_id),
         {:ok, admin} <- Accounts.fetch_active_admin(),
         {:ok, request} <- Requests.fetch_request(id),
         {:ok, profile} <- approval_profile(params["media_profile"], request),
         {:ok, approved} <- Requests.approve_request(request, admin, profile) do
      json(conn, Requests.for_api(approved))
    else
      {:error, reason} -> api_error(conn, reason)
    end
  end

  def deny_request(conn, %{"id" => raw_id} = params) do
    with :ok <- only_keys(params, ["id", "reason"]),
         {:ok, id} <- route_id(raw_id),
         {:ok, reason} <- denial_reason(params["reason"]),
         {:ok, admin} <- Accounts.fetch_active_admin(),
         {:ok, request} <- Requests.fetch_request(id),
         {:ok, denied} <- Requests.deny_request(request, admin, reason) do
      json(conn, Requests.for_api(denied))
    else
      {:error, reason} -> api_error(conn, reason)
    end
  end

  def delete_request(conn, %{"id" => raw_id} = params) do
    with :ok <- only_keys(params, ["id"]),
         {:ok, id} <- route_id(raw_id),
         {:ok, admin} <- Accounts.fetch_active_admin(),
         {:ok, request} <- Requests.fetch_request(id),
         {:ok, _deleted} <- Requests.delete_request(request, admin) do
      send_resp(conn, :no_content, "")
    else
      {:error, reason} -> api_error(conn, reason)
    end
  end

  defp create_attrs(params) do
    with :ok <- only_keys(params, @create_keys),
         {:ok, target_type} <- target_type(params["target_type"]),
         {:ok, target_id} <- body_id(params["target_id"]),
         {:ok, season_number} <- season_number(target_type, params["season_number"]),
         {:ok, requester_id} <- optional_id(params["requester_id"]),
         {:ok, preferred_language} <- preferred_language(params["preferred_language"]),
         {:ok, profile} <- proposed_profile(params["media_profile"]) do
      attrs = %{
        target_type: target_type,
        target_id: target_id,
        season_number: season_number,
        preferred_language: preferred_language,
        proposed_media_profile: profile
      }

      {:ok, attrs, requester_id}
    end
  end

  defp requester(admin, nil), do: {:ok, admin}
  defp requester(_admin, id), do: Accounts.fetch_active_user(id)

  defp only_keys(params, allowed) do
    if Enum.all?(Map.keys(params), &(&1 in allowed)),
      do: :ok,
      else: {:error, :invalid_payload}
  end

  defp target_type(type) when type in ["movie", "season"], do: {:ok, type}
  defp target_type(_type), do: {:error, :invalid_payload}

  defp body_id(id) when is_integer(id) and id > 0 and id <= @max_id, do: {:ok, id}
  defp body_id(_id), do: {:error, :invalid_payload}

  defp optional_id(nil), do: {:ok, nil}
  defp optional_id(id), do: body_id(id)

  defp route_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {value, ""} when value > 0 and value <= @max_id -> {:ok, value}
      _ -> {:error, :invalid_id}
    end
  end

  defp route_id(_id), do: {:error, :invalid_id}

  defp season_number("movie", nil), do: {:ok, nil}

  defp season_number("season", number)
       when is_integer(number) and number >= 0 and number <= 10_000,
       do: {:ok, number}

  defp season_number(_target_type, _number), do: {:error, :invalid_payload}

  defp preferred_language(nil), do: {:ok, nil}

  defp preferred_language(language) when is_binary(language) do
    if language in Language.preferences(),
      do: {:ok, language},
      else: {:error, :invalid_payload}
  end

  defp preferred_language(_language), do: {:error, :invalid_payload}

  defp proposed_profile(nil), do: {:ok, nil}
  defp proposed_profile("standard"), do: {:ok, :standard}
  defp proposed_profile("anime"), do: {:ok, :anime}
  defp proposed_profile(_profile), do: {:error, :invalid_payload}

  defp approval_profile(nil, request),
    do: {:ok, request.proposed_media_profile || :standard}

  defp approval_profile(profile, _request), do: proposed_profile(profile)

  defp denial_reason(reason) when is_binary(reason) do
    case String.trim(reason) do
      "" -> {:error, :invalid_payload}
      trimmed when byte_size(trimmed) <= 1_000 -> {:ok, trimmed}
      _ -> {:error, :invalid_payload}
    end
  end

  defp denial_reason(_reason), do: {:error, :invalid_payload}

  defp api_error(conn, :invalid_id), do: json_error(conn, :bad_request, "invalid_id")
  defp api_error(conn, :not_found), do: json_error(conn, :not_found, "not_found")

  defp api_error(conn, :invalid_requester),
    do: json_error(conn, :unprocessable_entity, "invalid_requester")

  defp api_error(conn, :invalid_payload),
    do: json_error(conn, :unprocessable_entity, "invalid_payload")

  defp api_error(conn, :invalid_media_profile),
    do: json_error(conn, :unprocessable_entity, "invalid_media_profile")

  defp api_error(conn, :quota_exceeded), do: json_error(conn, :conflict, "quota_exceeded")
  defp api_error(conn, :not_pending), do: json_error(conn, :conflict, "not_pending")

  defp api_error(conn, :admin_unavailable),
    do: json_error(conn, :service_unavailable, "admin_unavailable")

  defp api_error(conn, %Ecto.Changeset{} = changeset) do
    if unique_error?(changeset),
      do: json_error(conn, :conflict, "request_already_pending"),
      else: json_error(conn, :unprocessable_entity, "invalid_request")
  end

  defp api_error(conn, _reason), do: json_error(conn, :unprocessable_entity, "request_failed")

  defp unique_error?(changeset) do
    Enum.any?(changeset.errors, fn {_field, {_message, metadata}} ->
      metadata[:constraint] == :unique
    end)
  end

  defp json_error(conn, status, error) do
    conn |> put_status(status) |> json(%{error: error})
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
