defmodule Cinder.Health do
  @moduledoc """
  Reachability checks for the external services the pipeline depends on
  (metadata provider, indexer, download client(s), media server). Each check resolves the
  configured impl behind its behaviour and calls its `health/0`. The `/dashboard` service-health
  panel uses this to surface an unwired/unreachable dependency instead of leaving it to stall
  silently and only show up in the logs.

  `check_all/0` runs every probe concurrently (`Task.async_stream/3`), so the sweep's wall clock
  is bounded by the slowest configured row instead of the sum of every row's own timeout.
  """
  alias Cinder.Books.Metadata
  alias Cinder.Download
  alias Cinder.LibraryKind

  # Backstop above the worst individual probe today (~12s: qBittorrent/SABnzbd's login + probe
  # round trip, or Plex's 2 video kinds × 6s) — the normal bound is each impl's own timeout, this
  # only guards against a probe that ignores its own timeout and hangs outright. Overridable via
  # `:health_probe_timeout_ms` so tests can shrink it instead of waiting out the real default.
  @probe_timeout_ms 15_000

  @doc """
  Checks every configured external service concurrently and returns a list of
  `%{label: String.t(), status: :ok | {:warning, term()} | {:error, term()}}`, ordered
  metadata (TMDB) → indexer → books metadata providers → download clients (sorted protocols) →
  media server → audiobook server → library rows (video kinds then book kinds) → media info →
  subtitles → stored credentials. A probe that exceeds the timeout budget reports
  `{:error, :timeout}` for its row without affecting any other row.
  """
  def check_all do
    probes = probes()
    timeout = Application.get_env(:cinder, :health_probe_timeout_ms, @probe_timeout_ms)

    probes
    |> Task.async_stream(fn {_label, fun} -> fun.() end,
      ordered: true,
      max_concurrency: length(probes),
      on_timeout: :kill_task,
      timeout: timeout
    )
    |> Enum.zip(probes)
    |> Enum.reduce([], fn
      {{:ok, :skip}, _probe}, rows ->
        rows

      {{:ok, status}, {label, _fun}}, rows ->
        [%{label: label, status: status} | rows]

      {{:exit, :timeout}, {label, _fun}}, rows ->
        [%{label: label, status: {:error, :timeout}} | rows]

      {{:exit, reason}, {label, _fun}}, rows ->
        [%{label: label, status: {:error, reason}} | rows]
    end)
    |> Enum.reverse()
  end

  @doc """
  Checks a single service against its currently-applied config, returning
  `:ok | {:warning, term()} | {:error, term()}`. Used by the settings "Test connection" buttons.
  `service` is `:tmdb | :indexer | :media_server | :audiobook_server | :discord | :subtitles |
  :media_info | {:download, protocol} | {:books_metadata, provider}`.
  """
  def check_service(:tmdb), do: run(Application.fetch_env!(:cinder, :tmdb))
  def check_service(:indexer), do: run(Application.fetch_env!(:cinder, :indexer))
  def check_service(:media_server), do: run(Application.fetch_env!(:cinder, :media_server))

  def check_service(:audiobook_server),
    do: run(Application.fetch_env!(:cinder, :audiobook_server))

  def check_service(:discord), do: run(Cinder.Notifier.Discord)

  def check_service({:migration_source, source}) do
    case Application.fetch_env!(:cinder, :migration_sources) do
      %{^source => mod} -> run(mod)
      _sources -> {:error, :not_configured}
    end
  end

  # media_info is `nil` when explicitly disabled (`config :cinder, media_info: nil`) — not a
  # broken install, so this reads the same as an opted-out feature (mirrors :subtitles below).
  def check_service(:media_info) do
    case Application.get_env(:cinder, :media_info) do
      nil -> {:error, :not_configured}
      mod -> run(mod)
    end
  end

  def check_service(:subtitles) do
    case Application.get_env(:cinder, Application.get_env(:cinder, :subtitles_provider), [])[
           :api_key
         ] do
      blank when blank in [nil, ""] -> {:error, :not_configured}
      _ -> run(Application.fetch_env!(:cinder, :subtitles_provider))
    end
  end

  def check_service({:download, protocol}) do
    case Download.client_for(protocol) do
      {:ok, mod} -> run(mod)
      :error -> {:error, :not_configured}
    end
  end

  def check_service({:books_metadata, provider}) do
    case Enum.find(Metadata.providers(), &(&1.provider() == provider)) do
      nil -> {:error, :not_configured}
      mod -> run(mod)
    end
  end

  def check_service({:library, kind}) do
    case Application.get_env(:cinder, :"#{LibraryKind.root_role(kind)}_library_path") do
      blank when blank in [nil, ""] -> {:error, :not_configured}
      path -> library_writable(path)
    end
  end

  # Ordered list of `{label, fun}` probes — the label is known upfront (cheap, no network); `fun`
  # is a 0-arity closure that runs the actual probe and returns `status | :skip`. `check_all/0`
  # fans these out through `Task.async_stream/3`; this function only builds the list, it never
  # calls a probe itself. `:skip` replaces the old "omit the row entirely" behaviour for rows
  # that are `{:error, :not_configured}` (subtitles, media_info, book library kinds) or have no
  # finding (`secrets_probe/0`'s empty case).
  defp probes do
    [tmdb_probe(), indexer_probe()] ++
      books_metadata_probes() ++
      download_probes() ++
      [media_server_probe(), audiobook_server_probe()] ++
      library_probes() ++
      [media_info_probe(), subtitles_probe(), secrets_probe()]
  end

  # TMDB drives discovery, requests, and the monitored-series refresh; an expired token leaves
  # those failing while the rest of the panel stays green — so it gets its own aggregate row.
  defp tmdb_probe do
    mod = Application.fetch_env!(:cinder, :tmdb)
    {"Metadata (TMDB)", fn -> run(mod) end}
  end

  defp indexer_probe do
    mod = Application.fetch_env!(:cinder, :indexer)
    {"Indexer (#{short(mod)})", fn -> run(mod) end}
  end

  # One row per configured metadata provider (Open Library, Hardcover, …) — the genuinely
  # missing health surface per the B5c plan (book-root/publisher health already exists below,
  # via `library_probes/0`).
  defp books_metadata_probes do
    for mod <- Metadata.providers() do
      {"Metadata (#{short(mod)})", fn -> run(mod) end}
    end
  end

  defp media_server_probe do
    mod = Application.fetch_env!(:cinder, :media_server)
    {"Media server (#{short(mod)})", fn -> run(mod) end}
  end

  defp audiobook_server_probe do
    mod = Application.fetch_env!(:cinder, :audiobook_server)
    {"Audiobook server (#{short(mod)})", fn -> run(mod) end}
  end

  # One row per configured protocol (sorted for a stable display order).
  defp download_probes do
    for protocol <- Enum.sort(Download.available_protocols()) do
      {:ok, mod} = Download.client_for(protocol)
      {"Download (#{protocol} · #{short(mod)})", fn -> run(mod) end}
    end
  end

  # One row per library kind (Movies, TV, …); reuses the writable-path probe so a missing or
  # unwritable root shows red on /status — the visible signal that an import is holding. Video
  # kinds always show a row; book kinds skip the row until their root is configured.
  defp library_probes do
    video_probes =
      for kind <- Cinder.Library.kinds() do
        {"Library (#{kind})", fn -> check_service({:library, kind}) end}
      end

    book_probes =
      for kind <- LibraryKind.all(), not LibraryKind.video?(kind) do
        {"Library (#{LibraryKind.label(kind)})", fn -> skip_if_unconfigured({:library, kind}) end}
      end

    video_probes ++ book_probes
  end

  # Subtitles is off-by-default (no api_key ⇒ :not_configured) — skip the row entirely rather
  # than show red noise on an install that hasn't opted into the feature.
  defp subtitles_probe do
    {"Subtitles (OpenSubtitles)", fn -> skip_if_unconfigured(:subtitles) end}
  end

  # media_info is enabled by default (ffprobe), but an operator can turn it off entirely — skip
  # the row rather than show red noise on an install that deliberately disabled it.
  defp media_info_probe do
    {"Media info (ffprobe)", fn -> skip_if_unconfigured(:media_info) end}
  end

  defp skip_if_unconfigured(service) do
    case check_service(service) do
      {:error, :not_configured} -> :skip
      status -> status
    end
  end

  # A stored secret that can't be decrypted (SECRET_KEY_BASE changed) is skipped at load, so every
  # service row above can read green while the pipeline is actually credential-less. Surface it as
  # its own red row naming the count; skip the row entirely when every secret decodes. Reads the
  # DB, so it goes through `safely/1` — a checkout failure (or anything else) degrades to "no
  # finding" rather than taking the whole panel down.
  #
  # This runs inside the same `Task.async_stream/3` sweep as every other probe, not inline in the
  # caller. `Cinder.Repo`'s Ecto SQL Sandbox ownership (via `DBConnection.Ownership`) resolves the
  # checked-out connection through the `$callers` process-dictionary chain that `Task` sets on the
  # spawned process — the same mechanism Mox's private mode already relies on for `run/1`'s
  # network probes — so no sandbox allowance is needed here.
  defp secrets_probe do
    {"Stored credentials",
     fn ->
       case safely(fn -> Cinder.Settings.undecryptable_secret_keys() end) do
         keys when is_list(keys) and keys != [] ->
           {:error, {:undecryptable_secrets, length(keys)}}

         _ ->
           :skip
       end
     end}
  end

  # Both probes run inside a LiveView async task, so a misbehaving impl must degrade to a
  # red row rather than take the whole panel down. `catch` covers exits/throws (e.g. a
  # pool-checkout timeout deep in the HTTP stack) that `rescue` would miss.
  defp safely(fun) do
    fun.()
  rescue
    e -> {:error, e}
  catch
    kind, value -> {:error, {kind, value}}
  end

  defp run(mod) do
    safely(fn ->
      case mod.health() do
        :ok -> :ok
        {:warning, _} = warning -> warning
        {:error, _} = err -> err
      end
    end)
  end

  # The library import target isn't a behaviour with health/0; "reachable" means the
  # configured path is writable. `mkdir_p` alone doesn't prove that: it's a no-op on an
  # existing directory, so a read-only mount or a Docker UID/GID mismatch reports healthy
  # while every import then fails. Actually create and remove a uniquely named, disposable
  # entry through the same Filesystem behaviour the import uses (mockable in tests).
  defp library_writable(path) do
    safely(fn ->
      fs = Application.fetch_env!(:cinder, :filesystem)
      probe = Path.join(path, ".cinder-health-probe-#{System.unique_integer([:positive])}")

      with :ok <- fs.mkdir_p(path),
           :ok <- fs.write_exclusive(probe, "") do
        fs.rm(probe)
        :ok
      end
    end)
  end

  defp short(mod), do: mod |> Module.split() |> List.last()
end
