defmodule Cinder.Download.ContentPolicyTest do
  # async: false — the disabled-path test flips the module's global Application env, which every
  # in-flight poller tick reads.
  use ExUnit.Case, async: false

  alias Cinder.Acquisition.BookKind
  alias Cinder.Download.ContentPolicy

  describe "check/1" do
    test "blocks a shortcut payload and names the offending file" do
      assert {:blocked, detail} =
               ContentPolicy.check(["Movie.2024.1080p/Movie.2024.1080p.mkv.lnk"])

      assert detail =~ "Movie.2024.1080p.mkv.lnk"
    end

    test "blocks every default extension, case-insensitively" do
      for ext <- ContentPolicy.blocked_extensions() do
        assert {:blocked, _} = ContentPolicy.check(["Payload" <> String.upcase(ext)])
      end
    end

    test "passes an ordinary release" do
      assert :ok =
               ContentPolicy.check([
                 "Movie.2024.1080p.BluRay/Movie.2024.1080p.BluRay.mkv",
                 "Movie.2024.1080p.BluRay/Movie.2024.1080p.BluRay.srt",
                 "Movie.2024.1080p.BluRay/RARBG.txt"
               ])
    end

    # The false positive that would have cost a household its library: RARBG-lineage releases ship
    # a 0-byte .exe next to the video, and they are a large share of public-tracker content.
    # Blocking on presence alone would re-queue and blocklist every candidate until :no_match.
    test "passes a real release that merely carries a blocked file alongside the video" do
      assert :ok =
               ContentPolicy.check([
                 "Movie.2024.1080p/Movie.2024.1080p.mkv",
                 "Movie.2024.1080p/RARBG_DO_NOT_MIRROR.exe",
                 "Movie.2024.1080p/RARBG.com"
               ])
    end

    # #750: the same filler ships next to e-books and audiobooks, and a book format is the media
    # there. Every format a book importer publishes counts, so a new accepted format cannot
    # quietly reopen this false positive.
    test "passes an e-book or audiobook release that carries a blocked file alongside the book" do
      for kind <- BookKind.all(), format <- BookKind.accepted_formats(kind) do
        assert :ok =
                 ContentPolicy.check([
                   "The Dispossessed/The Dispossessed.#{format}",
                   "The Dispossessed/RARBG_DO_NOT_MIRROR.exe"
                 ]),
               "#{kind} .#{format} release was blocked"
      end
    end

    # A format no importer publishes is not media: the download could never become an available
    # book, so its executable is the payload.
    test "a book format no importer publishes does not shield an executable" do
      for kind <- BookKind.all(),
          format <- BookKind.fetch!(kind).known_formats -- accepted_book_formats() do
        assert {:blocked, _} = ContentPolicy.check(["The Dispossessed.#{format}", "setup.exe"]),
               "#{kind} .#{format} shielded the executable"
      end
    end

    test "still blocks a lone or book-disguised payload" do
      assert {:blocked, _} = ContentPolicy.check(["The Dispossessed.epub.exe", "readme.txt"])
      assert {:blocked, _} = ContentPolicy.check(["The Dispossessed (Audiobook).m4b.lnk"])
      assert {:blocked, _} = ContentPolicy.check(["The Dispossessed/setup.exe"])
    end

    # Seeing through an ADS suffix must not cost colon-titled releases their extension — reading
    # "Re:Zero ....mkv" as extension-less would stop it counting as media and blocklist it.
    test "a colon in the title neither hides a payload nor disqualifies the media" do
      assert :ok =
               ContentPolicy.check([
                 "[SubsPlease] Re:Zero S02E01 (1080p).mkv",
                 "RARBG_DO_NOT_MIRROR.exe"
               ])

      assert :ok = ContentPolicy.check(["Movie: The Sequel (2024) 1080p BluRay.mkv", "RARBG.com"])

      assert {:blocked, _} =
               ContentPolicy.check(["Watch full movie in HD: click here.lnk", "readme.txt"])

      assert {:blocked, _} = ContentPolicy.check(["free movie: setup.exe", "info.nfo"])
    end

    test "passes a VIDEO_TS DVD rip, whose only content type is .vob/.ifo" do
      assert :ok =
               ContentPolicy.check([
                 "VIDEO_TS/VTS_01_1.VOB",
                 "VIDEO_TS/VIDEO_TS.IFO",
                 "VIDEO_TS/VIDEO_TS.BUP",
                 "RARBG.com"
               ])
    end

    test "passes an archive-packed release carrying a blocked companion" do
      assert :ok =
               ContentPolicy.check([
                 "Show.S01E01/show.s01e01.rar",
                 "Show.S01E01/show.s01e01.par2",
                 "Show.S01E01/Downloaded.from.somewhere.exe"
               ])
    end

    # The reason there is no "contains no video file" rule: these are legitimate mid-download
    # states, and a false positive here deletes a good download.
    test "passes an archive-packed release that has not been unpacked yet" do
      assert :ok =
               ContentPolicy.check([
                 "Show.S01E01/show.s01e01.rar",
                 "Show.S01E01/show.s01e01.r00",
                 "Show.S01E01/show.s01e01.par2"
               ])
    end

    test "passes an empty list — a torrent with no metadata yet has no opinion to give" do
      assert :ok = ContentPolicy.check([])
    end

    # A bare Path.extname/1 match is defeated by one appended byte, and all three of these still
    # name an executable on the machine that opens the download share.
    test "is not evaded by a trailing dot, trailing space, or an ADS suffix" do
      for name <- [
            "evil.exe.",
            "evil.exe..",
            "evil.exe ",
            "evil.exe . ",
            "evil.exe:$DATA",
            "evil.lnk:Zone.Identifier"
          ] do
        assert {:blocked, _} = ContentPolicy.check([name]), "#{name} slipped through"
      end
    end

    test "an operator's upper-case configured extension still matches" do
      original = Application.get_env(:cinder, ContentPolicy, [])
      Application.put_env(:cinder, ContentPolicy, enabled: true, blocked_extensions: [".EXE"])
      on_exit(fn -> Application.put_env(:cinder, ContentPolicy, original) end)

      assert {:blocked, _} = ContentPolicy.check(["payload.exe"])
    end

    test "the detail is sanitized — the filename is remote and gets logged and persisted" do
      assert {:blocked, detail} =
               ContentPolicy.check(["ok.mkv\n2026-08-01 [error] forged log line.exe"])

      refute detail =~ "\n"
      assert byte_size(detail) < 600
    end

    test "ignores a non-binary entry rather than raising" do
      assert :ok = ContentPolicy.check([nil, 42])
      assert {:blocked, _} = ContentPolicy.check([nil, "bad.exe"])
    end
  end

  describe "vet/2 and vet_completed/3" do
    defmodule CleanClient do
      @moduledoc false
      def files(_id), do: {:ok, ["Movie.mkv"]}
    end

    defmodule FakeClient do
      @moduledoc false
      def files(_id), do: {:ok, ["Movie.mkv.lnk"]}
    end

    defmodule BrokenClient do
      @moduledoc false
      def files(_id), do: {:error, :econnrefused}
    end

    defmodule ExplodingClient do
      @moduledoc false
      def files(_id), do: raise("must not be called when disabled")
    end

    test "reports the verdict for the client's file list" do
      assert :ok = ContentPolicy.vet(CleanClient, "id")
      assert {:blocked, _} = ContentPolicy.vet(FakeClient, "id")
    end

    test "a client failure is :ok — a check that could not run must not kill a download" do
      assert :ok = ContentPolicy.vet(BrokenClient, "id")
    end

    test "does not even ask the client, or walk the disk, when disabled" do
      original = Application.get_env(:cinder, ContentPolicy, [])
      Application.put_env(:cinder, ContentPolicy, enabled: false)
      on_exit(fn -> Application.put_env(:cinder, ContentPolicy, original) end)

      assert :ok = ContentPolicy.vet(ExplodingClient, "id")
      # No filesystem stub: a walk would raise Mox.UnexpectedCallError.
      assert :ok = ContentPolicy.vet_completed(ExplodingClient, "id", "/dl/Movie")
    end
  end

  defp accepted_book_formats, do: Enum.flat_map(BookKind.all(), &BookKind.accepted_formats/1)
end
