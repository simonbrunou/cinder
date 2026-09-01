defmodule Cinder.Library.BookArchive.RarTest do
  @moduledoc """
  Bounded RAR extraction via the external `unrar` binary.

  `unrar` is closed-source and cannot be scripted to produce adversarial fixtures (a genuine
  traversal entry, an oversized archive, a hang) on demand, so every test here drives a fake
  `unrar` installed at the front of `PATH` — the same seam `System.find_executable/1` itself
  resolves through. `async: false`: `PATH` is a real OS-process-wide environment variable, not
  scoped to one Elixir process.
  """
  use ExUnit.Case, async: false

  alias Cinder.Library.BookArchive.Rar

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    original_path = System.get_env("PATH")
    fakebin = Path.join(tmp, "fakebin")
    File.mkdir_p!(fakebin)
    dest = Path.join(tmp, "dest")
    File.mkdir_p!(dest)

    on_exit(fn ->
      if original_path, do: System.put_env("PATH", original_path)
    end)

    {:ok, tmp: tmp, fakebin: fakebin, dest: dest, original_path: original_path}
  end

  # Installs `script` as the `unrar` resolved by `System.find_executable/1` for the rest of
  # this test, by putting a fake binary ahead of the real PATH.
  defp install_fake_unrar(fakebin, original_path, script) do
    path = Path.join(fakebin, "unrar")
    File.write!(path, script)
    File.chmod!(path, 0o755)
    System.put_env("PATH", fakebin <> ":" <> (original_path || ""))
  end

  defp remove_fake_unrar(fakebin, original_path) do
    File.rm(Path.join(fakebin, "unrar"))
    System.put_env("PATH", original_path || "")
  end

  describe "available?/0" do
    test "true when unrar resolves on PATH", %{fakebin: fakebin, original_path: original_path} do
      install_fake_unrar(fakebin, original_path, "#!/bin/sh\nexit 0\n")
      assert Rar.available?()
    end

    test "false when unrar is absent from PATH", %{fakebin: fakebin, original_path: original_path} do
      remove_fake_unrar(fakebin, original_path)
      System.put_env("PATH", fakebin)
      refute Rar.available?()
    end
  end

  describe "extract/3 when unrar is absent" do
    test "refuses as :unsupported_archive, the same reason the feature is skipped for", %{
      fakebin: fakebin,
      dest: dest
    } do
      System.put_env("PATH", fakebin)
      assert {:error, :unsupported_archive} = Rar.extract("/tmp/whatever.rar", dest)
    end
  end

  describe "extract/3 with a working unrar" do
    test "lists then extracts, and the extracted file lands under dest", %{
      fakebin: fakebin,
      original_path: original_path,
      dest: dest
    } do
      install_fake_unrar(fakebin, original_path, """
      #!/bin/sh
      case "$1" in
        lb) printf 'book.epub\\n'; exit 0 ;;
        x) printf 'epub bytes' > "$7book.epub"; exit 0 ;;
      esac
      """)

      assert :ok = Rar.extract("/tmp/book.rar", dest)
      assert File.read!(Path.join(dest, "book.epub")) == "epub bytes"
    end
  end

  describe "extract/3 entry safety" do
    test "a traversal entry name from `lb` refuses before extraction ever runs", %{
      fakebin: fakebin,
      original_path: original_path,
      dest: dest,
      tmp: tmp
    } do
      marker = Path.join(tmp, "extraction_ran")

      install_fake_unrar(fakebin, original_path, """
      #!/bin/sh
      case "$1" in
        lb) printf '../../../etc/evil.txt\\n'; exit 0 ;;
        x) touch #{marker}; exit 0 ;;
      esac
      """)

      assert {:error, :archive_entry_unsafe} = Rar.extract("/tmp/evil.rar", dest)
      refute File.exists?(marker)
    end

    test "an absolute entry name from `lb` refuses before extraction ever runs", %{
      fakebin: fakebin,
      original_path: original_path,
      dest: dest,
      tmp: tmp
    } do
      marker = Path.join(tmp, "extraction_ran")

      install_fake_unrar(fakebin, original_path, """
      #!/bin/sh
      case "$1" in
        lb) printf '/etc/evil.txt\\n'; exit 0 ;;
        x) touch #{marker}; exit 0 ;;
      esac
      """)

      assert {:error, :archive_entry_unsafe} = Rar.extract("/tmp/evil.rar", dest)
      refute File.exists?(marker)
    end
  end

  describe "extract/3 ceilings" do
    test "exceeding max_entries refuses without extracting", %{
      fakebin: fakebin,
      original_path: original_path,
      dest: dest,
      tmp: tmp
    } do
      marker = Path.join(tmp, "extraction_ran")

      entries = Enum.map_join(1..20, "\\n", &"book#{&1}.txt")

      install_fake_unrar(fakebin, original_path, """
      #!/bin/sh
      case "$1" in
        lb) printf '#{entries}\\n'; exit 0 ;;
        x) touch #{marker}; exit 0 ;;
      esac
      """)

      assert {:error, :archive_entry_limit} =
               Rar.extract("/tmp/many.rar", dest, max_entries: 10)

      refute File.exists?(marker)
    end

    test "a nonzero exit from `lb` (a corrupt or password-protected archive) is refused", %{
      fakebin: fakebin,
      original_path: original_path,
      dest: dest
    } do
      install_fake_unrar(fakebin, original_path, """
      #!/bin/sh
      case "$1" in
        lb) echo "cannot open archive"; exit 1 ;;
      esac
      """)

      assert {:error, :archive_corrupt} = Rar.extract("/tmp/broken.rar", dest)
    end

    test "exceeding max_expanded_size kills the process and refuses", %{
      fakebin: fakebin,
      original_path: original_path,
      dest: dest
    } do
      install_fake_unrar(fakebin, original_path, """
      #!/bin/sh
      case "$1" in
        lb) printf 'book.epub\\n'; exit 0 ;;
        x)
          dest="$7"
          i=0
          while true; do
            i=$((i+1))
            dd if=/dev/zero of="$dest/chunk_$i" bs=1024 count=200 2>/dev/null
            sleep 0.02
          done
          ;;
      esac
      """)

      assert {:error, :archive_size_limit} =
               Rar.extract("/tmp/bomb.rar", dest,
                 max_expanded_size: 500 * 1024,
                 poll_interval: 20
               )

      # The killed process must actually stop growing the destination, not merely return early
      # while still writing in the background.
      size_at_return = dir_size(dest)
      Process.sleep(300)
      assert dir_size(dest) == size_at_return
    end

    test "exceeding max_duration_ms kills a hung process and refuses", %{
      fakebin: fakebin,
      original_path: original_path,
      dest: dest
    } do
      install_fake_unrar(fakebin, original_path, """
      #!/bin/sh
      case "$1" in
        lb) printf 'book.epub\\n'; exit 0 ;;
        x) sleep 3600 ;;
      esac
      """)

      t0 = System.monotonic_time(:millisecond)

      assert {:error, :archive_timeout} =
               Rar.extract("/tmp/hung.rar", dest, max_duration_ms: 200, poll_interval: 20)

      elapsed = System.monotonic_time(:millisecond) - t0
      assert elapsed < 3000
    end
  end

  defp dir_size(dir) do
    dir
    |> Path.join("**")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&File.stat!(&1).size)
    |> Enum.sum()
  end
end
