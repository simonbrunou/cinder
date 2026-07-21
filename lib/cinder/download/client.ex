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
  """
  @callback status(id :: String.t()) :: {:ok, map()} | {:error, term()}

  @doc "Lightweight reachability check — `:ok` if the client answers, else `{:error, reason}`."
  @callback health() :: :ok | {:error, term()}

  @doc """
  Removes a tracked download by `id` (qBittorrent infohash / SABnzbd nzo_id, as
  passed to `status/1`). **Idempotent: an unknown/missing id returns `:ok`** (the
  download may have auto-removed on completion). `opts` carries `delete_files:`
  (default `true` — a cancelled pre-`:available` item's partial download is junk).
  Callers skip this entirely when the tracked download id is nil.
  """
  @callback remove(id :: String.t(), opts :: keyword()) :: :ok | {:error, term()}
end
