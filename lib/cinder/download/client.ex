defmodule Cinder.Download.Client do
  @moduledoc """
  Behaviour for the download client (qBittorrent): add a release, report status.

  Fleshed out in Phase 3.
  """

  @callback add(release :: map(), opts :: keyword()) ::
              {:ok, id :: String.t()} | {:error, term()}

  @doc "Finds a previously submitted download by Cinder's operation key."
  @callback find_by_operation_key(key :: String.t()) ::
              {:ok, id :: String.t()} | :not_found | {:error, term()}

  @doc """
  Reports the status of a download by id. The `:ok` map carries at least
  `:state` (`:downloading | :completed | :error`), `:progress` (float), optional
  per-download `:speed` (bytes per second or nil), `:eta` (seconds or nil), and
  `:seeders` (connected seed count or nil — torrent clients only; usenet has no
  seeds, so it is absent/nil there). For a `:completed` download it also carries
  `:content_path` — the on-disk path the importer hardlinks from; the poller will
  not advance a completed download to `:downloaded` until `:content_path` is present.
  An `:error` state may carry an optional human-facing `:reason` (a short string, e.g.
  SABnzbd's paused state or `fail_message`) that the poller persists as the park reason.
  """
  @callback status(id :: String.t()) :: {:ok, map()} | {:error, term()}

  @doc "Lightweight reachability check — `:ok` if the client answers, else `{:error, reason}`."
  @callback health() :: :ok | {:error, term()}

  @doc """
  Lists **only the downloads Cinder itself submitted** — the ones carrying its
  `cinder-<operation_key>` marker (a qBittorrent tag, a SABnzbd job-name suffix).
  A household's hand-added downloads are never reported, so a caller sweeping this
  list can't act on something it doesn't own.

  Each entry is `%{id:, operation_key:, state:}`, where `:state` uses the same
  `:downloading | :completed | :error` vocabulary as `status/1`. An entry whose
  marker can't be parsed back to a key is omitted rather than reported keyless.
  """
  @callback list_managed() ::
              {:ok, [%{id: String.t(), operation_key: String.t(), state: atom()}]}
              | {:error, term()}

  @doc """
  Removes a tracked download by `id` (qBittorrent infohash / SABnzbd nzo_id, as
  passed to `status/1`). **Idempotent: an unknown/missing id returns `:ok`** (the
  download may have auto-removed on completion). `opts` carries `delete_files:`
  (default `true` — a cancelled pre-`:available` item's partial download is junk).
  Callers skip this entirely when the tracked download id is nil.
  """
  @callback remove(id :: String.t(), opts :: keyword()) :: :ok | {:error, term()}
end
