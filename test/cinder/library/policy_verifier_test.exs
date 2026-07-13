defmodule Cinder.Library.PolicyVerifierTest do
  use ExUnit.Case, async: true

  import Mox

  alias Cinder.Library.PolicyVerifier

  setup :verify_on_exit!

  test "every required audio language and one desired embedded subtitle pass" do
    report = policy_report(audio: ["ja", "fra"], subtitles: ["eng"])

    expect(Cinder.Library.MediaInfoMock, :probe_policy, fn "/downloads/a.mkv" ->
      {:ok, report}
    end)

    assert {:ok, reports} =
             PolicyVerifier.verify_sources(
               ["/downloads/a.mkv"],
               policy_snapshot(["ja", "fr"], ["fr", "en"]),
               Cinder.Library.MediaInfoMock
             )

    assert reports["/downloads/a.mkv"] == report
  end

  test "known missing audio is a confirmed mismatch" do
    assert {:mismatch, %{source: "a.mkv", missing_audio: ["fr"]}} =
             verify(policy_report(audio: ["ja"], subtitles: ["fr"]))
  end

  test "known missing embedded subtitles are a confirmed mismatch" do
    assert {:mismatch, %{source: "a.mkv", missing_embedded_subtitles: ["fr"]}} =
             verify(policy_report(audio: ["ja", "fr"], subtitles: []))
  end

  test "probe failure or unknown evidence that could satisfy a missing language is unavailable" do
    assert {:unavailable, :media_info_not_configured} =
             PolicyVerifier.verify_sources(["a.mkv"], policy_snapshot(), nil)

    expect(Cinder.Library.MediaInfoMock, :probe_policy, fn "a.mkv" -> {:error, :timeout} end)

    assert {:unavailable, {:probe_failed, "a.mkv", :timeout}} =
             PolicyVerifier.verify_sources(
               ["a.mkv"],
               policy_snapshot(),
               Cinder.Library.MediaInfoMock
             )

    assert {:unavailable, {:unprobeable_audio, "a.mkv"}} =
             verify(policy_report(audio: ["ja"], subtitles: ["fr"], audio_unknown?: true))

    assert {:unavailable, {:unprobeable_subtitles, "a.mkv"}} =
             verify(
               policy_report(
                 audio: ["ja", "fr"],
                 subtitles: [],
                 subtitle_unknown?: true
               )
             )
  end

  test "deduplicates a shared story source and probes it once" do
    report = policy_report(audio: ["ja", "fr"], subtitles: ["fr"])

    expect(Cinder.Library.MediaInfoMock, :probe_policy, fn "/downloads/shared.mkv" ->
      {:ok, report}
    end)

    assert {:ok, %{}} =
             PolicyVerifier.verify_sources([], policy_snapshot(), Cinder.Library.MediaInfoMock)

    assert {:ok, %{"/downloads/shared.mkv" => ^report}} =
             PolicyVerifier.verify_sources(
               ["/downloads/shared.mkv", "/downloads/shared.mkv"],
               policy_snapshot(),
               Cinder.Library.MediaInfoMock
             )
  end

  test "a second failing story source rejects the whole set" do
    expect(Cinder.Library.MediaInfoMock, :probe_policy, 2, fn
      "/downloads/a.mkv" ->
        {:ok, policy_report(audio: ["ja", "fr"], subtitles: ["fr"])}

      "/downloads/b.mkv" ->
        {:ok, policy_report(audio: ["ja"], subtitles: ["fr"])}
    end)

    assert {:mismatch, %{source: "b.mkv", missing_audio: ["fr"]}} =
             PolicyVerifier.verify_sources(
               ["/downloads/a.mkv", "/downloads/b.mkv"],
               policy_snapshot(),
               Cinder.Library.MediaInfoMock
             )
  end

  test "nil or soft-only snapshots need no probe" do
    assert {:ok, %{}} =
             PolicyVerifier.verify_sources(["a.mkv"], nil, Cinder.Library.MediaInfoMock)

    assert {:ok, %{}} =
             PolicyVerifier.verify_sources(
               ["a.mkv"],
               policy_snapshot([], []),
               Cinder.Library.MediaInfoMock
             )
  end

  defp verify(report) do
    expect(Cinder.Library.MediaInfoMock, :probe_policy, fn "a.mkv" -> {:ok, report} end)
    PolicyVerifier.verify_sources(["a.mkv"], policy_snapshot(), Cinder.Library.MediaInfoMock)
  end

  defp policy_snapshot(audio \\ ["ja", "fr"], subtitles \\ ["fr"]) do
    %{
      "version" => 1,
      "required_audio_languages" => audio,
      "required_embedded_subtitle_languages" => subtitles,
      "release_group" => "subsplease",
      "release_title" => "Anime.Release"
    }
  end

  defp policy_report(overrides) do
    Map.merge(
      %{audio: [], subtitles: [], audio_unknown?: false, subtitle_unknown?: false},
      Map.new(overrides)
    )
  end
end
