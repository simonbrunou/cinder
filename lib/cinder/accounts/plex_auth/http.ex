defmodule Cinder.Accounts.PlexAuth.HTTP do
  @moduledoc """
  Real `Cinder.Accounts.PlexAuth` impl, backed by `Req`, against plex.tv's
  PIN-based OAuth API: create/check a PIN (`/api/v2/pins`), fetch the signed-in
  account (`/api/v2/user`), and read the account ids on the household server's share list
  (`/api/servers/<machine id>/shared_servers`, which plex.tv answered in XML even to
  `accept: application/json` on 2026-11-17, so the request asks for XML).
  `server_machine_id/1` instead hits the configured local Plex server's
  unauthenticated `/identity`, and `watchlist/1` hits the account-level discover
  host (`https://discover.provider.plex.tv`). `account/2`, `server_share_ids/3` and
  `server_machine_id/1` take `timeouts: :probe` for the `plex_signin` health check.

  Reads `req_options` from `config :cinder, #{inspect(__MODULE__)}`; the local
  server's `url` comes from `config :cinder, Cinder.Library.MediaServer.Plex` (the
  same key the media-server impl reads). Validated against live plex.tv only at dogfood.
  """
  @behaviour Cinder.Accounts.PlexAuth

  alias Cinder.Accounts.PlexAuth
  alias Cinder.HTTPPolicy

  @max_response_bytes 4 * 1024 * 1024
  @base_url "https://plex.tv"
  # The watchlist is account state, served by plex.tv's discover host rather than the
  # /api/v2 surface the sign-in calls use.
  @discover_base_url "https://discover.provider.plex.tv"
  # One page is the whole watchlist for a household; plex.tv caps the page size anyway.
  @watchlist_page_size 500
  # `timeouts: :probe` (the `PlexAuth.call_opts()` type): 3 s to connect, to get a pooled
  # connection and to receive, the bounds `Cinder.Health` asks of every health probe. The probe
  # makes three calls (the owner's account, `/identity`, the share list); three that each wait out
  # both bounds take 18 s, and `Cinder.Health`'s 15-second budget still ends the check.
  @probe_timeouts [receive_timeout: 3_000, pool_timeout: 3_000, connect_options: [timeout: 3_000]]

  @impl true
  def create_pin do
    request(:post, "/api/v2/pins", params: [strong: true])
    |> result()
    |> case do
      {:ok, %{"id" => id, "code" => code}} -> {:ok, %{id: id, code: code}}
      {:ok, _other} -> {:error, :unexpected_response}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def check_pin(id) do
    request(:get, "/api/v2/pins/#{id}")
    |> result()
    |> case do
      {:ok, %{"authToken" => token}} when is_binary(token) and token != "" -> {:ok, token}
      {:ok, _pending} -> {:error, :pending}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def account(token, opts) do
    request(:get, "/api/v2/user", [headers: [{"x-plex-token", token}]] ++ timeouts(opts))
    |> result()
    |> case do
      {:ok, %{} = body} ->
        {:ok, %{id: body["id"], email: body["email"], username: body["username"]}}

      {:ok, _other} ->
        {:error, :unexpected_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def server_share_ids(token, machine_id, opts) do
    request(
      :get,
      "/api/servers/#{URI.encode(machine_id, &URI.char_unreserved?/1)}/shared_servers",
      [headers: [{"x-plex-token", token}, {"accept", "application/xml"}]] ++ timeouts(opts)
    )
    |> result()
    |> case do
      {:ok, body} when is_binary(body) -> share_user_ids(body)
      {:ok, _other} -> {:error, :unexpected_response}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def server_machine_id(opts) do
    config = Application.get_env(:cinder, Cinder.Library.MediaServer.Plex, [])

    # A nil/blank base_url makes Req raise rather than return {:error, _} — guard it
    # (mirrors Cinder.Library.MediaServer.Plex.health/0).
    case Keyword.get(config, :url) do
      url when url in [nil, ""] -> {:error, :not_configured}
      url -> fetch_identity(url, opts)
    end
  end

  # The `plex_signin` health check's bounds (the `PlexAuth.call_opts()` type); `[]` keeps each
  # call's own.
  defp timeouts(opts) do
    case Keyword.get(opts, :timeouts) do
      :probe -> @probe_timeouts
      nil -> []
    end
  end

  @impl true
  def watchlist(token) do
    req(@discover_base_url)
    |> Req.merge(
      method: :get,
      url: "/library/sections/watchlist/all",
      headers: [{"x-plex-token", token}],
      params: [
        includeGuids: 1,
        "X-Plex-Container-Start": 0,
        "X-Plex-Container-Size": @watchlist_page_size
      ]
    )
    |> HTTPPolicy.bounded_request(@max_response_bytes)
    |> watchlist_result()
    |> case do
      {:ok, %{"MediaContainer" => %{} = container}} -> {:ok, watchlist_entries(container)}
      {:ok, _other} -> {:error, :unexpected_response}
      {:error, reason} -> {:error, reason}
    end
  end

  # A rejected token is its own outcome, not just another failed status: the caller parks that
  # user's sync on it instead of retrying every tick.
  defp watchlist_result({:ok, %{status: status}}) when status in [401, 403],
    do: {:error, :unauthorized}

  defp watchlist_result(response), do: result(response)

  # An empty watchlist comes back as a MediaContainer with no Metadata key at all.
  defp watchlist_entries(%{"Metadata" => metadata}) when is_list(metadata),
    do: Enum.flat_map(metadata, &watchlist_entry/1)

  defp watchlist_entries(_container), do: []

  # Drop anything plex.tv can't map to a TMDB id: there is nothing Cinder could request from it.
  defp watchlist_entry(%{"type" => type} = item) when is_binary(type) do
    case tmdb_id(item) do
      nil -> []
      id -> [%{tmdb_id: id, type: type, title: item["title"], year: item["year"]}]
    end
  end

  defp watchlist_entry(_item), do: []

  defp tmdb_id(%{"Guid" => guids}) when is_list(guids) do
    Enum.find_value(guids, fn
      %{"id" => "tmdb://" <> id} -> positive_integer(id)
      _ -> nil
    end)
  end

  defp tmdb_id(_item), do: nil

  defp positive_integer(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> id
      _ -> nil
    end
  end

  # The share list is XML: a `MediaContainer` root holding one `SharedServer` element per account
  # the server is shared with, its plex.tv account id in `userID`, and the root's `size` saying how
  # many there are. The body also holds each shared account's `accessToken`, email and username,
  # so a body that does not read as that shape is `:unexpected_response` and nothing of it is
  # returned: a root other than `MediaContainer`, a `SharedServer` directly under it whose `userID`
  # is missing or not a positive integer, a root `size` that is missing, not a count or not the
  # number of `SharedServer` elements directly under the root, or anything but whitespace after
  # the root. So a renamed element or attribute refuses at the share-list step and fails the
  # health check, rather than reading as a list shared with nobody. An element deeper in the body
  # is neither read nor counted. A `SharedServer` with a valid `userID` counts whatever its other
  # attributes (`acceptedAt` included) say. The parser refuses a body that declares an entity,
  # and runs with `external_entities: :none`.
  defp share_user_ids(body) do
    options = [
      :disallow_entities,
      external_entities: :none,
      event_fun: &share_event/3,
      event_state: {[], [], nil}
    ]

    case :xmerl_sax_parser.stream(body, options) do
      # The parser stops after the root element and returns what follows it: only whitespace may.
      {:ok, {[], ids, size}, rest} when is_list(ids) and is_binary(rest) ->
        if String.trim(rest) == "" and size == length(ids),
          do: {:ok, Enum.reverse(ids)},
          else: {:error, :unexpected_response}

      _other ->
        {:error, :unexpected_response}
    end
  catch
    _kind, _reason -> {:error, :unexpected_response}
  end

  # The state is `{open element names, ids so far, the root's size}` (`nil` before the root), or
  # `:unexpected` once the body leaves the shape above.
  defp share_event(_event, _location, :unexpected), do: :unexpected

  defp share_event({:startElement, _uri, name, _qname, attributes}, _location, {[], [], nil}) do
    with ~c"MediaContainer" <- name,
         {:ok, size} <- count(attribute(attributes, ~c"size")) do
      {[name], [], size}
    else
      _other -> :unexpected
    end
  end

  defp share_event(
         {:startElement, _uri, ~c"SharedServer" = name, _qname, attributes},
         _location,
         {[~c"MediaContainer"] = open, ids, size}
       ) do
    case attribute(attributes, ~c"userID") |> positive_id() do
      {:ok, id} -> {[name | open], [id | ids], size}
      :error -> :unexpected
    end
  end

  defp share_event(
         {:startElement, _uri, name, _qname, _attributes},
         _location,
         {open, ids, size}
       ),
       do: {[name | open], ids, size}

  defp share_event({:endElement, _uri, name, _qname}, _location, {[name | open], ids, size}),
    do: {open, ids, size}

  defp share_event(_event, _location, state), do: state

  defp attribute(attributes, name) do
    Enum.find_value(attributes, fn
      {_uri, _prefix, ^name, value} -> List.to_string(value)
      _attribute -> nil
    end)
  end

  defp positive_id(value) do
    case count(value) do
      {:ok, id} when id > 0 -> {:ok, id}
      _other -> :error
    end
  end

  defp count(value) when is_binary(value) do
    if String.match?(value, ~r/\A[0-9]{1,18}\z/),
      do: {:ok, String.to_integer(value)},
      else: :error
  end

  defp count(nil), do: :error

  defp fetch_identity(url, opts) do
    config = Application.get_env(:cinder, __MODULE__, [])

    [
      base_url: HTTPPolicy.without_fragment(url),
      receive_timeout: 5_000,
      connect_options: [timeout: 5_000],
      retry: false,
      headers: [{"accept", "application/json"}]
    ]
    |> Keyword.merge(Keyword.get(config, :req_options, []))
    |> Keyword.put(:redirect, false)
    |> Req.new()
    |> Req.merge([method: :get, url: "/identity"] ++ timeouts(opts))
    |> HTTPPolicy.bounded_request(@max_response_bytes)
    |> result()
    |> case do
      {:ok, %{"MediaContainer" => %{"machineIdentifier" => id}}}
      when is_binary(id) and id != "" ->
        {:ok, id}

      {:ok, _other} ->
        {:error, :unexpected_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp req(base_url \\ @base_url) do
    config = Application.get_env(:cinder, __MODULE__, [])

    [
      base_url: HTTPPolicy.without_fragment(base_url),
      receive_timeout: 15_000,
      pool_timeout: 5_000,
      connect_options: [timeout: 5_000],
      retry: false,
      headers: [
        {"x-plex-product", "Cinder"},
        {"x-plex-client-identifier", PlexAuth.client_identifier()},
        {"accept", "application/json"}
      ]
    ]
    |> Keyword.merge(Keyword.get(config, :req_options, []))
    |> Keyword.put(:redirect, false)
    |> Req.new()
  end

  defp request(method, url, options \\ []) do
    req()
    |> Req.merge([method: method, url: url] ++ options)
    |> HTTPPolicy.bounded_request(@max_response_bytes)
  end

  defp result({:ok, %{status: status, body: body}}) when status in 200..299, do: {:ok, body}
  defp result({:ok, %{status: status}}), do: {:error, {:plex_tv_status, status}}
  defp result({:error, reason}), do: {:error, reason}
end
