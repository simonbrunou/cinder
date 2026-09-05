defmodule Cinder.Library.BookArchive.RarTest do
  @moduledoc """
  Bounded RAR extraction via the external `unrar` binary.

  `unrar` is closed-source and cannot be scripted to produce adversarial fixtures (a genuine
  traversal entry, an oversized archive, a hang) on demand, so every test here drives a fake
  `unrar` installed at the front of `PATH` — the same seam `System.find_executable/1` itself
  resolves through. `async: false`: `PATH` is a real OS-process-wide environment variable, not
  scoped to one Elixir process.

  ## What this proves, and what it does not

  This suite proves `Cinder.Library.BookArchive.Rar`'s own contract with `unrar`: what it does
  with a listing, how it reacts to extraction output, how it kills a runaway or hung process,
  and — critically — that it does not simply trust the real `unrar`'s `-ol-` flag or its path
  handling (the fake binary here can freely violate both, on demand, in ways the real
  closed-source binary can't be scripted to). It does NOT prove anything about the real
  `unrar`'s own behavior against a genuinely malicious `.rar` file — that binary is opaque to
  this codebase by construction, which is exactly why the extraction pipeline never trusts it
  unverified.
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

    test "a symlink planted by `unrar x` despite `-ol-` is refused, not trusted", %{
      fakebin: fakebin,
      original_path: original_path,
      dest: dest,
      tmp: tmp
    } do
      # `-ol-` is passed to `unrar x` asking it to skip symbolic links, but `unrar` is
      # closed-source and this module does not trust it to have honoured that flag — this fake
      # binary plants one anyway, exactly as a real `unrar` bug (or the CVE-2022-30333 class of
      # listing/extraction divergence) would.
      outside = Path.join(tmp, "outside_target")
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "secret.txt"), "not meant to be reachable")

      install_fake_unrar(fakebin, original_path, """
      #!/bin/sh
      case "$1" in
        lb) printf 'book.epub\\n'; exit 0 ;;
        x)
          dest="$7"
          printf 'epub bytes' > "${dest}book.epub"
          ln -s #{outside} "${dest}evil_link"
          exit 0
          ;;
      esac
      """)

      assert {:error, :archive_entry_unsafe} = Rar.extract("/tmp/evil.rar", dest)
    end

    test "a symlinked directory planted by `unrar x` is refused, never walked into", %{
      fakebin: fakebin,
      original_path: original_path,
      dest: dest,
      tmp: tmp
    } do
      outside = Path.join(tmp, "outside_dir")
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "secret.txt"), "not meant to be reachable")

      install_fake_unrar(fakebin, original_path, """
      #!/bin/sh
      case "$1" in
        lb) printf 'book.epub\\n'; exit 0 ;;
        x)
          dest="$7"
          printf 'epub bytes' > "${dest}book.epub"
          ln -s #{outside} "${dest}evil_dir"
          exit 0
          ;;
      esac
      """)

      assert {:error, :archive_entry_unsafe} = Rar.extract("/tmp/evil.rar", dest)
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

    test "a hung `lb` call is killed by list_timeout_ms and refused, without extraction ever
          running",
         %{
           fakebin: fakebin,
           original_path: original_path,
           dest: dest,
           tmp: tmp
         } do
      marker = Path.join(tmp, "extraction_ran")

      install_fake_unrar(fakebin, original_path, """
      #!/bin/sh
      case "$1" in
        lb) sleep 3600 ;;
        x) touch #{marker}; exit 0 ;;
      esac
      """)

      t0 = System.monotonic_time(:millisecond)

      assert {:error, :archive_corrupt} =
               Rar.extract("/tmp/hung-list.rar", dest, list_timeout_ms: 200)

      elapsed = System.monotonic_time(:millisecond) - t0
      assert elapsed < 3000
      refute File.exists?(marker)
    end

    # #510: a hung `lb` timing out its Elixir-side Task used to leave the underlying OS process
    # running — closing a port does nothing to a child that never reads stdin. Proven here by a
    # fake `lb` that outlives the configured timeout and then writes a marker: the marker must
    # never appear, meaning the real process was killed, not merely abandoned.
    test "a hung `lb` call's OS process is actually killed, not merely abandoned by the timeout",
         %{
           fakebin: fakebin,
           original_path: original_path,
           dest: dest,
           tmp: tmp
         } do
      marker = Path.join(tmp, "list_survived")

      install_fake_unrar(fakebin, original_path, """
      #!/bin/sh
      case "$1" in
        lb) sleep 1; touch #{marker}; exit 0 ;;
      esac
      """)

      assert {:error, :archive_corrupt} =
               Rar.extract("/tmp/hung-list.rar", dest, list_timeout_ms: 100)

      Process.sleep(1200)
      refute File.exists?(marker)
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

    # #506: `unrar` emitting continuous stdout activity (no sleep between writes — a
    # sleep-throttled stub leaves incidental gaps that let the timer fire by accident and would
    # not reliably reproduce this under suite scheduler load) must not suppress the size ceiling
    # forever. The oversized write happens up front, then the process spins on `printf` alone —
    # no forked subprocess in the loop — to keep stdout messages arriving back-to-back.
    @tag timeout: 5_000
    test "continuous stdout activity cannot suppress max_expanded_size indefinitely", %{
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
          dd if=/dev/zero of="$dest/big" bs=1024 count=200 2>/dev/null
          while :; do printf 'spam'; done
          ;;
      esac
      """)

      assert {:error, :archive_size_limit} =
               Rar.extract("/tmp/chatty-bomb.rar", dest,
                 max_expanded_size: 50 * 1024,
                 poll_interval: 50,
                 max_duration_ms: 3_000
               )
    end

    # #506: the zero-exit-status path returned :ok unconditionally, with no final size check —
    # so a fast extraction that finishes (and exits 0) before the first poll tick ever fires
    # slipped through even though it already exceeded the cap on disk.
    test "a fast extractor exceeding max_expanded_size is refused even if it exits 0 before the first poll",
         %{fakebin: fakebin, original_path: original_path, dest: dest} do
      install_fake_unrar(fakebin, original_path, """
      #!/bin/sh
      case "$1" in
        lb) printf 'book.epub\\n'; exit 0 ;;
        x) dd if=/dev/zero of="$7big" bs=1024 count=64 2>/dev/null; exit 0 ;;
      esac
      """)

      assert {:error, :archive_size_limit} =
               Rar.extract("/tmp/fast-bomb.rar", dest,
                 max_expanded_size: 1024,
                 poll_interval: 1_000
               )
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
