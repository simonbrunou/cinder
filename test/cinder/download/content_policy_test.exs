defmodule Cinder.Download.ContentPolicyTest do
  # async: false — the disabled-path test flips the module's global Application env, which every
  # in-flight poller tick reads.
  use ExUnit.Case, async: false

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

    test "ignores a non-binary entry rather than raising" do
      assert :ok = ContentPolicy.check([nil, 42])
      assert {:blocked, _} = ContentPolicy.check([nil, "bad.exe"])
    end
  end

  describe "vet/2" do
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

    test "does not even ask the client when disabled" do
      Application.put_env(:cinder, ContentPolicy, enabled: false)
      on_exit(fn -> Application.put_env(:cinder, ContentPolicy, enabled: true) end)

      assert :ok = ContentPolicy.vet(ExplodingClient, "id")
    end
  end
end
