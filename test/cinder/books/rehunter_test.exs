defmodule Cinder.Books.RehunterTest do
  # async: false — the sweep runs in its own process against the test-owned (shared Sandbox)
  # connection, and status/0 stamps process-global :persistent_term.
  use Cinder.DataCase, async: false

  @moduletag :capture_log

  alias Cinder.Books
  alias Cinder.Books.{BookTarget, Rehunter}

  @rehunt_after :timer.hours(24)

  setup do
    on_exit(fn -> :persistent_term.erase({Rehunter, :last_run}) end)
    # Long interval: every test drives the sweep synchronously via poll/0, never the timer.
    start_supervised!({Rehunter, interval: 60_000})
    :ok
  end

  defp backdate(id, ago_ms) do
    at = DateTime.add(DateTime.utc_now(), -ago_ms, :millisecond) |> DateTime.truncate(:second)
    Repo.update_all(from(t in BookTarget, where: t.id == ^id), set: [updated_at: at])
  end

  defp poll, do: assert(:ok = Rehunter.poll())

  test "a held target with hold_transient: false is never touched, at any cooldown" do
    target = ebook_target()
    {:ok, held} = Books.hold_target(target, :blocked_content, "Bad Release", false)
    backdate(held.id, @rehunt_after * 10)

    poll()

    assert Repo.get!(BookTarget, held.id).status == :held
  end

  test "a held target with hold_transient: true inside the cooldown is left alone" do
    target = ebook_target()
    {:ok, held} = Books.hold_target(target, :download_failed, "Retryable Release", true)
    backdate(held.id, @rehunt_after - :timer.minutes(1))

    poll()

    assert Repo.get!(BookTarget, held.id).status == :held
  end

  test "a held target with hold_transient: true past cooldown returns to :monitored with
        hold_reason and hold_transient both cleared, blocklist untouched" do
    target = ebook_target()
    {:ok, held} = Books.hold_target(target, :download_failed, "Retryable Release", true)
    backdate(held.id, @rehunt_after + :timer.minutes(1))

    poll()

    reloaded = Repo.get!(BookTarget, held.id)
    assert reloaded.status == :monitored
    assert reloaded.hold_reason == nil
    assert reloaded.hold_transient == nil
    assert Books.blocked_release_titles(held.id) == ["Retryable Release"]
  end

  test "never touches an in-flight (:monitored) or :available target" do
    monitored = ebook_target()
    backdate(monitored.id, @rehunt_after * 10)

    {:ok, available} =
      Books.Files.record_import(ebook_target(), %{
        path: "/tmp/book-#{monitored.id}-rehunt.epub",
        size: 1000,
        format: :epub
      })

    backdate(available.book_target_id, @rehunt_after * 10)

    poll()

    assert Repo.get!(BookTarget, monitored.id).status == :monitored
  end

  test "does nothing at all when disabled" do
    Application.put_env(:cinder, Rehunter, enabled: false, rehunt_after: @rehunt_after)
    on_exit(fn -> Application.delete_env(:cinder, Rehunter) end)

    target = ebook_target()
    {:ok, held} = Books.hold_target(target, :download_failed, "Retryable Release", true)
    backdate(held.id, @rehunt_after * 10)

    poll()

    assert Repo.get!(BookTarget, held.id).status == :held
  end

  defp ebook_target do
    id = unique_id()

    {:ok, profile} =
      Cinder.Catalog.create_profile(%{name: "Ebooks #{id}", kind: :ebook, handling: :standard})

    {:ok, work} =
      Books.upsert_work(%{
        title: "Work #{id}",
        identifier: %{provider: "openlibrary", kind: "work", foreign_id: id}
      })

    {:ok, target} = Books.monitor_target(work, :ebook, profile)
    target
  end

  defp unique_id, do: Integer.to_string(System.unique_integer([:positive]))
end
