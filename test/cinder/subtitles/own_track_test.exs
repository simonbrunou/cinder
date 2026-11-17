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

  defp track(index, language),
    do: %{index: index, language: language, forced?: false, packet_count: 500}
end
