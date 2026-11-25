defmodule Cinder.Subtitles.OwnTrackTest do
  use ExUnit.Case, async: true

  alias Cinder.Subtitles.OwnTrack

  # The own track takes only an exact language match: a generic Chinese `chi` track may be
  # Mandarin, so it never replaces a Cantonese download (#573), while `yue` does.

  describe "wanted?/2" do
    test "looks at the tracks only when the import probe recorded an exact match" do
      assert OwnTrack.wanted?(%{embedded_subtitles: ["yue"]}, "cn")
      refute OwnTrack.wanted?(%{embedded_subtitles: ["chi"]}, "cn")
      refute OwnTrack.wanted?(%{embedded_subtitles: ["cmn"]}, "cn")
      assert OwnTrack.wanted?(%{embedded_subtitles: ["fre"]}, "fra")
      refute OwnTrack.wanted?(%{embedded_subtitles: nil}, "fra")
    end

    test "always looks at a fresh import's tracks" do
      assert OwnTrack.wanted?(%{fresh: true, embedded_subtitles: ["chi"]}, "cn")
    end
  end

  describe "select/2" do
    test "takes an exact track and passes a tolerated one over" do
      chi = track(2, "chi")
      yue = track(3, "yue")

      assert OwnTrack.select([chi], "cn") == nil
      assert OwnTrack.select([chi, yue], "cn") == yue
      assert OwnTrack.select([track(4, "cmn")], "cn") == nil
    end
  end

  # #1434: a track the base language of a wanted code with a subtag takes is only tolerated, which
  # the own track never takes: from the tracks it is given, `select/2` passes a `por` track over
  # for `pt-br` and takes a `pt-BR` one.
  describe "a wanted code with a subtag" do
    test "wanted?/2 outside a fresh import answers true only for an import code with the whole code" do
      assert OwnTrack.wanted?(%{embedded_subtitles: ["pt-BR"]}, "pt-br")
      refute OwnTrack.wanted?(%{embedded_subtitles: ["por"]}, "pt-br")
      refute OwnTrack.wanted?(%{embedded_subtitles: ["pt"]}, "pt-br")
      assert OwnTrack.wanted?(%{embedded_subtitles: ["zh-Hant"]}, "zh-hant")
      refute OwnTrack.wanted?(%{embedded_subtitles: ["zh"]}, "zh-hant")
      refute OwnTrack.wanted?(%{embedded_subtitles: ["chi"]}, "zh-hant")
    end

    test "select/2 takes a track with the whole code and passes the base language's over" do
      por = track(2, "por")
      pt_br = track(3, "pt-BR")

      assert OwnTrack.select([por], "pt-br") == nil
      assert OwnTrack.select([track(4, "pt")], "pt-br") == nil
      assert OwnTrack.select([por, pt_br], "pt-br") == pt_br
      assert OwnTrack.select([track(5, "zh")], "zh-hant") == nil
      assert OwnTrack.select([track(6, "zh-Hant")], "zh-hant") == track(6, "zh-Hant")
    end
  end

  defp track(index, language),
    do: %{index: index, language: language, forced?: false, packet_count: 500}
end
