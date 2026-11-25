defmodule Cinder.Subtitles.WantedLanguageTest do
  use ExUnit.Case, async: true

  alias Cinder.Acquisition.Language
  alias Cinder.Acquisition.Parser
  alias Cinder.Subtitles.WantedLanguage

  # The table every subtitle answer about a wanted language reads from (#1415). Its expected
  # values are what the merge base's code answered (e1554d50): `Language.exact_track?/2` and
  # `raw_track_satisfies?/2` for a track, and `Cinder.Subtitles`' private `in_language?/2` for a
  # sidecar name. The track rows of a wanted code with a subtag changed since (#1434). Each wanted
  # code lists the codes of `@tracks` and the names of `@names` it takes; it refuses the others
  # in those lists.

  @wanted ~w(fr fra fre french pt pt-br pt-pt pt_br zh zho chi zh-hant cn yue cantonese hi hin und eo)

  @tracks [
    nil
    | ~w(fr fre fra FRE French por pt pt-BR pt-PT pt_BR zh zh-Hant chi CHI zho cmn cn yue chinese und hin hi eo)
  ]

  @french_tracks ~w(fr fre fra FRE French)
  @generic_chinese ~w(chi CHI zho)

  # {wanted, exact tracks, tolerated tracks}
  @track_table [
    {"fr", @french_tracks, []},
    {"fra", @french_tracks, []},
    {"fre", @french_tracks, []},
    {"french", @french_tracks, []},
    {"pt", ~w(por pt), []},
    # #1434: a wanted code with a subtag takes a track with its whole code, separator included, as
    # exact, and a track its base language takes, exact or tolerated, as tolerated. A track with
    # another subtag stays refused, since the base refuses it too.
    {"pt-br", ~w(pt-BR), ~w(por pt)},
    {"pt-pt", ~w(pt-PT), ~w(por pt)},
    {"pt_br", ~w(pt_BR), ~w(por pt)},
    {"zh", ~w(zh cmn chinese), @generic_chinese},
    {"zho", ~w(zh cmn chinese), @generic_chinese},
    {"chi", ~w(zh cmn chinese), @generic_chinese},
    {"zh-hant", ~w(zh-Hant), ~w(zh cmn chinese) ++ @generic_chinese},
    # The generic Chinese codes are tolerated for Cantonese too, never Mandarin's `cmn` (#573).
    {"cn", ~w(cn yue), @generic_chinese},
    {"yue", ~w(cn yue), @generic_chinese},
    {"cantonese", ~w(cn yue), @generic_chinese},
    {"hi", ~w(hin hi), []},
    {"hin", ~w(hin hi), []},
    {"und", ~w(und), []},
    {"eo", ~w(eo), []}
  ]

  @names ~w(M.fr.srt M.fre.srt M.fr-FR.srt M.fr_FR.srt M.fr-CA.srt M.FR.srt M.fr.hi.srt
            M.fr.sdh.srt M.pt.srt M.pt-PT.srt M.pt-BR.srt M.pt-br.sdh.srt M.zh.srt M.chi.srt
            M.zho.srt M.chi-TW.srt M.zho_HK.srt M.cn.srt M.yue.srt M.cmn.srt M.chinese.srt
            M.hi.srt M.hin.srt M.srt M.und.srt M.eo.srt)

  @french_names ~w(M.fr.srt M.fre.srt M.fr-FR.srt M.fr_FR.srt M.fr-CA.srt M.FR.srt M.fr.hi.srt
                   M.fr.sdh.srt)
  @portuguese_names ~w(M.pt.srt M.pt-PT.srt M.pt-BR.srt M.pt-br.sdh.srt)
  @chinese_names ~w(M.zh.srt M.chi.srt M.zho.srt M.chi-TW.srt M.zho_HK.srt M.cmn.srt
                    M.chinese.srt)
  # #1343: a generic Chinese file reads as `zh`, yet a wanted Cantonese code takes it too.
  @cantonese_names ~w(M.chi.srt M.zho.srt M.chi-TW.srt M.zho_HK.srt M.cn.srt M.yue.srt)

  # {wanted, sidecar names it takes}
  @sidecar_table [
    {"fr", @french_names},
    {"fra", @french_names},
    {"fre", @french_names},
    {"french", @french_names},
    {"pt", @portuguese_names},
    # #1309: a sidecar name is matched on the wanted code's part before its subtag.
    {"pt-br", @portuguese_names},
    {"pt-pt", @portuguese_names},
    {"pt_br", @portuguese_names},
    {"zh", @chinese_names},
    {"zho", @chinese_names},
    {"chi", @chinese_names},
    {"zh-hant", @chinese_names},
    {"cn", @cantonese_names},
    {"yue", @cantonese_names},
    {"cantonese", @cantonese_names},
    # #201: a lone `hi` is Hindi, and `M.fr.hi.srt` is French for the hearing impaired.
    {"hi", ~w(M.hi.srt M.hin.srt)},
    {"hin", ~w(M.hi.srt M.hin.srt)},
    # A name with no language the registry knows reads as `und`, Esperanto included.
    {"und", ~w(M.srt M.und.srt M.eo.srt)},
    {"eo", []}
  ]

  test "the table covers every wanted code" do
    assert Enum.map(@track_table, &elem(&1, 0)) == @wanted
    assert Enum.map(@sidecar_table, &elem(&1, 0)) == @wanted
  end

  test "track/2 reads each track code as exact, tolerated or no match for each wanted code" do
    # Each cell is built whole before the filter: a bare `answer = ...` clause in `for` is itself a
    # filter, and would drop every `nil` answer unchecked.
    mismatches =
      for {wanted, exact, tolerated} <- @track_table,
          code <- @tracks,
          cell = {wanted, code, WantedLanguage.track(wanted, code)},
          cell != {wanted, code, expected_track(code, exact, tolerated)},
          do: cell

    assert mismatches == []
  end

  test "sidecar?/2 takes exactly the sidecar names each wanted code lists" do
    mismatches =
      for {wanted, taken} <- @sidecar_table,
          name <- @names,
          cell = {wanted, name, WantedLanguage.sidecar?(wanted, "/lib/M/" <> name)},
          cell != {wanted, name, name in taken},
          do: cell

    assert mismatches == []
  end

  test "name_language/1 maps filename tokens to iso codes; flags ignored; unknown -> und" do
    assert WantedLanguage.name_language("Movie (2020).en.srt") == "en"
    assert WantedLanguage.name_language("Movie (2020).eng.forced.srt") == "en"
    assert WantedLanguage.name_language("Movie (2020).fre.srt") == "fr"
    assert WantedLanguage.name_language("subs.srt") == "und"
    assert WantedLanguage.name_language("Movie (2020).forced.srt") == "und"
    assert WantedLanguage.name_language("The.Italian.Job.2003.srt") == "und"
    assert WantedLanguage.name_language("Movie (2020).sdh.srt") == "und"
  end

  # Issue #201: `hi` is ISO-639-1 Hindi as well as the hearing-impaired flag. Stripping it
  # unconditionally left `Movie.hi.srt` — the exact convention this module writes — unable to
  # express Hindi at all, and undetectable afterwards since the result was a plain "und".
  test "name_language/1 reads a lone hi as Hindi but keeps it a flag beside a real language" do
    assert WantedLanguage.name_language("Movie (2020).hi.srt") == "hi"
    assert WantedLanguage.name_language("Movie (2020).hin.srt") == "hi"
    assert WantedLanguage.name_language("Movie (2020).hi.forced.srt") == "hi"

    assert WantedLanguage.name_language("Movie (2020).fr.hi.srt") == "fr"
    assert WantedLanguage.name_language("Movie (2020).hi.fr.srt") == "fr"
  end

  # #1070: the subtitle fallback skips a forced sidecar and prefers an unflagged one, so a lone
  # `hi` read as Hindi must not come back as the hearing-impaired flag.
  test "name_flags/1 lists the flags name_language/1 stripped, with a lone hi read as Hindi" do
    assert WantedLanguage.name_flags("Movie (2020).en.srt") == []
    assert WantedLanguage.name_flags("Movie (2020).eng.forced.srt") == ["forced"]
    assert WantedLanguage.name_flags("Movie (2020).en.sdh.srt") == ["sdh"]
    assert WantedLanguage.name_flags("Movie (2020).en.cc.srt") == ["cc"]
    assert WantedLanguage.name_flags("Movie (2020).fr.hi.srt") == ["hi"]
    assert WantedLanguage.name_flags("Movie (2020).hi.srt") == []
    assert WantedLanguage.name_flags("Movie (2020).hi.forced.srt") == ["forced"]
    assert WantedLanguage.name_flags("Movie (2020).forced.srt") == ["forced"]
  end

  # #1087: a flag word counts only in the trailing run of flag and language tokens, so a title
  # word or a release tag (`CC` is the Criterion Collection's) is no flag.
  for {name, reading} <- [
        {"Forced.Entry.1983.1080p.BluRay.x264-GRP.fr.srt", {"fr", []}},
        {"Hi.Mom.2021.1080p.WEB-DL.fr.srt", {"fr", []}},
        {"Movie.1960.CC.1080p.BluRay.x264-GRP.en.srt", {"en", []}},
        {"Hi.Mom.2021.1080p.WEB-DL.fr.hi.srt", {"fr", ["hi"]}},
        {"Forced.Entry.1983.1080p.BluRay.x264-GRP.forced.srt", {"und", ["forced"]}},
        {"Movie (2020).hi.forced.srt", {"hi", ["forced"]}},
        {"Movie (2020).hi.fr.srt", {"fr", ["hi"]}},
        {"Movie (2020).fr.hi.srt", {"fr", ["hi"]}},
        {"Movie (2020).hi.srt", {"hi", []}},
        {"Movie (2020).eng.forced.srt", {"en", ["forced"]}},
        # A full language name belongs to the run as an ISO code does.
        {"Hi.Mom.2021.1080p.WEB-DL.hi.French.srt", {"fr", ["hi"]}},
        # The flags come in name order.
        {"Forced.Entry.1983.1080p.BluRay.x264-GRP.fr.sdh.forced.srt", {"fr", ["sdh", "forced"]}},
        # #201: a lone `hi` in the run is Hindi, and the title's `Hi` is no flag either.
        {"Hi.Mom.2021.1080p.WEB-DL.hi.srt", {"hi", []}}
      ] do
    test "name_language/1 and name_flags/1 read #{name} as #{inspect(reading)}" do
      assert reading(unquote(name)) == unquote(Macro.escape(reading))
    end
  end

  # #1087: the title's tokens never change the reading, so a scene-named sidecar reads as the
  # library-named one with the same tail. Each title ends in a token that is neither a flag nor a
  # language: a title word right before the tail is out of scope (`Show.S01E01.Hi.fr.srt`).
  test "a scene title's flag words never change the reading of the tail after it" do
    tail_tokens = ~w(fr fre French hi forced sdh cc)

    # Every tail of up to three of those tokens, repeats included: each step puts one token in
    # front of every tail of the step before.
    tails =
      [[]]
      |> Stream.iterate(fn shorter ->
        for token <- tail_tokens, tail <- shorter, do: [token | tail]
      end)
      |> Enum.take(4)
      |> Enum.concat()

    titles = [
      "Forced.Entry.1983.1080p.BluRay.x264-GRP",
      "Hi.Mom.2021.1080p.WEB-DL",
      "Movie.1960.CC.1080p.BluRay.x264-GRP",
      "Sdh.Forced.Cc.Hi.2020.x264-GRP"
    ]

    mismatches =
      for title <- titles,
          tail <- tails,
          name = Enum.join([title | tail] ++ ["srt"], "."),
          reference = Enum.join(["Movie (2020)" | tail] ++ ["srt"], "."),
          reading(name) != reading(reference),
          do: {name, reading(name), reading(reference)}

    assert mismatches == []
  end

  # #1309: a language with a region or script subtag reads as the base language's ISO 639-1 code,
  # so the fetch's copy takes it and the import names it as any other sidecar of that language.
  test "name_language/1 reads a language with a region or script subtag as the base language" do
    for {name, language} <- [
          {"M.fr-FR.srt", "fr"},
          {"M.fr_FR.srt", "fr"},
          {"M.fr-CA.srt", "fr"},
          {"M.pt-BR.srt", "pt"},
          {"M.pt-br.srt", "pt"},
          {"M.en-US.srt", "en"},
          {"M.es-419.srt", "es"},
          {"M.zh-Hant.srt", "zh"},
          # The base reads as a lone token does: a 639-2 code or a registry language name.
          {"M.fre-CA.srt", "fr"},
          {"M.French-CA.srt", "fr"},
          {"M.hi-IN.srt", "hi"}
        ] do
      assert {name, WantedLanguage.name_language(name)} == {name, language}
    end
  end

  test "name_language/1 reads a token that is no language with a subtag as und" do
    for name <- [
          "M.x264-GRP.srt",
          "M.WEB-DL.srt",
          "M.francais.srt",
          "M.VF.srt",
          # A base that reads as no language.
          "M.eo-FR.srt",
          "M.vf-FR.srt",
          # A subtag that is not 2 letters, 3 digits or 4 letters.
          "M.fr-F.srt",
          "M.fr-FRA.srt",
          "M.fr-Hants.srt",
          "M.fr-12.srt",
          "M.fr-1234.srt",
          "M.fr-F1.srt",
          "M.fr-.srt",
          "M.-FR.srt",
          # More than one subtag, or another separator.
          "M.zh-Hant-TW.srt",
          "M.fr--FR.srt",
          "M.fr-_FR.srt",
          "M.fr FR.srt"
        ] do
      assert {name, WantedLanguage.name_language(name)} == {name, "und"}
    end
  end

  # #1343: `Parser.audio_codes/0` lists the generic Chinese `chi` and `zho` under both `zh` and
  # Cantonese `cn`, and the module's own map kept `cn`, unlike `Language.normalize/1`.
  test "name_language/1 reads a generic Chinese code as zh, and Cantonese's own codes as cn" do
    for {name, language} <- [
          {"M.chi.srt", "zh"},
          {"M.zho.srt", "zh"},
          {"M.CHI.srt", "zh"},
          {"M.chi-TW.srt", "zh"},
          {"M.zho_HK.srt", "zh"},
          {"M.chi.forced.srt", "zh"},
          {"M.zh.srt", "zh"},
          {"M.cmn.srt", "zh"},
          {"M.chinese.srt", "zh"},
          {"M.yue.srt", "cn"},
          {"M.cn.srt", "cn"},
          {"M.cantonese.srt", "cn"}
        ] do
      assert {name, WantedLanguage.name_language(name)} == {name, language}
    end
  end

  test "name_language/1 reads every registry code and tag name as Language.normalize/1 does" do
    codes =
      Enum.uniq(
        Enum.flat_map(Parser.audio_codes(), fn {code, aliases} -> [code | aliases] end) ++
          Enum.map(Parser.language_tags(), fn {_code, tag} -> String.downcase(tag) end)
      )

    mismatches =
      for code <- codes,
          reading = WantedLanguage.name_language("M.#{code}.srt"),
          reading != Language.normalize(code),
          do: {code, reading, Language.normalize(code)}

    assert mismatches == []
  end

  # #1343: a generic Chinese code a name writes is tolerated for Cantonese, though the name reads
  # as `zh`; the code is taken without its subtag and its flags.
  test "sidecar?/2 lets wanted cn take the generic Chinese code a name writes, and nothing else" do
    for {name, taken?} <- [
          {"M.chi.srt", true},
          {"M.ZHO.srt", true},
          {"M.chi-TW.srt", true},
          {"M.zho_HK.forced.srt", true},
          {"M.fr-FR.srt", false},
          {"M.French.srt", false},
          {"M.hi.srt", false},
          {"M.fr.hi.srt", false},
          {"M.srt", false},
          {"M.eo.srt", false},
          {"M.forced.srt", false},
          {"M.x264-GRP.srt", false}
        ] do
      assert {name, WantedLanguage.sidecar?("cn", name)} == {name, taken?}
    end
  end

  for {name, reading} <- [
        {"M.pt-BR.sdh.srt", {"pt", ["sdh"]}},
        {"M.en-US.forced.srt", {"en", ["forced"]}},
        {"Forced.Entry.1983.1080p.BluRay.x264-GRP.fr-FR.forced.srt", {"fr", ["forced"]}},
        {"Hi.Mom.2021.1080p.WEB-DL.hi.fr-CA.srt", {"fr", ["hi"]}},
        {"M.hi-IN.srt", {"hi", []}}
      ] do
    test "name_language/1 and name_flags/1 read the regional #{name} as #{inspect(reading)}" do
      assert reading(unquote(name)) == unquote(Macro.escape(reading))
    end
  end

  # A fetched sidecar carries the wanted code as typed, a placed release sidecar the language its
  # name reads as, with its flags in name order (#1309, #1343). #1391 kept the generic Chinese
  # `chi` placed as `zh`.
  test "sidecar_path/2 names a fetched sidecar by the wanted code as typed" do
    for {wanted, path} <- [
          {"fra", "/lib/M/M.fra.srt"},
          {"pt-br", "/lib/M/M.pt-br.srt"},
          {"cn", "/lib/M/M.cn.srt"},
          {"und", "/lib/M/M.und.srt"}
        ] do
      assert {wanted, WantedLanguage.sidecar_path("/lib/M/M.mkv", wanted)} == {wanted, path}
    end
  end

  test "placed_path/2 names a release sidecar by the language its name reads as" do
    for {name, path} <- [
          {"Rel.fre.srt", "/lib/M/M.fr.srt"},
          {"Rel.fr-FR.srt", "/lib/M/M.fr.srt"},
          {"Rel.chi.srt", "/lib/M/M.zh.srt"},
          {"Rel.zho_HK.srt", "/lib/M/M.zh.srt"},
          {"Rel.yue.srt", "/lib/M/M.cn.srt"},
          {"Rel.pt-BR.SDH.srt", "/lib/M/M.pt.sdh.srt"},
          {"Rel.fr.hi.srt", "/lib/M/M.fr.hi.srt"},
          {"Rel.hi.srt", "/lib/M/M.hi.srt"},
          {"Rel.hi.forced.ASS", "/lib/M/M.hi.forced.ass"},
          {"Rel.fr.sdh.forced.srt", "/lib/M/M.fr.sdh.forced.srt"},
          {"Rel.srt", "/lib/M/M.und.srt"},
          {"Rel.eo.srt", "/lib/M/M.und.srt"}
        ] do
      assert {name, WantedLanguage.placed_path("/dl/Rel/" <> name, "/lib/M/M.mkv")} ==
               {name, path}
    end
  end

  # #1416: the rank `Sidecars.link_listed/2` keeps one of two sidecars that take one placed name by.
  test "name_rank/1 ranks the placed code, then another code or name, then a subtag" do
    for {name, rank} <- [
          {"Rel.zh.srt", 1},
          {"Rel.ZH.srt", 1},
          {"Rel.cn.srt", 1},
          {"Rel.yue.srt", 2},
          {"Rel.fr.forced.srt", 1},
          {"Rel.hi.srt", 1},
          {"Rel.fr.hi.srt", 1},
          {"Rel.chi.srt", 2},
          {"Rel.zho.srt", 2},
          {"Rel.fre.srt", 2},
          {"Rel.french.srt", 2},
          {"Rel.eng.forced.srt", 2},
          {"Rel.zh-Hans.srt", 3},
          {"Rel.fr-FR.srt", 3},
          {"Rel.pt_BR.sdh.srt", 3},
          {"Rel.chi-TW.srt", 3},
          {"Rel.srt", 1},
          {"Rel.foo.srt", 1},
          {"Rel.eo.srt", 1}
        ] do
      assert {name, WantedLanguage.name_rank("/dl/Rel/" <> name)} == {name, rank}
    end
  end

  defp expected_track(code, exact, tolerated) do
    cond do
      code in exact -> :exact
      code in tolerated -> :tolerated
      true -> nil
    end
  end

  defp reading(name), do: {WantedLanguage.name_language(name), WantedLanguage.name_flags(name)}
end
