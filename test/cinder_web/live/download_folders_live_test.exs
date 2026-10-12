defmodule CinderWeb.DownloadFoldersLiveTest do
  # async: false — flips process-global Application env, and the page's start_async tasks run in
  # their own processes, so the mocks are global.
  use CinderWeb.ConnCase, async: false

  import Ecto.Query
  import Mox
  import Phoenix.LiveViewTest

  alias Cinder.AccountsFixtures
  alias Cinder.Catalog.Movie
  alias Cinder.Download.{ClientMock, SabnzbdClientMock}
  alias Cinder.Repo

  import Cinder.CatalogFixtures

  @moduletag :tmp_dir
  @moduletag :capture_log
  @video_size 200_000

  setup :set_mox_global
  setup :verify_on_exit!

  setup %{tmp_dir: tmp} do
    downloads = Path.join(tmp, "downloads")
    library = Path.join(tmp, "library")
    File.mkdir_p!(downloads)
    File.mkdir_p!(library)

    keys = [:filesystem, :path_policy, :import_roots, :explicit_import_roots]
    saved = Map.new(keys, &{&1, Application.get_env(:cinder, &1)})

    Application.put_env(:cinder, :filesystem, Cinder.Library.Filesystem.Disk)
    Application.put_env(:cinder, :path_policy, Cinder.Library.PathPolicy)
    Application.put_env(:cinder, :import_roots, [downloads])
    Application.put_env(:cinder, :explicit_import_roots, [downloads])

    on_exit(fn ->
      Enum.each(saved, fn
        {key, nil} -> Application.delete_env(:cinder, key)
        {key, value} -> Application.put_env(:cinder, key, value)
      end)
    end)

    stub(ClientMock, :health, fn -> :ok end)
    stub(SabnzbdClientMock, :health, fn -> :ok end)
    stub(ClientMock, :list_managed, fn -> {:ok, []} end)
    stub(SabnzbdClientMock, :list_managed, fn -> {:ok, []} end)

    %{downloads: downloads, library: library}
  end

  describe "access" do
    test "an anonymous visitor is sent to log in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} =
               live(conn, ~p"/settings/download-folders")
    end

    test "a non-admin cannot reach the panel", %{conn: conn} do
      conn = log_in_user(conn, AccountsFixtures.user_fixture())
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/settings/download-folders")
    end
  end

  describe "as an admin" do
    setup :register_and_log_in_admin

    test "the settings page links to the panel", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings")

      assert has_element?(
               lv,
               ~s(a[href="/settings/download-folders"]),
               "Leftover download folders"
             )
    end

    test "lists unreferenced folders with class and size, and counts the ones in use", ctx do
      empty = job_folder(ctx.downloads, "Empty Show")
      copy = job_folder(ctx.downloads, "Copy Movie")
      unmatched = job_folder(ctx.downloads, "Mystery")
      in_use = job_folder(ctx.downloads, "In Use")

      write_aged(Path.join(copy.path, "Copy.mkv"), video(1))
      library_movie(ctx.library, video(1))
      write_aged(Path.join(unmatched.path, "Mystery.mkv"), video(2))

      expect(SabnzbdClientMock, :list_managed, fn ->
        {:ok, [%{id: "nzo-1", operation_key: in_use.key, state: :completed}]}
      end)

      {:ok, lv, html} = live(ctx.conn, ~p"/settings/download-folders")
      assert html =~ "Leftover download folders"
      render_async(lv)

      assert has_element?(lv, "#folder-#{empty.key} .badge", "Empty")
      assert has_element?(lv, "#folder-#{copy.key} .badge", "Library copy")
      assert has_element?(lv, "#folder-#{copy.key}", "200000 B")
      assert has_element?(lv, "#folder-#{unmatched.key} .badge", "Not in the library")
      refute has_element?(lv, "#folder-#{in_use.key}")
      assert has_element?(lv, "#folders-summary", "1 job folder is still in use")

      # Only the unmatched folder offers a per-folder delete.
      assert has_element?(lv, "#folder-#{unmatched.key} button", "Delete…")
      refute has_element?(lv, "#folder-#{empty.key} button", "Delete…")
      refute has_element?(lv, "#folder-#{copy.key} button", "Delete…")
    end

    test "bulk clear removes the empty and library-copy folders after a confirmation", ctx do
      empty = job_folder(ctx.downloads, "Empty Show")
      copy = job_folder(ctx.downloads, "Copy Movie")
      unmatched = job_folder(ctx.downloads, "Mystery")
      write_aged(Path.join(copy.path, "Copy.mkv"), video(1))
      library_movie(ctx.library, video(1))
      write_aged(Path.join(unmatched.path, "Mystery.mkv"), video(2))

      {:ok, lv, _html} = live(ctx.conn, ~p"/settings/download-folders")
      render_async(lv)

      assert has_element?(lv, "#clear-safe", "Clear 2 empty or duplicate folders")
      lv |> element("#clear-safe") |> render_click()

      # Nothing is deleted until the confirmation is accepted.
      assert File.dir?(empty.path)
      assert has_element?(lv, "#confirm-clear-safe")

      lv |> element("#confirm-clear-safe button", "Clear folders") |> render_click()
      # The clear finishes, then the page rescans: two async rounds.
      render_async(lv)
      render_async(lv)

      refute File.exists?(empty.path)
      refute File.exists?(copy.path)
      assert File.exists?(Path.join(unmatched.path, "Mystery.mkv"))
      assert File.exists?(Path.join(ctx.library, "Movie (2000)/Movie (2000).mkv"))

      refute has_element?(lv, "#folder-#{empty.key}")
      refute has_element?(lv, "#folder-#{copy.key}")
      assert has_element?(lv, "#folder-#{unmatched.key}")
      refute has_element?(lv, "#clear-safe")
      assert render(lv) =~ "Cleared 2 download folders."

      rows = Repo.all(from a in Cinder.Audit.AdminAudit, where: a.entity_type == "DownloadFolder")

      assert length(rows) == 2
      assert Enum.all?(rows, &(&1.actor_id == ctx.user.id))
      assert Enum.all?(rows, &(&1.action == "clear_download_folder"))
    end

    test "cancelling the bulk confirmation deletes nothing", ctx do
      empty = job_folder(ctx.downloads)

      {:ok, lv, _html} = live(ctx.conn, ~p"/settings/download-folders")
      render_async(lv)

      lv |> element("#clear-safe") |> render_click()
      lv |> element("#confirm-clear-safe button", "Cancel") |> render_click()
      render_async(lv)

      refute has_element?(lv, "#confirm-clear-safe")
      assert File.dir?(empty.path)
    end

    test "an unmatched folder is deleted one at a time, only after its own confirmation", ctx do
      first = job_folder(ctx.downloads, "First")
      second = job_folder(ctx.downloads, "Second")
      write_aged(Path.join(first.path, "a.mkv"), video(2))
      write_aged(Path.join(second.path, "b.mkv"), video(3))

      {:ok, lv, _html} = live(ctx.conn, ~p"/settings/download-folders")
      render_async(lv)

      refute has_element?(lv, "#clear-safe")
      lv |> element("#folder-#{first.key} button", "Delete…") |> render_click()
      assert File.exists?(Path.join(first.path, "a.mkv"))

      lv |> element("#confirm-clear-#{first.key} button", "Delete folder") |> render_click()
      render_async(lv)
      render_async(lv)

      refute File.exists?(first.path)
      assert File.exists?(Path.join(second.path, "b.mkv"))
      refute has_element?(lv, "#folder-#{first.key}")
      assert has_element?(lv, "#folder-#{second.key}")
    end

    test "a forged clear for a folder that is not unmatched, or not listed, does nothing", ctx do
      empty = job_folder(ctx.downloads)

      {:ok, lv, _html} = live(ctx.conn, ~p"/settings/download-folders")
      render_async(lv)

      render_click(lv, "clear", %{"id" => empty.key})
      render_click(lv, "clear", %{"id" => Ecto.UUID.generate()})
      render_click(lv, "clear", %{"id" => ["not", "a", "key"]})
      render_click(lv, "ask_clear", %{"id" => empty.key})
      render_hook(lv, "unknown", %{})
      render_async(lv)

      assert File.dir?(empty.path)
      refute has_element?(lv, "#confirm-clear-#{empty.key}")
    end

    test "a folder claimed after the page loaded survives the clear and is reported", ctx do
      folder = job_folder(ctx.downloads)

      {:ok, lv, _html} = live(ctx.conn, ~p"/settings/download-folders")
      render_async(lv)

      movie = movie_fixture()

      Repo.update_all(from(m in Movie, where: m.id == ^movie.id),
        set: [content_path: Path.join(folder.path, "Movie.mkv")]
      )

      lv |> element("#clear-safe") |> render_click()
      lv |> element("#confirm-clear-safe button", "Clear folders") |> render_click()
      # The clear finishes, then the page rescans: two async rounds.
      render_async(lv)
      render_async(lv)

      assert File.dir?(folder.path)
      assert render(lv) =~ "1 folder was left alone because it changed or is in use again."
    end

    test "a failed delete is reported distinctly and logged, not called a changed folder", ctx do
      folder = job_folder(ctx.downloads)

      {:ok, lv, _html} = live(ctx.conn, ~p"/settings/download-folders")
      render_async(lv)

      # A permission bit cannot make the delete fail when the suite runs as root (CI does), so
      # fail it at the filesystem behaviour; everything else stays the real disk.
      Application.put_env(:cinder, :filesystem, Cinder.Library.FilesystemMock)
      stub_with(Cinder.Library.FilesystemMock, Cinder.Library.Filesystem.Disk)
      stub(Cinder.Library.FilesystemMock, :rm_rf, fn path -> {:error, :eacces, path} end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          lv |> element("#clear-safe") |> render_click()
          lv |> element("#confirm-clear-safe button", "Clear folders") |> render_click()
          render_async(lv)
          render_async(lv)
        end)

      html = render(lv)
      assert File.dir?(folder.path)

      assert html =~
               "1 folder could not be deleted (permission or path check failed); see the log."

      refute html =~ "changed or is in use again"
      refute html =~ "Cleared"
      assert log =~ "orphan download folder not deleted: #{folder.path}"
    end

    test "a client that cannot list its jobs shows the error and offers no clearing", ctx do
      empty = job_folder(ctx.downloads)
      expect(SabnzbdClientMock, :list_managed, fn -> {:error, :econnrefused} end)

      {:ok, lv, _html} = live(ctx.conn, ~p"/settings/download-folders")
      render_async(lv)

      assert has_element?(lv, "#folders-error", "usenet download client could not list its jobs")
      refute has_element?(lv, "#clear-safe")
      refute has_element?(lv, "#orphan-folders")

      # A forged bulk clear finds no listing to act on either.
      render_click(lv, "clear_safe", %{})
      assert File.dir?(empty.path)
    end

    test "a client failing its health check says so and points at its Test button", ctx do
      empty = job_folder(ctx.downloads)
      stub(SabnzbdClientMock, :health, fn -> {:error, :bad_api_key} end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {:ok, lv, _html} = live(ctx.conn, ~p"/settings/download-folders")
          render_async(lv)

          assert has_element?(
                   lv,
                   "#folders-error",
                   "usenet download client failed its health check"
                 )

          refute has_element?(lv, "#clear-safe")
        end)

      assert log =~ "usenet download client is unhealthy, download folders refused: :bad_api_key"
      assert File.dir?(empty.path)
    end

    test "without explicit download folders it explains why it cannot scan", ctx do
      job_folder(ctx.downloads)
      Application.delete_env(:cinder, :explicit_import_roots)

      {:ok, lv, _html} = live(ctx.conn, ~p"/settings/download-folders")
      render_async(lv)

      assert has_element?(lv, "#folders-error", "Download folders")
      refute has_element?(lv, "#clear-safe")
      refute has_element?(lv, "#orphan-folders")
    end

    test "a folder held by a recent change is listed as held and offers no delete", ctx do
      folder = job_folder(ctx.downloads)
      File.write!(Path.join(folder.path, "fresh.mkv"), video(2))

      {:ok, lv, _html} = live(ctx.conn, ~p"/settings/download-folders")
      render_async(lv)

      assert has_element?(lv, "#folder-#{folder.key} .badge", "Held")
      assert has_element?(lv, "#folder-#{folder.key}", "Changed in the last hour")
      refute has_element?(lv, "#folder-#{folder.key} button")
      refute has_element?(lv, "#clear-safe")
    end

    test "says so when every job folder is still in use", ctx do
      in_use = job_folder(ctx.downloads)

      expect(SabnzbdClientMock, :list_managed, fn ->
        {:ok, [%{id: "nzo-1", operation_key: in_use.key, state: :downloading}]}
      end)

      {:ok, lv, _html} = live(ctx.conn, ~p"/settings/download-folders")
      render_async(lv)

      assert render(lv) =~ "No leftover job folders"
      assert File.dir?(in_use.path)
    end
  end

  # --- fixtures ---------------------------------------------------------------------------

  defp job_folder(downloads, title \\ "Show") do
    key = Ecto.UUID.generate()
    path = Path.join(downloads, "#{title}.cinder-#{key}")
    File.mkdir_p!(path)
    %{key: key, path: path}
  end

  defp video(seed), do: :binary.copy(<<seed>>, @video_size)

  defp write_aged(path, contents) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    File.touch!(path, {{2020, 1, 1}, {0, 0, 0}})
  end

  defp library_movie(library, contents) do
    path = Path.join(library, "Movie (2000)/Movie (2000).mkv")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    movie = movie_fixture()
    Repo.update_all(from(m in Movie, where: m.id == ^movie.id), set: [file_path: path])
  end
end
