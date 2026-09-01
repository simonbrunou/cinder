defmodule Cinder.Library.BookArchive.ZipTest do
  @moduledoc """
  Bounded ZIP extraction: legitimate archives extract, and every adversarial shape this module's
  own moduledoc documents as deliberately refused is proven refused rather than partially
  interpreted.
  """
  use ExUnit.Case, async: true

  alias Cinder.Library.BookArchive.Zip

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    dest = Path.join(tmp, "dest")
    File.mkdir_p!(dest)
    {:ok, dest: dest, tmp: tmp}
  end

  describe "legitimate archives" do
    test "a small zip with a stored entry extracts", %{tmp_dir: tmp, dest: dest} do
      archive = Path.join(tmp, "book.zip")
      :zip.create(String.to_charlist(archive), [{~c"book.epub", "epub bytes"}])

      assert :ok = Zip.extract(archive, dest)
      assert File.read!(Path.join(dest, "book.epub")) == "epub bytes"
    end

    test "a zip with multiple entries and a subdirectory extracts all of them", %{
      tmp_dir: tmp,
      dest: dest
    } do
      archive = Path.join(tmp, "book.zip")

      :zip.create(String.to_charlist(archive), [
        {~c"book.epub", "epub bytes"},
        {~c"chapters/one.txt", "chapter one"},
        {~c"chapters/two.txt", "chapter two"}
      ])

      assert :ok = Zip.extract(archive, dest)
      assert File.read!(Path.join(dest, "book.epub")) == "epub bytes"
      assert File.read!(Path.join([dest, "chapters", "one.txt"])) == "chapter one"
      assert File.read!(Path.join([dest, "chapters", "two.txt"])) == "chapter two"
    end

    test "a deflated (compressed) entry inflates correctly", %{tmp_dir: tmp, dest: dest} do
      archive = Path.join(tmp, "book.zip")
      content = String.duplicate("The quick brown fox jumps over the lazy dog. ", 500)

      {:ok, {_name, zip_binary}} =
        :zip.zip(~c"book.zip", [{~c"book.epub", content}], [:memory])

      File.write!(archive, zip_binary)

      assert :ok = Zip.extract(archive, dest)
      assert File.read!(Path.join(dest, "book.epub")) == content
    end
  end

  describe "refused: traversal and absolute paths" do
    test "an entry naming a `../` traversal is refused, nothing extracted", %{
      tmp_dir: tmp,
      dest: dest
    } do
      archive = Path.join(tmp, "evil.zip")
      :zip.create(String.to_charlist(archive), [{~c"../../../etc/evil.txt", "pwned"}])

      assert {:error, :archive_entry_unsafe} = Zip.extract(archive, dest)
      refute File.exists?(Path.join([tmp, "evil.txt"]))
    end

    test "an entry naming an absolute path is refused", %{tmp_dir: tmp, dest: dest} do
      archive = Path.join(tmp, "evil.zip")
      # `:zip.create/2` itself sanitizes an absolute entry name before writing it (proven in
      # development — it silently rewrites to a relative path), so a hostile archive built by
      # some other tool is the fixture that actually exercises this refusal.
      script = """
      import zipfile
      with zipfile.ZipFile(#{inspect(archive)}, "w") as zf:
          zi = zipfile.ZipInfo("/etc/evil_absolute.txt")
          zf.writestr(zi, "pwned")
      """

      python = System.find_executable("python3") || raise "python3 not found on PATH"
      {_output, 0} = System.cmd(python, ["-c", script])

      assert {:error, :archive_entry_unsafe} = Zip.extract(archive, dest)
    end

    test "a whole-archive refusal leaves no partial extraction behind", %{
      tmp_dir: tmp,
      dest: dest
    } do
      archive = Path.join(tmp, "mixed.zip")

      :zip.create(String.to_charlist(archive), [
        {~c"book.epub", "legit content"},
        {~c"../escape.txt", "pwned"}
      ])

      assert {:error, :archive_entry_unsafe} = Zip.extract(archive, dest)
      # Entries are read from the central directory in order; even though "book.epub" would
      # have been safe on its own, the whole archive refuses together.
      refute File.exists?(Path.join(dest, "book.epub"))
    end
  end

  describe "refused: ceilings" do
    test "exceeding max_entries refuses without reading any entry data", %{
      tmp_dir: tmp,
      dest: dest
    } do
      archive = Path.join(tmp, "many.zip")
      entries = for i <- 1..20, do: {String.to_charlist("book#{i}.txt"), "x"}
      :zip.create(String.to_charlist(archive), entries)

      assert {:error, :archive_entry_limit} = Zip.extract(archive, dest, max_entries: 10)
    end

    test "exceeding max_expanded_size aborts mid-stream, proven against a real bomb", %{
      tmp_dir: tmp,
      dest: dest
    } do
      archive = Path.join(tmp, "bomb.zip")

      # A single highly-compressible entry: 20MB of zeros compresses to a tiny stream, so this
      # exercises the same mechanism a genuine gigabyte-scale bomb would, without the fixture
      # cost of actually generating one.
      big = String.duplicate(<<0>>, 20 * 1024 * 1024)

      {:ok, {_name, zip_binary}} =
        :zip.zip(~c"bomb.zip", [{~c"bomb.epub", big}], [:memory])

      File.write!(archive, zip_binary)

      assert {:error, :archive_size_limit} =
               Zip.extract(archive, dest, max_expanded_size: 10 * 1024 * 1024)

      # Nothing left half-written under dest.
      refute File.exists?(Path.join(dest, "bomb.epub"))
    end
  end

  describe "refused: corrupt or malformed archives" do
    test "a file with no valid EOCD record is refused", %{tmp_dir: tmp, dest: dest} do
      archive = Path.join(tmp, "not_a_zip.zip")
      File.write!(archive, "this is not a zip file at all")

      assert {:error, :archive_corrupt} = Zip.extract(archive, dest)
    end

    test "an empty file is refused, not treated as an empty archive", %{
      tmp_dir: tmp,
      dest: dest
    } do
      archive = Path.join(tmp, "empty.zip")
      File.write!(archive, "")

      assert {:error, :archive_corrupt} = Zip.extract(archive, dest)
    end

    test "a CRC-32 mismatch (corrupted compressed data) is refused", %{
      tmp_dir: tmp,
      dest: dest
    } do
      archive = Path.join(tmp, "corrupt.zip")
      :zip.create(String.to_charlist(archive), [{~c"book.epub", "hello world"}])

      corrupted = corrupt_first_local_data_byte(File.read!(archive))
      File.write!(archive, corrupted)

      assert {:error, :archive_corrupt} = Zip.extract(archive, dest)
    end

    test "a local/central header compression-method mismatch is refused", %{
      tmp_dir: tmp,
      dest: dest
    } do
      archive = Path.join(tmp, "mismatch.zip")
      :zip.create(String.to_charlist(archive), [{~c"book.epub", "hello world"}])

      tampered = tamper_local_compression_method(File.read!(archive))
      File.write!(archive, tampered)

      assert {:error, :archive_corrupt} = Zip.extract(archive, dest)
    end
  end

  describe "refused: zip64" do
    test "an archive built with force_zip64 is refused via the version_needed marker", %{
      tmp_dir: tmp,
      dest: dest
    } do
      archive = Path.join(tmp, "zip64.zip")

      # Erlang's `:zip` module has no zip64 writer; build the archive with Python's `zipfile`
      # (available on this system, used elsewhere in this module's own development) so the
      # fixture is a genuine zip64-marked entry, not a hand-rolled approximation.
      script = """
      import zipfile
      with zipfile.ZipFile(#{inspect(archive)}, "w") as zf:
          with zf.open("book.epub", "w", force_zip64=True) as f:
              f.write(b"zip64 forced content")
      """

      python = System.find_executable("python3") || raise "python3 not found on PATH"
      {_output, 0} = System.cmd(python, ["-c", script])
      assert {:error, :archive_corrupt} = Zip.extract(archive, dest)
    end
  end

  # Corrupts one byte inside the compressed data region of the first (only) local entry, found
  # by locating the local file header and offsetting past its fixed fields + name.
  defp corrupt_first_local_data_byte(bytes) do
    <<"PK", 3, 4, _version::little-16, _gpflag::little-16, _method::little-16, _time::little-16,
      _date::little-16, _crc::little-32, _comp::little-32, _uncomp::little-32,
      name_len::little-16, extra_len::little-16, rest::binary>> = bytes

    header_size = 30 + name_len + extra_len
    <<header::binary-size(^header_size), byte0, tail::binary>> = rest
    <<"PK", 3, 4, header::binary, Bitwise.bxor(byte0, 0xFF), tail::binary>>
  end

  # Flips the local header's compression-method field to a value that disagrees with the
  # central directory's own record for the same entry.
  defp tamper_local_compression_method(bytes) do
    <<"PK", 3, 4, version::little-16, gpflag::little-16, _method::little-16, tail::binary>> =
      bytes

    <<"PK", 3, 4, version::little-16, gpflag::little-16, 99::little-16, tail::binary>>
  end
end
