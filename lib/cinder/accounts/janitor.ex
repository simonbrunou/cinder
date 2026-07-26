defmodule Cinder.Accounts.Janitor do
  @moduledoc """
  Periodic retention janitor (storage limitation). Each tick prunes rows that have outlived their
  purpose — the first two under GDPR (Art.5(1)(e)) for personal data, the third plain housekeeping:

  * `users_tokens` rows older than `Cinder.Accounts.UserToken.max_validity_in_days/0` — expired
    session and change-email tokens (the latter carrying a `sent_to` email address) are only
    filtered by validity at query time, never garbage-collected, so without this they linger
    indefinitely;
  * `admin_audit` rows older than the retention window (`@audit_retention_days`, default 365);
  * `blocked_releases` rows older than `@blocked_release_retention_days` (default 180) — release
    rejections (mostly anime verification blocks) accrue one row per distinct release name and are
    never re-blocked, so once a title has moved well past a bad release its row is dead weight.

  Holds no state — re-derives its work from the DB each tick, so it recovers cleanly after a crash.
  Runs daily, `:start_poller`-gated like the pollers so the suite doesn't auto-run it. Each delete
  is wrapped in `isolate/2`: a transient SQLite `Exqlite.Error` (busy) is logged and retried next
  tick rather than crash-looping the worker.

  These are ordinary bulk `Repo.delete_all` writes, accounts-side — like `Cinder.Accounts`'s own
  token deletes they do NOT go through `Catalog.transition`, which is the movie/episode pipeline
  status choke-point only.

  Lifecycle is `Cinder.Download.PollerSkeleton` (`stateful: false`). The interval is module config:
  `config :cinder, #{inspect(__MODULE__)}, interval: <ms>`; the audit window is
  `config :cinder, #{inspect(__MODULE__)}, audit_retention_days: <int>`.
  """
  import Ecto.Query

  alias Cinder.Accounts.UserToken
  alias Cinder.Audit.AdminAudit
  alias Cinder.Catalog.BlockedRelease
  alias Cinder.Repo

  @default_interval :timer.hours(24)
  @audit_retention_days 365
  @blocked_release_retention_days 180
  use Cinder.Download.PollerSkeleton,
    log_prefix: "janitor",
    stateful: false,
    first_interval: :timer.minutes(1)

  defp do_poll do
    isolate("expired token sweep", &sweep_expired_tokens/0)
    isolate("admin audit sweep", &sweep_stale_audit/0)
    isolate("stale blocked-release sweep", &sweep_stale_blocked_releases/0)
    :ok
  end

  # Expired tokens outlive their validity window (session 14d / change-email 7d) as dead rows —
  # verify queries filter them out, but nothing deletes them. Prune everything past the longest
  # window, derived from UserToken's own constants so the number is never duplicated here.
  defp sweep_expired_tokens do
    cutoff = DateTime.add(DateTime.utc_now(:second), -UserToken.max_validity_in_days(), :day)
    Repo.delete_all(from t in UserToken, where: t.inserted_at < ^cutoff)
  end

  defp sweep_stale_audit do
    cutoff = DateTime.add(DateTime.utc_now(:second), -audit_retention_days(), :day)
    Repo.delete_all(from a in AdminAudit, where: a.inserted_at < ^cutoff)
  end

  # Blocklist rows are not personal data, so the window is a fixed module attribute (no
  # per-instance config / no `/settings` field) — 180d is generous enough that a title's own
  # re-block would refresh a still-relevant row long before it ages out.
  defp sweep_stale_blocked_releases do
    cutoff = DateTime.add(DateTime.utc_now(:second), -@blocked_release_retention_days, :day)
    Repo.delete_all(from b in BlockedRelease, where: b.inserted_at < ^cutoff)
  end

  defp audit_retention_days do
    :cinder
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:audit_retention_days, @audit_retention_days)
  end
end
