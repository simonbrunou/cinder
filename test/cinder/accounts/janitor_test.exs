defmodule Cinder.Accounts.JanitorTest do
  # async: false — the Janitor runs in its own GenServer process, which reaches the test-owned DB
  # connection only under the shared Sandbox (DataCase uses `shared: not async`). The gating test
  # also mutates the global `:start_poller` env key.
  use Cinder.DataCase, async: false

  import Cinder.AccountsFixtures

  alias Cinder.Accounts
  alias Cinder.Accounts.{Janitor, UserToken}
  alias Cinder.Audit.AdminAudit
  alias Cinder.Catalog.BlockedRelease

  # A poll stamps last-run into process-global :persistent_term (PollerSkeleton.status/0); erase it
  # so a recorded run can't bleed into another suite that reads Cinder.Jobs.statuses/0.
  setup do
    on_exit(fn -> :persistent_term.erase({Janitor, :last_run}) end)
    :ok
  end

  test "sweeps expired session and change-email tokens; fresh ones of both contexts survive" do
    user = user_fixture()

    # Session tokens: the raw token binary is stored directly, so we can look it up by value.
    expired_session = Accounts.generate_user_session_token(user)
    offset_user_token(expired_session, -15, :day)
    fresh_session = Accounts.generate_user_session_token(user)

    # Change-email tokens (context "change:...", carrying a `sent_to` email address).
    expired_change = insert_email_token(user, "change:old@example.com", -15)
    fresh_change = insert_email_token(user, "change:new@example.com", 0)

    {:ok, pid} = start_supervised({Janitor, name: :janitor_tokens})
    assert :ok = Janitor.poll(pid)

    refute Repo.get_by(UserToken, token: expired_session)
    assert Repo.get_by(UserToken, token: fresh_session)
    refute Repo.get(UserToken, expired_change.id)
    assert Repo.get(UserToken, fresh_change.id)
  end

  test "sweeps admin_audit rows older than the retention window; recent ones survive" do
    stale = Repo.insert!(%AdminAudit{action: "delete_user", entity_type: "user", entity_id: 1})
    backdate(stale, -400)
    recent = Repo.insert!(%AdminAudit{action: "delete_movie", entity_type: "movie", entity_id: 2})

    {:ok, pid} = start_supervised({Janitor, name: :janitor_audit})
    assert :ok = Janitor.poll(pid)

    refute Repo.get(AdminAudit, stale.id)
    assert Repo.get(AdminAudit, recent.id)
  end

  test "sweeps blocked_releases older than the retention window; recent ones survive" do
    stale = Repo.insert!(%BlockedRelease{release_title: "Old.Show.S01E01.1080p"})
    backdate(stale, -200)
    recent = Repo.insert!(%BlockedRelease{release_title: "Fresh.Show.S01E01.1080p"})

    {:ok, pid} = start_supervised({Janitor, name: :janitor_blocked})
    assert :ok = Janitor.poll(pid)

    refute Repo.get(BlockedRelease, stale.id)
    assert Repo.get(BlockedRelease, recent.id)
  end

  test "is supervised only when :start_poller is enabled" do
    original = Application.get_env(:cinder, :start_poller, true)
    on_exit(fn -> Application.put_env(:cinder, :start_poller, original) end)

    Application.put_env(:cinder, :start_poller, false)
    refute Janitor in Cinder.Application.poller_child()

    Application.put_env(:cinder, :start_poller, true)
    assert Janitor in Cinder.Application.poller_child()
  end

  defp insert_email_token(user, context, days_ago) do
    {_encoded, struct} = UserToken.build_email_token(user, context)
    row = Repo.insert!(struct)
    if days_ago != 0, do: backdate(row, days_ago)
    row
  end

  defp backdate(%schema{id: id}, days_ago) do
    dt = DateTime.add(DateTime.utc_now(:second), days_ago, :day)
    Repo.update_all(from(r in schema, where: r.id == ^id), set: [inserted_at: dt])
  end
end
