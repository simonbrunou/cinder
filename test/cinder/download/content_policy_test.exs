defmodule Cinder.Download.ContentPolicyTest do
  # async: false — the disabled-path test flips the module's global Application env, which every
  # in-flight poller tick reads.
  use ExUnit.Case, async: false

  import Cinder.ConfigCase, only: [put_config: 2]

  alias Cinder.Acquisition.BookKind
  alias Cinder.Download.ContentPolicy
  alias Cinder.Library

  @kinds [:video, :book]

  # The default video containers, listed here rather than read from the module so a container
  # dropped from the default fails a test.
  @video_containers ~w(.mkv .mp4 .avi .m4v .mov .wmv .ts)

  # Video containers and disc entries no importer accepts (#1448). `Cinder.LibraryTest`, "the
  # containers outside video_extensions/0", shows each is refused at import.
  @refused_containers ~w(.m2ts .mpg .mpeg .webm .flv .ogm .iso .img .vob .ifo .bup)

  @archives ~w(.rar .zip .7z .par2 .tar .gz .001)

  describe "check/2" do
    test "blocks a shortcut payload and names the offending file" do
      assert {:blocked, detail} =
               ContentPolicy.check(["Movie.2024.1080p/Movie.2024.1080p.mkv.lnk"], :video)

      assert detail =~ "Movie.2024.1080p.mkv.lnk"
    end

    test "blocks every default extension, case-insensitively, for every kind" do
      for kind <- @kinds, ext <- ContentPolicy.blocked_extensions() do
        assert match?(
                 {:blocked, _},
                 ContentPolicy.check(["Payload" <> String.upcase(ext)], kind)
               ),
               "#{kind} #{ext}"
      end
    end

    test "passes an ordinary release" do
      assert :ok =
               ContentPolicy.check(
                 [
                   "Movie.2024.1080p.BluRay/Movie.2024.1080p.BluRay.mkv",
                   "Movie.2024.1080p.BluRay/Movie.2024.1080p.BluRay.srt",
                   "Movie.2024.1080p.BluRay/RARBG.txt"
                 ],
                 :video
               )
    end

    # The false positive that would have cost a household its library: RARBG-lineage releases ship
    # a 0-byte .exe next to the video, and they are a large share of public-tracker content.
    # Blocking on presence alone would re-queue and blocklist every candidate until :no_match.
    test "passes a video release that carries a blocked file beside each video container" do
      for container <- @video_containers do
        assert ContentPolicy.check(
                 [
                   "Movie.2024.1080p/Movie.2024.1080p#{container}",
                   "Movie.2024.1080p/RARBG_DO_NOT_MIRROR.exe",
                   "Movie.2024.1080p/RARBG.com"
                 ],
                 :video
               ) == :ok,
               container
      end
    end

    # #750: the same filler ships next to e-books and audiobooks, and a book format is the media
    # there. Every format a book importer publishes counts, so a new accepted format cannot
    # quietly reopen this false positive.
    test "passes an e-book or audiobook release that carries a blocked file beside the book" do
      for format <- accepted_book_formats() do
        assert ContentPolicy.check(
                 [
                   "The Dispossessed/The Dispossessed.#{format}",
                   "The Dispossessed/RARBG_DO_NOT_MIRROR.exe"
                 ],
                 :book
               ) == :ok,
               ".#{format} book release was blocked"
      end
    end

    # #780: the other kind's media never imports, so it does not shield an executable. Before,
    # one media set served every kind, and these downloaded whole only to fail at import.
    test "a book format does not shield an executable in a video download" do
      for format <- accepted_book_formats() do
        assert match?({:blocked, _}, ContentPolicy.check(["x.#{format}", "setup.exe"], :video)),
               ".#{format} shielded the executable in a video download"
      end
    end

    # #1448: the default video media list holds only the extensions the importers accept (#780's
    # rule), so a container or disc entry they refuse no longer counts as media beside a blocked
    # file.
    test "a video container or disc entry the importers refuse does not shield an executable" do
      results =
        Map.new(@refused_containers, fn ext ->
          {ext, ContentPolicy.check(["X.2020.1080p/X.2020.1080p#{ext}", "Codec.exe"], :video)}
        end)

      assert results ==
               Map.new(@refused_containers, &{&1, {:blocked, "download contains Codec.exe"}})
    end

    test "blocks a VIDEO_TS DVD rip that carries an executable, since no importer takes a disc" do
      assert ContentPolicy.check(
               [
                 "VIDEO_TS/VTS_01_1.VOB",
                 "VIDEO_TS/VIDEO_TS.IFO",
                 "VIDEO_TS/VIDEO_TS.BUP",
                 "RARBG.com"
               ],
               :video
             ) == {:blocked, "download contains RARBG.com"}
    end

    test "a video container does not shield an executable in a book download" do
      for container <- @video_containers ++ @refused_containers do
        assert match?({:blocked, _}, ContentPolicy.check(["x#{container}", "setup.exe"], :book)),
               "#{container} shielded the executable in a book download"
      end
    end

    # The two book kinds share one set (moduledoc, "Media depends on the download's kind").
    test "a book download counts every book kind's formats as media" do
      assert :ok = ContentPolicy.check(["x.mp3", "setup.exe"], :book)
      assert :ok = ContentPolicy.check(["x.epub", "setup.exe"], :book)
    end

    # A format no importer publishes is not media: the download could never become an available
    # book, so its executable is the payload.
    test "a book format no importer publishes does not shield an executable" do
      for kind <- BookKind.all(),
          format <- BookKind.fetch!(kind).known_formats -- accepted_book_formats() do
        assert match?(
                 {:blocked, _},
                 ContentPolicy.check(["The Dispossessed.#{format}", "setup.exe"], :book)
               ),
               "#{kind} .#{format} shielded the executable"
      end
    end

    test "still blocks a lone or book-disguised payload" do
      assert {:blocked, _} =
               ContentPolicy.check(["The Dispossessed.epub.exe", "readme.txt"], :book)

      assert {:blocked, _} = ContentPolicy.check(["The Dispossessed (Audiobook).m4b.lnk"], :book)
      assert {:blocked, _} = ContentPolicy.check(["The Dispossessed/setup.exe"], :book)
    end

    # Seeing through an ADS suffix must not cost colon-titled releases their extension — reading
    # "Re:Zero ....mkv" as extension-less would stop it counting as media and blocklist it.
    test "a colon in the title neither hides a payload nor disqualifies the media" do
      assert :ok =
               ContentPolicy.check(
                 ["[SubsPlease] Re:Zero S02E01 (1080p).mkv", "RARBG_DO_NOT_MIRROR.exe"],
                 :video
               )

      assert :ok =
               ContentPolicy.check(
                 ["Movie: The Sequel (2024) 1080p BluRay.mkv", "RARBG.com"],
                 :video
               )

      assert {:blocked, _} =
               ContentPolicy.check(
                 ["Watch full movie in HD: click here.lnk", "readme.txt"],
                 :video
               )

      assert {:blocked, _} = ContentPolicy.check(["free movie: setup.exe", "info.nfo"], :video)
    end

    # The media reading before the colon is the kind's too: `setup.exe:x.mp3` is media in a book
    # download and the payload in a video one.
    test "the reading before a colon counts as media only for its kind" do
      assert :ok = ContentPolicy.check(["x.mp3:setup.exe"], :book)
      assert {:blocked, _} = ContentPolicy.check(["x.mp3:setup.exe"], :video)
      assert :ok = ContentPolicy.check(["x.mkv:setup.exe"], :video)
      assert {:blocked, _} = ContentPolicy.check(["x.mkv:setup.exe"], :book)
    end

    test "passes an archive-packed release carrying a blocked companion, for every kind" do
      for kind <- @kinds, archive <- @archives do
        assert ContentPolicy.check(
                 ["Release/release#{archive}", "Release/Downloaded.from.somewhere.exe"],
                 kind
               ) == :ok,
               "#{kind} #{archive}"
      end
    end

    # The reason there is no "contains no video file" rule: these are legitimate mid-download
    # states, and a false positive here deletes a good download.
    test "passes an archive-packed release that has not been unpacked yet, for every kind" do
      for kind <- @kinds do
        assert ContentPolicy.check(
                 [
                   "Show.S01E01/show.s01e01.rar",
                   "Show.S01E01/show.s01e01.r00",
                   "Show.S01E01/show.s01e01.par2"
                 ],
                 kind
               ) == :ok,
               "#{kind}"
      end
    end

    test "passes an empty list — a torrent with no metadata yet has no opinion to give" do
      for kind <- @kinds, do: assert(ContentPolicy.check([], kind) == :ok)
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
        assert match?({:blocked, _}, ContentPolicy.check([name], :video)),
               "#{name} slipped through"
      end
    end

    test "an operator's upper-case configured extension still matches" do
      put_config(ContentPolicy, blocked_extensions: [".EXE"])

      assert {:blocked, _} = ContentPolicy.check(["payload.exe"], :video)
    end

    # The flat override replaces the default of every kind, so no existing config changes
    # meaning: what it lists shields an executable for every kind, and nothing else does.
    test "a configured media list decides the check for every kind" do
      put_config(ContentPolicy, media_extensions: [".MP3"])

      for kind <- @kinds do
        assert ContentPolicy.media_extensions(kind) == [".mp3"]
        assert ContentPolicy.check(["x.mp3", "setup.exe"], kind) == :ok, "#{kind}"
        assert match?({:blocked, _}, ContentPolicy.check(["x.mkv", "setup.exe"], kind)), "#{kind}"

        assert match?({:blocked, _}, ContentPolicy.check(["x.epub", "setup.exe"], kind)),
               "#{kind}"
      end
    end

    test "rejects a kind it has no media set for" do
      # Built at run time: the compiler's type check reads `:music` as a kind the guard refuses
      # and warns, which fails `mix test`.
      kind = String.to_atom("music")
      assert_raise FunctionClauseError, fn -> ContentPolicy.check(["x.mkv"], kind) end
    end

    test "the detail is sanitized — the filename is remote and gets logged and persisted" do
      assert {:blocked, detail} =
               ContentPolicy.check(["ok.mkv\n2026-08-01 [error] forged log line.exe"], :video)

      refute detail =~ "\n"
      assert byte_size(detail) < 600
    end

    test "ignores a non-binary entry rather than raising" do
      assert :ok = ContentPolicy.check([nil, 42], :video)
      assert {:blocked, _} = ContentPolicy.check([nil, "bad.exe"], :video)
    end

    # `Cinder.Library.BookArchive`'s companion rule leans on this (#903).
    test "passes a normalised filler beside a .rar set or a .zip" do
      for kind <- @kinds,
          name <- ["RARBG_DO_NOT_MIRROR.exe.", "filler.exe ", "filler.exe:$DATA"] do
        assert ContentPolicy.check(["r.rar", "r.r00", name], kind) == :ok, "#{kind} #{name}"
        assert ContentPolicy.check(["r.zip", name], kind) == :ok, "#{kind} #{name}"
      end
    end
  end

  describe "media_extensions/1" do
    # #1448: the video half is read from the importers' own list, so the two cannot disagree.
    test "is exactly what the importers accept plus the archives for :video" do
      assert Enum.sort(ContentPolicy.media_extensions(:video)) ==
               Enum.sort(Library.video_extensions() ++ @archives)

      assert Enum.sort(Library.video_extensions()) == Enum.sort(@video_containers)
    end

    test "holds every accepted book format and the archives for :book" do
      media = ContentPolicy.media_extensions(:book)

      assert Enum.all?(accepted_book_formats(), &(".#{&1}" in media))
      assert ".rar" in media
      refute Enum.any?(@video_containers, &(&1 in media))
    end
  end

  # #903: the one name's half of `check/2`, which `Cinder.Library.BookArchive` reads.
  describe "blocked_name?/1" do
    test "is true for a blocked extension, plain or normalised" do
      for name <- [
            "x.exe",
            "x.exe.",
            "x.exe ",
            "x.exe:$DATA",
            "evil.lnk:Zone.Identifier",
            "Release/RARBG_DO_NOT_MIRROR.EXE."
          ] do
        assert ContentPolicy.blocked_name?(name), name
      end
    end

    test "is false for a colon-titled video and for a scene file" do
      for name <- ["[SubsPlease] Re:Zero - 01.mkv", "RARBG_DO_NOT_MIRROR.nfo", "x.txt:$DATA"] do
        refute ContentPolicy.blocked_name?(name), name
      end
    end

    # Both answers come from the one reading, so a lone name with no media reading is blocked
    # by `check/2` exactly when the predicate says so.
    test "agrees with check/2 on a lone name" do
      for kind <- @kinds,
          name <- [
            "evil.exe.",
            "evil.exe..",
            "evil.exe ",
            "evil.exe . ",
            "evil.exe:$DATA",
            "evil.lnk:Zone.Identifier",
            "x.exe:y.foo",
            "PAYLOAD.EXE",
            "RARBG_DO_NOT_MIRROR.nfo",
            "notes.txt",
            "x.txt:$DATA"
          ] do
        assert ContentPolicy.blocked_name?(name) ==
                 match?({:blocked, _}, ContentPolicy.check([name], kind)),
               "#{kind} #{name}"
      end
    end

    test "reads the configured blocked list" do
      put_config(ContentPolicy, blocked_extensions: [".APK"])

      assert ContentPolicy.blocked_name?("x.apk.")
      refute ContentPolicy.blocked_name?("x.exe.")
    end
  end

  # #913: the reader of `check/2`'s detail, which a held book's reason names the file from.
  describe "blocked_file/1" do
    test "reads back the file name check/2 put in its detail, sanitized" do
      for {list, kind, file} <- [
            {["Book/setup.exe"], :book, "setup.exe"},
            {["Movie.mkv.lnk", "readme.txt"], :video, "Movie.mkv.lnk"},
            {["a\r\nb.exe"], :book, "ab.exe"}
          ] do
        assert {:blocked, detail} = ContentPolicy.check(list, kind)
        assert ContentPolicy.blocked_file(detail) == {:ok, file}, inspect(list)
      end
    end

    test "reads a blank file name as empty, and any other shape as :error" do
      assert ContentPolicy.blocked_file("download contains ") == {:ok, ""}
      assert ContentPolicy.blocked_file("download contains  \t") == {:ok, ""}

      for detail <- ["", "download contains", "download containssetup.exe", "something else"] do
        assert ContentPolicy.blocked_file(detail) == :error, inspect(detail)
      end
    end
  end

  describe "vet/3 and vet_completed/4" do
    defmodule CleanClient do
      @moduledoc false
      def files(_id), do: {:ok, ["Movie.mkv"]}
    end

    defmodule FakeClient do
      @moduledoc false
      def files(_id), do: {:ok, ["Movie.mkv.lnk"]}
    end

    defmodule AudioClient do
      @moduledoc false
      def files(_id), do: {:ok, ["x.mp3", "setup.exe"]}
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
      assert :ok = ContentPolicy.vet(CleanClient, "id", :video)
      assert {:blocked, _} = ContentPolicy.vet(FakeClient, "id", :video)
    end

    test "judges the client's file list as the given kind" do
      assert {:blocked, _} = ContentPolicy.vet(AudioClient, "id", :video)
      assert :ok = ContentPolicy.vet(AudioClient, "id", :book)
    end

    test "a client failure is :ok — a check that could not run must not kill a download" do
      assert :ok = ContentPolicy.vet(BrokenClient, "id", :video)
    end

    test "does not even ask the client, or walk the disk, when disabled" do
      put_config(ContentPolicy, enabled: false)

      assert :ok = ContentPolicy.vet(ExplodingClient, "id", :video)
      # No filesystem stub: a walk would raise Mox.UnexpectedCallError.
      assert :ok = ContentPolicy.vet_completed(ExplodingClient, "id", "/dl/Movie", :video)
    end
  end

  defp accepted_book_formats, do: Enum.flat_map(BookKind.all(), &BookKind.accepted_formats/1)
end
