defmodule Cinder.Notifier.Discord do
  @moduledoc """
  Discord-webhook notifier: when a webhook URL is configured, posts embeds for approvals,
  availability, and failures. Best-effort: a failed post is logged and swallowed so a Discord
  outage never touches the pipeline, and the request carries a bounded `receive_timeout` so a
  hung webhook can't stall synchronous poller call sites. Registered alongside `Cinder.Notifier.Log`
  and `Cinder.Notifier.Email` in `Cinder.Notifier.Dispatcher`, the configured `:cinder, :notifier`
  default — `Cinder.Notifier.notify/1` catches raises on top of that.

  The webhook URL is a `Cinder.Settings` registry entry, overlaid onto
  `Application.get_env(:cinder, __MODULE__)[:webhook_url]`.
  """
  @behaviour Cinder.Notifier
  alias Cinder.Accounts.User
  alias Cinder.Catalog.Episode
  alias Cinder.HTTPPolicy
  alias Cinder.Util
  require Logger

  @green 0x2ECC71
  @red 0xE74C3C
  # Neither success nor failure: something is sitting in a queue waiting for an admin to act.
  @blue 0x3498DB
  @image_base "https://image.tmdb.org/t/p/w342"
  @maintenance_names %{
    movie_pipeline: "Movie pipeline",
    tv_pipeline: "TV pipeline",
    series_refresh: "Monitored series refresh",
    subtitle_backfill: "Subtitle backfill",
    scan_movies: "Movie library scan",
    scan_tv: "TV library scan"
  }

  # Bounded so a hung/dead webhook can't stall the synchronous notify/1 call sites (poller ticks,
  # the admin Approve handler). Bounds both connect (Mint's default is ~30s) and the response
  # wait — 3s each, matching the other service probes (Prowlarr/TMDB/Jellyfin/…) and the ~3s
  # assumption behind settings_live's synchronous Test button. retry: false stops a Test-button
  # GET retrying a bad webhook.
  @default_req_options [receive_timeout: 3_000, connect_options: [timeout: 3_000], retry: false]
  @max_response_bytes 4 * 1024 * 1024

  @impl true
  def notify(event) do
    with url when is_binary(url) <- webhook_url(),
         embed when is_map(embed) <- embed(event) do
      post(url, embed)
    end

    :ok
  end

  @doc """
  Validates the configured webhook for the `/settings` Test button via a GET (Discord's
  "Get Webhook with Token" endpoint — checks the webhook without posting a message).
  """
  @spec health() :: :ok | {:error, term()}
  def health do
    case webhook_url() do
      nil -> {:error, :not_configured}
      url -> request(:get, url) |> classify()
    end
  end

  # --- embeds (one per event; nil for anything unknown so notify/1 skips the post) ---

  defp embed({:request_approved, request}),
    do:
      with_poster(
        %{
          title: "✅ Request approved",
          description: "#{request_line(request)} — for #{requester(request)}",
          color: @green
        },
        request.poster_path
      )

  defp embed({:request_created, request}),
    do:
      with_poster(
        %{
          title: "🙋 Request awaiting approval",
          description: "#{request_line(request)} — from #{requester(request)}",
          color: @blue
        },
        request.poster_path
      )

  # Matches the request_approved/request_created shape (title + requester display name, never the
  # email — #184), plus the admin's free-text reason when one was given. The admin channel already
  # carries this requester content for the sibling request events, so a denial belongs here too.
  defp embed({:request_denied, request, reason}),
    do:
      with_poster(
        %{
          title: "🚫 Request denied",
          description: denied_line(request, reason),
          color: @red
        },
        request.poster_path
      )

  # Admin-channel awareness that a delivered title has a problem. Requester display name only
  # (never the email — #184), category + title, and NEVER the free-text `detail` (user input).
  defp embed({:issue_reported, report}),
    do: %{
      title: "⚠️ Issue reported",
      description: "#{issue_line(report)} — from #{requester(report)}",
      color: @blue
    }

  defp embed({:user_registered, user}),
    do: %{
      title: "👤 Account awaiting activation",
      description:
        "#{display_name(user)} — approve on the Users page before they can request anything",
      color: @blue
    }

  defp embed({:movie_available, movie}),
    do:
      with_poster(
        %{title: "🎬 Now available", description: title_year(movie), color: @green},
        movie.poster_path
      )

  defp embed({:movie_failed, movie, reason}), do: failure_embed("Movie failed", movie, reason)

  defp embed({:movie_upgrade_failed, movie, reason}),
    do: failure_embed("Upgrade failed", movie, reason)

  defp embed({:season_available, season}),
    do:
      with_poster(
        %{
          title: "📺 Season now available",
          description: "#{season.title} — Season #{season.season_number}",
          color: @green
        },
        season.poster_path
      )

  defp embed({:grab_failed, grab, reason}),
    do: %{title: "TV grab ##{grab.id} failed", description: inspect(reason), color: @red}

  # A newly created operator-action hold: something is queued waiting for an admin to act (@blue,
  # neither success nor failure). No requester PII — a grab is operator-facing, identified by id.
  defp embed({:operator_hold, %{id: id}, reason}),
    do: %{
      title: "⏸️ Download needs your attention",
      description: "TV grab ##{id} #{hold_summary(reason)} — resolve it on /activity",
      color: @blue
    }

  defp embed({:episodes_search_exhausted, episodes}) do
    {summary, poster} = episodes_summary(episodes)

    with_poster(
      %{
        title: "Episode search exhausted",
        description: "#{summary} — giving up until a manual Search",
        color: @red
      },
      poster
    )
  end

  defp embed({:maintenance_completed, key}),
    do: %{title: "Maintenance completed", description: maintenance_name(key), color: @green}

  defp embed({:maintenance_failed, key, reason}),
    do: %{
      title: "Maintenance failed",
      description: "#{maintenance_name(key)} — #{inspect(reason)}",
      color: @red
    }

  # `:account_activated` is deliberately absent: it's a per-user "you're in now" message (Email's
  # job), not a household-channel signal — the admin already saw `:user_registered` and did the
  # activating. Keeping it out of Discord also keeps requester PII off this admin channel (#184).
  defp embed(_other), do: nil

  # --- helpers ---

  defp maintenance_name(key), do: Map.get(@maintenance_names, key, inspect(key))

  defp hold_summary(:needs_mapping), do: "needs episode mapping"
  defp hold_summary(:verification_blocked), do: "failed release verification"
  defp hold_summary(:residual_files), do: "has files awaiting a fold/part decision"
  defp hold_summary(other), do: "needs attention (#{inspect(other)})"

  defp failure_embed(title, movie, reason) do
    with_poster(
      %{title: title, description: "#{title_year(movie)} — #{inspect(reason)}", color: @red},
      movie.poster_path
    )
  end

  defp title_year(%{title: title, year: year}) when not is_nil(year), do: "#{title} (#{year})"
  defp title_year(%{title: title}), do: title

  # A season request's own :title column holds only the series name, so rendering it bare would
  # read "Frieren (2023)" for a request that was actually for one season.
  defp request_line(%{target_type: "season", season_number: number} = request)
       when not is_nil(number),
       do: "#{title_year(request)} — Season #{number}"

  defp request_line(request), do: title_year(request)

  # An issue report carries no `year`, so it renders its bare title + season + category (no
  # `detail` — user free-text stays off the admin channel).
  defp issue_line(%{target_type: "season", season_number: n, title: t, category: c})
       when not is_nil(n),
       do: "#{t} — Season #{n} · #{issue_category(c)}"

  defp issue_line(%{title: t, category: c}), do: "#{t} · #{issue_category(c)}"

  # Plain English, matching the other embed labels (the household channel is single-locale).
  defp issue_category(:wrong_content), do: "Wrong content"
  defp issue_category(:audio), do: "Audio"
  defp issue_category(:subtitles), do: "Subtitles"
  defp issue_category(:playback), do: "Playback"
  defp issue_category(:other), do: "Other"
  defp issue_category(other), do: to_string(other)

  defp denied_line(request, reason) do
    base = "#{request_line(request)} — for #{requester(request)}"

    case Util.blank_to_nil(reason) do
      nil -> base
      reason -> "#{base} (#{reason})"
    end
  end

  # %Ecto.Association.NotLoaded{} does not match `%User{}`, so an un-preloaded :user degrades to
  # the id rather than raising — and Cinder.Notifier.notify/1 swallows raises, which would turn a
  # missing preload into a silently-missing Discord post.
  defp requester(%{user: %User{} = user}), do: display_name(user)
  defp requester(%{user_id: id}), do: "user ##{id}"

  # A non-PII display identity: the linked Plex username if one is set, else an opaque `user #<id>`.
  # The requester's email is deliberately never sent to Discord — it's a third-party processor and
  # an in-app identifier is all the household channel needs (GDPR data minimisation).
  defp display_name(%User{plex_username: username})
       when is_binary(username) and username != "",
       do: sanitize(username)

  defp display_name(%User{id: id}), do: "user ##{id}"

  # `plex_username` is externally sourced (whatever the linked Plex account reports), so it gets
  # markdown/mention sanitizing: Discord renders embed text as markdown, and both `[x](url)`
  # (masked link) and `<https://url>` (auto-link) would otherwise put an attacker-controlled link
  # in the admin's channel.
  #
  # This is a whitelist, not an escape of known-bad characters: a blacklist has to enumerate every
  # metacharacter the renderer honours, and missing one is a live vector. Dropping `:` and `/` in
  # particular means no URL scheme can survive, so no renderer can be talked into making a link
  # regardless of which syntax it supports. An ordinary username is unaffected.
  #
  # Titles are not sanitized — those come from TMDB, not from a user.
  defp sanitize(text) do
    text
    |> String.replace(~r/[^A-Za-z0-9._%+'@-]/, "")
    # A username like "@everyone"/"@here" survives the whitelist above. A zero-width space keeps
    # it inert even if this text ever moves into `content`, where Discord would otherwise resolve
    # it.
    #
    # No word boundary, matching discord.py's and discord.js's canonical escapes: Discord matches
    # the substring, so "@everyone" inside "@everyones" would still ping. The zero-width space
    # lands mid-word but renders identically.
    |> String.replace(~r/@(everyone|here)/i, "@​\\1")
  end

  # A blank poster_path (nil or "") yields no thumbnail: an empty string would otherwise build a
  # bare base URL with no image path and render as a broken thumbnail in Discord.
  defp with_poster(embed, path) when is_binary(path) and path != "",
    do: Map.put(embed, :thumbnail, %{url: @image_base <> path})

  defp with_poster(embed, _path), do: embed

  defp episodes_summary([%{season: %{series: series}} | _] = episodes) do
    codes =
      Enum.map_join(episodes, ", ", fn ep ->
        Episode.code(ep.season.season_number, ep.episode_number)
      end)

    {"#{series.title} — #{codes}", series.poster_path}
  end

  defp episodes_summary(episodes), do: {"#{length(episodes)} episode(s)", nil}

  defp webhook_url do
    :cinder
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:webhook_url)
    |> Util.blank_to_nil()
  end

  # Matches the repo's Req idiom (jellyfin.ex): a base req from config's req_options merged onto the
  # bounded defaults, then Req.post / Req.get with the full webhook url. req_options carries the
  # test plug (+ retry: false) in :test and is empty in prod.
  defp base_req do
    req_options = :cinder |> Application.get_env(__MODULE__, []) |> Keyword.get(:req_options, [])

    @default_req_options
    |> Keyword.merge(req_options)
    |> Keyword.put(:redirect, false)
    |> Req.new()
  end

  defp post(url, embed) do
    # allowed_mentions: no parse — Discord's own documented switch, so nothing in a payload can
    # ping a user, role, or the channel regardless of what the text turns out to contain. The
    # sanitizing in sanitize/1 is the belt to this pair of braces.
    request(:post, url, json: %{embeds: [embed], allowed_mentions: %{parse: []}})
    |> classify()
    |> log_if_error()
  end

  defp request(method, url, options \\ []) do
    base_req()
    |> Req.merge([method: method, url: url] ++ options)
    |> HTTPPolicy.bounded_request(@max_response_bytes)
  end

  defp classify({:ok, %{status: status}}) when status in 200..299, do: :ok
  defp classify({:ok, %{status: status}}), do: {:error, {:http_status, status}}
  defp classify({:error, reason}), do: {:error, reason}

  defp log_if_error(:ok), do: :ok

  defp log_if_error({:error, reason} = error) do
    Logger.warning("Discord notify failed: #{HTTPPolicy.sanitize_log(reason)}")
    error
  end
end
