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

  defp identifier(provider, kind, foreign_id),
    do: %{provider: provider, kind: kind, foreign_id: foreign_id}

  defp unique_id, do: Integer.to_string(System.unique_integer([:positive]))
end
