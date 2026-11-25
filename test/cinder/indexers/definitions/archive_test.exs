defmodule Cinder.Indexers.Definitions.ArchiveTest do
  use ExUnit.Case, async: true

  alias Cinder.Indexers.Definitions.{Archive, Set}
  alias Cinder.Indexers.Definitions.Set.{DefinitionFile, Versions}
  alias Cinder.Test.DefinitionsZip

  @commit "56b20b19c18fee53869fca2bca72ba59101da2f9"
  @root "Indexers-56b20b19c18fee53869fca2bca72ba59101da2f9/"
  @versions """
  # Comment lines and blank lines are skipped.

  CURRENT_VERSION=11
  MAX_VERSION=12
  MIN_VERSION=11
  NEXT_VERSION=13
  """

  defp read(files), do: Archive.read(DefinitionsZip.codeload(@commit, files), @commit)

  defp kept_paths({:ok, set}), do: Enum.map(set.files, &"#{&1.folder}/#{&1.name}")

  describe "read/2 on a codeload archive" do
    test "keeps VERSIONS and each definitions/vN/*.yml file, and skips every other entry" do
      assert {:ok, set} =
               read([
                 {"VERSIONS", @versions},
                 {"definitions/v11/a.yml", "id: a11\n"},
                 {"definitions/v12/a.yml", "id: a12\n", method: 0},
                 {"definitions/v11/schema.json", "{}"},
                 {"README.md", "readme"},
                 {".github/x.yml", "on: push\n"}
               ])

      assert %Set{commit: @commit} = set

      assert set.versions == %Versions{
               min: 11,
               max: 12,
               values: %{
                 "CURRENT_VERSION" => "11",
                 "MAX_VERSION" => "12",
                 "MIN_VERSION" => "11",
                 "NEXT_VERSION" => "13"
               }
             }

      assert [
               %DefinitionFile{folder: "v11", name: "a.yml", bytes: "id: a11\n"},
               %DefinitionFile{folder: "v12", name: "a.yml", bytes: "id: a12\n"}
             ] = set.files
    end

    test "each kept file carries git's blob hash of its bytes, in lowercase hex" do
      assert {:ok, %{files: [file]}} =
               read([{"VERSIONS", @versions}, {"definitions/v11/hello.yml", "hello\n"}])

      assert file.blob_sha == "ce013625030ba8dba906f756967f9e9ca394464a"
    end

    test "keeps only names whose folder is v and digits and whose file is a .yml directly in it" do
      result =
        read([
          {"VERSIONS", @versions},
          {"definitions/v11/kept.yml", "x"},
          {"definitions/v0/kept.yml", "x"},
          {"definitions/x11/a.yml", "x"},
          {"definitions/V11/a.yml", "x"},
          {"definitions/v/a.yml", "x"},
          {"definitions/v1a/a.yml", "x"},
          {"definitions/av11/a.yml", "x"},
          {"definitions/v11/sub/a.yml", "x"},
          {"definitions/v11/a.yaml", "x"},
          {"definitions/v11/a.yml.bak", "x"},
          {"definitions/v11/.yml", "x"},
          {"definitions/a.yml", "x"},
          {"defs/v11/a.yml", "x"},
          {"docs/definitions/v11/a.yml", "x"},
          {"definitions/v11/VERSIONS", "x"}
        ])

      assert kept_paths(result) == ["v11/kept.yml", "v0/kept.yml"]
    end

    test "reads VERSIONS only at the root" do
      assert {:error, :versions_missing} =
               read([
                 {"docs/VERSIONS", @versions},
                 {"VERSIONS.bak", @versions},
                 {"definitions/v11/a.yml", "x"}
               ])
    end

    test "skips other entries unread: bad data, a wrong CRC, a bomb and a size over the caps" do
      bomb = :binary.copy(<<0>>, 80 * 1024 * 1024)

      assert {:ok, set} =
               read([
                 {"VERSIONS", @versions},
                 {"definitions/v11/a.yml", "x"},
                 {"scripts/broken.sh", "x", compressed: <<0xFF, 0xFF, 0xFF, 0xFF>>},
                 {"README.md", "readme", crc: 1, method: 0},
                 {"bomb.bin", bomb, uncomp_size: 10},
                 {"declared-large.bin", "x", method: 0, uncomp_size: 100_000_000}
               ])

      assert kept_paths({:ok, set}) == ["v11/a.yml"]
    end

    test "refuses a commit that is not 40 lowercase hex characters" do
      zip = DefinitionsZip.codeload(@commit, [{"VERSIONS", @versions}])

      for commit <- [String.upcase(@commit), String.slice(@commit, 0, 39), @commit <> "0", "../x"] do
        assert {commit, {:error, :invalid_commit}} == {commit, Archive.read(zip, commit)}
      end
    end
  end

  describe "read/2 refuses a layout other than one root folder for the commit" do
    test "a root folder named for another commit" do
      other = String.duplicate("a", 40)
      zip = DefinitionsZip.codeload(other, [{"VERSIONS", @versions}])

      assert {:error, :archive_layout} = Archive.read(zip, @commit)
    end

    test "a second root folder beside the commit's" do
      zip =
        DefinitionsZip.build([
          {@root, "", method: 0},
          {@root <> "VERSIONS", @versions},
          {"Indexers-main/", "", method: 0}
        ])

      assert {:error, :archive_layout} = Archive.read(zip, @commit)
    end

    test "an entry outside the root folder" do
      zip = DefinitionsZip.build([{@root <> "VERSIONS", @versions}, {"README.md", "x"}])

      assert {:error, :archive_layout} = Archive.read(zip, @commit)
    end

    test "an entry whose name only starts with the root folder's name" do
      for name <- ["Indexers-#{@commit}x/VERSIONS", "Indexers-#{@commit}"] do
        zip = DefinitionsZip.build([{@root <> "VERSIONS", @versions}, {name, "x"}])

        assert {name, {:error, :archive_layout}} == {name, Archive.read(zip, @commit)}
      end
    end
  end

  describe "read/2 refuses an unsafe entry name" do
    test "a kept name with a .. component" do
      assert {:error, :archive_entry_unsafe} =
               read([{"VERSIONS", @versions}, {"definitions/v11/../../evil.yml", "x"}])
    end

    test "a skipped name with a .. component" do
      assert {:error, :archive_entry_unsafe} =
               read([{"VERSIONS", @versions}, {"scripts/../x.sh", "x"}])
    end

    test "an absolute name" do
      zip = DefinitionsZip.build([{@root <> "VERSIONS", @versions}, {"/etc/passwd", "x"}])

      assert {:error, :archive_entry_unsafe} = Archive.read(zip, @commit)
    end

    test "a kept name that is not UTF-8" do
      assert {:error, :archive_entry_unsafe} =
               read([{"VERSIONS", @versions}, {<<"definitions/v11/", 0xFF, ".yml">>, "x"}])
    end
  end

  describe "read/2 caps" do
    test "5,000 entries read, and 5,001 refuse" do
      files = for n <- 1..4_997, do: {"scripts/#{n}.sh", "", method: 0}

      zip = DefinitionsZip.codeload(@commit, [{"VERSIONS", @versions} | files])
      assert {:ok, _set} = Archive.read(zip, @commit)

      zip = DefinitionsZip.codeload(@commit, [{"VERSIONS", @versions} | files ++ [{"x", ""}]])
      assert {:error, :archive_entry_limit} = Archive.read(zip, @commit)
    end

    test "the entry count is checked from the end record, before the directory is read" do
      zip = DefinitionsZip.build([{@root <> "VERSIONS", @versions}], entry_count: 5_001)

      assert {:error, :archive_entry_limit} = Archive.read(zip, @commit)
    end

    test "a kept file of 524,288 bytes reads, and one of 524,289 refuses" do
      at_cap = :binary.copy("a", 524_288)

      assert {:ok, %{files: [%{bytes: ^at_cap}]}} =
               read([{"VERSIONS", @versions}, {"definitions/v11/a.yml", at_cap}])

      assert {:error, :file_too_large} =
               read([{"VERSIONS", @versions}, {"definitions/v11/a.yml", at_cap <> "a"}])

      assert {:error, :file_too_large} =
               read([
                 {"VERSIONS", @versions},
                 {"definitions/v11/a.yml", at_cap <> "a", method: 0}
               ])
    end

    test "kept files of 67,108,864 bytes in all read, and one byte more refuses" do
      file = :binary.copy("a", 524_288)
      last = :binary.copy("a", 524_288 - byte_size(@versions))
      full = for n <- 1..127, do: {"definitions/v11/#{n}.yml", file}
      files = [{"VERSIONS", @versions}, {"definitions/v12/last.yml", last} | full]

      assert {:ok, set} = read(files)
      assert Enum.sum_by(set.files, &byte_size(&1.bytes)) + byte_size(@versions) == 67_108_864

      assert {:error, :archive_size_limit} = read(files ++ [{"definitions/v12/one.yml", "a"}])
    end

    test "a DEFLATE bomb declared small stops within one inflate piece past the file cap" do
      bomb = :binary.copy(<<0>>, 64 * 1024 * 1024)

      zip =
        DefinitionsZip.codeload(@commit, [{"definitions/v11/bomb.yml", bomb, uncomp_size: 100}])

      {result, inflated} = inflated_bytes(fn -> Archive.read(zip, @commit) end)

      assert {:error, :file_too_large} = result
      assert inflated > 524_288
      assert inflated <= 524_288 + 16_384
    end
  end

  describe "read/2 refuses a corrupt archive" do
    test "a kept entry with a wrong CRC" do
      assert {:error, :archive_corrupt} =
               read([{"VERSIONS", @versions}, {"definitions/v11/a.yml", "x", crc: 1}])

      assert {:error, :archive_corrupt} =
               read([{"VERSIONS", @versions}, {"definitions/v11/a.yml", "x", crc: 1, method: 0}])
    end

    test "a method other than STORED and DEFLATED, on a kept or a skipped entry" do
      assert {:error, :archive_corrupt} =
               read([{"VERSIONS", @versions}, {"definitions/v11/a.yml", "x", method: 12}])

      assert {:error, :archive_corrupt} =
               read([{"VERSIONS", @versions}, {"README.md", "x", method: 12}])
    end

    test "a ZIP64 sentinel or marker, on a skipped entry too" do
      for sentinel <- [uncomp_size: 0xFFFFFFFF, cd_comp_size: 0xFFFFFFFF, cd_offset: 0xFFFFFFFF] do
        assert {sentinel, {:error, :archive_corrupt}} ==
                 {sentinel, read([{"VERSIONS", @versions}, {"README.md", "x", [sentinel]}])}
      end

      assert {:error, :archive_corrupt} =
               read([{"VERSIONS", @versions}, {"README.md", "x", version_needed: 45}])

      zip = DefinitionsZip.build([{@root <> "VERSIONS", @versions}], entry_count: 0xFFFF)
      assert {:error, :archive_corrupt} = Archive.read(zip, @commit)
    end

    test "a local header whose name or method differs from the central directory's" do
      assert {:error, :archive_corrupt} =
               read([
                 {"VERSIONS", @versions},
                 {"definitions/v11/a.yml", "x", local_name: @root <> "definitions/v11/b.yml"}
               ])

      assert {:error, :archive_corrupt} =
               read([{"VERSIONS", @versions}, {"definitions/v11/a.yml", "x", local_method: 0}])
    end

    test "a kept entry whose real size differs from its declared size" do
      assert {:error, :archive_corrupt} =
               read([
                 {"VERSIONS", @versions},
                 {"definitions/v11/a.yml", "abcdef", uncomp_size: 3}
               ])

      assert {:error, :archive_corrupt} =
               read([{"VERSIONS", @versions}, {"definitions/v11/a.yml", "abc", uncomp_size: 6}])
    end

    test "a kept entry whose DEFLATE stream is cut short or invalid" do
      data = :crypto.strong_rand_bytes(4_000)
      cut = binary_part(DefinitionsZip.deflate(data), 0, 100)

      assert {:error, :archive_corrupt} =
               read([{"VERSIONS", @versions}, {"definitions/v11/a.yml", data, compressed: cut}])

      assert {:error, :archive_corrupt} =
               read([
                 {"VERSIONS", @versions},
                 {"definitions/v11/a.yml", "x", compressed: <<0xFF, 0xFF, 0xFF, 0xFF>>}
               ])
    end

    test "a kept entry whose DEFLATE stream holds every byte but never ends" do
      data = "id: a\n"
      unended = DefinitionsZip.deflate(data, :sync)

      assert {:error, :archive_corrupt} =
               read([
                 {"VERSIONS", @versions},
                 {"definitions/v11/a.yml", data, compressed: unended}
               ])

      ended = DefinitionsZip.deflate(data)

      assert {:ok, %{files: [%{bytes: ^data}]}} =
               read([{"VERSIONS", @versions}, {"definitions/v11/a.yml", data, compressed: ended}])
    end

    test "two kept entries with the same name" do
      assert {:error, :archive_corrupt} =
               read([
                 {"VERSIONS", @versions},
                 {"definitions/v11/a.yml", "x"},
                 {"definitions/v11/a.yml", "y"}
               ])
    end

    test "an end record that counts another number of entries on this disk" do
      zip = DefinitionsZip.build([{@root <> "VERSIONS", @versions}], entries_this_disk: 2)

      assert {:error, :archive_corrupt} = Archive.read(zip, @commit)
    end

    test "a directory past the end of the zip, or one that ends early" do
      zip = DefinitionsZip.build([{@root <> "VERSIONS", @versions}], cd_offset: 1_000_000)
      assert {:error, :archive_corrupt} = Archive.read(zip, @commit)

      zip = DefinitionsZip.build([{@root <> "VERSIONS", @versions}], entry_count: 2)
      assert {:error, :archive_corrupt} = Archive.read(zip, @commit)
    end

    test "a directory holding a header past the end record's count" do
      entries = [{@root <> "VERSIONS", @versions}, {@root <> "definitions/v11/a.yml", "x"}]

      assert {:ok, _set} = Archive.read(DefinitionsZip.build(entries), @commit)

      assert {:error, :archive_corrupt} =
               Archive.read(DefinitionsZip.build(entries, entry_count: 1), @commit)
    end

    test "bytes with no end record" do
      assert {:error, :archive_corrupt} = Archive.read("not a zip", @commit)
      assert {:error, :archive_corrupt} = Archive.read("", @commit)
    end
  end

  describe "read/2 reads VERSIONS" do
    test "a missing VERSIONS" do
      assert {:error, :versions_missing} = read([{"definitions/v11/a.yml", "x"}])
    end

    test "MIN_VERSION and MAX_VERSION must be integers, present once each" do
      for versions <- [
            "MIN_VERSION=eleven\nMAX_VERSION=12\n",
            "MIN_VERSION=11\nMAX_VERSION=12.0\n",
            "MIN_VERSION=-11\nMAX_VERSION=12\n",
            "MIN_VERSION=\nMAX_VERSION=12\n",
            "MAX_VERSION=12\n",
            "MIN_VERSION=11\n",
            "MIN_VERSION=11\nMAX_VERSION=12\nMIN_VERSION=10\n",
            "MIN_VERSION=11\nMAX_VERSION=12\nNOT A PAIR\n",
            "MIN_VERSION=11\nMAX_VERSION=12\n=13\n",
            <<"MIN_VERSION=11\nMAX_VERSION=12\n", 0xFF, "=1\n">>
          ] do
        assert {versions, {:error, :versions_unreadable}} ==
                 {versions, read([{"VERSIONS", versions}])}
      end
    end

    test "skips comment and blank lines, trims spaces and reads CRLF line ends" do
      assert {:ok, set} =
               read([
                 {"VERSIONS", "# MIN_VERSION=x\r\n\r\n  MIN_VERSION = 11 \r\nMAX_VERSION=12\r\n"}
               ])

      assert set.versions == %Versions{
               min: 11,
               max: 12,
               values: %{"MIN_VERSION" => "11", "MAX_VERSION" => "12"}
             }
    end
  end

  # Sums the bytes each `:zlib.safeInflate/2` call returns while `fun` runs in this process. The
  # tracer is another process: a process that traces itself gets no trace messages.
  defp inflated_bytes(fun) do
    mfa = {:zlib, :safeInflate, 2}
    test_pid = self()
    tracer = start_supervised!({Task, fn -> sum_inflated(test_pid, 0) end})
    :erlang.trace_pattern(mfa, [{:_, [], [{:return_trace}]}], [:global])
    :erlang.trace(self(), true, [:call, {:tracer, tracer}])

    result =
      try do
        fun.()
      after
        :erlang.trace(self(), false, [:call])
        :erlang.trace_pattern(mfa, false, [:global])
      end

    # The runtime may still be delivering trace messages; once it reports them delivered, the
    # tracer has them all in its mailbox ahead of `:done`.
    ref = :erlang.trace_delivered(self())
    assert_receive {:trace_delivered, _pid, ^ref}
    send(tracer, :done)
    assert_receive {:inflated, total}
    {result, total}
  end

  defp sum_inflated(test_pid, total) do
    receive do
      {:trace, _pid, :return_from, {:zlib, :safeInflate, 2}, result} ->
        sum_inflated(test_pid, total + IO.iodata_length(elem(result, tuple_size(result) - 1)))

      {:trace, _pid, :call, {:zlib, :safeInflate, 2}, _args} ->
        sum_inflated(test_pid, total)

      :done ->
        send(test_pid, {:inflated, total})
    end
  end
end
