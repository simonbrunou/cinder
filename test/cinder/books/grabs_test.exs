defmodule Cinder.Books.GrabsTest do
  @moduledoc """
  `track/2`'s broadcast: added in B4c so `/books/:id` can render live download progress, mirroring
  `Cinder.Catalog.Grabs.update_grab_download_metrics/2`'s own broadcast-only-on-real-change guard.
  Every other write in this module (`create`, `mark_downloaded`, `bump_attempts`, `delete`)
  deliberately does not broadcast — see the module doc — so this file only covers `track/2`.
  """
  use Cinder.DataCase, async: false

  alias Cinder.Books
  alias Cinder.Books.Grabs
  alias Cinder.Catalog

  setup do
    id = unique_id()

    {:ok, profile} =
      Catalog.create_profile(%{name: "Ebooks #{id}", kind: :ebook, handling: :standard})

    {:ok, work} =
      Books.upsert_work(%{
        title: "Progress Test #{id}",
        identifier: identifier("openlibrary", "work", id)
      })

    {:ok, target} = Books.monitor_target(work, :ebook, profile)
    {:ok, grab} = Grabs.create(target.id, "remote-#{id}", :torrent, "Release #{id}")

    %{grab: grab}
  end

  test "a real progress change writes and broadcasts {:book_grab_updated, grab}", %{grab: grab} do
    Books.subscribe_targets()

    assert {:ok, updated} =
             Grabs.track(grab, %{download_progress: 0.5, download_speed: 1000, download_eta: 60})

    assert updated.download_progress == 0.5

    assert_receive {:book_grab_updated, %Cinder.Books.BookGrab{id: id, download_progress: 0.5}}
    assert id == updated.id
  end

  test "an identical snapshot writes and broadcasts nothing", %{grab: grab} do
    {:ok, first} =
      Grabs.track(grab, %{download_progress: 0.2, download_speed: 500, download_eta: 90})

    Books.subscribe_targets()

    assert {:ok, ^first} =
             Grabs.track(first, %{download_progress: 0.2, download_speed: 500, download_eta: 90})

    refute_receive {:book_grab_updated, _grab}, 50
  end

  test "a partial change (speed only) still broadcasts", %{grab: grab} do
    {:ok, first} = Grabs.track(grab, %{download_progress: 0.2})
    Books.subscribe_targets()

    assert {:ok, updated} = Grabs.track(first, %{download_progress: 0.2, download_speed: 999})
    assert updated.download_speed == 999

    assert_receive {:book_grab_updated, %Cinder.Books.BookGrab{download_speed: 999}}
  end

  test "a grab already marked downloaded refuses the write and broadcasts nothing", %{grab: grab} do
    {:ok, downloaded} = Grabs.mark_downloaded(grab, "/tmp/book-#{grab.id}.epub")
    Books.subscribe_targets()

    assert {:error, :stale_grab} =
             Grabs.track(downloaded, %{download_progress: 0.9, download_speed: 1_000})

    # The write never landed: re-reading confirms nothing about the completed grab changed.
    refute Cinder.Repo.get!(Cinder.Books.BookGrab, grab.id).download_progress == 0.9
    refute_receive {:book_grab_updated, _grab}, 50
  end

  test "a regressed download_progress is dropped, not recorded — the bar never walks backwards",
       %{grab: grab} do
    {:ok, first} = Grabs.track(grab, %{download_progress: 0.7, download_speed: 100})
    Books.subscribe_targets()

    # A single tick that under-reports progress but genuinely changed speed: the regression is
    # dropped from the write while the real change still lands and still broadcasts.
    assert {:ok, updated} = Grabs.track(first, %{download_progress: 0.3, download_speed: 250})

    assert updated.download_progress == 0.7
    assert updated.download_speed == 250

    assert_receive {:book_grab_updated,
                    %Cinder.Books.BookGrab{download_progress: 0.7, download_speed: 250}}
  end

  test "a download_progress-only regression with nothing else changed writes and broadcasts nothing",
       %{grab: grab} do
    {:ok, first} = Grabs.track(grab, %{download_progress: 0.7, download_speed: 100})
    Books.subscribe_targets()

    assert {:ok, ^first} =
             Grabs.track(first, %{download_progress: 0.3, download_speed: 100})

    refute_receive {:book_grab_updated, _grab}, 50
  end

  defp identifier(provider, kind, foreign_id),
    do: %{provider: provider, kind: kind, foreign_id: foreign_id}

  defp unique_id, do: Integer.to_string(System.unique_integer([:positive]))
end
