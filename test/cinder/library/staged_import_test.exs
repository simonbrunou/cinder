defmodule Cinder.Library.StagedImportTest do
  @moduledoc """
  The staged import through its own interface: what `place/5` does at each destination, how
  `commit/2` settles by the journal rather than by the writer's answer, the post-commit effects,
  the household lock, and the engine's crash-recovery rules.

  Real temp directories, the real `PathPolicy` and the SQLite sandbox throughout — what is under
  test is what actually lands on disk and what a rollback or a reconcile actually restores.
  `Cinder.Test.BarrierFilesystem` pauses or fails one filesystem call to stand in for a crash or
  a concurrent writer.
  """
  use Cinder.DataCase, async: false

  import ExUnit.CaptureLog
  import Mox

  alias Cinder.Catalog.Movie
  alias Cinder.Library.{ImportStage, StagedImport}
  alias Cinder.Repo
  alias Cinder.Test.{BarrierFilesystem, DiskTask, ForeignFile}

  @moduletag :tmp_dir
  @moduletag :capture_log

  @video [".mkv"]

  defmodule OutputCloseErrorFile do
    @moduledoc false

    def open(path, modes) do
      case :file.open(path, modes) do
        {:ok, io} = opened ->
          if :write in modes, do: Process.put({__MODULE__, :output}, io)
          opened

        error ->
          error
      end
    end

    defdelegate read(io, count), to: :file
    defdelegate write(io, bytes), to: :file
    defdelegate read_file_info(io), to: :file

    def close(io) do
      result = :file.close(io)

      if io == Process.get({__MODULE__, :output}) do
        Process.delete({__MODULE__, :output})
        {:error, :enospc}
      else
        result
      end
    end
  end

  # Effects and reconciles run in other processes (tasks, a killed owner).
  setup :set_mox_global

  setup %{tmp_dir: tmp} do
    downloads = Path.join(tmp, "downloads")
    library = Path.join(tmp, "library")
    File.mkdir_p!(downloads)
    File.mkdir_p!(library)

    keys = [
      :filesystem,
      :path_policy,
      :import_roots,
      :explicit_import_roots,
      :movies_library_path
    ]

    saved = Map.new(keys, &{&1, Application.get_env(:cinder, &1)})

    Application.put_env(:cinder, :filesystem, BarrierFilesystem)
    Application.put_env(:cinder, :path_policy, Cinder.Library.PathPolicy)
    Application.put_env(:cinder, :import_roots, [downloads])
    Application.put_env(:cinder, :explicit_import_roots, [downloads])
    # A configured library root, so `backing_identity/1` answers for destinations (#584).
    Application.put_env(:cinder, :movies_library_path, library)

    on_exit(fn ->
      Enum.each(saved, fn
        {key, nil} -> Application.delete_env(:cinder, key)
        {key, value} -> Application.put_env(:cinder, key, value)
      end)

      for key <- [
            :filesystem_barrier,
            :filesystem_failure,
            :exclusive_copy_file_module,
            :import_stage_claim_barrier
          ],
          do: Application.delete_env(:cinder, key)
    end)

    {:ok, downloads: downloads, library: library}
  end

  # A download file and its library destination (whose directory exists, as every stager
  # `mkdir_p`s it first).
  defp files(downloads, library, name, bytes \\ "candidate") do
    source = Path.join(downloads, "#{name}.2020.mkv")
    File.write!(source, bytes)
    dest = Path.join([library, "#{name} (2020)", "#{name} (2020).mkv"])
    File.mkdir_p!(Path.dirname(dest))
    {source, dest}
  end

  # As `files/4`, with "original" already sitting at the destination.
  defp replacement_files(downloads, library, name) do
    {source, dest} = files(downloads, library, name)
    File.write!(dest, "original")
    {source, dest}
  end

  defp place(source, dest, root, opts \\ []),
    do: place_into(StagedImport.new(), source, dest, root, opts)

  defp place_into(staged, source, dest, root, opts \\ []) do
    opts = Keyword.put_new(opts, :extensions, @video)
    StagedImport.place(staged, source, dest, root, opts)
  end

  # The writer every catalog write is: one transaction that marks the ids committed.
  defp record_all(_record, ids), do: Repo.transaction(fn -> ImportStage.mark_committed!(ids) end)

  # A catalog write that lost (the movie moved on, the grab is stale): it commits nothing.
  defp refuse(_record, _ids), do: {:error, :stale_status}

  defp scratch_files(dest),
    do: dest |> Path.dirname() |> File.ls!() |> Enum.filter(&String.starts_with?(&1, ".cinder-"))

  defp expire!(row),
    do: ImportStage.update!(row, %{next_attempt_at: DateTime.add(DateTime.utc_now(), -1)})

  defp scan_counter do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    stub(Cinder.Library.MediaServerMock, :scan, fn _kind ->
      Agent.update(counter, &(&1 + 1))
      :ok
    end)

    counter
  end

  defp scans(counter), do: Agent.get(counter, & &1)

  defp movie, do: %Movie{title: "M", year: 2020, tmdb_id: 1}

  describe "place/5 outcomes" do
    test "an empty destination receives the source's bytes", %{
      downloads: downloads,
      library: library
    } do
      {source, dest} = files(downloads, library, "Fresh")

      assert {:ok, staged, :placed} = place(source, dest, library)
      assert File.read!(dest) == "candidate"
      assert [%ImportStage{state: :prepared, kind: :placement}] = Repo.all(ImportStage)

      assert {:ok, :ok} = StagedImport.commit(staged, &record_all/2)
      assert File.read!(dest) == "candidate"
      refute Repo.exists?(ImportStage)
      assert scratch_files(dest) == []
    end

    test "a destination already holding this exact file is a no-op, even with :replace", %{
      downloads: downloads,
      library: library
    } do
      {source, dest} = files(downloads, library, "Same")
      File.ln!(source, dest)

      assert {:ok, staged, :same_file} = place(source, dest, library, on_collision: :replace)
      assert [%ImportStage{kind: :noop}] = Repo.all(ImportStage)
      assert scratch_files(dest) == []
      assert {:ok, :ok} = StagedImport.commit(staged, &record_all/2)
      assert File.read!(dest) == "candidate"
    end

    test "another file at the destination is kept with :keep", %{
      downloads: downloads,
      library: library
    } do
      {source, dest} = replacement_files(downloads, library, "Kept")

      assert {:ok, staged, :kept} = place(source, dest, library)
      assert File.read!(dest) == "original"
      assert {:ok, :ok} = StagedImport.commit(staged, &record_all/2)
      assert File.read!(dest) == "original"
      refute Repo.exists?(ImportStage)
    end

    test "another file at the destination is swapped out with :replace, its backup kept until commit",
         %{downloads: downloads, library: library} do
      {source, dest} = replacement_files(downloads, library, "Swap")

      assert {:ok, staged, :replaced} = place(source, dest, library, on_collision: :replace)
      assert File.read!(dest) == "candidate"
      assert [%ImportStage{backup: backup}] = Repo.all(ImportStage)
      assert File.read!(backup) == "original"

      assert {:ok, :ok} = StagedImport.commit(staged, &record_all/2)
      refute File.exists?(backup)
      assert scratch_files(dest) == []
    end

    # A directory where a file should be is not something an import can adopt or move aside as
    # a backup: the import refuses and the operator's directory stays where it is.
    test "a directory at the destination is refused and left alone", %{
      downloads: downloads,
      library: library
    } do
      {source, dest} = files(downloads, library, "Dir")
      File.mkdir_p!(Path.join(dest, "extras"))

      for on_collision <- [:keep, :replace] do
        assert {:error, {:unexpected_destination_type, :directory}} =
                 place(source, dest, library, on_collision: on_collision)
      end

      assert File.dir?(Path.join(dest, "extras"))
      refute Repo.exists?(ImportStage)
    end

    test "the source's extension must be on the caller's allow-list", %{
      downloads: downloads,
      library: library
    } do
      source = Path.join(downloads, "chapter.mp3")
      File.write!(source, "mp3 bytes")
      dest = Path.join(library, "Author/Title/01 - Title.mp3")
      File.mkdir_p!(Path.dirname(dest))

      assert {:error, :unsafe_source} = place(source, dest, library)

      assert {:ok, _staged, :placed} =
               place(source, dest, library, extensions: [".mp3", ".m4b"])

      assert File.read!(dest) == "mp3 bytes"
    end
  end

  # Issue #584: the collision branch asks "is `dest` already this exact file?" by comparing what
  # `lstat` reports for two DIFFERENT paths, which on this mount class always reads "different".
  # A replay of an already-completed replace would then re-run the whole backup-then-swap over
  # content already swapped once.
  describe "place/5 on a mount that reports path-derived inodes" do
    test "a replayed replace is still a no-op", %{downloads: downloads, library: library} do
      {source, dest} = files(downloads, library, "Replay")
      File.ln!(source, dest)
      BarrierFilesystem.report_path_derived_inodes()

      assert {:ok, staged, :same_file} = place(source, dest, library, on_collision: :replace)

      # The outcome alone is also satisfied by a swap that happened and was reported as a no-op,
      # so pin the absence of the backup a real swap would have left behind.
      assert scratch_files(dest) == []
      assert {:ok, :ok} = StagedImport.commit(staged, &record_all/2)
    end

    # The destination is hardlinked from a SECOND download so it clears the link-count
    # precondition and the cross-path proof actually runs.
    test "a genuinely different destination is still replaced", %{
      downloads: downloads,
      library: library
    } do
      {source, dest} = files(downloads, library, "Different", "new bytes")
      other = Path.join(downloads, "Different.old.mkv")
      File.write!(other, "old bytes")
      File.ln!(other, dest)
      BarrierFilesystem.report_path_derived_inodes()

      assert {:ok, staged, :replaced} = place(source, dest, library, on_collision: :replace)
      assert File.read!(dest) == "new bytes"
      assert {:ok, :ok} = StagedImport.commit(staged, &record_all/2)
      assert Cinder.Library.quarantined_import_stages() == []
    end

    # Issue #558: the backup's identity is captured at `dest` and checked at the backup path,
    # either side of a rename the engine performs itself; the operation-keyed path is the
    # ownership evidence that survives.
    test "a committed replace still cleans up its backup", %{
      downloads: downloads,
      library: library
    } do
      {source, dest} = replacement_files(downloads, library, "Cleanup")
      BarrierFilesystem.report_path_derived_inodes()

      assert {:ok, staged, :replaced} = place(source, dest, library, on_collision: :replace)
      assert {:ok, :ok} = StagedImport.commit(staged, &record_all/2)
      assert scratch_files(dest) == []
      assert Cinder.Library.quarantined_import_stages() == []
    end

    test "a rollback still restores the original bytes", %{downloads: downloads, library: library} do
      {source, dest} = replacement_files(downloads, library, "Restore")
      BarrierFilesystem.report_path_derived_inodes()

      Application.put_env(:cinder, :filesystem_failure, %{
        operation: :ln,
        source_contains: ".cinder-stage-",
        reason: :eio
      })

      assert {:error, :eio} = place(source, dest, library, on_collision: :replace)

      # Without this, the assertion below is also satisfied by a stage that failed BEFORE the
      # backup move — `dest` untouched and nothing to restore.
      refute File.exists?(dest)
      assert Enum.any?(scratch_files(dest), &String.starts_with?(&1, ".cinder-rollback-"))

      Application.delete_env(:cinder, :filesystem_failure)
      assert :ok = StagedImport.reconcile()
      assert File.read!(dest) == "original"
      assert Cinder.Library.quarantined_import_stages() == []
    end

    # Issue #588: a fresh placement's rollback has to recognise the file it landed itself,
    # through the candidate's backing identity.
    test "a rolled-back fresh placement removes what it landed", %{
      downloads: downloads,
      library: library
    } do
      {source, dest} = files(downloads, library, "Landed")
      BarrierFilesystem.report_path_derived_inodes()

      assert {:ok, staged, :placed} = place(source, dest, library)
      assert :ok = StagedImport.rollback(staged)
      refute File.exists?(dest)
      refute Repo.exists?(ImportStage)
    end

    # The other half: the backing identity is evidence for the file THIS stage landed, not a
    # licence to delete whatever occupies `dest` now. The replacement is a different length on
    # purpose, so the size guard against a reused inode is exercised too.
    test "a third party's file at the destination afterward is preserved and the stage parks", %{
      downloads: downloads,
      library: library
    } do
      {source, dest} = files(downloads, library, "Third")
      BarrierFilesystem.report_path_derived_inodes()

      assert {:ok, staged, :placed} = place(source, dest, library)
      File.rm!(dest)
      File.write!(dest, "someone else's bytes")

      log = capture_log(fn -> assert :ok = StagedImport.rollback(staged) end)
      assert log =~ "staged import rollback for #{dest} remains pending"
      assert File.read!(dest) == "someone else's bytes"
      assert [_stage] = Cinder.Library.quarantined_import_stages()
    end
  end

  describe "commit/2" do
    test "hands the writer the record and the stage ids, and returns its value", %{
      downloads: downloads,
      library: library
    } do
      {first_source, first_dest} = files(downloads, library, "First")
      {second_source, second_dest} = files(downloads, library, "Second")
      {:ok, staged, :placed} = place(first_source, first_dest, library)
      {:ok, staged, :placed} = place_into(staged, second_source, second_dest, library)
      staged = StagedImport.put_record(staged, :the_record)
      ids = ImportStage |> Repo.all() |> Enum.map(& &1.id) |> Enum.sort()

      writer = fn record, stage_ids ->
        assert record == :the_record
        assert Enum.sort(stage_ids) == ids
        {:ok, :ok} = record_all(record, stage_ids)
        :written
      end

      assert :written = StagedImport.commit(staged, writer)
      assert StagedImport.record(staged) == :the_record
      refute Repo.exists?(ImportStage)
    end

    test "a writer that commits nothing rolls every staged file back", %{
      downloads: downloads,
      library: library
    } do
      {fresh_source, fresh_dest} = files(downloads, library, "Gone")
      {swap_source, swap_dest} = replacement_files(downloads, library, "Back")
      {:ok, staged, :placed} = place(fresh_source, fresh_dest, library)

      {:ok, staged, :replaced} =
        place_into(staged, swap_source, swap_dest, library, on_collision: :replace)

      assert {:error, :stale_status} = StagedImport.commit(staged, &refuse/2)
      refute File.exists?(fresh_dest)
      assert File.read!(swap_dest) == "original"
      assert scratch_files(swap_dest) == []
      refute Repo.exists?(ImportStage)
    end

    test "a writer that raises after its transaction still commits, and the raise propagates", %{
      downloads: downloads,
      library: library
    } do
      {source, dest} = files(downloads, library, "RaiseAfter")
      {:ok, staged, :placed} = place(source, dest, library)

      writer = fn record, ids ->
        {:ok, :ok} = record_all(record, ids)
        raise "broadcast failed"
      end

      assert_raise RuntimeError, "broadcast failed", fn -> StagedImport.commit(staged, writer) end
      assert File.read!(dest) == "candidate"
      refute Repo.exists?(ImportStage)
    end

    test "a writer that raises before its transaction rolls back", %{
      downloads: downloads,
      library: library
    } do
      {source, dest} = files(downloads, library, "RaiseBefore")
      {:ok, staged, :placed} = place(source, dest, library)

      assert_raise RuntimeError, fn ->
        StagedImport.commit(staged, fn _record, _ids -> raise "lost" end)
      end

      refute File.exists?(dest)
      refute Repo.exists?(ImportStage)
    end

    test "runs a staged file's effects once its write commits: sidecars first, then the effect",
         %{downloads: downloads, library: library} do
      folder = Path.join(downloads, "M.2020")
      File.mkdir_p!(folder)
      source = Path.join(folder, "M.2020.mkv")
      File.write!(source, "candidate")
      File.write!(Path.join(folder, "M.2020.en.srt"), "subtitle")
      dest = Path.join([library, "M (2020)", "M (2020).mkv"])
      File.mkdir_p!(Path.dirname(dest))
      counter = scan_counter()

      {:ok, staged, :placed} = place(source, dest, library)

      staged =
        StagedImport.after_commit(staged, dest, {:movie, movie(), []}, link_sidecars_from: source)

      assert {:ok, :ok} = StagedImport.commit(staged, &record_all/2)
      assert scans(counter) == 1
      assert File.read!(Path.rootname(dest) <> ".en.srt") == "subtitle"
    end

    test "a staged file that kept another file links none of the source's sidecars (#784)", %{
      downloads: downloads,
      library: library
    } do
      {source, dest} = replacement_files(downloads, library, "Kept")
      File.write!(Path.rootname(source) <> ".en.srt", "subtitle")
      counter = scan_counter()

      {:ok, staged, :kept} = place(source, dest, library)

      staged =
        StagedImport.after_commit(staged, dest, {:movie, movie(), []}, link_sidecars_from: source)

      assert {:ok, :ok} = StagedImport.commit(staged, &record_all/2)
      assert scans(counter) == 1
      assert File.read!(dest) == "original"
      refute File.exists?(Path.rootname(dest) <> ".en.srt")
    end

    test "runs no effects for a staged file nothing committed", %{
      downloads: downloads,
      library: library
    } do
      {source, dest} = files(downloads, library, "NoEffects")
      counter = scan_counter()
      {:ok, staged, :placed} = place(source, dest, library)
      staged = StagedImport.after_commit(staged, dest, {:movie, movie(), []})

      assert {:error, :stale_status} = StagedImport.commit(staged, &refuse/2)
      assert scans(counter) == 0
    end

    test "runs no effects once the journal row is gone", %{downloads: downloads, library: library} do
      {source, dest} = files(downloads, library, "Missing")
      counter = scan_counter()
      {:ok, staged, :placed} = place(source, dest, library)
      staged = StagedImport.after_commit(staged, dest, {:movie, movie(), []})
      Repo.delete!(Repo.one!(ImportStage))

      assert :ok = StagedImport.commit(staged, fn _record, _ids -> :ok end)
      assert scans(counter) == 0
    end

    test "the first effect registered for a staged file is the one that runs", %{
      downloads: downloads,
      library: library
    } do
      {source, dest} = files(downloads, library, "First")
      counter = scan_counter()
      {:ok, staged, :placed} = place(source, dest, library)
      staged = StagedImport.after_commit(staged, dest, {:movie_part, movie(), []})
      staged = StagedImport.after_commit(staged, dest, {:movie, movie(), []})

      assert {:ok, :ok} = StagedImport.commit(staged, &record_all/2)
      # A part fetches subtitles and scans nothing.
      assert scans(counter) == 0
    end

    test "claims a staged file's effects once, even when its cleanup fails and it settles again",
         %{downloads: downloads, library: library} do
      {source, dest} = replacement_files(downloads, library, "Once")
      counter = scan_counter()
      {:ok, staged, :replaced} = place(source, dest, library, on_collision: :replace)
      staged = StagedImport.after_commit(staged, dest, {:movie, movie(), []})

      Application.put_env(:cinder, :filesystem_failure, %{
        operation: :rm,
        source_contains: ".cinder-rollback-",
        reason: :eacces,
        once: true
      })

      log = capture_log(fn -> assert {:ok, :ok} = StagedImport.commit(staged, &record_all/2) end)
      assert log =~ "staged import commit for #{dest} remains pending: :eacces"
      assert scans(counter) == 1
      assert %ImportStage{state: :cleaning, effects_claimed_at: claimed} = Repo.one!(ImportStage)
      assert claimed

      # Settling the same staged import again finds the stage already recorded and runs no
      # effect a second time.
      assert {:error, :stale_import_stage} = StagedImport.commit(staged, &record_all/2)
      assert scans(counter) == 1

      expire!(Repo.one!(ImportStage))
      assert :ok = StagedImport.reconcile()
      refute Repo.exists?(ImportStage)
      assert scratch_files(dest) == []
    end
  end

  test "rollback/1 undoes every staged file", %{downloads: downloads, library: library} do
    {fresh_source, fresh_dest} = files(downloads, library, "One")
    {swap_source, swap_dest} = replacement_files(downloads, library, "Two")
    {:ok, staged, :placed} = place(fresh_source, fresh_dest, library)

    {:ok, staged, :replaced} =
      place_into(staged, swap_source, swap_dest, library, on_collision: :replace)

    assert :ok = StagedImport.rollback(staged)
    refute File.exists?(fresh_dest)
    assert File.read!(swap_dest) == "original"
    refute Repo.exists?(ImportStage)
  end

  describe "run/1" do
    test "holds the household lock that reconcile/0 takes" do
      observer =
        StagedImport.run(fn ->
          observer = Task.async(&StagedImport.reconcile/0)
          refute Task.yield(observer, 100)
          observer
        end)

      assert :ok = DiskTask.await(observer)
    end

    # `:global.trans/2` releases a lock when an inner call with the same id returns, which would
    # leave the rest of the outer import unprotected.
    test "a nested run keeps the lock until the outermost one returns" do
      observer =
        StagedImport.run(fn ->
          assert :inner = StagedImport.run(fn -> :inner end)
          observer = Task.async(&StagedImport.reconcile/0)
          refute Task.yield(observer, 100)
          observer
        end)

      assert :ok = DiskTask.await(observer)
    end
  end

  describe "crash recovery" do
    test "a reconcile removes a candidate left by process death before placement", %{
      downloads: downloads,
      library: library
    } do
      {source, dest} = files(downloads, library, "Dead")
      operation_key = Ecto.UUID.generate()
      stale = Path.join(Path.dirname(dest), ".cinder-stage-#{operation_key}")
      File.write!(stale, "partial")

      ImportStage.create!(%{
        operation_key: operation_key,
        state: :preparing,
        root: library,
        dest: dest,
        candidate: stale
      })

      assert :ok = StagedImport.reconcile()
      refute File.exists?(stale)
      refute Repo.exists?(ImportStage)

      assert {:ok, _staged, :placed} = place(source, dest, library)
      assert File.read!(dest) == "candidate"
    end

    test "a file appearing during a cross-filesystem copy is never overwritten", %{
      downloads: downloads,
      library: library
    } do
      {source, dest} = files(downloads, library, "Racer")

      Application.put_env(:cinder, :filesystem_failure, %{
        operation: :ln,
        source_contains: source,
        reason: :exdev,
        once: true
      })

      Application.put_env(:cinder, :filesystem_barrier, %{
        owner: self(),
        operation: :cp,
        contains: ".cinder-stage-",
        once: true
      })

      staging = Task.async(fn -> place(source, dest, library) end)
      assert_receive {:filesystem_barrier, pid, ref, :cp, _candidate}, DiskTask.timeout_ms()
      File.write!(dest, "user file")
      send(pid, {ref, :continue})

      assert {:error, :eexist} = DiskTask.await(staging)
      assert File.read!(dest) == "user file"
    end

    # #338: a season pack copies one file after another. The first file's handoff deadline can
    # pass while a later one is still copying; without the household lock, another poller's
    # reconcile would roll the first file back and the whole import would fail at its write.
    test "a reconcile waits for an import that holds the household lock, however long it runs",
         %{downloads: downloads, library: library} do
      {early_source, early_dest} = files(downloads, library, "Early")
      {late_source, late_dest} = files(downloads, library, "Late")

      Application.put_env(:cinder, :filesystem_failure, %{
        operation: :ln,
        source_contains: late_source,
        reason: :exdev,
        once: true
      })

      Application.put_env(:cinder, :filesystem_barrier, %{
        owner: self(),
        operation: :cp,
        contains: ".cinder-stage-",
        once: true
      })

      importer =
        Task.async(fn ->
          StagedImport.run(fn ->
            {:ok, staged, :placed} = place(early_source, early_dest, library)
            # The early file's deadline passes while the late one is still copying.
            expire!(Repo.one!(ImportStage))
            {:ok, staged, :placed} = place_into(staged, late_source, late_dest, library)
            StagedImport.commit(staged, &record_all/2)
          end)
        end)

      assert_receive {:filesystem_barrier, pid, ref, :cp, _candidate}, DiskTask.timeout_ms()
      observer = Task.async(&StagedImport.reconcile/0)
      refute Task.yield(observer, 100)
      send(pid, {ref, :continue})

      assert {:ok, :ok} = DiskTask.await(importer)
      assert :ok = DiskTask.await(observer)
      assert File.read!(early_dest) == "candidate"
      assert File.read!(late_dest) == "candidate"
      refute Repo.exists?(ImportStage)
    end

    test "a reconcile leaves a fresh :prepared stage alone until its handoff deadline passes", %{
      downloads: downloads,
      library: library
    } do
      {source, dest} = files(downloads, library, "Lease")

      Application.put_env(:cinder, :filesystem_failure, %{
        operation: :ln,
        source_contains: source,
        reason: :exdev,
        once: true
      })

      Application.put_env(:cinder, :filesystem_barrier, %{
        owner: self(),
        operation: :cp,
        contains: ".cinder-stage-",
        once: true
      })

      staging = Task.async(fn -> StagedImport.run(fn -> place(source, dest, library) end) end)
      assert_receive {:filesystem_barrier, pid, ref, :cp, _candidate}, DiskTask.timeout_ms()

      observer = Task.async(&StagedImport.reconcile/0)
      refute Task.yield(observer, 50)
      send(pid, {ref, :continue})

      assert {:ok, _staged, :placed} = DiskTask.await(staging)
      assert :ok = DiskTask.await(observer)
      prepared = Repo.one!(ImportStage)
      assert prepared.state == :prepared
      assert DateTime.compare(prepared.next_attempt_at, DateTime.utc_now()) == :gt
      assert File.read!(dest) == "candidate"

      expire!(prepared)
      assert :ok = StagedImport.reconcile()
      refute File.exists?(dest)
      refute Repo.exists?(ImportStage)
    end

    test "the committed handoff grace lets the owner run its effects before a reconcile", %{
      downloads: downloads,
      library: library
    } do
      {source, dest} = files(downloads, library, "Grace")
      counter = scan_counter()
      {:ok, staged, :placed} = place(source, dest, library)
      staged = StagedImport.after_commit(staged, dest, {:movie, movie(), []})

      # Another poller reconciles between the owner's write and its settle.
      writer = fn record, ids ->
        {:ok, :ok} = record_all(record, ids)
        assert :ok = DiskTask.await(Task.async(&StagedImport.reconcile/0))
        assert %ImportStage{state: :committed, effects_claimed_at: nil} = Repo.one!(ImportStage)
        :written
      end

      assert :written = StagedImport.commit(staged, writer)
      assert scans(counter) == 1
      refute Repo.exists?(ImportStage)
    end

    test "an abandoned committed handoff auto-cleans only after its grace expires", %{
      downloads: downloads,
      library: library
    } do
      {source, dest} = replacement_files(downloads, library, "Abandoned")
      {:ok, staged, :replaced} = place(source, dest, library, on_collision: :replace)

      # The owner dies right after its write commits, before it settles anything.
      {owner, ref} =
        spawn_monitor(fn ->
          StagedImport.commit(staged, fn record, ids ->
            {:ok, :ok} = record_all(record, ids)
            Process.exit(self(), :kill)
          end)
        end)

      assert_receive {:DOWN, ^ref, :process, ^owner, :killed}, 15_000

      assert :ok = StagedImport.reconcile()
      committed = Repo.one!(ImportStage)
      assert committed.state == :committed
      assert File.read!(dest) == "candidate"
      assert File.exists?(committed.backup)

      expire!(committed)
      assert :ok = StagedImport.reconcile()
      refute Repo.exists?(ImportStage)
      assert File.read!(dest) == "candidate"
      refute File.exists?(committed.backup)
    end

    test "a filesystem without hardlinks lands through an exclusive streaming copy", %{
      downloads: downloads,
      library: library,
      tmp_dir: tmp
    } do
      {source, dest} = files(downloads, library, "Linkless", String.duplicate("candidate", 1_000))

      Application.put_env(:cinder, :filesystem_failure, %{
        operation: :ln,
        source_contains: tmp,
        reason: :eopnotsupp
      })

      assert {:ok, staged, :placed} = place(source, dest, library)
      assert File.read!(dest) == File.read!(source)
      assert :ok = StagedImport.rollback(staged)
      refute File.exists?(dest)
    end

    test "an exclusive landing preserves a user file that wins creation", %{
      downloads: downloads,
      library: library,
      tmp_dir: tmp
    } do
      {source, dest} = files(downloads, library, "Winner")

      Application.put_env(:cinder, :filesystem_failure, %{
        operation: :ln,
        source_contains: tmp,
        reason: :eperm
      })

      Application.put_env(:cinder, :filesystem_barrier, %{
        owner: self(),
        operation: :cp_exclusive,
        phase: :before,
        contains: Path.basename(dest),
        once: true
      })

      staging = Task.async(fn -> place(source, dest, library) end)
      assert_receive {:filesystem_barrier, pid, ref, :cp_exclusive, ^dest}, DiskTask.timeout_ms()
      File.write!(dest, "user file")
      send(pid, {ref, :continue})

      assert {:error, :eexist} = DiskTask.await(staging)
      assert File.read!(dest) == "user file"
      assert :ok = StagedImport.reconcile()
      assert File.read!(dest) == "user file"
    end

    test "recovery removes an owned partial exclusive copy and restores the backup", %{
      downloads: downloads,
      library: library,
      tmp_dir: tmp
    } do
      {source, dest} = replacement_files(downloads, library, "Partial")

      Application.put_env(:cinder, :filesystem_failure, %{
        operation: :ln,
        source_contains: tmp,
        reason: :enotsup
      })

      Application.put_env(:cinder, :filesystem_barrier, %{
        owner: self(),
        operation: :cp_exclusive,
        contains: Path.basename(dest),
        once: true
      })

      staging = Task.async(fn -> place(source, dest, library, on_collision: :replace) end)
      Process.unlink(staging.pid)
      assert_receive {:filesystem_barrier, pid, _ref, :cp_exclusive, ^dest}, DiskTask.timeout_ms()
      journal = Repo.one!(ImportStage)
      assert journal.state == :preparing
      assert journal.staged_inode
      assert File.exists?(journal.backup)
      assert File.stat!(dest).size == 0

      Process.exit(pid, :kill)
      catch_exit(Task.await(staging))
      Application.delete_env(:cinder, :filesystem_barrier)
      Application.delete_env(:cinder, :filesystem_failure)

      assert :ok = StagedImport.reconcile()
      assert File.read!(dest) == "original"
      refute File.exists?(journal.backup)
      refute Repo.exists?(ImportStage)
    end

    test "an exclusive landing rejects a path replaced after opening, without deleting it", %{
      downloads: downloads,
      library: library,
      tmp_dir: tmp
    } do
      {source, dest} = files(downloads, library, "Opened", String.duplicate("candidate", 1_000))

      Application.put_env(:cinder, :filesystem_failure, %{
        operation: :ln,
        source_contains: tmp,
        reason: :eperm
      })

      Application.put_env(:cinder, :filesystem_barrier, %{
        owner: self(),
        operation: :cp_exclusive,
        contains: Path.basename(dest),
        once: true
      })

      staging = Task.async(fn -> place(source, dest, library) end)
      assert_receive {:filesystem_barrier, pid, ref, :cp_exclusive, ^dest}, DiskTask.timeout_ms()
      displaced = dest <> ".opened"
      File.rename!(dest, displaced)
      File.write!(dest, "user replacement")
      send(pid, {ref, :continue})

      assert {:error, :import_stage_destination_changed} = DiskTask.await(staging)
      assert File.read!(dest) == "user replacement"
      assert File.exists?(displaced)
      assert [%ImportStage{state: :preparing} = journal] = Repo.all(ImportStage)
      assert File.exists?(journal.candidate)

      assert :ok = StagedImport.reconcile()
      assert Repo.get!(ImportStage, journal.id).state == :quarantined
      assert File.read!(dest) == "user replacement"
    end

    test "an output close failure leaves the candidate and journal unprepared", %{
      downloads: downloads,
      library: library,
      tmp_dir: tmp
    } do
      {source, dest} = files(downloads, library, "Close")

      Application.put_env(:cinder, :filesystem_failure, %{
        operation: :ln,
        source_contains: tmp,
        reason: :eperm
      })

      Application.put_env(:cinder, :exclusive_copy_file_module, OutputCloseErrorFile)

      assert {:error, :enospc} = place(source, dest, library)
      assert [%ImportStage{state: :preparing} = journal] = Repo.all(ImportStage)
      assert File.exists?(journal.candidate)
      assert File.exists?(journal.dest)
    end

    for {label, on_collision} <- [{"fresh", :keep}, {"replacement", :replace}] do
      test "a pre-journal exclusive-copy crash quarantines an unknown #{label} destination", %{
        downloads: downloads,
        library: library,
        tmp_dir: tmp
      } do
        on_collision = unquote(on_collision)

        {source, dest} =
          if on_collision == :replace,
            do: replacement_files(downloads, library, "Crash"),
            else: files(downloads, library, "Crash")

        Application.put_env(:cinder, :filesystem_failure, %{
          operation: :ln,
          source_contains: tmp,
          reason: :eperm
        })

        Application.put_env(:cinder, :filesystem_barrier, %{
          owner: self(),
          operation: :cp_exclusive_created,
          contains: ".mkv",
          once: true
        })

        staging = Task.async(fn -> place(source, dest, library, on_collision: on_collision) end)
        Process.unlink(staging.pid)

        assert_receive {:filesystem_barrier, pid, _ref, :cp_exclusive_created, ^dest},
                       DiskTask.timeout_ms()

        journal = Repo.one!(ImportStage)
        assert journal.staged_inode == nil
        assert File.exists?(dest)
        Process.exit(pid, :kill)
        catch_exit(Task.await(staging))
        Application.delete_env(:cinder, :filesystem_barrier)

        assert :ok = StagedImport.reconcile()
        assert Repo.get!(ImportStage, journal.id).state == :quarantined
        assert File.exists?(dest)
      end
    end

    test "concurrent stages for one destination admit only one journal owner", %{
      downloads: downloads,
      library: library
    } do
      {first_source, dest} = files(downloads, library, "Shared", "first")
      second_source = Path.join(downloads, "Shared.second.mkv")
      File.write!(second_source, "second")

      Application.put_env(:cinder, :filesystem_barrier, %{
        owner: self(),
        operation: :lstat,
        contains: ".cinder-stage-",
        once: true
      })

      first = Task.async(fn -> place(first_source, dest, library) end)
      assert_receive {:filesystem_barrier, pid, ref, :lstat, _candidate}, DiskTask.timeout_ms()

      second = Task.async(fn -> place(second_source, dest, library) end)
      refute Task.yield(second, 50)
      send(pid, {ref, :continue})

      assert {:ok, staged, :placed} = DiskTask.await(first)
      assert {:error, :import_stage_busy} = DiskTask.await(second)
      assert File.read!(dest) == "first"
      assert :ok = StagedImport.rollback(staged)
    end

    test "a replacement revalidates the captured destination before moving it", %{
      downloads: downloads,
      library: library
    } do
      {source, dest} = replacement_files(downloads, library, "Revalidate")

      Application.put_env(:cinder, :filesystem_barrier, %{
        owner: self(),
        operation: :lstat,
        contains: ".cinder-stage-",
        once: true
      })

      staging = Task.async(fn -> place(source, dest, library, on_collision: :replace) end)
      assert_receive {:filesystem_barrier, pid, ref, :lstat, _candidate}, DiskTask.timeout_ms()
      ForeignFile.publish!(dest, "user replacement")
      send(pid, {ref, :continue})

      assert {:error, :import_stage_destination_changed} = DiskTask.await(staging)
      assert File.read!(dest) == "user replacement"
    end

    test "a rollback claim atomically defeats a simultaneous catalog commit", %{
      downloads: downloads,
      library: library
    } do
      {source, dest} = replacement_files(downloads, library, "Claim")
      {:ok, staged, :replaced} = place(source, dest, library, on_collision: :replace)
      expire!(Repo.one!(ImportStage))

      Application.put_env(:cinder, :import_stage_claim_barrier, %{
        owner: self(),
        state: :rolling_back,
        once: true
      })

      reconcile = Task.async(&StagedImport.reconcile/0)

      assert_receive {:import_stage_claim_barrier, pid, ref, _stage_id, :rolling_back},
                     DiskTask.timeout_ms()

      test = self()

      owner =
        Task.async(fn ->
          StagedImport.commit(staged, fn record, ids ->
            written = record_all(record, ids)
            send(test, {:written, written})
            written
          end)
        end)

      assert_receive {:written, {:error, :stale_import_stage}}, DiskTask.timeout_ms()
      send(pid, {ref, :continue})

      assert :ok = DiskTask.await(reconcile)
      assert {:error, :stale_import_stage} = DiskTask.await(owner)
      assert File.read!(dest) == "original"
    end

    test "a permanent identity conflict is quarantined and not retried", %{library: library} do
      dir = Path.join(library, "Conflict")
      dest = Path.join(dir, "Conflict.mkv")
      backup = Path.join(dir, ".cinder-rollback-conflict")
      File.mkdir_p!(dir)
      File.write!(dest, "unknown user file")
      File.write!(backup, "original")
      backup_stat = File.lstat!(backup)

      stage =
        ImportStage.create!(%{
          operation_key: Ecto.UUID.generate(),
          state: :prepared,
          root: library,
          dest: dest,
          candidate: Path.join(dir, ".cinder-stage-conflict"),
          backup: backup,
          staged_inode: 1,
          staged_device: 1,
          staged_size: 1,
          backup_inode: backup_stat.inode,
          backup_device: backup_stat.major_device,
          backup_size: backup_stat.size
        })

      assert :ok = StagedImport.reconcile()
      quarantined = Repo.get!(ImportStage, stage.id)
      assert quarantined.state == :quarantined
      assert quarantined.attempt_count == 1

      assert :ok = StagedImport.reconcile()
      assert Repo.get!(ImportStage, stage.id).state == :quarantined
      assert File.read!(dest) == "unknown user file"
      assert File.read!(backup) == "original"
    end

    test "two concurrent reconciles cannot double-attempt one transient cleanup", %{
      library: library
    } do
      dir = Path.join(library, "Retry")
      dest = Path.join(dir, "Retry.mkv")
      backup = Path.join(dir, ".cinder-rollback-retry")
      File.mkdir_p!(dir)
      File.write!(dest, "candidate")
      File.write!(backup, "original")
      dest_stat = File.lstat!(dest)
      backup_stat = File.lstat!(backup)

      stage =
        ImportStage.create!(%{
          operation_key: Ecto.UUID.generate(),
          state: :prepared,
          root: library,
          dest: dest,
          candidate: Path.join(dir, ".cinder-stage-retry"),
          backup: backup,
          candidate_inode: dest_stat.inode,
          candidate_device: dest_stat.major_device,
          candidate_size: dest_stat.size,
          staged_inode: dest_stat.inode,
          staged_device: dest_stat.major_device,
          staged_size: dest_stat.size,
          backup_inode: backup_stat.inode,
          backup_device: backup_stat.major_device,
          backup_size: backup_stat.size
        })

      Application.put_env(:cinder, :filesystem_failure, %{
        operation: :rename,
        source_contains: ".cinder-rollback-retry",
        reason: :eacces
      })

      first = Task.async(&StagedImport.reconcile/0)
      second = Task.async(&StagedImport.reconcile/0)
      assert :ok = DiskTask.await(first)
      assert :ok = DiskTask.await(second)

      retrying = Repo.get!(ImportStage, stage.id)
      assert retrying.state == :rolling_back
      assert retrying.attempt_count == 1
      assert DateTime.diff(retrying.next_attempt_at, DateTime.utc_now()) >= 25

      for expected_attempt <- 2..8 do
        stage.id |> then(&Repo.get!(ImportStage, &1)) |> expire!()
        assert :ok = StagedImport.reconcile()
        assert Repo.get!(ImportStage, stage.id).attempt_count == expected_attempt

        if expected_attempt < 8,
          do: assert(Repo.get!(ImportStage, stage.id).state == :rolling_back)
      end

      quarantined = Repo.get!(ImportStage, stage.id)
      assert quarantined.state == :quarantined
      assert quarantined.next_attempt_at == nil
    end

    test "a late rollback preserves a user file that replaced the staged destination", %{
      downloads: downloads,
      library: library
    } do
      {source, dest} = files(downloads, library, "Delayed")

      Application.put_env(:cinder, :filesystem_barrier, %{
        owner: self(),
        operation: :ln,
        contains: Path.basename(dest),
        once: true
      })

      staging = Task.async(fn -> place(source, dest, library) end)
      assert_receive {:filesystem_barrier, pid, ref, :ln, ^dest}, DiskTask.timeout_ms()
      ForeignFile.publish!(dest, "user replacement")
      assert [%ImportStage{state: :preparing, candidate_size: 9}] = Repo.all(ImportStage)
      send(pid, {ref, :continue})

      assert {:ok, staged, :placed} = DiskTask.await(staging)
      assert {:error, :stale_status} = StagedImport.commit(staged, &refuse/2)
      assert File.read!(dest) == "user replacement"
    end

    test "a refused replacement restores the original bytes", %{
      downloads: downloads,
      library: library
    } do
      {source, dest} = replacement_files(downloads, library, "Refused")
      {:ok, staged, :replaced} = place(source, dest, library, on_collision: :replace)
      assert File.read!(dest) == "candidate"

      assert {:error, :stale_status} = StagedImport.commit(staged, &refuse/2)
      assert File.read!(dest) == "original"
      assert scratch_files(dest) == []
    end

    test "a death during a replacement recovers without rollback debris", %{
      downloads: downloads,
      library: library
    } do
      {source, dest} = replacement_files(downloads, library, "Death")

      Application.put_env(:cinder, :filesystem_barrier, %{
        owner: self(),
        operation: :ln,
        contains: Path.basename(dest),
        excludes: ".cinder-rollback",
        once: true
      })

      staging = Task.async(fn -> place(source, dest, library, on_collision: :replace) end)
      Process.unlink(staging.pid)
      assert_receive {:filesystem_barrier, pid, _ref, :ln, ^dest}, DiskTask.timeout_ms()
      assert File.read!(dest) == "candidate"
      Process.exit(pid, :kill)
      catch_exit(Task.await(staging))
      assert Enum.any?(scratch_files(dest), &String.starts_with?(&1, ".cinder-rollback-"))

      assert :ok = StagedImport.reconcile()
      assert File.read!(dest) == "original"
      assert scratch_files(dest) == []
      refute Repo.exists?(ImportStage)

      assert {:ok, staged, :replaced} = place(source, dest, library, on_collision: :replace)
      assert {:ok, :ok} = StagedImport.commit(staged, &record_all/2)
      assert File.read!(dest) == "candidate"
      assert scratch_files(dest) == []
    end

    test "a death after the catalog write keeps the new bytes and cleans the backup", %{
      downloads: downloads,
      library: library
    } do
      {source, dest} = replacement_files(downloads, library, "Afterwards")
      {:ok, staged, :replaced} = place(source, dest, library, on_collision: :replace)

      Application.put_env(:cinder, :filesystem_barrier, %{
        owner: self(),
        operation: :rm,
        phase: :before,
        contains: ".cinder-rollback",
        once: true
      })

      {owner, ref} = spawn_monitor(fn -> StagedImport.commit(staged, &record_all/2) end)
      assert_receive {:filesystem_barrier, ^owner, _ref, :rm, backup}, DiskTask.timeout_ms()
      assert Repo.one!(ImportStage).state == :cleaning
      assert File.read!(dest) == "candidate"
      assert File.exists?(backup)

      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^ref, :process, ^owner, :killed}, 15_000

      expire!(Repo.one!(ImportStage))
      assert :ok = StagedImport.reconcile()
      assert File.read!(dest) == "candidate"
      refute File.exists?(backup)
      refute Repo.exists?(ImportStage)
    end

    test "a failed rollback restore stays durable and converges", %{
      downloads: downloads,
      library: library
    } do
      {source, dest} = replacement_files(downloads, library, "Converge")
      {:ok, staged, :replaced} = place(source, dest, library, on_collision: :replace)

      Application.put_env(:cinder, :filesystem_failure, %{
        operation: :rename,
        source_contains: ".cinder-rollback",
        reason: :eacces,
        once: true
      })

      assert {:error, :stale_status} = StagedImport.commit(staged, &refuse/2)
      refute File.exists?(dest)

      assert [%ImportStage{state: :rolling_back, last_error: "eacces", attempt_count: 1} = row] =
               Repo.all(ImportStage)

      assert :ok = StagedImport.reconcile()
      refute File.exists?(dest)
      assert File.exists?(row.backup)

      expire!(Repo.one!(ImportStage))
      assert :ok = StagedImport.reconcile()
      assert File.read!(dest) == "original"
      assert scratch_files(dest) == []
      refute Repo.exists?(ImportStage)
    end
  end
end
