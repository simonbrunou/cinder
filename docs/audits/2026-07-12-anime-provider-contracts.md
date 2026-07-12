# Anime provider contract report

Corpus version: `1`

## Official references

- [TMDB API](https://developer.themoviedb.org/reference/intro/getting-started)
- [TVDB API](https://github.com/thetvdb/v4-api)
- [AniDB HTTP API](https://wiki.anidb.net/HTTP_API_Definition)
- [Prowlarr](https://github.com/Prowlarr/Prowlarr)

## Must-support title checks

| Title | Check | Family | Status | Evidence |
| --- | --- | --- | --- | --- |
| attack-on-titan | absolute-entries | episode_order | pass | %{required: 0, observed: 97} |
| attack-on-titan | discovery-hits | discovery | pass | %{required: 3, observed: 3} |
| attack-on-titan | discovery:Attack on Titan | discovery | pass | %{expected_tmdb_id: 1429, observed_tmdb_ids: [1429, 63510, 65242, 224499]} |
| attack-on-titan | discovery:Shingeki no Kyojin | discovery | pass | %{expected_tmdb_id: 1429, observed_tmdb_ids: [1429]} |
| attack-on-titan | discovery:進撃の巨人 | discovery | pass | %{expected_tmdb_id: 1429, observed_tmdb_ids: [1429, 65242, 224499, 313024, 313028]} |
| attack-on-titan | group-integrity | episode_order | pass | %{automatic_wrong_mappings: 0} |
| attack-on-titan | prowlarr-results:Attack on Titan:all | prowlarr_inventory | recorded | %{count: 50} |
| attack-on-titan | prowlarr-results:Attack on Titan:anime | prowlarr_inventory | recorded | %{count: 50} |
| attack-on-titan | prowlarr-results:Shingeki no Kyojin:all | prowlarr_inventory | recorded | %{count: 50} |
| attack-on-titan | prowlarr-results:Shingeki no Kyojin:anime | prowlarr_inventory | recorded | %{count: 50} |
| attack-on-titan | specials | episode_order | pass | %{required: true, observed: true} |
| bleach | absolute-entries | episode_order | pass | %{required: 366, observed: 419} |
| bleach | discovery-hits | discovery | pass | %{required: 3, observed: 3} |
| bleach | discovery:BLEACH | discovery | pass | %{expected_tmdb_id: 30984, observed_tmdb_ids: [30984, 248063, 300070, 328279]} |
| bleach | discovery:Bleach | discovery | pass | %{expected_tmdb_id: 30984, observed_tmdb_ids: [30984, 248063, 300070, 328279]} |
| bleach | discovery:ブリーチ | discovery | pass | %{expected_tmdb_id: 30984, observed_tmdb_ids: [30984]} |
| bleach | group-integrity | episode_order | pass | %{automatic_wrong_mappings: 0} |
| bleach | group-type:2 | episode_order | pass | %{required: 2, observed: [2]} |
| bleach | prowlarr-results:Bleach 366:all | prowlarr_inventory | recorded | %{count: 50} |
| bleach | prowlarr-results:Bleach 366:anime | prowlarr_inventory | recorded | %{count: 50} |
| bleach | prowlarr-results:Bleach:all | prowlarr_inventory | recorded | %{count: 50} |
| bleach | prowlarr-results:Bleach:anime | prowlarr_inventory | recorded | %{count: 50} |
| bleach | specials | episode_order | pass | %{required: true, observed: true} |
| demon-slayer | absolute-entries | episode_order | pass | %{required: 0, observed: 63} |
| demon-slayer | discovery-hits | discovery | pass | %{required: 3, observed: 3} |
| demon-slayer | discovery:Demon Slayer: Kimetsu no Yaiba | discovery | pass | %{expected_tmdb_id: 85937, observed_tmdb_ids: [85937]} |
| demon-slayer | discovery:Kimetsu no Yaiba | discovery | pass | %{expected_tmdb_id: 85937, observed_tmdb_ids: [85937]} |
| demon-slayer | discovery:鬼滅の刃 | discovery | pass | %{expected_tmdb_id: 85937, observed_tmdb_ids: [85937]} |
| demon-slayer | group-integrity | episode_order | pass | %{automatic_wrong_mappings: 0} |
| demon-slayer | prowlarr-results:Demon Slayer:all | prowlarr_inventory | recorded | %{count: 50} |
| demon-slayer | prowlarr-results:Demon Slayer:anime | prowlarr_inventory | recorded | %{count: 50} |
| demon-slayer | prowlarr-results:Kimetsu no Yaiba:all | prowlarr_inventory | recorded | %{count: 50} |
| demon-slayer | prowlarr-results:Kimetsu no Yaiba:anime | prowlarr_inventory | recorded | %{count: 50} |
| demon-slayer | specials | episode_order | pass | %{required: false, observed: true} |
| one-piece | absolute-entries | episode_order | pass | %{required: 1000, observed: 1208} |
| one-piece | discovery-hits | discovery | pass | %{required: 3, observed: 3} |
| one-piece | discovery:ONE PIECE | discovery | pass | %{expected_tmdb_id: 37854, observed_tmdb_ids: [251, 37534, 37854, 99112, 111110, 241709, 243471, 287202, 316804, 318421, 318918, 326805]} |
| one-piece | discovery:One Piece | discovery | pass | %{expected_tmdb_id: 37854, observed_tmdb_ids: [251, 37534, 37854, 99112, 111110, 241709, 243471, 287202, 316804, 318421, 318918, 326805]} |
| one-piece | discovery:ワンピース | discovery | pass | %{expected_tmdb_id: 37854, observed_tmdb_ids: [37854, 111507, 243471, 287202]} |
| one-piece | group-integrity | episode_order | pass | %{automatic_wrong_mappings: 0} |
| one-piece | group-type:2 | episode_order | pass | %{required: 2, observed: [2]} |
| one-piece | prowlarr-results:One Piece 1122:all | prowlarr_inventory | recorded | %{count: 50} |
| one-piece | prowlarr-results:One Piece 1122:anime | prowlarr_inventory | recorded | %{count: 50} |
| one-piece | prowlarr-results:One Piece:all | prowlarr_inventory | recorded | %{count: 50} |
| one-piece | prowlarr-results:One Piece:anime | prowlarr_inventory | recorded | %{count: 50} |
| one-piece | specials | episode_order | pass | %{required: true, observed: true} |
| pokemon | absolute-entries | episode_order | pass | %{required: 0, observed: 1240} |
| pokemon | discovery-hits | discovery | pass | %{required: 3, observed: 3} |
| pokemon | discovery:Pokemon | discovery | pass | %{expected_tmdb_id: 60572, observed_tmdb_ids: [13230, 60572, 61295, 67882, 80652, 94760, 96420, 107538, 132636, 196267, 199966, 207567, 220150, 221301, 232214, 232215, 260604, 301959, 327350, 327899]} |
| pokemon | discovery:Pokémon | discovery | pass | %{expected_tmdb_id: 60572, observed_tmdb_ids: [13230, 60572, 61295, 67882, 94760, 96420, 107538, 132636, 199966, 207567, 220150, 221301, 232214, 232215, 260604, 301959, 327350, 327351, 327354, 327899]} |
| pokemon | discovery:ポケットモンスター | discovery | pass | %{expected_tmdb_id: 60572, observed_tmdb_ids: [13230, 60572, 61295, 96420, 207567, 220150, 327775]} |
| pokemon | group-integrity | episode_order | pass | %{automatic_wrong_mappings: 0} |
| pokemon | prowlarr-results:Pocket Monsters:all | prowlarr_inventory | recorded | %{count: 50} |
| pokemon | prowlarr-results:Pocket Monsters:anime | prowlarr_inventory | recorded | %{count: 50} |
| pokemon | prowlarr-results:Pokemon:all | prowlarr_inventory | recorded | %{count: 50} |
| pokemon | prowlarr-results:Pokemon:anime | prowlarr_inventory | recorded | %{count: 50} |
| pokemon | specials | episode_order | pass | %{required: true, observed: true} |
| re-zero | absolute-entries | episode_order | pass | %{required: 0, observed: 138} |
| re-zero | discovery-hits | discovery | pass | %{required: 3, observed: 3} |
| re-zero | discovery:Re Zero | discovery | pass | %{expected_tmdb_id: 65942, observed_tmdb_ids: [65942, 328061, 328062]} |
| re-zero | discovery:Re:ZERO -Starting Life in Another World- | discovery | pass | %{expected_tmdb_id: 65942, observed_tmdb_ids: [65942, 328061, 328062]} |
| re-zero | discovery:Re:ゼロから始める異世界生活 | discovery | pass | %{expected_tmdb_id: 65942, observed_tmdb_ids: [65942, 328061, 328062]} |
| re-zero | group-integrity | episode_order | pass | %{automatic_wrong_mappings: 0} |
| re-zero | prowlarr-results:Re Zero Season 2:all | prowlarr_inventory | recorded | %{count: 50} |
| re-zero | prowlarr-results:Re Zero Season 2:anime | prowlarr_inventory | recorded | %{count: 50} |
| re-zero | prowlarr-results:Re Zero:all | prowlarr_inventory | recorded | %{count: 50} |
| re-zero | prowlarr-results:Re Zero:anime | prowlarr_inventory | recorded | %{count: 50} |
| re-zero | specials | episode_order | pass | %{required: true, observed: true} |
| your-name | absolute-entries | episode_order | pass | %{required: 0, observed: 0} |
| your-name | discovery-hits | discovery | pass | %{required: 3, observed: 3} |
| your-name | discovery:Kimi no Na wa. | discovery | pass | %{expected_tmdb_id: 372058, observed_tmdb_ids: [294293, 372058, 382520, 382526, 553301, 627611]} |
| your-name | discovery:Your Name. | discovery | pass | %{expected_tmdb_id: 372058, observed_tmdb_ids: [104184, 105326, 135252, 294716, 372058, 398818, 412258, 515330, 553301, 591796, 657763, 719410, 751429, 917237, 976991, 1032919, 1146526, 1366143, 1399134, 1446533]} |
| your-name | discovery:君の名は。 | discovery | pass | %{expected_tmdb_id: 372058, observed_tmdb_ids: [294293, 372058, 382520, 382526, 627611, 1724810]} |
| your-name | group-integrity | episode_order | pass | %{automatic_wrong_mappings: 0} |
| your-name | prowlarr-results:Kimi no Na wa:all | prowlarr_inventory | recorded | %{count: 50} |
| your-name | prowlarr-results:Kimi no Na wa:anime | prowlarr_inventory | recorded | %{count: 50} |
| your-name | prowlarr-results:Your Name 2016:all | prowlarr_inventory | recorded | %{count: 50} |
| your-name | prowlarr-results:Your Name 2016:anime | prowlarr_inventory | recorded | %{count: 50} |
| your-name | specials | episode_order | pass | %{required: false, observed: false} |

## Prowlarr field coverage

| Check | Status | Evidence |
| --- | --- | --- |
| prowlarr-anime-category-sample | pass | %{observed: 700} |
| prowlarr-categories | pass | %{complete: 1400, sampled: 1400} |
| prowlarr-published-at | pass | %{complete: 1400, sampled: 1400} |
| prowlarr-sample | pass | %{observed: 1400} |

## Sanitized release-title appendix

| Title | Query | Mode | Release | Size | Protocol | Categories | Published at |
| --- | --- | --- | --- | ---: | --- | --- | --- |
| attack-on-titan | Attack on Titan | all | Attack.On.Titan.S04E29.Retail.ENGsubs.1080p.WEB-DL.H.264.AAC2.0-ADDICTION | 1901158907 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-05-20T08:51:50Z |
| attack-on-titan | Attack on Titan | all | Attack.On.Titan.S04E30.Retail.ENGsubs.1080p.WEB-DL.H.264.AAC2.0-ADDICTION | 3096945978 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-05-20T08:52:31Z |
| attack-on-titan | Attack on Titan | all | Attack.on.Titan.S01E01.To.You.in.2.000.Years.The.Fall.of.Shiganshina.1.1080p.FLAC.2.0.AVC.REMUX-FraMeSToR | 7436598259 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-05-11T12:25:09Z |
| attack-on-titan | Attack on Titan | all | Attack.on.Titan.S01E02.That.Day.The.Fall.of.Shiganshina.2.1080p.FLAC.2.0.AVC.REMUX-FraMeSToR | 7018999542 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-05-11T12:27:28Z |
| attack-on-titan | Attack on Titan | all | Attack.on.Titan.S01E03.A.Dim.Light.Amid.Despair.Humanity's.Comeback.1.1080p.FLAC.2.0.AVC.REMUX-FraMeSToR | 7154650646 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-05-11T12:23:38Z |
| attack-on-titan | Attack on Titan | all | Attack.on.Titan.S01E04.The.Night.of.the.Closing.Ceremony.Humanity's.Comeback.2.1080p.FLAC.2.0.AVC.REMUX-FraMeSToR | 7075815669 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-05-11T12:20:12Z |
| attack-on-titan | Attack on Titan | all | Attack.on.Titan.S01E05.First.Battle.The.Struggle.for.Trost.1.1080p.FLAC.2.0.AVC.REMUX-FraMeSToR | 7051378981 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-05-11T12:20:50Z |
| attack-on-titan | Attack on Titan | all | Attack.on.Titan.S01E07.Small.Blade.The.Struggle.for.Trost.3.1080p.FLAC.2.0.AVC.REMUX-FraMeSToR | 7010216833 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-05-11T12:17:45Z |
| attack-on-titan | Attack on Titan | all | Attack.on.Titan.S01E09.Whereabouts.of.His.Left.Arm.The.Struggle.for.Trost.5.1080p.FLAC.2.0.AVC.REMUX-FraMeSToR | 8107121095 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-05-11T12:17:01Z |
| attack-on-titan | Attack on Titan | all | Attack.on.Titan.S01E13.Primal.Desire.The.Struggle.for.Trost.9.1080p.FLAC.2.0.AVC.REMUX-FraMeSToR | 8275342298 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-05-11T12:16:01Z |
| attack-on-titan | Attack on Titan | all | Attack.on.Titan.S01E14.Can't.Look.into.His.Eyes.Yet.Eve.of.the.Counterattack.1.1080p.FLAC.2.0.AVC.REMUX-FraMeSToR | 8090331994 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-05-11T12:26:45Z |
| attack-on-titan | Attack on Titan | all | Attack.on.Titan.S01E15.Special.Operations.Squad.Eve.of.the.Counterattack.2.1080p.FLAC.2.0.AVC.REMUX-FraMeSToR | 7960799027 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-05-11T12:18:48Z |
| attack-on-titan | Attack on Titan | all | Attack.on.Titan.S01E18.Forest.of.Giant.Trees.The.57th.Exterior.Scouting.Mission.2.1080p.FLAC.2.0.AVC.REMUX-FraMeSToR | 8182412983 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-05-11T12:14:57Z |
| attack-on-titan | Attack on Titan | all | Attack.on.Titan.S01E19.Bite.The.57th.Exterior.Scouting.Mission.3.1080p.FLAC.2.0.AVC.REMUX-FraMeSToR | 8153984237 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-05-11T12:24:19Z |
| attack-on-titan | Attack on Titan | all | Attack.on.Titan.S01E20.Erwin.Smith.The.57th.Exterior.Scouting.Mission.4.1080p.FLAC.2.0.AVC.REMUX-FraMeSToR | 8168619105 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-05-11T12:13:55Z |
| attack-on-titan | Attack on Titan | all | Attack.on.Titan.S01E23.Smile.Assault.on.Stohess.1.1080p.FLAC.2.0.AVC.REMUX-FraMeSToR | 8075684262 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-05-11T12:19:25Z |
| attack-on-titan | Attack on Titan | all | Attack.on.Titan.S01E24.Mercy.Assault.on.Stohess.2.1080p.FLAC.2.0.AVC.REMUX-FraMeSToR | 8186570201 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-05-11T12:22:44Z |
| attack-on-titan | Attack on Titan | all | Attack.on.Titan.S01E25.Wall.Assault.on.Stohess.3.1080p.FLAC.2.0.AVC.REMUX-FraMeSToR | 8185254605 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-05-11T12:25:53Z |
| attack-on-titan | Attack on Titan | all | Attack.on.Titan.S04E01.The.Other.Side.of.the.Sea.PROPER.1080p.FLAC.2.0.AVC.REMUX-FraMeSToR | 7443581312 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-05-14T04:18:36Z |
| attack-on-titan | Attack on Titan | all | Attack.on.Titan.S04E02.Midnight.Train.PROPER.1080p.FLAC.2.0.AVC.REMUX-FraMeSToR | 7401266531 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-05-14T04:19:56Z |
| attack-on-titan | Attack on Titan | all | Attack.on.Titan.S04E03.The.Door.of.Hope.PROPER.1080p.FLAC.2.0.AVC.REMUX-FraMeSToR | 7416455916 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-05-14T04:22:11Z |
| attack-on-titan | Attack on Titan | all | Attack.on.Titan.S04E04.From.One.Hand.to.Another.PROPER.1080p.FLAC.2.0.AVC.REMUX-FraMeSToR | 7404176143 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-05-14T04:13:51Z |
| attack-on-titan | Attack on Titan | all | Attack.on.Titan.S04E05.Declaration.of.War.PROPER.1080p.FLAC.2.0.AVC.REMUX-FraMeSToR | 7424228669 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-05-14T04:16:26Z |
| attack-on-titan | Attack on Titan | all | Attack.on.Titan.S04E06.The.War.Hammer.Titan.PROPER.1080p.FLAC.2.0.AVC.REMUX-FraMeSToR | 7455339920 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-05-14T04:21:11Z |
| attack-on-titan | Attack on Titan | all | Attack.on.Titan.S04E07.Assault.PROPER.1080p.FLAC.2.0.AVC.REMUX-FraMeSToR | 7483029223 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-05-14T04:24:03Z |
| attack-on-titan | Attack on Titan | all | Attack.on.Titan.S04E08.Assassin's.Bullet.PROPER.1080p.FLAC.2.0.AVC.REMUX-FraMeSToR | 7400826577 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-05-14T04:12:52Z |
| attack-on-titan | Attack on Titan | all | Attack.on.Titan.S04E09.Brave.Volunteers.PROPER.1080p.FLAC.2.0.AVC.REMUX-FraMeSToR | 7421609182 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-05-14T04:27:01Z |
| attack-on-titan | Attack on Titan | all | Attack.on.Titan.S04E10.A.Sound.Argument.PROPER.1080p.FLAC.2.0.AVC.REMUX-FraMeSToR | 7367159227 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-05-14T04:24:37Z |
| attack-on-titan | Attack on Titan | all | Attack.on.Titan.S04E11.Deceiver.PROPER.1080p.FLAC.2.0.AVC.REMUX-FraMeSToR | 7375350272 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-05-14T04:26:01Z |
| attack-on-titan | Attack on Titan | all | Attack.on.Titan.S04E12.Guides.PROPER.1080p.FLAC.2.0.AVC.REMUX-FraMeSToR | 7389337477 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-05-14T04:20:27Z |
| attack-on-titan | Attack on Titan | all | Attack.on.Titan.S04E13.Children.of.the.Forest.PROPER.1080p.FLAC.2.0.AVC.REMUX-FraMeSToR | 7419781406 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-05-14T04:17:31Z |
| attack-on-titan | Attack on Titan | all | Attack.on.Titan.S04E14.Savagery.PROPER.1080p.FLAC.2.0.AVC.REMUX-FraMeSToR | 7425623788 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-05-14T04:10:14Z |
| attack-on-titan | Attack on Titan | all | Attack.on.Titan.S04E15.Sole.Salvation.PROPER.1080p.FLAC.2.0.AVC.REMUX-FraMeSToR | 7333863750 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-05-14T04:18:03Z |
| attack-on-titan | Attack on Titan | all | Attack.on.Titan.S04E16.Above.and.Below.PROPER.1080p.FLAC.2.0.AVC.REMUX-FraMeSToR | 7328165858 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-05-14T04:23:27Z |
| attack-on-titan | Attack on Titan | all | Attack.on.Titan.S04E17.Judgment.PROPER.1080p.FLAC.2.0.AVC.REMUX-FraMeSToR | 7457414250 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-05-14T04:10:48Z |
| attack-on-titan | Attack on Titan | all | Attack.on.Titan.S04E18.Sneak.Attack.PROPER.1080p.FLAC.2.0.AVC.REMUX-FraMeSToR | 7406874485 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-05-14T04:25:14Z |
| attack-on-titan | Attack on Titan | all | Attack.on.Titan.S04E19.Two.Brothers.PROPER.1080p.FLAC.2.0.AVC.REMUX-FraMeSToR | 7421528780 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-05-14T04:19:09Z |
| attack-on-titan | Attack on Titan | all | Attack.on.Titan.S04E20.Memories.of.the.Future.PROPER.1080p.FLAC.2.0.AVC.REMUX-FraMeSToR | 7356055786 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-05-14T04:11:44Z |
| attack-on-titan | Attack on Titan | all | Attack.on.Titan.S04E21.From.You.2.000.Years.Ago.PROPER.1080p.FLAC.2.0.AVC.REMUX-FraMeSToR | 7403773791 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-05-14T04:22:44Z |
| attack-on-titan | Attack on Titan | all | Attack.on.Titan.S04E22.Thaw.PROPER.1080p.FLAC.2.0.AVC.REMUX-FraMeSToR | 7432649798 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-05-14T04:12:23Z |
| attack-on-titan | Attack on Titan | all | Attack.on.Titan.S04E23.Sunset.PROPER.1080p.FLAC.2.0.AVC.REMUX-FraMeSToR | 7390506462 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-05-14T04:30:43Z |
| attack-on-titan | Attack on Titan | all | Attack.on.Titan.S04E24.Pride.PROPER.1080p.FLAC.2.0.AVC.REMUX-FraMeSToR | 7388969483 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-05-14T04:27:58Z |
| attack-on-titan | Attack on Titan | all | Attack.on.Titan.S04E25.Night.of.the.End.PROPER.1080p.FLAC.2.0.AVC.REMUX-FraMeSToR | 7398821462 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-05-14T04:15:51Z |
| attack-on-titan | Attack on Titan | all | Attack.on.Titan.S04E26.Traitor.PROPER.1080p.FLAC.2.0.AVC.REMUX-FraMeSToR | 7410578578 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-05-14T04:11:16Z |
| attack-on-titan | Attack on Titan | all | Attack.on.Titan.S04E27.Retrospective.PROPER.1080p.FLAC.2.0.AVC.REMUX-FraMeSToR | 7469757320 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-05-14T04:13:20Z |
| attack-on-titan | Attack on Titan | all | Attack.on.Titan.S04E28.The.Dawn.of.Humanity.PROPER.1080p.FLAC.2.0.AVC.REMUX-FraMeSToR | 7348693093 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-05-14T04:16:52Z |
| attack-on-titan | Attack on Titan | all | Attack.on.Titan.S04E29.The.Final.Chapters.Special.1.PROPER.1080p.FLAC.2.0.AVC.REMUX-FraMeSToR | 20096486440 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-05-14T04:15:18Z |
| attack-on-titan | Attack on Titan | all | Attack.on.Titan.S04E30.The.Final.Chapters.Special.2.PROPER.1080p.FLAC.2.0.AVC.REMUX-FraMeSToR | 27951903377 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-05-14T04:30:10Z |
| attack-on-titan | Attack on Titan | all | [Anime Time] Attack on Titan Movie 05 - The Last Attack | 4621472354 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-18T14:28:53Z |
| attack-on-titan | Attack on Titan | all | [Baws] Attack on Titan - S04E29 v3 - The Final Chapters (Part 1) (WEB 1080p Hi10 EAC3 AAC) [7E6E0C64] | 1481378970 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-05T15:24:55Z |
| attack-on-titan | Attack on Titan | anime | Attack on Titan (2013) - S04E29 The Final Chapters Special 1 [Bluray-1080p][10bit][x265][Opus 2.0][JA+EN]-ZeroBuild | 7725586765 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-03-18T18:24:09Z |
| attack-on-titan | Attack on Titan | anime | Attack on Titan (2013) - S04E30 The Final Chapters Special 2 [Bluray-1080p][10bit][x265][Opus 2.0][JA+EN]-ZeroBuild | 11006965000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-03-18T18:27:55Z |
| attack-on-titan | Attack on Titan | anime | Attack on Titan - Before the Fall v02 (2014) (Digital) (LostNerevarine-Empire) | 598486672 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-03-18T03:58:59Z |
| attack-on-titan | Attack on Titan | anime | Attack on Titan - Before the Fall v03 (2014) (Digital) (LostNerevarine-Empire) | 536846513 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-03-18T03:59:16Z |
| attack-on-titan | Attack on Titan | anime | Attack on Titan - Before the Fall v04 (2015) (Digital) (LostNerevarine-Empire) | 590439732 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-03-18T03:59:34Z |
| attack-on-titan | Attack on Titan | anime | Attack on Titan - Before the Fall v05 (2015) (Digital) (LostNerevarine-Empire) | 633973570 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-03-18T03:59:52Z |
| attack-on-titan | Attack on Titan | anime | Attack on Titan - Before the Fall v06 (2015) (Digital) (LostNerevarine-Empire) | 511218500 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-03-18T04:00:09Z |
| attack-on-titan | Attack on Titan | anime | Attack on Titan - Before the Fall v07 (2015) (Digital) (Hexer-Empire) | 696810620 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-03-18T04:00:29Z |
| attack-on-titan | Attack on Titan | anime | Attack on Titan - Before the Fall v08 (2016) (Digital) (Hexer-Empire) | 588016285 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-03-18T04:00:47Z |
| attack-on-titan | Attack on Titan | anime | Attack on Titan - Before the Fall v09 (2016) (Digital) (jdcox215) | 550579296 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-03-18T04:01:04Z |
| attack-on-titan | Attack on Titan | anime | Attack on Titan - Before the Fall v10 (2017) (Digital) (jdcox215) | 567530143 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-03-18T04:01:22Z |
| attack-on-titan | Attack on Titan | anime | Attack on Titan - Before the Fall v11 (2017) (Digital) (jdcox215) | 522052788 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-03-18T04:01:39Z |
| attack-on-titan | Attack on Titan | anime | Attack on Titan - Before the Fall v12 (2017) (Digital) (jdcox215) | 507185940 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-03-18T04:01:56Z |
| attack-on-titan | Attack on Titan | anime | Attack on Titan - Before the Fall v13 (2018) (Digital) (jdcox215) | 473530622 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-03-18T04:02:13Z |
| attack-on-titan | Attack on Titan | anime | Attack on Titan - Before the Fall v14 (2018) (Digital) (jdcox215) | 688910246 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-03-18T04:02:32Z |
| attack-on-titan | Attack on Titan | anime | Attack on Titan - Before the Fall v15 (2018) (Digital) (jdcox215) | 598376898 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-03-18T04:02:50Z |
| attack-on-titan | Attack on Titan | anime | Attack on Titan - Before the Fall v16 (2019) (Digital) (jdcox215) | 676663563 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-03-18T04:03:09Z |
| attack-on-titan | Attack on Titan | anime | Attack on Titan - Before the Fall v17 (2019) (Digital) (jdcox215) | 695906343 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-03-18T04:03:28Z |
| attack-on-titan | Attack on Titan | anime | Attack on Titan - Junior High v01 (2014) (Kodansha Comics USA) (Digital) (LostNerevarine-Empire) | 622852314 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-03-18T04:03:47Z |
| attack-on-titan | Attack on Titan | anime | Attack on Titan - Junior High v02 (2014) (Kodansha Comics USA) (Digital) (LostNerevarine-Empire) | 614118951 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-03-18T04:04:05Z |
| attack-on-titan | Attack on Titan | anime | Attack on Titan - Junior High v03 (2015) (Kodansha Comics USA) (Digital) (LostNerevarine-Empire) | 678813161 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-03-18T04:04:25Z |
| attack-on-titan | Attack on Titan | anime | Attack on Titan - Junior High v04 (2015) (Kodansha Comics USA) (Digital) (LostNerevarine-Empire) | 600051878 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-03-18T04:04:43Z |
| attack-on-titan | Attack on Titan | anime | Attack on Titan - Junior High v05 (2018) (Kodansha Comics USA) (Digital) (jdcox215) | 772470778 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-03-18T04:05:05Z |
| attack-on-titan | Attack on Titan | anime | Attack on Titan - Lost Girls v01 (2016) (Digital) (Hexer-Empire) | 433796705 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-03-18T04:05:21Z |
| attack-on-titan | Attack on Titan | anime | Attack on Titan - Lost Girls v02 (2017) (Digital) (jdcox215) | 437012600 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-03-18T04:05:37Z |
| attack-on-titan | Attack on Titan | anime | Attack on Titan - No Regrets v01 (2014) (Kodansha Comics USA) (Digital) (danke-Empire) | 241181179 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-03-18T04:05:51Z |
| attack-on-titan | Attack on Titan | anime | Attack on Titan - No Regrets v02 (2014) (Kodansha Comics USA) (Digital) (danke-Empire) | 239252326 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-03-18T04:06:05Z |
| attack-on-titan | Attack on Titan | anime | Attack.on.Titan.Chronicle.2020.1080p.BluRay.Remux.FLAC5.1.H.264-Meakes | 39614932477 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-06-20T20:26:31Z |
| attack-on-titan | Attack on Titan | anime | Attack.on.Titan.The.Last.Attack.2024.1080p.CR.WEB-DL.DUAL.AAC2.0.H.264-VARYG | 10117674733 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-04-18T15:01:59Z |
| attack-on-titan | Attack on Titan | anime | Attack.on.Titan.The.Last.Attack.2024.1080p.CR.WEB-DL.MULTi.AAC2.0.H.264-VARYG | 10590424891 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-04-18T13:37:52Z |
| attack-on-titan | Attack on Titan | anime | Attack.on.Titan.The.Last.Attack.2025.1080p.CR.WEB-DL.DUAL.AAC2.0.H.264.MSubs-ToonsHub | 10120390072 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-04-18T10:47:05Z |
| attack-on-titan | Attack on Titan | anime | [Anime Time] Attack on Titan - The Last Attack [Web-DL][1080p][HEVC 10bit x265][AAC] [Dual Audio][Multi Subs] | 3853799862 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-06-30T23:34:36Z |
| attack-on-titan | Attack on Titan | anime | [Anime Time] Attack on Titan Movie 05 - The Last Attack | 4621472354 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-18T14:28:53Z |
| attack-on-titan | Attack on Titan | anime | [Baws] Attack on Titan - S04E29 v3 - The Final Chapters (Part 1) (WEB 1080p Hi10 EAC3 AAC) [7E6E0C64] | 1481378970 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-05T15:24:55Z |
| attack-on-titan | Attack on Titan | anime | [Golumpa] Attack on Titan S2 - 01 [FuniDub 1080p x264 AAC] | 929823349 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-06-08T23:46:23Z |
| attack-on-titan | Attack on Titan | anime | [Golumpa] Attack on Titan S2 - 02 [FuniDub 1080p x264 AAC] | 926971777 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-06-08T23:46:24Z |
| attack-on-titan | Attack on Titan | anime | [Golumpa] Attack on Titan S2 - 03 [FuniDub 1080p x264 AAC] | 949080197 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-06-08T23:46:26Z |
| attack-on-titan | Attack on Titan | anime | [Golumpa] Attack on Titan S2 - 05 [FuniDub 1080p x264 AAC] | 694380798 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-06-08T23:46:28Z |
| attack-on-titan | Attack on Titan | anime | [Golumpa] Attack on Titan S2 - 06 [FuniDub 1080p x264 AAC] | 521878031 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-06-08T23:46:29Z |
| attack-on-titan | Attack on Titan | anime | [Golumpa] Attack on Titan S2 - 07 [FuniDub 1080p x264 AAC] | 616626125 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-06-08T23:46:29Z |
| attack-on-titan | Attack on Titan | anime | [Golumpa] Attack on Titan S2 - 08 [FuniDub 1080p x264 AAC] | 529267136 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-06-08T23:46:31Z |
| attack-on-titan | Attack on Titan | anime | [Golumpa] Attack on Titan S2 - 09 [FuniDub 1080p x264 AAC] | 624509364 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-06-08T23:46:32Z |
| attack-on-titan | Attack on Titan | anime | [Golumpa] Attack on Titan S2 - 10 [FuniDub 1080p x264 AAC] | 241239699 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-06-08T23:46:29Z |
| attack-on-titan | Attack on Titan | anime | [Golumpa] Attack on Titan S2 - 11 [FuniDub 1080p x264 AAC] | 189835571 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-06-08T23:46:25Z |
| attack-on-titan | Attack on Titan | anime | [Golumpa] Attack on Titan S2 - 12 [FuniDub 1080p x264 AAC] | 592130687 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-06-09T02:22:17Z |
| attack-on-titan | Attack on Titan | anime | [Yameii] Attack on Titan - S04E29 [English Dub] [FUNi WEB-DL 720p] [40D4E5B9] | 1963574563 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-05-03T11:34:12Z |
| attack-on-titan | Attack on Titan | anime | [Yameii] Attack on Titan - S04E30 [English Dub] [FUNi WEB-DL 720p] [B22B590F] | 2767215265 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-05-03T11:37:11Z |
| attack-on-titan | Attack on Titan | anime | [Yameii] Attack on Titan - The Last Attack (2024) [English Dub] [CR WEB-DL 1080p] [5433BCE3] | 9956407489 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-04-18T15:28:14Z |
| attack-on-titan | Attack on Titan | anime | [Yameii] Attack on Titan - The Last Attack (2024) [English Dub] [CR WEB-DL 720p] [9C01388C] | 5066110807 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-04-18T15:09:22Z |
| attack-on-titan | Attack on Titan | anime | [speedmux] Attack on Titan - The Last Attack (1080p, Dual, CR, AMZN) | 11027700876 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-04-19T13:01:17Z |
| attack-on-titan | Shingeki no Kyojin | all | Shingeki no Kyojin - The Last Attack 2024 1080p Blu-ray Remux AVC DUAL Atmos-E.N.D | 40876386206 | usenet | 2000:Movies, 2040:Movies/HD, 102000:, 102040: | 2026-03-12T18:37:40Z |
| attack-on-titan | Shingeki no Kyojin | all | Shingeki.no.Kyojin.Chronicle.Movie.2020.MULTI.Audio.Sub[FRE][ENG][ARA][POR][CHI] | 17644189469 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-01-12T20:20:36Z |
| attack-on-titan | Shingeki no Kyojin | all | [ASW] Shingeki no Kyojin Movie - The Last Attack [1080p HEVC][D35451B5] | 2617565833 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-04-20T08:00:02Z |
| attack-on-titan | Shingeki no Kyojin | all | [Commie] Shingeki no Kyojin - 22 [C1F74745] | 435828980 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-02-16T07:58:43Z |
| attack-on-titan | Shingeki no Kyojin | all | [Erai-raws] Shingeki no Kyojin - Kanketsu-hen - The Last Attack - Movie [1080p CR WEB-DL AVC EAC3][MultiSub][33E16E93] | 10077431458 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-04-18T08:24:56Z |
| attack-on-titan | Shingeki no Kyojin | all | [Erai-raws] Shingeki no Kyojin - Kanketsu-hen - The Last Attack - Movie [1080p CR WEBRip HEVC EAC3][MultiSub][91ABD6D7] | 5043166794 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-04-18T19:16:29Z |
| attack-on-titan | Shingeki no Kyojin | all | [Erai-raws] Shingeki no Kyojin - Kanketsu-hen - The Last Attack - Movie [480p CR WEB-DL AVC EAC3][MultiSub][D4E5B5A2] | 2735387017 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-04-18T08:04:03Z |
| attack-on-titan | Shingeki no Kyojin | all | [Erai-raws] Shingeki no Kyojin - Kanketsu-hen - The Last Attack - Movie [720p CR WEB-DL AVC EAC3][MultiSub][56FA4EDF] | 5187966076 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-04-18T08:00:24Z |
| attack-on-titan | Shingeki no Kyojin | all | [Erai-raws] Shingeki no Kyojin Season 3 - 11 [1080p][AVC-YUV444P10][Multiple Subtitle] | 140007182 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-02-09T04:45:34Z |
| attack-on-titan | Shingeki no Kyojin | all | [Judas] Shingeki no Kyojin - The Last Attack | 2704024296 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-04-26T17:08:04Z |
| attack-on-titan | Shingeki no Kyojin | all | [Judas] Shingeki no Kyojin - The Last Attack v2 | 2704070436 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-04-29T14:10:34Z |
| attack-on-titan | Shingeki no Kyojin | all | [MiniMTBB] Shingeki no Kyojin - 20 (BD 1080p) [3864BB7D] | 438262556 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T14:08:25Z |
| attack-on-titan | Shingeki no Kyojin | all | [MiniMTBB] Shingeki no Kyojin - 21 (BD 1080p) [D98E4493] | 536422604 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T14:08:54Z |
| attack-on-titan | Shingeki no Kyojin | all | [MiniMTBB] Shingeki no Kyojin - 22 (BD 1080p) [2BFFCB20] | 422965185 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T14:09:19Z |
| attack-on-titan | Shingeki no Kyojin | all | [MiniMTBB] Shingeki no Kyojin - 23 (BD 1080p) [BE74C5A1] | 335389644 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T14:09:38Z |
| attack-on-titan | Shingeki no Kyojin | all | [MiniMTBB] Shingeki no Kyojin - 24 (BD 1080p) [3A90C1B4] | 433410804 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T14:10:01Z |
| attack-on-titan | Shingeki no Kyojin | all | [MiniMTBB] Shingeki no Kyojin - 25 (BD 1080p) [4F8D7B57] | 429579906 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T14:10:28Z |
| attack-on-titan | Shingeki no Kyojin | all | [MiniMTBB] Shingeki no Kyojin - 60 (BD 1080p) [98884696] | 366063070 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:26:38Z |
| attack-on-titan | Shingeki no Kyojin | all | [MiniMTBB] Shingeki no Kyojin - 61 (BD 1080p) [3706CDF6] | 351482732 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:26:56Z |
| attack-on-titan | Shingeki no Kyojin | all | [MiniMTBB] Shingeki no Kyojin - 62 (BD 1080p) [1F7AB996] | 354338794 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:27:18Z |
| attack-on-titan | Shingeki no Kyojin | all | [MiniMTBB] Shingeki no Kyojin - 63 (BD 1080p) [1EB1F680] | 317167634 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:27:35Z |
| attack-on-titan | Shingeki no Kyojin | all | [MiniMTBB] Shingeki no Kyojin - 64 (BD 1080p) [29F95CEC] | 262755617 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:27:51Z |
| attack-on-titan | Shingeki no Kyojin | all | [MiniMTBB] Shingeki no Kyojin - 65 (BD 1080p) [100903C9] | 314258857 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:28:09Z |
| attack-on-titan | Shingeki no Kyojin | all | [MiniMTBB] Shingeki no Kyojin - 66 (BD 1080p) [2E004A59] | 328847502 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:28:28Z |
| attack-on-titan | Shingeki no Kyojin | all | [MiniMTBB] Shingeki no Kyojin - 67 (BD 1080p) [E8A76765] | 307094212 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:28:45Z |
| attack-on-titan | Shingeki no Kyojin | all | [MiniMTBB] Shingeki no Kyojin - 68 (BD 1080p) [87115315] | 310798686 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:29:04Z |
| attack-on-titan | Shingeki no Kyojin | all | [MiniMTBB] Shingeki no Kyojin - 69 (BD 1080p) [F21BE400] | 292336444 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:29:20Z |
| attack-on-titan | Shingeki no Kyojin | all | [MiniMTBB] Shingeki no Kyojin - 70 (BD 1080p) [319154DA] | 287331597 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:29:38Z |
| attack-on-titan | Shingeki no Kyojin | all | [MiniMTBB] Shingeki no Kyojin - 71 (BD 1080p) [94B0EB7E] | 288869415 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:29:54Z |
| attack-on-titan | Shingeki no Kyojin | all | [MiniMTBB] Shingeki no Kyojin - 72 (BD 1080p) [61E8600C] | 328538645 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:30:11Z |
| attack-on-titan | Shingeki no Kyojin | all | [MiniMTBB] Shingeki no Kyojin - 73 (BD 1080p) [E616CC7A] | 335348623 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:30:30Z |
| attack-on-titan | Shingeki no Kyojin | all | [MiniMTBB] Shingeki no Kyojin - 74 (BD 1080p) [041DB1AD] | 312355200 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:30:46Z |
| attack-on-titan | Shingeki no Kyojin | all | [MiniMTBB] Shingeki no Kyojin - 75 (BD 1080p) [ACF4B7B0] | 271403964 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:31:02Z |
| attack-on-titan | Shingeki no Kyojin | all | [MiniMTBB] Shingeki no Kyojin - 76 (BD 1080p) [C4531856] | 477352997 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:31:29Z |
| attack-on-titan | Shingeki no Kyojin | all | [MiniMTBB] Shingeki no Kyojin - 77 (BD 1080p) [B0EE7131] | 389901820 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:31:49Z |
| attack-on-titan | Shingeki no Kyojin | all | [MiniMTBB] Shingeki no Kyojin - 78 (BD 1080p) [83C7C9BB] | 425067673 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:32:11Z |
| attack-on-titan | Shingeki no Kyojin | all | [MiniMTBB] Shingeki no Kyojin - 79 (BD 1080p) [9C03CC87] | 315823280 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:32:30Z |
| attack-on-titan | Shingeki no Kyojin | all | [MiniMTBB] Shingeki no Kyojin - 80 (BD 1080p) [E9A96D61] | 502886708 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:32:58Z |
| attack-on-titan | Shingeki no Kyojin | all | [MiniMTBB] Shingeki no Kyojin - 81 (BD 1080p) [816986E3] | 442836393 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:33:25Z |
| attack-on-titan | Shingeki no Kyojin | all | [MiniMTBB] Shingeki no Kyojin - 82 (BD 1080p) [434F56E7] | 319232835 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:33:41Z |
| attack-on-titan | Shingeki no Kyojin | all | [MiniMTBB] Shingeki no Kyojin - 83 (BD 1080p) [C9092D89] | 402666820 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:33:57Z |
| attack-on-titan | Shingeki no Kyojin | all | [MiniMTBB] Shingeki no Kyojin - 84 (BD 1080p) [FFAD20F3] | 282972949 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:34:10Z |
| attack-on-titan | Shingeki no Kyojin | all | [MiniMTBB] Shingeki no Kyojin - 85 (BD 1080p) [A220140D] | 488505734 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:34:30Z |
| attack-on-titan | Shingeki no Kyojin | all | [MiniMTBB] Shingeki no Kyojin - 86 (BD 1080p) [854947A1] | 546144911 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:35:00Z |
| attack-on-titan | Shingeki no Kyojin | all | [MiniMTBB] Shingeki no Kyojin - 87 (BD 1080p) [9C4A680F] | 345887742 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:35:21Z |
| attack-on-titan | Shingeki no Kyojin | all | [MiniMTBB] Shingeki no Kyojin - 88 (BD 1080p) [778EC79E] | 951442445 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:36:14Z |
| attack-on-titan | Shingeki no Kyojin | all | [MiniMTBB] Shingeki no Kyojin - 89 (BD 1080p) [607FFC76] | 1426490755 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:37:27Z |
| attack-on-titan | Shingeki no Kyojin | all | [SubsPlease] Shingeki no Kyojin Movie - The Last Attack (1080p) [40DD2396] | 9961423770 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-04-18T17:44:24Z |
| attack-on-titan | Shingeki no Kyojin | all | [SubsPlease] Shingeki no Kyojin Movie - The Last Attack (480p) [6D5D5107] | 2620701224 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-04-18T17:34:45Z |
| attack-on-titan | Shingeki no Kyojin | all | [SubsPlease] Shingeki no Kyojin Movie - The Last Attack (720p) [FCC184BF] | 5071375452 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-04-18T17:31:37Z |
| attack-on-titan | Shingeki no Kyojin | anime | Shingeki.no.Kyojin.Chronicle.Movie.2020.MULTI.Audio.Sub[FRE][ENG][ARA][POR][CHI] | 17644189469 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-01-12T20:20:36Z |
| attack-on-titan | Shingeki no Kyojin | anime | [ASW] Shingeki no Kyojin Movie - The Last Attack [1080p HEVC][D35451B5] | 2617565833 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-04-20T08:00:02Z |
| attack-on-titan | Shingeki no Kyojin | anime | [Commie] Shingeki no Kyojin - 22 [C1F74745] | 435828980 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-02-16T07:58:43Z |
| attack-on-titan | Shingeki no Kyojin | anime | [Erai-raws] Shingeki no Kyojin - Kanketsu-hen - The Last Attack - Movie [1080p CR WEB-DL AVC EAC3][MultiSub][33E16E93] | 10077431458 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-04-18T08:24:56Z |
| attack-on-titan | Shingeki no Kyojin | anime | [Erai-raws] Shingeki no Kyojin - Kanketsu-hen - The Last Attack - Movie [1080p CR WEBRip HEVC EAC3][MultiSub][91ABD6D7] | 5043166794 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-04-18T19:16:29Z |
| attack-on-titan | Shingeki no Kyojin | anime | [Erai-raws] Shingeki no Kyojin - Kanketsu-hen - The Last Attack - Movie [480p CR WEB-DL AVC EAC3][MultiSub][D4E5B5A2] | 2735387017 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-04-18T08:04:03Z |
| attack-on-titan | Shingeki no Kyojin | anime | [Erai-raws] Shingeki no Kyojin - Kanketsu-hen - The Last Attack - Movie [720p CR WEB-DL AVC EAC3][MultiSub][56FA4EDF] | 5187966076 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-04-18T08:00:24Z |
| attack-on-titan | Shingeki no Kyojin | anime | [Erai-raws] Shingeki no Kyojin Season 3 - 11 [1080p][AVC-YUV444P10][Multiple Subtitle] | 140007182 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-02-09T04:45:34Z |
| attack-on-titan | Shingeki no Kyojin | anime | [Judas] Shingeki no Kyojin - The Last Attack | 2704024296 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-04-26T17:08:04Z |
| attack-on-titan | Shingeki no Kyojin | anime | [Judas] Shingeki no Kyojin - The Last Attack v2 | 2704070436 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-04-29T14:10:34Z |
| attack-on-titan | Shingeki no Kyojin | anime | [MiniMTBB] Shingeki no Kyojin - 19 (BD 1080p) [D071C5B6] | 438942218 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T14:07:58Z |
| attack-on-titan | Shingeki no Kyojin | anime | [MiniMTBB] Shingeki no Kyojin - 20 (BD 1080p) [3864BB7D] | 438262556 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T14:08:25Z |
| attack-on-titan | Shingeki no Kyojin | anime | [MiniMTBB] Shingeki no Kyojin - 21 (BD 1080p) [D98E4493] | 536422604 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T14:08:54Z |
| attack-on-titan | Shingeki no Kyojin | anime | [MiniMTBB] Shingeki no Kyojin - 22 (BD 1080p) [2BFFCB20] | 422965185 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T14:09:19Z |
| attack-on-titan | Shingeki no Kyojin | anime | [MiniMTBB] Shingeki no Kyojin - 23 (BD 1080p) [BE74C5A1] | 335389644 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T14:09:38Z |
| attack-on-titan | Shingeki no Kyojin | anime | [MiniMTBB] Shingeki no Kyojin - 24 (BD 1080p) [3A90C1B4] | 433410804 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T14:10:01Z |
| attack-on-titan | Shingeki no Kyojin | anime | [MiniMTBB] Shingeki no Kyojin - 25 (BD 1080p) [4F8D7B57] | 429579906 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T14:10:28Z |
| attack-on-titan | Shingeki no Kyojin | anime | [MiniMTBB] Shingeki no Kyojin - 60 (BD 1080p) [98884696] | 366063070 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:26:38Z |
| attack-on-titan | Shingeki no Kyojin | anime | [MiniMTBB] Shingeki no Kyojin - 61 (BD 1080p) [3706CDF6] | 351482732 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:26:56Z |
| attack-on-titan | Shingeki no Kyojin | anime | [MiniMTBB] Shingeki no Kyojin - 62 (BD 1080p) [1F7AB996] | 354338794 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:27:18Z |
| attack-on-titan | Shingeki no Kyojin | anime | [MiniMTBB] Shingeki no Kyojin - 63 (BD 1080p) [1EB1F680] | 317167634 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:27:35Z |
| attack-on-titan | Shingeki no Kyojin | anime | [MiniMTBB] Shingeki no Kyojin - 64 (BD 1080p) [29F95CEC] | 262755617 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:27:51Z |
| attack-on-titan | Shingeki no Kyojin | anime | [MiniMTBB] Shingeki no Kyojin - 65 (BD 1080p) [100903C9] | 314258857 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:28:09Z |
| attack-on-titan | Shingeki no Kyojin | anime | [MiniMTBB] Shingeki no Kyojin - 66 (BD 1080p) [2E004A59] | 328847502 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:28:28Z |
| attack-on-titan | Shingeki no Kyojin | anime | [MiniMTBB] Shingeki no Kyojin - 67 (BD 1080p) [E8A76765] | 307094212 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:28:45Z |
| attack-on-titan | Shingeki no Kyojin | anime | [MiniMTBB] Shingeki no Kyojin - 68 (BD 1080p) [87115315] | 310798686 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:29:04Z |
| attack-on-titan | Shingeki no Kyojin | anime | [MiniMTBB] Shingeki no Kyojin - 69 (BD 1080p) [F21BE400] | 292336444 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:29:20Z |
| attack-on-titan | Shingeki no Kyojin | anime | [MiniMTBB] Shingeki no Kyojin - 70 (BD 1080p) [319154DA] | 287331597 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:29:38Z |
| attack-on-titan | Shingeki no Kyojin | anime | [MiniMTBB] Shingeki no Kyojin - 71 (BD 1080p) [94B0EB7E] | 288869415 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:29:54Z |
| attack-on-titan | Shingeki no Kyojin | anime | [MiniMTBB] Shingeki no Kyojin - 72 (BD 1080p) [61E8600C] | 328538645 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:30:11Z |
| attack-on-titan | Shingeki no Kyojin | anime | [MiniMTBB] Shingeki no Kyojin - 73 (BD 1080p) [E616CC7A] | 335348623 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:30:30Z |
| attack-on-titan | Shingeki no Kyojin | anime | [MiniMTBB] Shingeki no Kyojin - 74 (BD 1080p) [041DB1AD] | 312355200 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:30:46Z |
| attack-on-titan | Shingeki no Kyojin | anime | [MiniMTBB] Shingeki no Kyojin - 75 (BD 1080p) [ACF4B7B0] | 271403964 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:31:02Z |
| attack-on-titan | Shingeki no Kyojin | anime | [MiniMTBB] Shingeki no Kyojin - 76 (BD 1080p) [C4531856] | 477352997 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:31:29Z |
| attack-on-titan | Shingeki no Kyojin | anime | [MiniMTBB] Shingeki no Kyojin - 77 (BD 1080p) [B0EE7131] | 389901820 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:31:49Z |
| attack-on-titan | Shingeki no Kyojin | anime | [MiniMTBB] Shingeki no Kyojin - 78 (BD 1080p) [83C7C9BB] | 425067673 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:32:11Z |
| attack-on-titan | Shingeki no Kyojin | anime | [MiniMTBB] Shingeki no Kyojin - 79 (BD 1080p) [9C03CC87] | 315823280 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:32:30Z |
| attack-on-titan | Shingeki no Kyojin | anime | [MiniMTBB] Shingeki no Kyojin - 80 (BD 1080p) [E9A96D61] | 502886708 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:32:58Z |
| attack-on-titan | Shingeki no Kyojin | anime | [MiniMTBB] Shingeki no Kyojin - 81 (BD 1080p) [816986E3] | 442836393 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:33:25Z |
| attack-on-titan | Shingeki no Kyojin | anime | [MiniMTBB] Shingeki no Kyojin - 82 (BD 1080p) [434F56E7] | 319232835 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:33:41Z |
| attack-on-titan | Shingeki no Kyojin | anime | [MiniMTBB] Shingeki no Kyojin - 83 (BD 1080p) [C9092D89] | 402666820 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:33:57Z |
| attack-on-titan | Shingeki no Kyojin | anime | [MiniMTBB] Shingeki no Kyojin - 84 (BD 1080p) [FFAD20F3] | 282972949 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:34:10Z |
| attack-on-titan | Shingeki no Kyojin | anime | [MiniMTBB] Shingeki no Kyojin - 85 (BD 1080p) [A220140D] | 488505734 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:34:30Z |
| attack-on-titan | Shingeki no Kyojin | anime | [MiniMTBB] Shingeki no Kyojin - 86 (BD 1080p) [854947A1] | 546144911 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:35:00Z |
| attack-on-titan | Shingeki no Kyojin | anime | [MiniMTBB] Shingeki no Kyojin - 87 (BD 1080p) [9C4A680F] | 345887742 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:35:21Z |
| attack-on-titan | Shingeki no Kyojin | anime | [MiniMTBB] Shingeki no Kyojin - 88 (BD 1080p) [778EC79E] | 951442445 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:36:14Z |
| attack-on-titan | Shingeki no Kyojin | anime | [MiniMTBB] Shingeki no Kyojin - 89 (BD 1080p) [607FFC76] | 1426490755 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-06-28T18:37:27Z |
| attack-on-titan | Shingeki no Kyojin | anime | [SubsPlease] Shingeki no Kyojin Movie - The Last Attack (1080p) [40DD2396] | 9961423770 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-04-18T17:44:24Z |
| attack-on-titan | Shingeki no Kyojin | anime | [SubsPlease] Shingeki no Kyojin Movie - The Last Attack (480p) [6D5D5107] | 2620701224 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-04-18T17:34:45Z |
| attack-on-titan | Shingeki no Kyojin | anime | [SubsPlease] Shingeki no Kyojin Movie - The Last Attack (720p) [FCC184BF] | 5071375452 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-04-18T17:31:37Z |
| bleach | Bleach | all | Bleach - Thousand Year Blood War - S17E14 [H3LL][BD 1080p][x264][10bit][Dual AAC][English Subs] | 1969631596 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-21T11:58:05Z |
| bleach | Bleach | all | Bleach 268 (HD) | 774362792 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-04T12:44:12Z |
| bleach | Bleach | all | Bleach 269 (HD) | 775832107 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-04T12:45:25Z |
| bleach | Bleach | all | Bleach 270 (HD) | 774078846 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-04T12:46:48Z |
| bleach | Bleach | all | Bleach 271 (HD) | 775518765 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-04T12:47:59Z |
| bleach | Bleach | all | Bleach 272 (HD) | 773437138 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-04T12:48:54Z |
| bleach | Bleach | all | Bleach 308 (HD) | 741655590 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-04T12:49:40Z |
| bleach | Bleach | all | Bleach 309 (HD) | 742007798 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-04T12:50:24Z |
| bleach | Bleach | all | Bleach 310 (HD) | 778685748 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-04T12:51:09Z |
| bleach | Bleach | all | Bleach To Death - Sacrificing Your Beliefs (2026) [FLAC 16bit-44.1kHz]-NICFEIN | 246751912 | usenet | 3000:Audio, 3040:Audio/Lossless, 103000:, 103040: | 2026-06-22T18:01:22Z |
| bleach | Bleach | all | Bleach To Death-Anguish-Single-WEB-2026-FiH | 17294231 | usenet | 3000:Audio, 3010:Audio/MP3, 103000:, 103010: | 2026-06-15T23:59:32Z |
| bleach | Bleach | all | Bleach To Death-Sacrificing Your Beliefs-16BIT-WEB-FLAC-2026-VEXED | 246874941 | usenet | 3000:Audio, 3040:Audio/Lossless, 103000:, 103040: | 2026-07-02T14:22:37Z |
| bleach | Bleach | all | Bleach To Death-Sacrificing Your Beliefs-WEB-2026-FiH | 97122157 | usenet | 3000:Audio, 3010:Audio/MP3, 103000:, 103010: | 2026-07-02T19:47:19Z |
| bleach | Bleach | all | Bleach iTunes (2019) | 622147847 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-04T12:53:01Z |
| bleach | Bleach | all | Bleach.Thousand.Year.Blood.War.Part.2.E01.Die.letzten.9.Tage.German.2023.ANiME.DL.1080p.BluRay.x264-STARS | 897441656 | usenet | 5000:TV, 5020:TV/Foreign, 105000:, 105020: | 2026-06-10T15:41:56Z |
| bleach | Bleach | all | Bleach.Thousand.Year.Blood.War.Part.2.E01.Die.letzten.9.Tage.German.2023.ANiME.DL.720p.BluRay.x264-STARS | 428205572 | usenet | 5000:TV, 5020:TV/Foreign, 105000:, 105020: | 2026-06-10T15:41:50Z |
| bleach | Bleach | all | Bleach.Thousand.Year.Blood.War.Part.2.E02.Frieden.aus.der.Finsternis.German.2023.ANiME.DL.1080p.BluRay.x264-STARS | 1040481420 | usenet | 5000:TV, 5020:TV/Foreign, 105000:, 105020: | 2026-06-10T15:42:13Z |
| bleach | Bleach | all | Bleach.Thousand.Year.Blood.War.Part.2.E02.Frieden.aus.der.Finsternis.German.2023.ANiME.DL.720p.BluRay.x264-STARS | 496952955 | usenet | 5000:TV, 5020:TV/Foreign, 105000:, 105020: | 2026-06-10T15:42:01Z |
| bleach | Bleach | all | Bleach.Thousand.Year.Blood.War.Part.2.E03.Die.grundlegende.Virulenz.German.2023.ANiME.DL.1080p.BluRay.x264-STARS | 1223939665 | usenet | 5000:TV, 5020:TV/Foreign, 105000:, 105020: | 2026-06-10T15:43:18Z |
| bleach | Bleach | all | Bleach.Thousand.Year.Blood.War.Part.2.E03.Die.grundlegende.Virulenz.German.2023.ANiME.DL.720p.BluRay.x264-STARS | 628538410 | usenet | 5000:TV, 5020:TV/Foreign, 105000:, 105020: | 2026-06-10T15:42:19Z |
| bleach | Bleach | all | Bleach.Thousand.Year.Blood.War.Part.2.E04.Das.Herz.eines.Wolfes.German.2023.ANiME.DL.1080p.BluRay.x264-STARS | 1260322345 | usenet | 5000:TV, 5020:TV/Foreign, 105000:, 105020: | 2026-06-10T15:43:32Z |
| bleach | Bleach | all | Bleach.Thousand.Year.Blood.War.Part.2.E04.Das.Herz.eines.Wolfes.German.2023.ANiME.DL.720p.BluRay.x264-STARS | 623145970 | usenet | 5000:TV, 5020:TV/Foreign, 105000:, 105020: | 2026-06-10T15:43:27Z |
| bleach | Bleach | all | Bleach.Thousand.Year.Blood.War.Part.2.E05.Die.Menge.tobt.German.2023.ANiME.DL.1080p.BluRay.x264-STARS | 1300461343 | usenet | 5000:TV, 5020:TV/Foreign, 105000:, 105020: | 2026-06-10T15:44:08Z |
| bleach | Bleach | all | Bleach.Thousand.Year.Blood.War.Part.2.E05.Die.Menge.tobt.German.2023.ANiME.DL.720p.BluRay.x264-STARS | 623982507 | usenet | 5000:TV, 5020:TV/Foreign, 105000:, 105020: | 2026-06-10T15:43:40Z |
| bleach | Bleach | all | Bleach.Thousand.Year.Blood.War.Part.2.E06.Der.weisse.Nebel.German.2023.ANiME.DL.1080p.BluRay.x264-STARS | 1048168378 | usenet | 5000:TV, 5020:TV/Foreign, 105000:, 105020: | 2026-06-10T15:44:29Z |
| bleach | Bleach | all | Bleach.Thousand.Year.Blood.War.Part.2.E06.Der.weisse.Nebel.German.2023.ANiME.DL.720p.BluRay.x264-STARS | 524239689 | usenet | 5000:TV, 5020:TV/Foreign, 105000:, 105020: | 2026-06-10T15:43:44Z |
| bleach | Bleach | all | Bleach.Thousand.Year.Blood.War.Part.2.E07.Ich.bin.die.Grenze.German.2023.ANiME.DL.1080p.BluRay.x264-STARS | 948176904 | usenet | 5000:TV, 5020:TV/Foreign, 105000:, 105020: | 2026-06-10T15:44:13Z |
| bleach | Bleach | all | Bleach.Thousand.Year.Blood.War.Part.2.E07.Ich.bin.die.Grenze.German.2023.ANiME.DL.720p.BluRay.x264-STARS | 481007238 | usenet | 5000:TV, 5020:TV/Foreign, 105000:, 105020: | 2026-06-10T15:43:36Z |
| bleach | Bleach | all | Bleach.Thousand.Year.Blood.War.Part.2.E08.Der.kopflose.Stern.German.2023.ANiME.DL.1080p.BluRay.x264-STARS | 897143137 | usenet | 5000:TV, 5020:TV/Foreign, 105000:, 105020: | 2026-06-10T15:44:37Z |
| bleach | Bleach | all | Bleach.Thousand.Year.Blood.War.Part.2.E08.Der.kopflose.Stern.German.2023.ANiME.DL.720p.BluRay.x264-STARS | 427907062 | usenet | 5000:TV, 5020:TV/Foreign, 105000:, 105020: | 2026-06-10T15:43:47Z |
| bleach | Bleach | all | Bleach.Thousand.Year.Blood.War.Part.2.E09.Marsch.der.Zombies.German.2023.ANiME.DL.1080p.BluRay.x264-STARS | 1040481122 | usenet | 5000:TV, 5020:TV/Foreign, 105000:, 105020: | 2026-06-10T15:43:52Z |
| bleach | Bleach | all | Bleach.Thousand.Year.Blood.War.Part.2.E09.Marsch.der.Zombies.German.2023.ANiME.DL.720p.BluRay.x264-STARS | 503714421 | usenet | 5000:TV, 5020:TV/Foreign, 105000:, 105020: | 2026-06-10T15:44:20Z |
| bleach | Bleach | all | Bleach.Thousand.Year.Blood.War.Part.2.E10.Marsch.der.Zombies.2.German.2023.ANiME.DL.1080p.BluRay.x264-STARS | 1223939460 | usenet | 5000:TV, 5020:TV/Foreign, 105000:, 105020: | 2026-06-10T15:44:48Z |
| bleach | Bleach | all | Bleach.Thousand.Year.Blood.War.Part.2.E10.Marsch.der.Zombies.2.German.2023.ANiME.DL.720p.BluRay.x264-STARS | 613199380 | usenet | 5000:TV, 5020:TV/Foreign, 105000:, 105020: | 2026-06-10T15:44:24Z |
| bleach | Bleach | all | Bleach.Thousand.Year.Blood.War.Part.2.E11.Zu.frueh.fuer.den.Sieg.zu.spaet.fuer.Gewissheit.German.2023.ANiME.DL.1080p.BluRay.x264-STARS | 1260323475 | usenet | 5000:TV, 5020:TV/Foreign, 105000:, 105020: | 2026-06-10T15:44:54Z |
| bleach | Bleach | all | Bleach.Thousand.Year.Blood.War.Part.2.E11.Zu.frueh.fuer.den.Sieg.zu.spaet.fuer.Gewissheit.German.2023.ANiME.DL.720p.BluRay.x264-STARS | 623146991 | usenet | 5000:TV, 5020:TV/Foreign, 105000:, 105020: | 2026-06-10T15:44:42Z |
| bleach | Bleach | all | Bleach.Thousand.Year.Blood.War.Part.2.E12.Der.Meister.German.2023.ANiME.DL.1080p.BluRay.x264-STARS | 1300461208 | usenet | 5000:TV, 5020:TV/Foreign, 105000:, 105020: | 2026-06-10T15:45:42Z |
| bleach | Bleach | all | Bleach.Thousand.Year.Blood.War.Part.2.E12.Der.Meister.German.2023.ANiME.DL.720p.BluRay.x264-STARS | 623982389 | usenet | 5000:TV, 5020:TV/Foreign, 105000:, 105020: | 2026-06-10T15:44:58Z |
| bleach | Bleach | all | Bleach.Thousand.Year.Blood.War.Part.2.E13.Schwarz.German.2023.ANiME.DL.1080p.BluRay.x264-STARS | 1048168037 | usenet | 5000:TV, 5020:TV/Foreign, 105000:, 105020: | 2026-06-10T15:45:10Z |
| bleach | Bleach | all | Bleach.Thousand.Year.Blood.War.Part.2.E13.Schwarz.German.2023.ANiME.DL.720p.BluRay.x264-STARS | 524239371 | usenet | 5000:TV, 5020:TV/Foreign, 105000:, 105020: | 2026-06-10T15:45:02Z |
| bleach | Bleach | all | [LostYears] Bleach Thousand-Year Blood War - S17E26 (WEB 1080p x264 AAC) [B98F225D] | 384388267 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-11T16:52:21Z |
| bleach | Bleach | all | [WonderhoyRips] BLEACH  Thousand-Year Blood War - The Calamity [E41 E42 E43] [720p SCR][H.264][AAC][EN Hardsub] | 178497631 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-05T01:12:01Z |
| bleach | Bleach | all | [WonderhoyRips] BLEACH Thousand-Year Blood War - The Calamity [720p SCR][H.264][AAC][EN Hardsub] | 1763318640 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-05T01:11:13Z |
| bleach | Bleach | all | [nekotan] Bleach the Movie Fade to Black 2008 (BD 1080p x264 10-bit DTS-HD MA) | 7628468839 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-05-31T23:04:09Z |
| bleach | Bleach | all | [nekotan] Bleach the Movie Fade to Black 2008 (BD 1080p x264 10-bit DTS-HD MA) | 7630902746 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T16:13:46Z |
| bleach | Bleach | all | [nekotan] Bleach the Movie Hell Verse 2010 (BD 1080p x264 10-bit DTS-HD MA) | 9880751229 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-05-31T23:26:00Z |
| bleach | Bleach | all | [nekotan] Bleach the Movie Hell Verse 2010 (BD 1080p x264 10-bit DTS-HD MA) | 9884212455 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T15:59:01Z |
| bleach | Bleach | all | [nekotan] Bleach the Movie Memories of Nobody 2006 (BD 1080p x264 10-bit DTS-HD MA) | 7553501059 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-05-31T22:56:39Z |
| bleach | Bleach | all | [nekotan] Bleach the Movie Memories of Nobody 2006 (BD 1080p x264 10-bit DTS-HD MA) | 7555670975 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T16:26:20Z |
| bleach | Bleach | all | [nekotan] Bleach the Movie The DiamondDust Rebellion 2007 (BD 1080p x264 10-bit DTS-HD MA) | 7450008165 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T15:54:34Z |
| bleach | Bleach | anime | Bleach - 300 ,396p\|.avi ~bY BKT ~ [non!english!subs] | 171100791 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-02-04T18:18:35Z |
| bleach | Bleach | anime | Bleach - Thousand Year Blood War - S17E14 [H3LL][BD 1080p][x264][10bit][Dual AAC][English Subs] | 1969631596 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-21T11:58:05Z |
| bleach | Bleach | anime | Bleach 268 (HD) | 774362792 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-04T12:44:12Z |
| bleach | Bleach | anime | Bleach 269 (HD) | 775832107 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-04T12:45:25Z |
| bleach | Bleach | anime | Bleach 270 (HD) | 774078846 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-04T12:46:48Z |
| bleach | Bleach | anime | Bleach 271 (HD) | 775518765 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-04T12:47:59Z |
| bleach | Bleach | anime | Bleach 272 (HD) | 773437138 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-04T12:48:54Z |
| bleach | Bleach | anime | Bleach 291 Sub - Ita Hd 720p ~bY AnimeManga-ITA ~ [non!english!subs] | 324994337 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-01-24T09:02:45Z |
| bleach | Bleach | anime | Bleach 304 Avi ,480p\|.avi ~bY Bleachverse | 218278475 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-02-07T07:51:50Z |
| bleach | Bleach | anime | Bleach 308 (HD) | 741655590 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-04T12:49:40Z |
| bleach | Bleach | anime | Bleach 309 (HD) | 742007798 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-04T12:50:24Z |
| bleach | Bleach | anime | Bleach 310 (HD) | 778685748 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-04T12:51:09Z |
| bleach | Bleach | anime | Bleach iTunes (2019) | 622147847 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-04T12:53:01Z |
| bleach | Bleach | anime | [BlackRabbit] Bleach (2004) - S01 [DVD-576p][Opus 2.0][Dual Audio][AV1] | 2466633443 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-04-11T14:43:03Z |
| bleach | Bleach | anime | [BlackRabbit] Bleach (2004) - S02 [DVD-576p][Opus 2.0][Dual Audio][AV1] | 2659411705 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-04-11T14:45:34Z |
| bleach | Bleach | anime | [BlackRabbit] Bleach (2004) - S03 [DVD-576p][Opus 2.0][Dual Audio][AV1] | 3090483408 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-04-11T22:51:36Z |
| bleach | Bleach | anime | [BlackRabbit] Bleach (2004) - S04 [DVD-576p][Opus 2.0][Dual Audio][AV1] | 3552050922 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-04-11T22:56:00Z |
| bleach | Bleach | anime | [BlackRabbit] Bleach (2004) - S05 [DVD-576p][Opus 2.0][Dual Audio][AV1] | 2262651061 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-04-11T22:16:38Z |
| bleach | Bleach | anime | [BlackRabbit] Bleach (2004) - S06 [DVD-576p][Opus 2.0][Dual Audio][AV1] | 3018082116 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-04-11T22:40:27Z |
| bleach | Bleach | anime | [BlackRabbit] Bleach (2004) - S07 [DVD-576p][Opus 2.0][Dual Audio][AV1] | 2729949423 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-04-11T22:37:16Z |
| bleach | Bleach | anime | [BlackRabbit] Bleach (2004) - S08 [DVD-576p][Opus 2.0][Dual Audio][AV1] | 2579267713 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-04-11T22:19:54Z |
| bleach | Bleach | anime | [Bleachverse] BLEACH 354 [480p] | 100145674 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-02-01T08:01:05Z |
| bleach | Bleach | anime | [Bleachverse] BLEACH 354 [720p] | 170672150 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-02-11T14:33:27Z |
| bleach | Bleach | anime | [Bleachverse] BLEACH 354 [720p] | 179346522 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-01-18T08:50:13Z |
| bleach | Bleach | anime | [CrunchySubs] Bleach - 303 [720p] | 253624282 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-02-04T06:46:40Z |
| bleach | Bleach | anime | [Lazier] Bleach Thousand-Year Blood War - 30 (WEB 1080p EAC3) [2171F7D5] | 1684386670 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-12-08T00:29:06Z |
| bleach | Bleach | anime | [Lazier] Bleach Thousand-Year Blood War - 31 (WEB 1080p EAC3) [6F85B95C] | 1621609768 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-12-08T00:30:46Z |
| bleach | Bleach | anime | [Lazier] Bleach Thousand-Year Blood War - 32 (WEB 1080p EAC3) [E0BF7156] | 1476823560 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-12-08T00:32:21Z |
| bleach | Bleach | anime | [Lazier] Bleach Thousand-Year Blood War - 33 (WEB 1080p EAC3) [5016AD08] | 1685538782 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-12-08T00:34:06Z |
| bleach | Bleach | anime | [Lazier] Bleach Thousand-Year Blood War - 34 (WEB 1080p AAC) [EBDB3283] | 1214150933 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-12-08T00:35:25Z |
| bleach | Bleach | anime | [Lazier] Bleach Thousand-Year Blood War - 35 (WEB 1080p AAC) [C72E26CE] | 1020019595 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-12-08T00:36:49Z |
| bleach | Bleach | anime | [Lazier] Bleach Thousand-Year Blood War - 36 (WEB 1080p AAC) [E73FCD9F] | 982596685 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-12-08T00:37:58Z |
| bleach | Bleach | anime | [Lazier] Bleach Thousand-Year Blood War - 37 (WEB 1080p AAC) [72E510BF] | 1047618673 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-12-08T00:39:15Z |
| bleach | Bleach | anime | [Lazier] Bleach Thousand-Year Blood War - 38 (WEB 1080p AAC) [CD3833B0] | 1031480794 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-12-08T00:40:39Z |
| bleach | Bleach | anime | [Lazier] Bleach Thousand-Year Blood War - 39 (WEB 1080p AAC) [A7BABE27] | 780392821 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-12-08T00:42:36Z |
| bleach | Bleach | anime | [Lazier] Bleach Thousand-Year Blood War - 40 (WEB 1080p AAC) [E323D12D] | 930051659 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-12-08T00:44:17Z |
| bleach | Bleach | anime | [LostYears] Bleach Thousand-Year Blood War - S17E26 (WEB 1080p x264 AAC) [B98F225D] | 384388267 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-11T16:52:21Z |
| bleach | Bleach | anime | [SGKK] Bleach - 291 (1280x720 h264 AAC) [6F7DA1C2] | 254310193 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-02-04T18:18:31Z |
| bleach | Bleach | anime | [SGKK] Bleach - 292 (848x480 XviD MP3) [D54F823B] | 221096362 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-02-04T18:18:33Z |
| bleach | Bleach | anime | [SGKK] Bleach - 302 (1280x720 h264 AAC) [5BC24518] | 333256144 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-01-31T06:23:10Z |
| bleach | Bleach | anime | [WonderhoyRips] BLEACH  Thousand-Year Blood War - The Calamity [E41 E42 E43] [720p SCR][H.264][AAC][EN Hardsub] | 178497631 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-05T01:12:01Z |
| bleach | Bleach | anime | [WonderhoyRips] BLEACH Thousand-Year Blood War - The Calamity [720p SCR][H.264][AAC][EN Hardsub] | 1763318640 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-05T01:11:13Z |
| bleach | Bleach | anime | [nekotan] Bleach the Movie Fade to Black 2008 (BD 1080p x264 10-bit DTS-HD MA) | 7628468839 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-05-31T23:04:09Z |
| bleach | Bleach | anime | [nekotan] Bleach the Movie Fade to Black 2008 (BD 1080p x264 10-bit DTS-HD MA) | 7630902746 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T16:13:46Z |
| bleach | Bleach | anime | [nekotan] Bleach the Movie Hell Verse 2010 (BD 1080p x264 10-bit DTS-HD MA) | 9880751229 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-05-31T23:26:00Z |
| bleach | Bleach | anime | [nekotan] Bleach the Movie Hell Verse 2010 (BD 1080p x264 10-bit DTS-HD MA) | 9884212455 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T15:59:01Z |
| bleach | Bleach | anime | [nekotan] Bleach the Movie Memories of Nobody 2006 (BD 1080p x264 10-bit DTS-HD MA) | 7553501059 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-05-31T22:56:39Z |
| bleach | Bleach | anime | [nekotan] Bleach the Movie Memories of Nobody 2006 (BD 1080p x264 10-bit DTS-HD MA) | 7555670975 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T16:26:20Z |
| bleach | Bleach | anime | [nekotan] Bleach the Movie The DiamondDust Rebellion 2007 (BD 1080p x264 10-bit DTS-HD MA) | 7447750093 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-05-31T22:56:35Z |
| bleach | Bleach | anime | [nekotan] Bleach the Movie The DiamondDust Rebellion 2007 (BD 1080p x264 10-bit DTS-HD MA) | 7450008165 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T15:54:34Z |
| bleach | Bleach 366 | all | BLEACH (2004) - COMPLETE (001-366) - JP BD + R2J DVD [Dual Audio][FLAC] [V2] | 332967346176 | torrent | 2020:Movies/Other, 5070:TV/Anime, 127720: | 2026-01-02T23:13:00Z |
| bleach | Bleach 366 | all | BLEACH 1-366 + MOVIE 1-4 +ESP 1-3 [omda] Bleach 275 (x264.720p) [55B3E151] | 199549138470 | usenet | 2000:Movies, 2040:Movies/HD, 102000:, 102040: | 2021-10-07T07:14:39Z |
| bleach | Bleach 366 | all | BLEACH SEASON 16 343-366 | 9111827618 | usenet | 5000:TV, 5030:TV/SD, 105000:, 105030: | 2013-10-26T17:04:42Z |
| bleach | Bleach 366 | all | BLEACH SEASON 16 343-366 | 9112383719 | usenet | 5000:TV, 5050:TV/Other, 105000:, 105050: | 2013-10-26T13:04:42Z |
| bleach | Bleach 366 | all | BLEACH ブリーチ ANIMATION BEST #6 [S01E366] {Tokyo MX1 Broadcast} | 219571808 | torrent | 2020:Movies/Other, 5070:TV/Anime, 134634: | 2022-08-07T13:27:00Z |
| bleach | Bleach 366 | all | BLEACH ブリーチ [001-366 END] TV TOKYO BROADCAST (2004-2012) TVRip/HDTVRip Raws | 95885148160 | torrent | 2020:Movies/Other, 5070:TV/Anime, 134634: | 2022-06-06T11:10:00Z |
| bleach | Bleach 366 | all | Bleach - 366 [SGKK] (848x480 h264 AAC) [12DF0338] | 200513000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2018-11-04T18:47:54Z |
| bleach | Bleach 366 | all | Bleach - 366 [SGKK] (848x480 h264 AAC) [12DF0338] | 200747416 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2018-11-04T19:47:54Z |
| bleach | Bleach 366 | all | Bleach - 366 [SGKK][1280x720][7ADD1610] | 330403321 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-06-04T00:43:57Z |
| bleach | Bleach 366 | all | Bleach - 366 [SGKK][1280x720][7ADD1610] | 332979622 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-06-04T00:43:58Z |
| bleach | Bleach 366 | all | Bleach - 44 [Lunar] [D5AFA366] | 200093000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2018-11-05T00:10:38Z |
| bleach | Bleach 366 | all | Bleach 1-366 [ArabicAnimeTeam] 2.0 | 161598144512 | torrent | 2020:Movies/Other, 5070:TV/Anime, 131088: | 2020-07-06T22:15:00Z |
| bleach | Bleach 366 | all | Bleach 366[End] | 158232000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2013-01-28T11:40:23Z |
| bleach | Bleach 366 | all | Bleach INTÉGRALE - 001 ~ 366 VOSTFR [BD 1080p] -EDC | 87509958656 | torrent | 2020:Movies/Other, 5070:TV/Anime, 131088: | 2022-08-06T11:43:00Z |
| bleach | Bleach 366 | all | Bleach.S16E24.Episodio.366.1080p.DSNP.WEB-DL.AAC2.0.H.264.DUAL-OLYMPUS | 1464162000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-12-18T02:36:31Z |
| bleach | Bleach 366 | all | [AWGS] Bleach 343-366 GREEK SUBS | 8482560512 | torrent | 2020:Movies/Other, 5070:TV/Anime, 131088: | 2023-04-24T17:54:00Z |
| bleach | Bleach 366 | all | [Adosin] Bleach 190-366 S01 (BD 1080p HEVC FLAC) [Dual Audio] | 287870189568 | torrent | 2020:Movies/Other, 5070:TV/Anime, 127720: | 2023-01-02T16:49:00Z |
| bleach | Bleach 366 | all | [BB] Bleach Saga 14. La desaparición del Shinigami Sustituto 343~366 | 6549825024 | torrent | 2020:Movies/Other, 5070:TV/Anime, 131088: | 2025-05-05T18:58:00Z |
| bleach | Bleach 366 | all | [DBD-Raws][死神/Bleach/ブリーチ][001-366TV][BOX1-3][日版/JPN.Ver][1080P][BDRip][HEVC-10bit][FLAC][MKV] | 110917533696 | torrent | 2020:Movies/Other, 5070:TV/Anime, 134634: | 2023-09-15T10:05:00Z |
| bleach | Bleach 366 | all | [DBD-Raws][死神/Bleach/ブリーチ][001-366TV全集+特典映像][BOX1-13][美版/USA.Ver][1080P][BDRip][HEVC-10bit][简繁外挂][FLAC][MKV] | 278850764800 | torrent | 2020:Movies/Other, 5070:TV/Anime, 127720: | 2023-09-10T08:17:00Z |
| bleach | Bleach 366 | all | [DBD-Raws][死神/Bleach/ブリーチ][001-366TV全集][日版&美版/JPN&USA][1080P][BDRip][HEVC-10bit][FLAC][MKV] | 233646227456 | torrent | 2020:Movies/Other, 5070:TV/Anime, 127720: | 2023-09-15T17:23:00Z |
| bleach | Bleach 366 | all | [DBD-Raws][死神/Bleach/ブリーチ][215-226&267-286&288-297&300-302&306-310&342-354&356-366TV][BOX3][日版/JPN.Ver][1080P][BDRip][HEVC-10bit][FLAC][MKV] | 50036367360 | torrent | 2020:Movies/Other, 5070:TV/Anime, 134634: | 2023-09-13T08:28:00Z |
| bleach | Bleach 366 | all | [DBD-Raws][死神/Bleach/ブリーチ][338-366TV+特典映像][BOX13][美版/USA.Ver][1080P][BDRip][HEVC-10bit][FLAC][MKV] | 22870700032 | torrent | 2020:Movies/Other, 5070:TV/Anime, 134634: | 2023-09-09T14:48:00Z |
| bleach | Bleach 366 | all | [Draknodd] Bleach S01 (2004) 01-366 (480p DVDRip VFR HEVC FLAC)[Multi Audio][Multi Subs] | 314391592960 | torrent | 2020:Movies/Other, 5070:TV/Anime, 127720: | 2026-05-29T12:33:00Z |
| bleach | Bleach 366 | all | [Erai-raws] Bleach S01  - 001 ~ 366 [1080p DSNP WEB-DL AVC AAC][MultiSub] [BATCH] | 345530105856 | torrent | 2020:Movies/Other, 5070:TV/Anime, 127720: | 2025-03-17T02:04:00Z |
| bleach | Bleach 366 | all | [Erai-raws] Bleach S01  - 001 ~ 366 [480p DSNP WEB-DL AVC AAC][MultiSub] [BATCH] | 129922760704 | torrent | 2020:Movies/Other, 5070:TV/Anime, 127720: | 2025-03-17T02:05:00Z |
| bleach | Bleach 366 | all | [Erai-raws] Bleach S01  - 001 ~ 366 [720p DSNP WEB-DL AVC AAC][MultiSub] [BATCH] | 186079461376 | torrent | 2020:Movies/Other, 5070:TV/Anime, 127720: | 2025-03-17T02:04:00Z |
| bleach | Bleach 366 | all | [HorribleRips] Bleach - 366 [480p] | 408088878 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2020-12-07T05:07:30Z |
| bleach | Bleach 366 | all | [HorribleRips] Bleach 343-366 S01 [1080p] | 35111358464 | torrent | 2020:Movies/Other, 5070:TV/Anime, 127720: | 2020-12-07T03:05:00Z |
| bleach | Bleach 366 | all | [HorribleRips] Bleach 343-366 S01 [480p] | 9019430912 | torrent | 2020:Movies/Other, 5070:TV/Anime, 127720: | 2020-12-07T03:05:00Z |
| bleach | Bleach 366 | all | [HorribleRips] Bleach 343-366 S01 [720p] | 17824114688 | torrent | 2020:Movies/Other, 5070:TV/Anime, 127720: | 2020-12-07T03:05:00Z |
| bleach | Bleach 366 | all | [HorribleRips].Bleach-366.[480p] | 412904000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2020-12-07T04:38:05Z |
| bleach | Bleach 366 | all | [HorribleSubs] Bleach 1-366 DvD Rip HD Batch | 133788229632 | torrent | 2020:Movies/Other, 5070:TV/Anime, 127720: | 2020-04-28T20:44:00Z |
| bleach | Bleach 366 | all | [IIDX-RAWS] Bleach 1-366 KidsStation VFR60 Encodes | 129600634880 | torrent | 2020:Movies/Other, 5070:TV/Anime, 134634: | 2024-04-11T01:40:00Z |
| bleach | Bleach 366 | all | [Judas] Bleach - 366 | 316559000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-12-16T16:49:59Z |
| bleach | Bleach 366 | all | [Judas] Bleach - 366 | 319012407 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-12-16T15:49:34Z |
| bleach | Bleach 366 | all | [Judas] Bleach - 366 | 319012457 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-12-16T17:49:59Z |
| bleach | Bleach 366 | all | [Judas] Bleach 338-366 S01 [BD 1080p][HEVC x265 10bit][Dual-Audio][Multi-Subs] (Batch) | 8482560512 | torrent | 2020:Movies/Other, 5070:TV/Anime, 127720: | 2021-12-16T16:21:00Z |
| bleach | Bleach 366 | all | [Judas] Bleach 338-366 [BD 1080p][HEVC x265 10bit][Dual-Audio][Multi-Subs] (Batch) | 677499000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-12-16T16:50:44Z |
| bleach | Bleach 366 | all | [Judas] Bleach 338-366 [BD 1080p][HEVC x265 10bit][Dual-Audio][Multi-Subs] (Batch) | 682727937 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-12-16T17:50:44Z |
| bleach | Bleach 366 | all | [MnI].Bleach-366-Changing.History.Unchanging.Heart-[TRP] | 131055000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2015-03-03T15:43:28Z |
| bleach | Bleach 366 | all | [RGB] Bleach 168-366 S01 (DVD, 480p, x264, 10b. dual FLAC. ASS Sub.) | 179529629696 | torrent | 2020:Movies/Other, 5070:TV/Anime, 127720: | 2026-06-27T20:39:00Z |
| bleach | Bleach 366 | all | [SOFCJ-Raws] BLEACH ANIMATION BEST  - 06 [366ep] (BS11 1920х1080 x264 VFR AAC).mp4 | 970771648 | torrent | 2020:Movies/Other, 5070:TV/Anime, 134634: | 2022-08-08T17:44:00Z |
| bleach | Bleach 366 | all | [ShafinKun] Bleach (01-366) [without Bount & Captain Amagai Filler Arcs] + Movie 2,4 [720pHDMicro] | 31245887488 | torrent | 2020:Movies/Other, 5070:TV/Anime, 127720: | 2022-05-17T19:04:00Z |
| bleach | Bleach 366 | all | [TESHI].Bleach-366-Changing.History.Unchanging.Heart-[720P]-[TRP] | 348616000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2015-03-24T13:46:07Z |
| bleach | Bleach 366 | all | [WZF]Bleach_-_248~366 S01 [HD][X264-AAC][1280X720][Sub_Esp][MP4] | 30816391168 | torrent | 2020:Movies/Other, 5070:TV/Anime, 131088: | 2025-07-27T03:04:00Z |
| bleach | Bleach 366 | all | [lost108] BLEACH S01  - 215-366 - VOSTFR - 1080p - x265 - JAP BDRIP | 156658925568 | torrent | 2020:Movies/Other, 5070:TV/Anime, 131088: | 2026-05-19T15:29:00Z |
| bleach | Bleach 366 | all | [pursua] Bleach 001-366 S01 (R2J DVD, JPN BD 1080p) | 141411794944 | torrent | 2020:Movies/Other, 5070:TV/Anime, 127720: | 2025-11-29T14:52:00Z |
| bleach | Bleach 366 | all | [台粵配] BLEACH 死神 S01 (Bleach) (1-366) (Mandarin Chinese + Cantonese Dub) [粵語][國語][国语][中文配音][中配版] | 123587682304 | torrent | 2020:Movies/Other, 5070:TV/Anime, 127720: | 2024-08-02T04:21:00Z |
| bleach | Bleach 366 | all | innit's Bleach 168-366 (BD 540p, multi DTS, multi PGS) | 315787476992 | torrent | 2020:Movies/Other, 5070:TV/Anime, 127720: | 2025-05-09T13:21:00Z |
| bleach | Bleach 366 | anime | BLEACH (2004) - COMPLETE (001-366) - JP BD + R2J DVD [Dual Audio][FLAC] [V2] | 332967346176 | torrent | 2020:Movies/Other, 5070:TV/Anime, 127720: | 2026-01-02T23:13:00Z |
| bleach | Bleach 366 | anime | BLEACH ブリーチ ANIMATION BEST #6 [S01E366] {Tokyo MX1 Broadcast} | 219571808 | torrent | 2020:Movies/Other, 5070:TV/Anime, 134634: | 2022-08-07T13:27:00Z |
| bleach | Bleach 366 | anime | BLEACH ブリーチ [001-366 END] TV TOKYO BROADCAST (2004-2012) TVRip/HDTVRip Raws | 95885148160 | torrent | 2020:Movies/Other, 5070:TV/Anime, 134634: | 2022-06-06T11:10:00Z |
| bleach | Bleach 366 | anime | Bleach - 366 [SGKK] (848x480 h264 AAC) [12DF0338] | 200513000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2018-11-04T18:47:54Z |
| bleach | Bleach 366 | anime | Bleach - 366 [SGKK] (848x480 h264 AAC) [12DF0338] | 200747416 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2018-11-04T19:47:54Z |
| bleach | Bleach 366 | anime | Bleach - 366 [SGKK][1280x720][7ADD1610] | 330403321 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-06-04T00:43:57Z |
| bleach | Bleach 366 | anime | Bleach - 366 [SGKK][1280x720][7ADD1610] | 332979622 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-06-04T00:43:58Z |
| bleach | Bleach 366 | anime | Bleach - 44 [Lunar] [D5AFA366] | 200093000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2018-11-05T00:10:38Z |
| bleach | Bleach 366 | anime | Bleach 1-366 [Arabic-Sub] | 150538600448 | torrent | 2020:Movies/Other, 5070:TV/Anime, 131088: | 2020-04-01T22:50:00Z |
| bleach | Bleach 366 | anime | Bleach 1-366 [ArabicAnimeTeam] 2.0 | 161598144512 | torrent | 2020:Movies/Other, 5070:TV/Anime, 131088: | 2020-07-06T22:15:00Z |
| bleach | Bleach 366 | anime | Bleach 366[End] | 158232000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2013-01-28T11:40:23Z |
| bleach | Bleach 366 | anime | Bleach INTÉGRALE - 001 ~ 366 VOSTFR [BD 1080p] -EDC | 87509958656 | torrent | 2020:Movies/Other, 5070:TV/Anime, 131088: | 2022-08-06T11:43:00Z |
| bleach | Bleach 366 | anime | Bleach.S16E24.Episodio.366.1080p.DSNP.WEB-DL.AAC2.0.H.264.DUAL-OLYMPUS | 1464162000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-12-18T02:36:31Z |
| bleach | Bleach 366 | anime | [AWGS] Bleach 343-366 GREEK SUBS | 8482560512 | torrent | 2020:Movies/Other, 5070:TV/Anime, 131088: | 2023-04-24T17:54:00Z |
| bleach | Bleach 366 | anime | [Adosin] Bleach 190-366 S01 (BD 1080p HEVC FLAC) [Dual Audio] | 287870189568 | torrent | 2020:Movies/Other, 5070:TV/Anime, 127720: | 2023-01-02T16:49:00Z |
| bleach | Bleach 366 | anime | [BB] Bleach Saga 14. La desaparición del Shinigami Sustituto 343~366 | 6549825024 | torrent | 2020:Movies/Other, 5070:TV/Anime, 131088: | 2025-05-05T18:58:00Z |
| bleach | Bleach 366 | anime | [DBD-Raws][死神/Bleach/ブリーチ][001-366TV][BOX1-3][日版/JPN.Ver][1080P][BDRip][HEVC-10bit][FLAC][MKV] | 110917533696 | torrent | 2020:Movies/Other, 5070:TV/Anime, 134634: | 2023-09-15T10:05:00Z |
| bleach | Bleach 366 | anime | [DBD-Raws][死神/Bleach/ブリーチ][001-366TV全集+特典映像][BOX1-13][美版/USA.Ver][1080P][BDRip][HEVC-10bit][简繁外挂][FLAC][MKV] | 278850764800 | torrent | 2020:Movies/Other, 5070:TV/Anime, 127720: | 2023-09-10T08:17:00Z |
| bleach | Bleach 366 | anime | [DBD-Raws][死神/Bleach/ブリーチ][001-366TV全集][日版&美版/JPN&USA][1080P][BDRip][HEVC-10bit][FLAC][MKV] | 233646227456 | torrent | 2020:Movies/Other, 5070:TV/Anime, 127720: | 2023-09-15T17:23:00Z |
| bleach | Bleach 366 | anime | [DBD-Raws][死神/Bleach/ブリーチ][215-226&267-286&288-297&300-302&306-310&342-354&356-366TV][BOX3][日版/JPN.Ver][1080P][BDRip][HEVC-10bit][FLAC][MKV] | 50036367360 | torrent | 2020:Movies/Other, 5070:TV/Anime, 134634: | 2023-09-13T08:28:00Z |
| bleach | Bleach 366 | anime | [DBD-Raws][死神/Bleach/ブリーチ][338-366TV+特典映像][BOX13][美版/USA.Ver][1080P][BDRip][HEVC-10bit][FLAC][MKV] | 22870700032 | torrent | 2020:Movies/Other, 5070:TV/Anime, 134634: | 2023-09-09T14:48:00Z |
| bleach | Bleach 366 | anime | [Draknodd] Bleach S01 (2004) 01-366 (480p DVDRip VFR HEVC FLAC)[Multi Audio][Multi Subs] | 314391592960 | torrent | 2020:Movies/Other, 5070:TV/Anime, 127720: | 2026-05-29T12:33:00Z |
| bleach | Bleach 366 | anime | [Erai-raws] Bleach S01  - 001 ~ 366 [1080p DSNP WEB-DL AVC AAC][MultiSub] [BATCH] | 345530105856 | torrent | 2020:Movies/Other, 5070:TV/Anime, 127720: | 2025-03-17T02:04:00Z |
| bleach | Bleach 366 | anime | [Erai-raws] Bleach S01  - 001 ~ 366 [480p DSNP WEB-DL AVC AAC][MultiSub] [BATCH] | 129922760704 | torrent | 2020:Movies/Other, 5070:TV/Anime, 127720: | 2025-03-17T02:05:00Z |
| bleach | Bleach 366 | anime | [Erai-raws] Bleach S01  - 001 ~ 366 [720p DSNP WEB-DL AVC AAC][MultiSub] [BATCH] | 186079461376 | torrent | 2020:Movies/Other, 5070:TV/Anime, 127720: | 2025-03-17T02:04:00Z |
| bleach | Bleach 366 | anime | [HorribleRips] Bleach - 366 [480p] | 408088878 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2020-12-07T05:07:30Z |
| bleach | Bleach 366 | anime | [HorribleRips] Bleach 343-366 S01 [1080p] | 35111358464 | torrent | 2020:Movies/Other, 5070:TV/Anime, 127720: | 2020-12-07T03:05:00Z |
| bleach | Bleach 366 | anime | [HorribleRips] Bleach 343-366 S01 [480p] | 9019430912 | torrent | 2020:Movies/Other, 5070:TV/Anime, 127720: | 2020-12-07T03:05:00Z |
| bleach | Bleach 366 | anime | [HorribleRips] Bleach 343-366 S01 [720p] | 17824114688 | torrent | 2020:Movies/Other, 5070:TV/Anime, 127720: | 2020-12-07T03:05:00Z |
| bleach | Bleach 366 | anime | [HorribleRips].Bleach-366.[480p] | 412904000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2020-12-07T04:38:05Z |
| bleach | Bleach 366 | anime | [HorribleSubs] Bleach 1-366 DvD Rip HD Batch | 133788229632 | torrent | 2020:Movies/Other, 5070:TV/Anime, 127720: | 2020-04-28T20:44:00Z |
| bleach | Bleach 366 | anime | [Horriblesubs] Bleach 01-366 S01 [Arigatou]DvDrip+1080p | 133788229632 | torrent | 2020:Movies/Other, 5070:TV/Anime, 127720: | 2020-01-18T17:42:00Z |
| bleach | Bleach 366 | anime | [IIDX-RAWS] Bleach 1-366 KidsStation VFR60 Encodes | 129600634880 | torrent | 2020:Movies/Other, 5070:TV/Anime, 134634: | 2024-04-11T01:40:00Z |
| bleach | Bleach 366 | anime | [Judas] Bleach - 366 | 316559000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-12-16T16:49:59Z |
| bleach | Bleach 366 | anime | [Judas] Bleach - 366 | 319012407 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-12-16T15:49:34Z |
| bleach | Bleach 366 | anime | [Judas] Bleach - 366 | 319012457 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-12-16T17:49:59Z |
| bleach | Bleach 366 | anime | [Judas] Bleach 338-366 S01 [BD 1080p][HEVC x265 10bit][Dual-Audio][Multi-Subs] (Batch) | 8482560512 | torrent | 2020:Movies/Other, 5070:TV/Anime, 127720: | 2021-12-16T16:21:00Z |
| bleach | Bleach 366 | anime | [Judas] Bleach 338-366 [BD 1080p][HEVC x265 10bit][Dual-Audio][Multi-Subs] (Batch) | 677499000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-12-16T16:50:44Z |
| bleach | Bleach 366 | anime | [Judas] Bleach 338-366 [BD 1080p][HEVC x265 10bit][Dual-Audio][Multi-Subs] (Batch) | 682727937 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-12-16T17:50:44Z |
| bleach | Bleach 366 | anime | [MnI].Bleach-366-Changing.History.Unchanging.Heart-[TRP] | 131055000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2015-03-03T15:43:28Z |
| bleach | Bleach 366 | anime | [RGB] Bleach 168-366 S01 (DVD, 480p, x264, 10b. dual FLAC. ASS Sub.) | 179529629696 | torrent | 2020:Movies/Other, 5070:TV/Anime, 127720: | 2026-06-27T20:39:00Z |
| bleach | Bleach 366 | anime | [SOFCJ-Raws] BLEACH ANIMATION BEST  - 06 [366ep] (BS11 1920х1080 x264 VFR AAC).mp4 | 970771648 | torrent | 2020:Movies/Other, 5070:TV/Anime, 134634: | 2022-08-08T17:44:00Z |
| bleach | Bleach 366 | anime | [ShafinKun] Bleach (01-366) [without Bount & Captain Amagai Filler Arcs] + Movie 2,4 [720pHDMicro] | 31245887488 | torrent | 2020:Movies/Other, 5070:TV/Anime, 127720: | 2022-05-17T19:04:00Z |
| bleach | Bleach 366 | anime | [TESHI].Bleach-366-Changing.History.Unchanging.Heart-[720P]-[TRP] | 348616000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2015-03-24T13:46:07Z |
| bleach | Bleach 366 | anime | [WZF]Bleach_-_248~366 S01 [HD][X264-AAC][1280X720][Sub_Esp][MP4] | 30816391168 | torrent | 2020:Movies/Other, 5070:TV/Anime, 131088: | 2025-07-27T03:04:00Z |
| bleach | Bleach 366 | anime | [lost108] BLEACH S01  - 215-366 - VOSTFR - 1080p - x265 - JAP BDRIP | 156658925568 | torrent | 2020:Movies/Other, 5070:TV/Anime, 131088: | 2026-05-19T15:29:00Z |
| bleach | Bleach 366 | anime | [pursua] Bleach 001-366 S01 (R2J DVD, JPN BD 1080p) | 141411794944 | torrent | 2020:Movies/Other, 5070:TV/Anime, 127720: | 2025-11-29T14:52:00Z |
| bleach | Bleach 366 | anime | [台粵配] BLEACH 死神 S01 (Bleach) (1-366) (Mandarin Chinese + Cantonese Dub) [粵語][國語][国语][中文配音][中配版] | 123587682304 | torrent | 2020:Movies/Other, 5070:TV/Anime, 127720: | 2024-08-02T04:21:00Z |
| bleach | Bleach 366 | anime | [猪猪字幕组] 死神 / Bleach TV 213-366 TVRip 1280x720p x264 AAC 日语 简繁中字 | 44667658240 | torrent | 2020:Movies/Other, 5070:TV/Anime, 131088: | 2020-01-17T01:47:00Z |
| bleach | Bleach 366 | anime | innit's Bleach 168-366 (BD 540p, multi DTS, multi PGS) | 315787476992 | torrent | 2020:Movies/Other, 5070:TV/Anime, 127720: | 2025-05-09T13:21:00Z |
| demon-slayer | Demon Slayer | all | Demon Slayer Kimetsu No Yaiba Infinity Castle 2025 1080p WEB DUAL H264-DJT | 5629335522 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-11T07:46:40Z |
| demon-slayer | Demon Slayer | all | Demon Slayer Kimetsu no Yaiba S01E01 VOSTFR 1080p WEB H.264 AAC -Tsundere-Raws (CR) | 2198059990 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-03-25T16:16:21Z |
| demon-slayer | Demon Slayer | all | Demon Slayer S04E01 2160p WEB H.264 AAC -Tsundere-Raws (B-Global) | 445430134 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-08T11:55:26Z |
| demon-slayer | Demon Slayer | all | Demon Slayer S04E03 2160p WEB H.264 AAC -Tsundere-Raws (B-Global) | 740601913 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-08T11:57:13Z |
| demon-slayer | Demon Slayer | all | Demon Slayer S04E05 2160p WEB H.264 AAC -Tsundere-Raws (B-Global) | 536190262 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-08T12:01:11Z |
| demon-slayer | Demon Slayer | all | Demon.Slayer.Kimetsu.No.Yaiba.Infinity.Castle.2025.1080p.WEB-DL.HCSubbed.AAC.H.264-Cassu | 3698453891 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-12-29T02:14:34Z |
| demon-slayer | Demon Slayer | all | Demon.Slayer.Kimetsu.No.Yaiba.Infinity.Castle.2025.720p.WEB.H264-JFF | 2537789673 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-12-28T23:15:26Z |
| demon-slayer | Demon Slayer | all | Demon.Slayer.Kimetsu.no.Yaiba.2021.S02.Complete.1080p.NF.WEB-DL.H.264.AAC.2Audios-UBWEB | 8240792451 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2025-12-27T13:08:07Z |
| demon-slayer | Demon Slayer | all | Demon.Slayer.Kimetsu.no.Yaiba.2021.S02E07.1080p.NF.WEB-DL.H.264.AAC.2Audios-UBWEB | 1280536478 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2025-12-27T13:00:36Z |
| demon-slayer | Demon Slayer | all | Demon.Slayer.Kimetsu.no.Yaiba.2023.S04.Complete.1080p.NF.WEB-DL.H.264.AAC-UBWEB | 15168128747 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2025-12-27T13:06:35Z |
| demon-slayer | Demon Slayer | all | Demon.Slayer.Kimetsu.no.Yaiba.2024.S05.Complete.1080p.NF.WEB-DL.H.264.AAC-UBWEB | 11476154556 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2025-12-27T13:06:03Z |
| demon-slayer | Demon Slayer | all | Demon.Slayer.Kimetsu.no.Yaiba.Infinity.Castle.2025.1080p.WEB-DL.H.264.Dual YG | 4033496380 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-12-28T23:51:22Z |
| demon-slayer | Demon Slayer | all | Demon.Slayer.Kimetsu.no.Yaiba.Infinity.Castle.2025.PROPER.1080p.WEB-DL.AAC2.0.H.264-FNP | 4017826992 | usenet | 2000:Movies, 2040:Movies/HD, 102000:, 102040: | 2025-12-30T18:28:52Z |
| demon-slayer | Demon Slayer | all | Demon.Slayer.Kimetsu.no.Yaiba.Infinity.Castle.2025.PROPER.1080p.WEB-DL.Spanish.Multi.DD2.0.H.264-FNP | 4388929434 | usenet | 2000:Movies, 2010:Movies/Foreign, 102000:, 102010: | 2025-12-30T20:22:26Z |
| demon-slayer | Demon Slayer | all | Demon.Slayer.Kimetsu.no.Yaiba.S01E03.Sabito.and.Makomo.REPACK.1080p.CR.WEB-DL.DUAL.DDP2.0.H.264-Kitsune | 1892353025 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-01-06T13:31:47Z |
| demon-slayer | Demon Slayer | all | Demon.Slayer.Kimetsu.no.Yaiba.The.Movie.Mugen.Train.2020.ANiME.DUAL.COMPLETE.UHD.BLURAY-iFPD | 69779660775 | usenet | 2000:Movies, 2050:Movies/BluRay, 102000:, 102050: | 2026-05-14T12:33:15Z |
| demon-slayer | Demon Slayer | all | Demon.Slayer.Kimetsu.no.Yaiba.The.Movie.Mugen.Train.2020.ANiME.GERMAN.DL.2160p.UHD.BluRay.HEVC-iFPD | 65306770550 | usenet | 2000:Movies, 2010:Movies/Foreign, 102000:, 102010: | 2026-05-14T17:30:24Z |
| demon-slayer | Demon Slayer | all | Demon.Slayer.Kimetsu.no.Yaiba.The.Movie.Mugen.Train.2020.BluRay.1080p.DDP.Atmos.5.1.x264-hallowed | 9049293177 | usenet | 2000:Movies, 2040:Movies/HD, 102000:, 102040: | 2026-02-08T15:27:14Z |
| demon-slayer | Demon Slayer | all | Demon.Slayer.Kimetsu.no.Yaiba.The.Movie.Mugen.Train.2020.BluRay.1080p.DDP.Atmos.5.1.x264-hallowed | 10550421227 | usenet | 2000:Movies, 2040:Movies/HD, 102000:, 102040: | 2026-02-08T15:37:41Z |
| demon-slayer | Demon Slayer | all | Demon.Slayer.Kimetsu.no.Yaiba.The.Movie.Mugen.Train.2020.German.DL.2160p.UHD.BluRay.x265-STARS | 36885065203 | usenet | 2000:Movies, 2010:Movies/Foreign, 102000:, 102010: | 2026-05-14T08:37:44Z |
| demon-slayer | Demon Slayer | all | Demon.Slayer.Kimetsu.no.Yaiba.The.Movie.Mugen.Train.2020.UHD.BluRay.2160p.DDP.Atmos.5.1.HDR.x265-hallowed | 14644610488 | usenet | 2000:Movies, 2045:Movies/UHD, 102000:, 102045: | 2026-02-08T15:32:16Z |
| demon-slayer | Demon Slayer | all | Demon.Slayer.Kimetsu.no.Yaiba.The.Movie.Mugen.Train.2020.UHD.BluRay.2160p.DDP.Atmos.5.1.HDR.x265-hallowed | 17142018967 | usenet | 2000:Movies, 2045:Movies/UHD, 102000:, 102045: | 2026-02-08T15:49:14Z |
| demon-slayer | Demon Slayer | all | Demon.Slayer.Swordsmith.Village.S01.2023.2160p.WEB-DL.H.264.AAC2.0-CSWEB | 22230046976 | usenet | 5000:TV, 5045:TV/UHD, 105000:, 105045: | 2025-12-31T05:49:22Z |
| demon-slayer | Demon Slayer | all | Demon.Slayer.Swordsmith.Village.S01E01.2023.2160p.WEB-DL.H.264.AAC2.0-CSWEB | 1134465792 | usenet | 5000:TV, 5045:TV/UHD, 105000:, 105045: | 2025-12-31T05:39:09Z |
| demon-slayer | Demon Slayer | all | Demon.Slayer.Swordsmith.Village.S01E02.2023.2160p.WEB-DL.H.264.AAC2.0-CSWEB | 1869429549 | usenet | 5000:TV, 5045:TV/UHD, 105000:, 105045: | 2025-12-31T05:39:58Z |
| demon-slayer | Demon Slayer | all | Demon.Slayer.Swordsmith.Village.S01E03.2023.2160p.WEB-DL.H.264.AAC2.0-CSWEB | 1479009015 | usenet | 5000:TV, 5045:TV/UHD, 105000:, 105045: | 2025-12-31T05:38:39Z |
| demon-slayer | Demon Slayer | all | Demon.Slayer.Swordsmith.Village.S01E04.2023.2160p.WEB-DL.H.264.AAC2.0-CSWEB | 1619406605 | usenet | 5000:TV, 5045:TV/UHD, 105000:, 105045: | 2025-12-31T05:38:30Z |
| demon-slayer | Demon Slayer | all | Demon.Slayer.Swordsmith.Village.S01E05.2023.2160p.WEB-DL.H.264.AAC2.0-CSWEB | 2571544405 | usenet | 5000:TV, 5045:TV/UHD, 105000:, 105045: | 2025-12-31T05:39:42Z |
| demon-slayer | Demon Slayer | all | Demon.Slayer.Swordsmith.Village.S01E06.2023.2160p.WEB-DL.H.264.AAC2.0-CSWEB | 1703341024 | usenet | 5000:TV, 5045:TV/UHD, 105000:, 105045: | 2025-12-31T05:38:58Z |
| demon-slayer | Demon Slayer | all | Demon.Slayer.Swordsmith.Village.S01E07.2023.2160p.WEB-DL.H.264.AAC2.0-CSWEB | 1585933038 | usenet | 5000:TV, 5045:TV/UHD, 105000:, 105045: | 2025-12-31T05:38:35Z |
| demon-slayer | Demon Slayer | all | Demon.Slayer.Swordsmith.Village.S01E08.2023.2160p.WEB-DL.H.264.AAC2.0-CSWEB | 1583890406 | usenet | 5000:TV, 5045:TV/UHD, 105000:, 105045: | 2025-12-31T05:39:54Z |
| demon-slayer | Demon Slayer | all | Demon.Slayer.Swordsmith.Village.S01E09.2023.2160p.WEB-DL.H.264.AAC2.0-CSWEB | 1506644719 | usenet | 5000:TV, 5045:TV/UHD, 105000:, 105045: | 2025-12-31T05:39:54Z |
| demon-slayer | Demon Slayer | all | Demon.Slayer.Swordsmith.Village.S01E10.2023.2160p.WEB-DL.H.264.AAC2.0-CSWEB | 1673676231 | usenet | 5000:TV, 5045:TV/UHD, 105000:, 105045: | 2025-12-31T05:38:38Z |
| demon-slayer | Demon Slayer | all | Demon.Slayer.Swordsmith.Village.S01E11.2023.2160p.WEB-DL.H.264.AAC2.0-CSWEB | 1773803468 | usenet | 5000:TV, 5045:TV/UHD, 105000:, 105045: | 2025-12-31T05:38:21Z |
| demon-slayer | Demon Slayer | all | Demon.Slayer.Swordsmith.Village.S01E12.2023.2160p.WEB-DL.H.264.AAC2.0-CSWEB | 2264599961 | usenet | 5000:TV, 5045:TV/UHD, 105000:, 105045: | 2025-12-31T05:39:22Z |
| demon-slayer | Demon Slayer | all | Demon.Slayer.Swordsmith.Village.S01E13.2023.2160p.WEB-DL.H.264.AAC2.0-CSWEB | 1473453169 | usenet | 5000:TV, 5045:TV/UHD, 105000:, 105045: | 2025-12-31T05:39:11Z |
| demon-slayer | Demon Slayer | all | Yashahime.Princess.Half-Demon.S01E30.Hisui.the.Demon.Slayer.1080p.CR.WEB-DL.DUAL.DDP2.0.H.264-Kitsune | 1691341816 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-02-01T09:35:02Z |
| demon-slayer | Demon Slayer | all | Yashahime.Princess.Half-Demon.S01E30.Hisui.the.Demon.Slayer.1080p.CR.WEB-DL.DUAL.DDP2.0.H.264-Kitsune | 1691341816 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-02-04T02:25:21Z |
| demon-slayer | Demon Slayer | all | Yashahime.Princess.Half-Demon.S01E30.Hisui.the.Demon.Slayer.1080p.CR.WEB-DL.DUAL.DDP2.0.H.264-Kitsune | 1691341816 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-02-07T14:26:44Z |
| demon-slayer | Demon Slayer | all | Yashahime.Princess.Half-Demon.S01E30.Hisui.the.Demon.Slayer.1080p.CR.WEB-DL.DUAL.DDP2.0.H.264-Kitsune | 1691342724 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-02-12T23:21:43Z |
| demon-slayer | Demon Slayer | all | Yashahime.Princess.Half-Demon.S01E35.Hisui.the.Demon.Slayer.1080p.CR.WEB-DL.DUAL.DDP2.0.H.264-Kitsune | 1689732426 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-02-05T00:31:32Z |
| demon-slayer | Demon Slayer | all | Yashahime.Princess.Half-Demon.S01E35.Hisui.the.Demon.Slayer.1080p.CR.WEB-DL.DUAL.DDP2.0.H.264-Kitsune | 1689732426 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-02-07T07:22:24Z |
| demon-slayer | Demon Slayer | all | Yashahime.Princess.Half-Demon.S01E35.Hisui.the.Demon.Slayer.1080p.CR.WEB-DL.DUAL.DDP2.0.H.264-Kitsune | 1689733334 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-02-10T17:43:53Z |
| demon-slayer | Demon Slayer | all | [BlackRabbit] Demon Slayer - Kimetsu no Yaiba (2019) - S01 [Bluray-1080p][Opus 2.0][Dual Audio][AV1] | 720650448 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-22T21:38:01Z |
| demon-slayer | Demon Slayer | all | [BlackRabbit] Demon Slayer - Kimetsu no Yaiba (2019) - S02 [Bluray-1080p][Opus 2.0][Dual Audio][AV1] | 206013186 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-23T03:38:28Z |
| demon-slayer | Demon Slayer | all | [BlackRabbit] Demon Slayer - Kimetsu no Yaiba (2019) - S03 [Bluray-1080p][Opus 2.0][Dual Audio][AV1] | 399543733 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-25T00:49:50Z |
| demon-slayer | Demon Slayer | all | [BlackRabbit] Demon Slayer - Kimetsu no Yaiba (2019) - S04 [Bluray-1080p][Opus 2.0][Dual Audio][AV1] | 384267511 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-26T12:39:39Z |
| demon-slayer | Demon Slayer | all | [BlackRabbit] Demon Slayer - Kimetsu no Yaiba (2019) - S05 [Bluray-1080p][Opus 2.0][Dual Audio][AV1] | 290711076 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-26T18:53:01Z |
| demon-slayer | Demon Slayer | all | [Raze] (Demon Slayer) Kimetsu no Yaiba - Infinity Castle (2025) (Web) x265 10bit 1080p 144fps | 9642876688 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-12-30T00:46:40Z |
| demon-slayer | Demon Slayer | all | [Tenrai-Sensei] Demon Slayer - Kimetsu no Yaiba S4+S5 [BD][1080p][HEVC 10bit x265][Dual Audio]  Katanakaji no Sato-hen (Swordsmith Village Arc) \| Hashira Geiko-hen (Hashira Training Arc) | 16985158562 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-01-02T11:27:28Z |
| demon-slayer | Demon Slayer | anime | Demon Slayer - Kimetsu no Yaiba - Corps Records v01 (2023) (Digital) (1r0n) | 668568787 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-03-18T12:24:16Z |
| demon-slayer | Demon Slayer | anime | Demon Slayer - Kimetsu no Yaiba - Stories of Water and Flame v01 (2022) (Digital) (1r0n) | 290299503 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-03-18T12:24:06Z |
| demon-slayer | Demon Slayer | anime | Demon Slayer - Kimetsu no Yaiba v01 (2018) (Digital) (danke-Empire) | 224149335 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-03-18T12:22:39Z |
| demon-slayer | Demon Slayer | anime | Demon Slayer - Kimetsu no Yaiba v02 (2018) (Digital) (danke-Empire) | 203085621 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-03-18T12:22:43Z |
| demon-slayer | Demon Slayer | anime | Demon Slayer - Kimetsu no Yaiba v03 (2018) (Digital) (danke-Empire) | 198756726 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-03-18T12:22:46Z |
| demon-slayer | Demon Slayer | anime | Demon Slayer - Kimetsu no Yaiba v04 (2019) (Digital) (danke-Empire) | 225558051 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-03-18T12:22:50Z |
| demon-slayer | Demon Slayer | anime | Demon Slayer - Kimetsu no Yaiba v05 (2019) (Digital) (danke-Empire) | 230634543 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-03-18T12:22:54Z |
| demon-slayer | Demon Slayer | anime | Demon Slayer - Kimetsu no Yaiba v06 (2019) (Digital) (danke-Empire) | 209306709 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-03-18T12:22:57Z |
| demon-slayer | Demon Slayer | anime | Demon Slayer - Kimetsu no Yaiba v07 (2019) (Digital) (danke-Empire) | 225324011 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-03-18T12:23:01Z |
| demon-slayer | Demon Slayer | anime | Demon Slayer - Kimetsu no Yaiba v08 (2019) (Digital) (danke-Empire) | 209975449 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-03-18T12:23:04Z |
| demon-slayer | Demon Slayer | anime | Demon Slayer - Kimetsu no Yaiba v09 (2019) (Digital) (danke-Empire) | 220208757 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-03-18T12:23:08Z |
| demon-slayer | Demon Slayer | anime | Demon Slayer - Kimetsu no Yaiba v10 (2020) (Digital) (danke-Empire) | 246893051 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-03-18T12:23:12Z |
| demon-slayer | Demon Slayer | anime | Demon Slayer - Kimetsu no Yaiba v11 (2020) (Digital) (danke-Empire) | 253714867 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-03-18T12:23:16Z |
| demon-slayer | Demon Slayer | anime | Demon Slayer - Kimetsu no Yaiba v12 (2020) (Digital) (danke-Empire) | 216358840 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-03-18T12:23:20Z |
| demon-slayer | Demon Slayer | anime | Demon Slayer - Kimetsu no Yaiba v13 (2020) (Digital) (danke-Empire) | 241884139 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-03-18T12:23:24Z |
| demon-slayer | Demon Slayer | anime | Demon Slayer - Kimetsu no Yaiba v14 (2020) (Digital) (danke-Empire) | 232366382 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-03-18T12:23:27Z |
| demon-slayer | Demon Slayer | anime | Demon Slayer - Kimetsu no Yaiba v15 (2020) (Digital) (danke-Empire) | 222881634 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-03-18T12:23:31Z |
| demon-slayer | Demon Slayer | anime | Demon Slayer - Kimetsu no Yaiba v16 (2020) (Digital) (danke-Empire) | 224840185 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-03-18T12:23:35Z |
| demon-slayer | Demon Slayer | anime | Demon Slayer - Kimetsu no Yaiba v17 (2020) (Digital) (danke-Empire) | 212709849 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-03-18T12:23:38Z |
| demon-slayer | Demon Slayer | anime | Demon Slayer - Kimetsu no Yaiba v18 (2020) (Digital) (danke-Empire) | 211863133 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-03-18T12:23:42Z |
| demon-slayer | Demon Slayer | anime | Demon Slayer - Kimetsu no Yaiba v19 (2020) (Digital) (danke-Empire) | 217237346 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-03-18T12:23:45Z |
| demon-slayer | Demon Slayer | anime | Demon Slayer - Kimetsu no Yaiba v20 (2021) (Digital) (danke-Empire) | 216719382 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-03-18T12:23:49Z |
| demon-slayer | Demon Slayer | anime | Demon Slayer - Kimetsu no Yaiba v21 (2021) (Digital) (danke-Empire) | 209494330 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-03-18T12:23:52Z |
| demon-slayer | Demon Slayer | anime | Demon Slayer - Kimetsu no Yaiba v22 (2021) (Digital) (danke-Empire) | 232757649 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-03-18T12:23:56Z |
| demon-slayer | Demon Slayer | anime | Demon Slayer - Kimetsu no Yaiba v23 (2021) (Digital) (danke-Empire) | 243697573 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-03-18T12:24:00Z |
| demon-slayer | Demon Slayer | anime | Demon Slayer Kimetsu No Yaiba Infinity Castle 2025 1080p WEB DUAL H264-DJT | 5629335522 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-11T07:46:40Z |
| demon-slayer | Demon Slayer | anime | Demon Slayer Kimetsu No Yaiba The Movie Infinity Castle 2025 V2 1080p TELESYNC MULTi x264-SyncUP | 151844059 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-09-27T23:26:27Z |
| demon-slayer | Demon Slayer | anime | Demon Slayer Kimetsu no Yaiba S01E01 VOSTFR 1080p WEB H.264 AAC -Tsundere-Raws (CR) | 2198059990 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-03-25T16:16:21Z |
| demon-slayer | Demon Slayer | anime | Demon Slayer S04E01 2160p WEB H.264 AAC -Tsundere-Raws (B-Global) | 445430134 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-08T11:55:26Z |
| demon-slayer | Demon Slayer | anime | Demon Slayer S04E03 2160p WEB H.264 AAC -Tsundere-Raws (B-Global) | 740601913 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-08T11:57:13Z |
| demon-slayer | Demon Slayer | anime | Demon Slayer S04E05 2160p WEB H.264 AAC -Tsundere-Raws (B-Global) | 536190262 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-08T12:01:11Z |
| demon-slayer | Demon Slayer | anime | Demon Slayer： Kimetsu no Yaiba Infinity Castle Trailer [Prores 4444 1080p FLAC 5.1 DCP Rip] | 2895283200 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-09-13T09:31:56Z |
| demon-slayer | Demon Slayer | anime | Demon.Slayer.Infinity.Castle | 4856088565 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-07-20T21:35:01Z |
| demon-slayer | Demon Slayer | anime | Demon.Slayer.Kimetsu.No.Yaiba.Infinity.Castle.2025.1080p.WEB-DL.HCSubbed.AAC.H.264-Cassu | 3698453891 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-12-29T02:14:34Z |
| demon-slayer | Demon Slayer | anime | Demon.Slayer.Kimetsu.No.Yaiba.Infinity.Castle.2025.720p.WEB.H264-JFF | 2537789673 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-12-28T23:15:26Z |
| demon-slayer | Demon Slayer | anime | Demon.Slayer.Kimetsu.No.Yaiba.The | 8054717841 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-09-17T15:46:02Z |
| demon-slayer | Demon Slayer | anime | Demon.Slayer.Kimetsu.No.Yaiba.The | 9621504403 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-09-27T23:38:51Z |
| demon-slayer | Demon Slayer | anime | Demon.Slayer.Kimetsu.no.Yaiba.Infinity.Castle.2025.1080p.WEB-DL.H.264.Dual YG | 4033496380 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-12-28T23:51:22Z |
| demon-slayer | Demon Slayer | anime | Demon.Slayer.Kimetsu.no.Yaiba.Infinity.Castle.2025.V2.2160p.SDR.HDTC.JAPANESE.x264.ESub-HDHub4u.Ms | 14844510237 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-07-24T09:17:01Z |
| demon-slayer | Demon Slayer | anime | [BlackRabbit] Demon Slayer - Kimetsu no Yaiba (2019) - S01 [Bluray-1080p][Opus 2.0][Dual Audio][AV1] | 720650448 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-22T21:38:01Z |
| demon-slayer | Demon Slayer | anime | [BlackRabbit] Demon Slayer - Kimetsu no Yaiba (2019) - S02 [Bluray-1080p][Opus 2.0][Dual Audio][AV1] | 206013186 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-23T03:38:28Z |
| demon-slayer | Demon Slayer | anime | [BlackRabbit] Demon Slayer - Kimetsu no Yaiba (2019) - S03 [Bluray-1080p][Opus 2.0][Dual Audio][AV1] | 399543733 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-25T00:49:50Z |
| demon-slayer | Demon Slayer | anime | [BlackRabbit] Demon Slayer - Kimetsu no Yaiba (2019) - S04 [Bluray-1080p][Opus 2.0][Dual Audio][AV1] | 384267511 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-26T12:39:39Z |
| demon-slayer | Demon Slayer | anime | [BlackRabbit] Demon Slayer - Kimetsu no Yaiba (2019) - S05 [Bluray-1080p][Opus 2.0][Dual Audio][AV1] | 290711076 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-26T18:53:01Z |
| demon-slayer | Demon Slayer | anime | [DB] Kimetsu no Yaiba: Hashira Geiko-hen \| Demon Slayer: Kimetsu no Yaiba Hashira Training Arc [Dual Audio 10bit BD1080p][HEVC-x265] | 184808262 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-05-25T14:18:35Z |
| demon-slayer | Demon Slayer | anime | [KNY LEAKS] Demon Slayer - Infinity Castle Movie (CAMRIP) ENG Sub | 8161860496 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-07-21T01:28:01Z |
| demon-slayer | Demon Slayer | anime | [Raze] (Demon Slayer) Kimetsu no Yaiba - Infinity Castle (2025) (Web) x265 10bit 1080p 144fps | 9642876688 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-12-30T00:46:40Z |
| demon-slayer | Demon Slayer | anime | [Seimeisen] Demon Slayer - Infinity Castle Movie (Camrip) VOSTFR V3 [Multiple Subs] | 2548216850 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-07-26T03:05:41Z |
| demon-slayer | Demon Slayer | anime | [Tenrai-Sensei] Demon Slayer - Kimetsu no Yaiba S4+S5 [BD][1080p][HEVC 10bit x265][Dual Audio]  Katanakaji no Sato-hen (Swordsmith Village Arc) \| Hashira Geiko-hen (Hashira Training Arc) | 16985158562 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-01-02T11:27:28Z |
| demon-slayer | Demon Slayer | anime | [Trix] Kimetsu no Yaiba S01-05 [Dual Audio] [Multi Subs] (BD 1080p AV1) - Demon Slayer VOSTFR (Batch) | 24298416001 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-09-01T11:35:07Z |
| demon-slayer | Kimetsu no Yaiba | all | Demon Slayer Kimetsu No Yaiba Infinity Castle 2025 1080p WEB DUAL H264-DJT | 5629335522 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-11T07:46:40Z |
| demon-slayer | Kimetsu no Yaiba | all | [BlackRabbit] Demon Slayer - Kimetsu no Yaiba (2019) - S01 [Bluray-1080p][Opus 2.0][Dual Audio][AV1] | 720650448 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-22T21:38:01Z |
| demon-slayer | Kimetsu no Yaiba | all | [BlackRabbit] Demon Slayer - Kimetsu no Yaiba (2019) - S02 [Bluray-1080p][Opus 2.0][Dual Audio][AV1] | 206013186 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-23T03:38:28Z |
| demon-slayer | Kimetsu no Yaiba | all | [BlackRabbit] Demon Slayer - Kimetsu no Yaiba (2019) - S03 [Bluray-1080p][Opus 2.0][Dual Audio][AV1] | 399543733 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-25T00:49:50Z |
| demon-slayer | Kimetsu no Yaiba | all | [BlackRabbit] Demon Slayer - Kimetsu no Yaiba (2019) - S04 [Bluray-1080p][Opus 2.0][Dual Audio][AV1] | 384267511 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-26T12:39:39Z |
| demon-slayer | Kimetsu no Yaiba | all | [BlackRabbit] Demon Slayer - Kimetsu no Yaiba (2019) - S05 [Bluray-1080p][Opus 2.0][Dual Audio][AV1] | 290711076 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-26T18:53:01Z |
| demon-slayer | Kimetsu no Yaiba | all | [Mo7tas] Kimetsu no Yaiba - S01E08 [BD 1080p] [Mugi - ARsub - kiyoshiisubs - NETFLIX - StarzPlay - Hunter Subs] | 397877146 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T11:59:48Z |
| demon-slayer | Kimetsu no Yaiba | all | [Mo7tas] Kimetsu no Yaiba - S01E09 [BD 1080p] [Mugi - ARsub - kiyoshiisubs - NETFLIX - StarzPlay - Hunter Subs] | 403353094 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:02:24Z |
| demon-slayer | Kimetsu no Yaiba | all | [Mo7tas] Kimetsu no Yaiba - S01E10 [BD 1080p] [Mugi - ARsub - kiyoshiisubs - NETFLIX - StarzPlay - Hunter Subs] | 383799713 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:02:31Z |
| demon-slayer | Kimetsu no Yaiba | all | [Mo7tas] Kimetsu no Yaiba - S01E11 [BD 1080p] [Mugi - ARsub - kiyoshiisubs - NETFLIX - StarzPlay - Hunter Subs] | 398414564 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:03:27Z |
| demon-slayer | Kimetsu no Yaiba | all | [Mo7tas] Kimetsu no Yaiba - S01E12 [BD 1080p] [Mugi - ARsub - kiyoshiisubs - NETFLIX - StarzPlay - Hunter Subs] | 361363866 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:02:31Z |
| demon-slayer | Kimetsu no Yaiba | all | [Mo7tas] Kimetsu no Yaiba - S01E13 [BD 1080p] [Mugi - ARsub - kiyoshiisubs - NETFLIX - StarzPlay - Hunter Subs] | 446823328 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:03:32Z |
| demon-slayer | Kimetsu no Yaiba | all | [Mo7tas] Kimetsu no Yaiba - S01E14 [BD 1080p] [Mugi - ARsub - kiyoshiisubs - NETFLIX - StarzPlay - Hunter Subs] | 387372546 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:03:20Z |
| demon-slayer | Kimetsu no Yaiba | all | [Mo7tas] Kimetsu no Yaiba - S01E15 [BD 1080p] [Mugi - ARsub - kiyoshiisubs - NETFLIX - StarzPlay - Hunter Subs] | 379607455 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:04:19Z |
| demon-slayer | Kimetsu no Yaiba | all | [Mo7tas] Kimetsu no Yaiba - S01E16 [BD 1080p] [Mugi - ARsub - kiyoshiisubs - NETFLIX - StarzPlay - Hunter Subs] | 387485457 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:05:04Z |
| demon-slayer | Kimetsu no Yaiba | all | [Mo7tas] Kimetsu no Yaiba - S01E17 [BD 1080p] [Mugi - ARsub - kiyoshiisubs - NETFLIX - StarzPlay - Hunter Subs] | 395884010 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:05:04Z |
| demon-slayer | Kimetsu no Yaiba | all | [Mo7tas] Kimetsu no Yaiba - S01E18 [BD 1080p] [Mugi - ARsub - kiyoshiisubs - NETFLIX - StarzPlay - Hunter Subs] | 362182512 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:04:28Z |
| demon-slayer | Kimetsu no Yaiba | all | [Mo7tas] Kimetsu no Yaiba - S01E19 [BD 1080p] [Mugi - ARsub - kiyoshiisubs - NETFLIX - StarzPlay - Hunter Subs] | 389420249 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:05:06Z |
| demon-slayer | Kimetsu no Yaiba | all | [Mo7tas] Kimetsu no Yaiba - S01E22 [BD 1080p] [Mugi - ARsub - kiyoshiisubs - NETFLIX - StarzPlay - Hunter Subs] | 336107311 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:04:47Z |
| demon-slayer | Kimetsu no Yaiba | all | [Mo7tas] Kimetsu no Yaiba - S01E23 [BD 1080p] [Mugi - ARsub - kiyoshiisubs - NETFLIX - StarzPlay - Hunter Subs] | 325151614 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:06:04Z |
| demon-slayer | Kimetsu no Yaiba | all | [Mo7tas] Kimetsu no Yaiba - S01E24 [BD 1080p] [Mugi - ARsub - kiyoshiisubs - NETFLIX - StarzPlay - Hunter Subs] | 377132725 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:05:54Z |
| demon-slayer | Kimetsu no Yaiba | all | [Mo7tas] Kimetsu no Yaiba - S01E25 [BD 1080p] [Mugi - ARsub - kiyoshiisubs - NETFLIX - StarzPlay - Hunter Subs] | 421345562 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:05:53Z |
| demon-slayer | Kimetsu no Yaiba | all | [Mo7tas] Kimetsu no Yaiba - S01E26 [BD 1080p] [Mugi - ARsub - kiyoshiisubs - NETFLIX - StarzPlay] | 315751763 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:06:43Z |
| demon-slayer | Kimetsu no Yaiba | all | [Mo7tas] Kimetsu no Yaiba∶ Hashira Geiko-hen - S05E01 [BD 1080p] [Mugi - Crunchyroll - kiyoshiisubs] | 860446564 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T11:56:58Z |
| demon-slayer | Kimetsu no Yaiba | all | [Mo7tas] Kimetsu no Yaiba∶ Hashira Geiko-hen - S05E02 [BD 1080p] [Mugi - Crunchyroll - kiyoshiisubs] | 394727165 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:15:32Z |
| demon-slayer | Kimetsu no Yaiba | all | [Mo7tas] Kimetsu no Yaiba∶ Hashira Geiko-hen - S05E03 [BD 1080p] [Mugi - Crunchyroll - kiyoshiisubs] | 482743947 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:17:31Z |
| demon-slayer | Kimetsu no Yaiba | all | [Mo7tas] Kimetsu no Yaiba∶ Hashira Geiko-hen - S05E05 [BD 1080p] [Mugi - Crunchyroll - kiyoshiisubs] | 577093449 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T11:55:17Z |
| demon-slayer | Kimetsu no Yaiba | all | [Mo7tas] Kimetsu no Yaiba∶ Hashira Geiko-hen - S05E06 [BD 1080p] [Mugi - Crunchyroll - kiyoshiisubs] | 495648622 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T11:54:49Z |
| demon-slayer | Kimetsu no Yaiba | all | [Mo7tas] Kimetsu no Yaiba∶ Hashira Geiko-hen - S05E07 [BD 1080p] [Mugi - Crunchyroll - kiyoshiisubs] | 590987098 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:18:59Z |
| demon-slayer | Kimetsu no Yaiba | all | [Mo7tas] Kimetsu no Yaiba∶ Katanakaji no Sato-hen - S04E01 [BD 1080p] [Mugi - Crunchyroll - kiyoshiisubs] | 721336282 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:16:57Z |
| demon-slayer | Kimetsu no Yaiba | all | [Mo7tas] Kimetsu no Yaiba∶ Katanakaji no Sato-hen - S04E02 [BD 1080p] [Mugi - Crunchyroll - kiyoshiisubs] | 408907209 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:15:24Z |
| demon-slayer | Kimetsu no Yaiba | all | [Mo7tas] Kimetsu no Yaiba∶ Katanakaji no Sato-hen - S04E06 [BD 1080p] [Mugi - Crunchyroll - kiyoshiisubs] | 397408864 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:15:31Z |
| demon-slayer | Kimetsu no Yaiba | all | [Mo7tas] Kimetsu no Yaiba∶ Katanakaji no Sato-hen - S04E08 [BD 1080p] [Mugi - Crunchyroll - kiyoshiisubs] | 412546333 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:15:22Z |
| demon-slayer | Kimetsu no Yaiba | all | [Mo7tas] Kimetsu no Yaiba∶ Katanakaji no Sato-hen - S04E10 [BD 1080p] [Mugi - Crunchyroll - kiyoshiisubs] | 885931521 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T11:54:52Z |
| demon-slayer | Kimetsu no Yaiba | all | [Mo7tas] Kimetsu no Yaiba∶ Katanakaji no Sato-hen - S04E11 [BD 1080p] [Mugi - Crunchyroll - kiyoshiisubs] | 926005470 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:20:49Z |
| demon-slayer | Kimetsu no Yaiba | all | [Mo7tas] Kimetsu no Yaiba∶ Mugen Ressha-hen - S02E05 [BD 1080p] [Mugi - Crunchyroll - kiyoshiisubs - NETFLIX - StarzPlay] | 489283982 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:07:19Z |
| demon-slayer | Kimetsu no Yaiba | all | [Mo7tas] Kimetsu no Yaiba∶ Mugen Ressha-hen - S02E07 [BD 1080p] [Mugi - Crunchyroll - kiyoshiisubs - NETFLIX - StarzPlay] | 377583064 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:07:01Z |
| demon-slayer | Kimetsu no Yaiba | all | [Mo7tas] Kimetsu no Yaiba∶ Yuukaku-hen - S03E01 [BD 1080p] [Mugi - Crunchyroll - kiyoshiisubs - NETFLIX - StarzPlay] | 874374990 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:10:50Z |
| demon-slayer | Kimetsu no Yaiba | all | [Mo7tas] Kimetsu no Yaiba∶ Yuukaku-hen - S03E02 [BD 1080p] [Mugi - Crunchyroll - kiyoshiisubs - NETFLIX - StarzPlay] | 525130449 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:10:04Z |
| demon-slayer | Kimetsu no Yaiba | all | [Mo7tas] Kimetsu no Yaiba∶ Yuukaku-hen - S03E03 [BD 1080p] [Mugi - Crunchyroll - kiyoshiisubs - NETFLIX - StarzPlay] | 430852233 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:08:33Z |
| demon-slayer | Kimetsu no Yaiba | all | [Mo7tas] Kimetsu no Yaiba∶ Yuukaku-hen - S03E04 [BD 1080p] [Mugi - Crunchyroll - kiyoshiisubs - NETFLIX - StarzPlay] | 400915487 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:09:46Z |
| demon-slayer | Kimetsu no Yaiba | all | [Mo7tas] Kimetsu no Yaiba∶ Yuukaku-hen - S03E05 [BD 1080p] [Mugi - Crunchyroll - kiyoshiisubs - NETFLIX - StarzPlay] | 431490049 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:09:54Z |
| demon-slayer | Kimetsu no Yaiba | all | [Mo7tas] Kimetsu no Yaiba∶ Yuukaku-hen - S03E06 [BD 1080p] [Mugi - Crunchyroll - kiyoshiisubs - NETFLIX - StarzPlay] | 534850633 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:11:16Z |
| demon-slayer | Kimetsu no Yaiba | all | [Mo7tas] Kimetsu no Yaiba∶ Yuukaku-hen - S03E07 [BD 1080p] [Mugi - Crunchyroll - kiyoshiisubs - NETFLIX - StarzPlay] | 446073954 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:11:12Z |
| demon-slayer | Kimetsu no Yaiba | all | [Mo7tas] Kimetsu no Yaiba∶ Yuukaku-hen - S03E08 [BD 1080p] [Mugi - Crunchyroll - kiyoshiisubs - NETFLIX - StarzPlay] | 479962679 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:12:19Z |
| demon-slayer | Kimetsu no Yaiba | all | [Mo7tas] Kimetsu no Yaiba∶ Yuukaku-hen - S03E09 [BD 1080p] [Mugi - Crunchyroll - kiyoshiisubs - NETFLIX - StarzPlay] | 675271392 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:13:17Z |
| demon-slayer | Kimetsu no Yaiba | all | [Mo7tas] Kimetsu no Yaiba∶ Yuukaku-hen - S03E10 [BD 1080p] [Mugi - Crunchyroll - kiyoshiisubs - NETFLIX - StarzPlay] | 629717458 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:14:45Z |
| demon-slayer | Kimetsu no Yaiba | all | [Mo7tas] Kimetsu no Yaiba∶ Yuukaku-hen - S03E11 [BD 1080p] [Mugi - Crunchyroll - kiyoshiisubs - NETFLIX - StarzPlay] | 442635752 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:13:56Z |
| demon-slayer | Kimetsu no Yaiba | all | [Mo7tas] [2020] Kimetsu no Yaiba Movie∶ Mugen Ressha-hen - S00E02 [BD 1080p] [Mugi] | 1818553519 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:10:15Z |
| demon-slayer | Kimetsu no Yaiba | all | [ShouryuuReppa] Kimetsu no Yaiba  Katanakaji no Sato-hen 11 1080p [HEVC][x265][10bit][AAC] | 205286627 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-07T11:49:46Z |
| demon-slayer | Kimetsu no Yaiba | anime | Demon Slayer Kimetsu No Yaiba Infinity Castle 2025 1080p WEB DUAL H264-DJT | 5629335522 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-11T07:46:40Z |
| demon-slayer | Kimetsu no Yaiba | anime | [BlackRabbit] Demon Slayer - Kimetsu no Yaiba (2019) - S01 [Bluray-1080p][Opus 2.0][Dual Audio][AV1] | 720650448 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-22T21:38:01Z |
| demon-slayer | Kimetsu no Yaiba | anime | [BlackRabbit] Demon Slayer - Kimetsu no Yaiba (2019) - S02 [Bluray-1080p][Opus 2.0][Dual Audio][AV1] | 206013186 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-23T03:38:28Z |
| demon-slayer | Kimetsu no Yaiba | anime | [BlackRabbit] Demon Slayer - Kimetsu no Yaiba (2019) - S03 [Bluray-1080p][Opus 2.0][Dual Audio][AV1] | 399543733 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-25T00:49:50Z |
| demon-slayer | Kimetsu no Yaiba | anime | [BlackRabbit] Demon Slayer - Kimetsu no Yaiba (2019) - S04 [Bluray-1080p][Opus 2.0][Dual Audio][AV1] | 384267511 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-26T12:39:39Z |
| demon-slayer | Kimetsu no Yaiba | anime | [BlackRabbit] Demon Slayer - Kimetsu no Yaiba (2019) - S05 [Bluray-1080p][Opus 2.0][Dual Audio][AV1] | 290711076 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-26T18:53:01Z |
| demon-slayer | Kimetsu no Yaiba | anime | [Mo7tas] Kimetsu no Yaiba - S01E08 [BD 1080p] [Mugi - ARsub - kiyoshiisubs - NETFLIX - StarzPlay - Hunter Subs] | 397877146 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T11:59:48Z |
| demon-slayer | Kimetsu no Yaiba | anime | [Mo7tas] Kimetsu no Yaiba - S01E09 [BD 1080p] [Mugi - ARsub - kiyoshiisubs - NETFLIX - StarzPlay - Hunter Subs] | 403353094 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:02:24Z |
| demon-slayer | Kimetsu no Yaiba | anime | [Mo7tas] Kimetsu no Yaiba - S01E10 [BD 1080p] [Mugi - ARsub - kiyoshiisubs - NETFLIX - StarzPlay - Hunter Subs] | 383799713 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:02:31Z |
| demon-slayer | Kimetsu no Yaiba | anime | [Mo7tas] Kimetsu no Yaiba - S01E11 [BD 1080p] [Mugi - ARsub - kiyoshiisubs - NETFLIX - StarzPlay - Hunter Subs] | 398414564 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:03:27Z |
| demon-slayer | Kimetsu no Yaiba | anime | [Mo7tas] Kimetsu no Yaiba - S01E12 [BD 1080p] [Mugi - ARsub - kiyoshiisubs - NETFLIX - StarzPlay - Hunter Subs] | 361363866 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:02:31Z |
| demon-slayer | Kimetsu no Yaiba | anime | [Mo7tas] Kimetsu no Yaiba - S01E13 [BD 1080p] [Mugi - ARsub - kiyoshiisubs - NETFLIX - StarzPlay - Hunter Subs] | 446823328 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:03:32Z |
| demon-slayer | Kimetsu no Yaiba | anime | [Mo7tas] Kimetsu no Yaiba - S01E14 [BD 1080p] [Mugi - ARsub - kiyoshiisubs - NETFLIX - StarzPlay - Hunter Subs] | 387372546 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:03:20Z |
| demon-slayer | Kimetsu no Yaiba | anime | [Mo7tas] Kimetsu no Yaiba - S01E15 [BD 1080p] [Mugi - ARsub - kiyoshiisubs - NETFLIX - StarzPlay - Hunter Subs] | 379607455 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:04:19Z |
| demon-slayer | Kimetsu no Yaiba | anime | [Mo7tas] Kimetsu no Yaiba - S01E16 [BD 1080p] [Mugi - ARsub - kiyoshiisubs - NETFLIX - StarzPlay - Hunter Subs] | 387485457 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:05:04Z |
| demon-slayer | Kimetsu no Yaiba | anime | [Mo7tas] Kimetsu no Yaiba - S01E17 [BD 1080p] [Mugi - ARsub - kiyoshiisubs - NETFLIX - StarzPlay - Hunter Subs] | 395884010 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:05:04Z |
| demon-slayer | Kimetsu no Yaiba | anime | [Mo7tas] Kimetsu no Yaiba - S01E18 [BD 1080p] [Mugi - ARsub - kiyoshiisubs - NETFLIX - StarzPlay - Hunter Subs] | 362182512 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:04:28Z |
| demon-slayer | Kimetsu no Yaiba | anime | [Mo7tas] Kimetsu no Yaiba - S01E19 [BD 1080p] [Mugi - ARsub - kiyoshiisubs - NETFLIX - StarzPlay - Hunter Subs] | 389420249 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:05:06Z |
| demon-slayer | Kimetsu no Yaiba | anime | [Mo7tas] Kimetsu no Yaiba - S01E22 [BD 1080p] [Mugi - ARsub - kiyoshiisubs - NETFLIX - StarzPlay - Hunter Subs] | 336107311 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:04:47Z |
| demon-slayer | Kimetsu no Yaiba | anime | [Mo7tas] Kimetsu no Yaiba - S01E23 [BD 1080p] [Mugi - ARsub - kiyoshiisubs - NETFLIX - StarzPlay - Hunter Subs] | 325151614 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:06:04Z |
| demon-slayer | Kimetsu no Yaiba | anime | [Mo7tas] Kimetsu no Yaiba - S01E24 [BD 1080p] [Mugi - ARsub - kiyoshiisubs - NETFLIX - StarzPlay - Hunter Subs] | 377132725 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:05:54Z |
| demon-slayer | Kimetsu no Yaiba | anime | [Mo7tas] Kimetsu no Yaiba - S01E25 [BD 1080p] [Mugi - ARsub - kiyoshiisubs - NETFLIX - StarzPlay - Hunter Subs] | 421345562 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:05:53Z |
| demon-slayer | Kimetsu no Yaiba | anime | [Mo7tas] Kimetsu no Yaiba - S01E26 [BD 1080p] [Mugi - ARsub - kiyoshiisubs - NETFLIX - StarzPlay] | 315751763 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:06:43Z |
| demon-slayer | Kimetsu no Yaiba | anime | [Mo7tas] Kimetsu no Yaiba∶ Hashira Geiko-hen - S05E01 [BD 1080p] [Mugi - Crunchyroll - kiyoshiisubs] | 860446564 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T11:56:58Z |
| demon-slayer | Kimetsu no Yaiba | anime | [Mo7tas] Kimetsu no Yaiba∶ Hashira Geiko-hen - S05E02 [BD 1080p] [Mugi - Crunchyroll - kiyoshiisubs] | 394727165 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:15:32Z |
| demon-slayer | Kimetsu no Yaiba | anime | [Mo7tas] Kimetsu no Yaiba∶ Hashira Geiko-hen - S05E03 [BD 1080p] [Mugi - Crunchyroll - kiyoshiisubs] | 482743947 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:17:31Z |
| demon-slayer | Kimetsu no Yaiba | anime | [Mo7tas] Kimetsu no Yaiba∶ Hashira Geiko-hen - S05E05 [BD 1080p] [Mugi - Crunchyroll - kiyoshiisubs] | 577093449 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T11:55:17Z |
| demon-slayer | Kimetsu no Yaiba | anime | [Mo7tas] Kimetsu no Yaiba∶ Hashira Geiko-hen - S05E06 [BD 1080p] [Mugi - Crunchyroll - kiyoshiisubs] | 495648622 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T11:54:49Z |
| demon-slayer | Kimetsu no Yaiba | anime | [Mo7tas] Kimetsu no Yaiba∶ Hashira Geiko-hen - S05E07 [BD 1080p] [Mugi - Crunchyroll - kiyoshiisubs] | 590987098 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:18:59Z |
| demon-slayer | Kimetsu no Yaiba | anime | [Mo7tas] Kimetsu no Yaiba∶ Katanakaji no Sato-hen - S04E01 [BD 1080p] [Mugi - Crunchyroll - kiyoshiisubs] | 721336282 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:16:57Z |
| demon-slayer | Kimetsu no Yaiba | anime | [Mo7tas] Kimetsu no Yaiba∶ Katanakaji no Sato-hen - S04E02 [BD 1080p] [Mugi - Crunchyroll - kiyoshiisubs] | 408907209 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:15:24Z |
| demon-slayer | Kimetsu no Yaiba | anime | [Mo7tas] Kimetsu no Yaiba∶ Katanakaji no Sato-hen - S04E06 [BD 1080p] [Mugi - Crunchyroll - kiyoshiisubs] | 397408864 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:15:31Z |
| demon-slayer | Kimetsu no Yaiba | anime | [Mo7tas] Kimetsu no Yaiba∶ Katanakaji no Sato-hen - S04E08 [BD 1080p] [Mugi - Crunchyroll - kiyoshiisubs] | 412546333 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:15:22Z |
| demon-slayer | Kimetsu no Yaiba | anime | [Mo7tas] Kimetsu no Yaiba∶ Katanakaji no Sato-hen - S04E10 [BD 1080p] [Mugi - Crunchyroll - kiyoshiisubs] | 885931521 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T11:54:52Z |
| demon-slayer | Kimetsu no Yaiba | anime | [Mo7tas] Kimetsu no Yaiba∶ Katanakaji no Sato-hen - S04E11 [BD 1080p] [Mugi - Crunchyroll - kiyoshiisubs] | 926005470 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:20:49Z |
| demon-slayer | Kimetsu no Yaiba | anime | [Mo7tas] Kimetsu no Yaiba∶ Mugen Ressha-hen - S02E05 [BD 1080p] [Mugi - Crunchyroll - kiyoshiisubs - NETFLIX - StarzPlay] | 489283982 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:07:19Z |
| demon-slayer | Kimetsu no Yaiba | anime | [Mo7tas] Kimetsu no Yaiba∶ Mugen Ressha-hen - S02E07 [BD 1080p] [Mugi - Crunchyroll - kiyoshiisubs - NETFLIX - StarzPlay] | 377583064 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:07:01Z |
| demon-slayer | Kimetsu no Yaiba | anime | [Mo7tas] Kimetsu no Yaiba∶ Yuukaku-hen - S03E01 [BD 1080p] [Mugi - Crunchyroll - kiyoshiisubs - NETFLIX - StarzPlay] | 874374990 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:10:50Z |
| demon-slayer | Kimetsu no Yaiba | anime | [Mo7tas] Kimetsu no Yaiba∶ Yuukaku-hen - S03E02 [BD 1080p] [Mugi - Crunchyroll - kiyoshiisubs - NETFLIX - StarzPlay] | 525130449 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:10:04Z |
| demon-slayer | Kimetsu no Yaiba | anime | [Mo7tas] Kimetsu no Yaiba∶ Yuukaku-hen - S03E03 [BD 1080p] [Mugi - Crunchyroll - kiyoshiisubs - NETFLIX - StarzPlay] | 430852233 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:08:33Z |
| demon-slayer | Kimetsu no Yaiba | anime | [Mo7tas] Kimetsu no Yaiba∶ Yuukaku-hen - S03E04 [BD 1080p] [Mugi - Crunchyroll - kiyoshiisubs - NETFLIX - StarzPlay] | 400915487 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:09:46Z |
| demon-slayer | Kimetsu no Yaiba | anime | [Mo7tas] Kimetsu no Yaiba∶ Yuukaku-hen - S03E05 [BD 1080p] [Mugi - Crunchyroll - kiyoshiisubs - NETFLIX - StarzPlay] | 431490049 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:09:54Z |
| demon-slayer | Kimetsu no Yaiba | anime | [Mo7tas] Kimetsu no Yaiba∶ Yuukaku-hen - S03E06 [BD 1080p] [Mugi - Crunchyroll - kiyoshiisubs - NETFLIX - StarzPlay] | 534850633 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:11:16Z |
| demon-slayer | Kimetsu no Yaiba | anime | [Mo7tas] Kimetsu no Yaiba∶ Yuukaku-hen - S03E07 [BD 1080p] [Mugi - Crunchyroll - kiyoshiisubs - NETFLIX - StarzPlay] | 446073954 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:11:12Z |
| demon-slayer | Kimetsu no Yaiba | anime | [Mo7tas] Kimetsu no Yaiba∶ Yuukaku-hen - S03E08 [BD 1080p] [Mugi - Crunchyroll - kiyoshiisubs - NETFLIX - StarzPlay] | 479962679 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:12:19Z |
| demon-slayer | Kimetsu no Yaiba | anime | [Mo7tas] Kimetsu no Yaiba∶ Yuukaku-hen - S03E09 [BD 1080p] [Mugi - Crunchyroll - kiyoshiisubs - NETFLIX - StarzPlay] | 675271392 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:13:17Z |
| demon-slayer | Kimetsu no Yaiba | anime | [Mo7tas] Kimetsu no Yaiba∶ Yuukaku-hen - S03E10 [BD 1080p] [Mugi - Crunchyroll - kiyoshiisubs - NETFLIX - StarzPlay] | 629717458 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:14:45Z |
| demon-slayer | Kimetsu no Yaiba | anime | [Mo7tas] Kimetsu no Yaiba∶ Yuukaku-hen - S03E11 [BD 1080p] [Mugi - Crunchyroll - kiyoshiisubs - NETFLIX - StarzPlay] | 442635752 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:13:56Z |
| demon-slayer | Kimetsu no Yaiba | anime | [Mo7tas] [2020] Kimetsu no Yaiba Movie∶ Mugen Ressha-hen - S00E02 [BD 1080p] [Mugi] | 1818553519 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T12:10:15Z |
| demon-slayer | Kimetsu no Yaiba | anime | [ShouryuuReppa] Kimetsu no Yaiba  Katanakaji no Sato-hen 11 1080p [HEVC][x265][10bit][AAC] | 205286627 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-07T11:49:46Z |
| one-piece | One Piece | all | ONE.PIECE.HEROINES.2026.1080p.BILI.WEB-DL.JPN.AAC2.0.H.265.MSubs-ToonsHub | 388702135 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-08T23:12:22Z |
| one-piece | One Piece | all | ONE.PIECE.HEROINES.2026.2160p.BILI.WEB-DL.JPN.AAC2.0.H.264.MSubs-ToonsHub | 1312587019 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-08T23:15:30Z |
| one-piece | One Piece | all | ONE.PIECE.HEROINES.2026.REPACK.1080p.CR.WEB-DL.DDP2.0.H.264-AnoZu | 1658206765 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-10T20:12:51Z |
| one-piece | One Piece | all | ONE.PIECE.HEROINES.Nami.S01E01.1080p.ADN.WEB-DL.AAC2.0.H.264-FRSTREAM | 685420404 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-07-09T22:42:12Z |
| one-piece | One Piece | all | One Piece - 1101v2 - 720p WEB x264 -NanDesuKa (CR) | 103312479 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-07T00:58:38Z |
| one-piece | One Piece | all | One Piece - Heroines [H3LL][1080p][x264][10bit][AAC][Multi-Subs] | 1346593319 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-08T21:03:33Z |
| one-piece | One Piece | all | One Piece Episode 1025 - 1036 [English Dub][720p][Crunchyroll] | 734249970 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-10T13:03:44Z |
| one-piece | One Piece | all | One.Piece.EP1169.1080p.iQ.WEB-DL.JPN.AAC2.0.H.264.MSubs-ToonsHub | 313584436 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-12T15:57:49Z |
| one-piece | One Piece | all | One.Piece.EP1169.The.Legend.Lurking.in.Elbaph.The.Identity.of.the.Mountain-Eater.1080p.CR.WEB-DL.JPN.AAC2.0.H.264.ESub-ToonsHub | 1643586016 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-12T16:20:35Z |
| one-piece | One Piece | all | One.Piece.EP1169.The.Legend.Lurking.in.Elbaph.The.Identity.of.the.Mountain-Eater.1080p.CR.WEB-DL.JPN.AAC2.0.H.264.ESub-ToonsHub | 1790717315 | usenet | 2000:Movies, 2040:Movies/HD, 102000:, 102040: | 2026-07-12T16:26:53Z |
| one-piece | One Piece | all | One.Piece.Heroines.2026.1080p.CR.WEB-DL.JPN.AAC2.0.H.264.MSubs-ToonsHub | 1624093525 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-08T20:15:12Z |
| one-piece | One Piece | all | One.Piece.Heroines.2026.1080p.NF.WEB-DL.AAC2.0.H.264-VARYG | 1018246526 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-11T18:50:59Z |
| one-piece | One Piece | all | One.Piece.Heroines.2026.1080p.NF.WEB-DL.AAC2.0.H.264-VARYG | 1110023394 | usenet | 2000:Movies, 2040:Movies/HD, 102000:, 102040: | 2026-07-11T07:58:59Z |
| one-piece | One Piece | all | One.Piece.Heroines.2026.1080p.NF.WEB-DL.JPN.AAC2.0.H.264.MSubs-ToonsHub | 1018284610 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-11T18:38:13Z |
| one-piece | One Piece | all | One.Piece.Heroines.2026.1080p.NF.WEB-DL.JPN.AAC2.0.H.264.MSubs-ToonsHub | 1110022410 | usenet | 2000:Movies, 2040:Movies/HD, 102000:, 102040: | 2026-07-11T07:59:00Z |
| one-piece | One Piece | all | One.Piece.Heroines.2026.1080p.iQ.WEB-DL.JPN.AAC2.0.H.264.MSubs-ToonsHub | 307374876 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-08T20:01:52Z |
| one-piece | One Piece | all | One.Piece.S01E01.HEROINES.1080p.CR.WEB-DL.AAC2.0.H.264-VARYG | 1623940635 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-08T20:25:49Z |
| one-piece | One Piece | all | One.Piece.S24E1169.The.Legend.Lurking.in.Elbaph-The.Identity.of.the.Mountain-Eater.1080p.CR.WEB-DL.AAC2.0.H.264-VARYG | 1644836118 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-12T16:25:30Z |
| one-piece | One Piece | all | One.Piece.S24E1169.The.Legend.Lurking.in.Elbaph-The.Identity.of.the.Mountain-Eater.1080p.CR.WEB-DL.AAC2.0.H.264-VARYG | 1792011361 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-07-12T16:31:54Z |
| one-piece | One Piece | all | [A&C] One Piece - Movie 10 (BD 1080p HEVC) [Multi-Audio-Subs] | 1897750861 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-11T07:18:00Z |
| one-piece | One Piece | all | [A&C] One Piece - S00E19 - Movie 10 (BD 1080p HEVC) [Multi-Audio-Subs] [C0A9F4CD] | 18654170039 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-11T06:39:06Z |
| one-piece | One Piece | all | [A&C] One Piece - S00E20 - OVA 03 - Strong World Episode 0 (WEB 1080p HEVC) [Multi-Subs] | 293611684 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-11T06:55:07Z |
| one-piece | One Piece | all | [A&C] One Piece - S00E20 - OVA 03 - Strong World Episode 0 (WEB 1080p HEVC) [Multi-Subs] [AB5B93FD] | 2900936238 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-11T06:49:20Z |
| one-piece | One Piece | all | [ASW] One Piece Novel Heroines [1080p HEVC][EC5A9559] | 460789178 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-08T20:49:10Z |
| one-piece | One Piece | all | [Erai-raws] One Piece - Heroines [1080p CR WEB-DL AVC AAC][F3CC3FFA] | 1624270508 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-08T20:28:54Z |
| one-piece | One Piece | all | [Erai-raws] One Piece - Heroines [1080p CR WEB-DL AVC AAC][MultiSub][0F375049] | 1630415772 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-09T14:16:07Z |
| one-piece | One Piece | all | [Erai-raws] One Piece - Heroines [1080p CR WEB-DL AVC AAC][MultiSub][0F375049] | 1630622250 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-07T20:27:07Z |
| one-piece | One Piece | all | [Erai-raws] One Piece - Heroines [1080p CR WEBRip HEVC AAC][MultiSub][7770B0E2] | 513528119 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-09T14:15:35Z |
| one-piece | One Piece | all | [Erai-raws] One Piece - Heroines [1080p CR WEBRip HEVC AAC][MultiSub][7770B0E2] | 513595678 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-07T20:19:06Z |
| one-piece | One Piece | all | [Erai-raws] One Piece - Heroines [720p CR WEB-DL AVC AAC][MultiSub][CEF6DD4C] | 506435326 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-07T20:21:34Z |
| one-piece | One Piece | all | [Feibanyama] One Piece Heroines [IQIYI WebRip 2160p HEVC AAC Multi-Subs] | 1614246097 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-09T07:21:38Z |
| one-piece | One Piece | all | [Feibanyama] One Piece Heroines [IQIYI WebRip 2160p HEVC AAC Multi-Subs] | 1614759008 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-07T01:50:27Z |
| one-piece | One Piece | all | [HatSubs] One Piece (BD 1080p 10-bit) | 1492527150 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-09T02:04:25Z |
| one-piece | One Piece | all | [HatSubs] One Piece 1094 (BD 1080p 10-bit Opus) [EBB00250] | 2433133090 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-09T01:34:21Z |
| one-piece | One Piece | all | [HatSubs] One Piece 1094-1099 (BD 1080p 10-bit) | 1476008525 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-06T18:43:51Z |
| one-piece | One Piece | all | [HatSubs] One Piece 1095 (BD 1080p 10-bit Opus) [92BC0124] | 2380373676 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-09T01:38:09Z |
| one-piece | One Piece | all | [HatSubs] One Piece 1096 (BD 1080p 10-bit Opus) [34AE9755] | 2364083471 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-09T01:43:25Z |
| one-piece | One Piece | all | [HatSubs] One Piece 1097 (BD 1080p 10-bit Opus) [AE550B14] | 2294246108 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-09T01:48:32Z |
| one-piece | One Piece | all | [HatSubs] One Piece 1098 (BD 1080p 10-bit Opus) [88442231] | 2759152561 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-09T01:53:30Z |
| one-piece | One Piece | all | [HatSubs] One Piece 1099 (BD 1080p 10-bit Opus) [131D7544] | 2469450019 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-09T01:58:20Z |
| one-piece | One Piece | all | [Judas] One Piece - HEROINES | 423308938 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-09T06:35:35Z |
| one-piece | One Piece | all | [MicroHatSubs] One Piece (BD 1080p) | 392104694 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-09T01:14:59Z |
| one-piece | One Piece | all | [MicroHatSubs] One Piece 1094 (BD 1080p AV1 Opus) [0EC75D47] | 676922176 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-09T01:07:47Z |
| one-piece | One Piece | all | [MicroHatSubs] One Piece 1095 (BD 1080p AV1 Opus) [CCFAF683] | 617713837 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-09T01:08:46Z |
| one-piece | One Piece | all | [MicroHatSubs] One Piece 1096 (BD 1080p AV1 Opus) [9D7DEB90] | 599967048 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-09T01:09:52Z |
| one-piece | One Piece | all | [MicroHatSubs] One Piece 1097 (BD 1080p AV1 Opus) [24D23F2D] | 554301220 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-09T01:10:52Z |
| one-piece | One Piece | all | [MicroHatSubs] One Piece 1098 (BD 1080p AV1 Opus) [4D8DB2A8] | 812205021 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-09T01:11:52Z |
| one-piece | One Piece | all | [MicroHatSubs] One Piece 1099 (BD 1080p AV1 Opus) [83E0B39A] | 616616151 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-09T01:13:24Z |
| one-piece | One Piece | all | [SubsPlease] One Piece Novel Heroines (1080p) [951AD374] | 1617458023 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-08T20:20:35Z |
| one-piece | One Piece | all | [YE] One Piece Heroines (THK 1280x720 x265 10bit AAC) | 541067320 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-08T05:42:16Z |
| one-piece | One Piece | anime | ONE.PIECE.HEROINES.2026.1080p.BILI.WEB-DL.JPN.AAC2.0.H.265.MSubs-ToonsHub | 388702135 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-08T23:12:22Z |
| one-piece | One Piece | anime | ONE.PIECE.HEROINES.2026.2160p.BILI.WEB-DL.JPN.AAC2.0.H.264.MSubs-ToonsHub | 1312587019 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-08T23:15:30Z |
| one-piece | One Piece | anime | ONE.PIECE.HEROINES.2026.REPACK.1080p.CR.WEB-DL.DDP2.0.H.264-AnoZu | 1658206765 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-10T20:12:51Z |
| one-piece | One Piece | anime | One Piece - 1101v2 - 720p WEB x264 -NanDesuKa (CR) | 103312479 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-07T00:58:38Z |
| one-piece | One Piece | anime | One Piece - Heroines [H3LL][1080p][x264][10bit][AAC][Multi-Subs] | 1346593319 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-08T21:03:33Z |
| one-piece | One Piece | anime | One Piece Episode 1025 - 1036 [English Dub][720p][Crunchyroll] | 734249970 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-10T13:03:44Z |
| one-piece | One Piece | anime | One.Piece.EP1169.1080p.iQ.WEB-DL.JPN.AAC2.0.H.264.MSubs-ToonsHub | 313584436 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-12T15:57:49Z |
| one-piece | One Piece | anime | One.Piece.EP1169.The.Legend.Lurking.in.Elbaph.The.Identity.of.the.Mountain-Eater.1080p.CR.WEB-DL.JPN.AAC2.0.H.264.ESub-ToonsHub | 1643586016 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-12T16:20:35Z |
| one-piece | One Piece | anime | One.Piece.Heroines.2026.1080p.CR.WEB-DL.JPN.AAC2.0.H.264.MSubs-ToonsHub | 1624093525 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-08T20:15:12Z |
| one-piece | One Piece | anime | One.Piece.Heroines.2026.1080p.NF.WEB-DL.AAC2.0.H.264-VARYG | 1018246526 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-11T18:50:59Z |
| one-piece | One Piece | anime | One.Piece.Heroines.2026.1080p.NF.WEB-DL.JPN.AAC2.0.H.264.MSubs-ToonsHub | 1018284610 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-11T18:38:13Z |
| one-piece | One Piece | anime | One.Piece.Heroines.2026.1080p.iQ.WEB-DL.JPN.AAC2.0.H.264.MSubs-ToonsHub | 307374876 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-08T20:01:52Z |
| one-piece | One Piece | anime | One.Piece.S01E01.HEROINES.1080p.CR.WEB-DL.AAC2.0.H.264-VARYG | 1623940635 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-08T20:25:49Z |
| one-piece | One Piece | anime | One.Piece.S24E1169.The.Legend.Lurking.in.Elbaph-The.Identity.of.the.Mountain-Eater.1080p.CR.WEB-DL.AAC2.0.H.264-VARYG | 1644836118 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-12T16:25:30Z |
| one-piece | One Piece | anime | [A&C] One Piece - Movie 10 (BD 1080p HEVC) [Multi-Audio-Subs] | 1897750861 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-11T07:18:00Z |
| one-piece | One Piece | anime | [A&C] One Piece - S00E19 - Movie 10 (BD 1080p HEVC) [Multi-Audio-Subs] [C0A9F4CD] | 18654170039 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-11T06:39:06Z |
| one-piece | One Piece | anime | [A&C] One Piece - S00E20 - OVA 03 - Strong World Episode 0 (WEB 1080p HEVC) [Multi-Subs] | 293611684 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-11T06:55:07Z |
| one-piece | One Piece | anime | [A&C] One Piece - S00E20 - OVA 03 - Strong World Episode 0 (WEB 1080p HEVC) [Multi-Subs] [AB5B93FD] | 2900936238 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-11T06:49:20Z |
| one-piece | One Piece | anime | [ASW] One Piece Novel Heroines [1080p HEVC][EC5A9559] | 460789178 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-08T20:49:10Z |
| one-piece | One Piece | anime | [Erai-raws] One Piece - Heroines [1080p CR WEB-DL AVC AAC][F3CC3FFA] | 1624270508 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-08T20:28:54Z |
| one-piece | One Piece | anime | [Erai-raws] One Piece - Heroines [1080p CR WEB-DL AVC AAC][MultiSub][0F375049] | 1630415772 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-09T14:16:07Z |
| one-piece | One Piece | anime | [Erai-raws] One Piece - Heroines [1080p CR WEB-DL AVC AAC][MultiSub][0F375049] | 1630622250 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-07T20:27:07Z |
| one-piece | One Piece | anime | [Erai-raws] One Piece - Heroines [1080p CR WEBRip HEVC AAC][MultiSub][7770B0E2] | 513528119 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-09T14:15:35Z |
| one-piece | One Piece | anime | [Erai-raws] One Piece - Heroines [1080p CR WEBRip HEVC AAC][MultiSub][7770B0E2] | 513595678 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-07T20:19:06Z |
| one-piece | One Piece | anime | [Erai-raws] One Piece - Heroines [720p CR WEB-DL AVC AAC][MultiSub][CEF6DD4C] | 506435326 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-07T20:21:34Z |
| one-piece | One Piece | anime | [Feibanyama] One Piece Heroines [IQIYI WebRip 2160p HEVC AAC Multi-Subs] | 1614246097 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-09T07:21:38Z |
| one-piece | One Piece | anime | [Feibanyama] One Piece Heroines [IQIYI WebRip 2160p HEVC AAC Multi-Subs] | 1614759008 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-07T01:50:27Z |
| one-piece | One Piece | anime | [HatSubs] One Piece (BD 1080p 10-bit) | 1492527150 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-09T02:04:25Z |
| one-piece | One Piece | anime | [HatSubs] One Piece 1094 (BD 1080p 10-bit Opus) [EBB00250] | 2433133090 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-09T01:34:21Z |
| one-piece | One Piece | anime | [HatSubs] One Piece 1094-1099 (BD 1080p 10-bit) | 1476008525 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-06T18:43:51Z |
| one-piece | One Piece | anime | [HatSubs] One Piece 1095 (BD 1080p 10-bit Opus) [92BC0124] | 2380373676 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-09T01:38:09Z |
| one-piece | One Piece | anime | [HatSubs] One Piece 1095 (BD 1080p 10-bit Opus) [92BC0124] | 2381173165 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-06T18:32:34Z |
| one-piece | One Piece | anime | [HatSubs] One Piece 1096 (BD 1080p 10-bit Opus) [34AE9755] | 2364083471 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-09T01:43:25Z |
| one-piece | One Piece | anime | [HatSubs] One Piece 1096 (BD 1080p 10-bit Opus) [34AE9755] | 2364891959 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-06T18:34:09Z |
| one-piece | One Piece | anime | [HatSubs] One Piece 1097 (BD 1080p 10-bit Opus) [AE550B14] | 2294246108 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-09T01:48:32Z |
| one-piece | One Piece | anime | [HatSubs] One Piece 1097 (BD 1080p 10-bit Opus) [AE550B14] | 2295040046 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-06T18:36:00Z |
| one-piece | One Piece | anime | [HatSubs] One Piece 1098 (BD 1080p 10-bit Opus) [88442231] | 2759152561 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-09T01:53:30Z |
| one-piece | One Piece | anime | [HatSubs] One Piece 1098 (BD 1080p 10-bit Opus) [88442231] | 2760093796 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-06T18:37:45Z |
| one-piece | One Piece | anime | [HatSubs] One Piece 1099 (BD 1080p 10-bit Opus) [131D7544] | 2469450019 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-09T01:58:20Z |
| one-piece | One Piece | anime | [HatSubs] One Piece 1099 (BD 1080p 10-bit Opus) [131D7544] | 2470269420 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-06T18:40:07Z |
| one-piece | One Piece | anime | [Judas] One Piece - HEROINES | 423308938 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-09T06:35:35Z |
| one-piece | One Piece | anime | [MicroHatSubs] One Piece (BD 1080p) | 392104694 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-09T01:14:59Z |
| one-piece | One Piece | anime | [MicroHatSubs] One Piece 1094 (BD 1080p AV1 Opus) [0EC75D47] | 676922176 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-09T01:07:47Z |
| one-piece | One Piece | anime | [MicroHatSubs] One Piece 1095 (BD 1080p AV1 Opus) [CCFAF683] | 617713837 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-09T01:08:46Z |
| one-piece | One Piece | anime | [MicroHatSubs] One Piece 1096 (BD 1080p AV1 Opus) [9D7DEB90] | 599967048 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-09T01:09:52Z |
| one-piece | One Piece | anime | [MicroHatSubs] One Piece 1097 (BD 1080p AV1 Opus) [24D23F2D] | 554301220 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-09T01:10:52Z |
| one-piece | One Piece | anime | [MicroHatSubs] One Piece 1098 (BD 1080p AV1 Opus) [4D8DB2A8] | 812205021 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-09T01:11:52Z |
| one-piece | One Piece | anime | [MicroHatSubs] One Piece 1099 (BD 1080p AV1 Opus) [83E0B39A] | 616616151 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-09T01:13:24Z |
| one-piece | One Piece | anime | [SubsPlease] One Piece Novel Heroines (1080p) [951AD374] | 1617458023 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-08T20:20:35Z |
| one-piece | One Piece | anime | [YE] One Piece Heroines (THK 1280x720 x265 10bit AAC) | 541067320 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-08T05:42:16Z |
| one-piece | One Piece 1122 | all | ASW-One Piece-1122-1080p HEVC-641CF501 | 765762529 | usenet | 2000:Movies, 2040:Movies/HD, 102000:, 102040: | 2024-10-13T04:12:29Z |
| one-piece | One Piece 1122 | all | Anime Time-One Piece-1122-1080p-HEVC 10bit x265-AAC-Eng Sub | 924356346 | usenet | 4000:PC, 4010:PC/0day, 104000:, 104010: | 2024-10-13T04:04:59Z |
| one-piece | One Piece 1122 | all | Erai-raws-One Piece-1122-1080p-Multiple Subtitle-52562AF2 | 1586783840 | usenet | 2000:Movies, 2040:Movies/HD, 102000:, 102040: | 2024-10-13T09:53:53Z |
| one-piece | One Piece 1122 | all | [ASW] One Piece - 1122 [1080p HEVC][641CF501] | 803508942 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-13T03:31:08Z |
| one-piece | One Piece 1122 | all | [ASW].One.Piece.-.1122.[1080p.HEVC][641CF501].mkv-[N-Z-B] | 729353769 | usenet | 2000:Movies, 2040:Movies/HD, 102000:, 102040: | 2024-10-13T03:52:00Z |
| one-piece | One Piece 1122 | all | [Anime Time] One Piece - 1122 [1080p][HEVC 10bit x265][AAC][Eng Sub] | 969741771 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-13T03:33:16Z |
| one-piece | One Piece 1122 | all | [Anime.Time].One.Piece.-.1122.[1080p][HEVC.10bit.x265][AAC][Eng.Sub].[Weekly] | 969741810 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-13T02:33:16Z |
| one-piece | One Piece 1122 | all | [Anime.Time].One.Piece.-.1122.[1080p][HEVC.10bit.x265][AAC][Eng.Sub].mkv-[N-Z-B] | 880453000 | usenet | 2000:Movies, 2040:Movies/HD, 102000:, 102040: | 2024-10-13T03:58:44Z |
| one-piece | One Piece 1122 | all | [Erai-raws] One Piece - 1122 [1080p][9493F0CD] | 1664082778 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-13T02:35:43Z |
| one-piece | One Piece 1122 | all | [Erai-raws] One Piece - 1122 [1080p][HEVC][Multiple Subtitle][2624BDED] | 1126405758 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-13T08:18:08Z |
| one-piece | One Piece 1122 | all | [Erai-raws] One Piece - 1122 [1080p][HEVC][Multiple Subtitle][2624BDED] | 1132501995 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-13T08:19:13Z |
| one-piece | One Piece 1122 | all | [Erai-raws] One Piece - 1122 [1080p][Multiple Subtitle][52562AF2] | 1654610527 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-13T08:21:59Z |
| one-piece | One Piece 1122 | all | [Erai-raws] One Piece - 1122 [1080p][Multiple Subtitle][52562AF2] | 1664484762 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-13T08:23:24Z |
| one-piece | One Piece 1122 | all | [Erai-raws] One Piece - 1122 [480p][237D1852] | 447464243 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-13T02:30:31Z |
| one-piece | One Piece 1122 | all | [Erai-raws] One Piece - 1122 [480p][Multiple Subtitle][6554E60E] | 445379235 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-13T08:20:18Z |
| one-piece | One Piece 1122 | all | [Erai-raws] One Piece - 1122 [480p][Multiple Subtitle][6554E60E] | 447723686 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-13T08:20:50Z |
| one-piece | One Piece 1122 | all | [Erai-raws] One Piece - 1122 [720p][7A9500A7] | 853652286 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-13T02:28:51Z |
| one-piece | One Piece 1122 | all | [Erai-raws] One Piece - 1122 [720p][Multiple Subtitle][4E4C3993] | 849524910 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-13T08:20:20Z |
| one-piece | One Piece 1122 | all | [Erai-raws] One Piece - 1122 [720p][Multiple Subtitle][4E4C3993] | 853967044 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-13T08:21:16Z |
| one-piece | One Piece 1122 | all | [Erai-raws].One.Piece-1122.[1080p][9493F0CD] | 1585769359 | usenet | 2000:Movies, 2040:Movies/HD, 102000:, 102040: | 2024-10-13T04:28:00Z |
| one-piece | One Piece 1122 | all | [Erai-raws].One.Piece-1122.[720p][7A9500A7] | 813853021 | usenet | 2000:Movies, 2040:Movies/HD, 102000:, 102040: | 2024-10-13T04:20:48Z |
| one-piece | One Piece 1122 | all | [Erai-raws].One.Piece.-.1122.[1080p][9493F0CD].mkv-[N-Z-B] | 1510270025 | usenet | 2000:Movies, 2040:Movies/HD, 102000:, 102040: | 2024-10-13T05:04:40Z |
| one-piece | One Piece 1122 | all | [Erai-raws].One.Piece.-.1122.[1080p][HEVC][Multiple.Subtitle][2624BDED] | 1079708464 | usenet | 2000:Movies, 2040:Movies/HD, 102000:, 102040: | 2024-10-13T09:59:56Z |
| one-piece | One Piece 1122 | all | [Erai-raws].One.Piece.-.1122.[1080p][HEVC][Multiple.Subtitle][2624BDED].mkv-[N-Z-B] | 1028118546 | usenet | 2000:Movies, 2040:Movies/HD, 102000:, 102040: | 2024-10-13T16:43:52Z |
| one-piece | One Piece 1122 | all | [Erai-raws].One.Piece.-.1122.[1080p][Multiple.Subtitle][52562AF2] | 1585980198 | usenet | 2000:Movies, 2040:Movies/HD, 102000:, 102040: | 2024-10-13T09:55:51Z |
| one-piece | One Piece 1122 | all | [Erai-raws].One.Piece.-.1122.[1080p][Multiple.Subtitle][52562AF2].mkv-[N-Z-B] | 1510471879 | usenet | 2000:Movies, 2040:Movies/HD, 102000:, 102040: | 2024-10-13T18:03:19Z |
| one-piece | One Piece 1122 | all | [Erai-raws].One.Piece.-.1122.[720p][7A9500A7] | 813854278 | usenet | 2000:Movies, 2040:Movies/HD, 102000:, 102040: | 2024-10-13T04:41:42Z |
| one-piece | One Piece 1122 | all | [Erai-raws].One.Piece.-.1122.[720p][7A9500A7].mkv-[N-Z-B] | 774691563 | usenet | 2000:Movies, 2040:Movies/HD, 102000:, 102040: | 2024-10-13T03:54:24Z |
| one-piece | One Piece 1122 | all | [Erai-raws].One.Piece.-.1122.[720p][Multiple.Subtitle][4E4C3993] | 814062581 | usenet | 2000:Movies, 2040:Movies/HD, 102000:, 102040: | 2024-10-13T11:52:56Z |
| one-piece | One Piece 1122 | all | [HatSubs] One Piece 1122 (WEB 1080p) [4FEADBCC] | 1667355229 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-13T16:28:29Z |
| one-piece | One Piece 1122 | all | [HatSubs] One Piece 1122 (WEB 1080p) [4FEADBCC] | 1678294259 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-13T16:30:11Z |
| one-piece | One Piece 1122 | all | [HatSubs] One Piece 1122 (WEB 1080p) v2 [889E0A7B] | 1668043213 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-30T01:57:27Z |
| one-piece | One Piece 1122 | all | [HatSubs] One Piece 1122 (WEB 1080p) v2 [889E0A7B] | 1678301626 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-30T01:58:39Z |
| one-piece | One Piece 1122 | all | [HatSubs] One Piece 1122-1133 (WEB 1080p) | 18383736608 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-06-23T14:07:15Z |
| one-piece | One Piece 1122 | all | [HatSubs].One.Piece.1112-1122.WEB.1080p | 21865102235 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-30T00:58:39Z |
| one-piece | One Piece 1122 | all | [Judas] One Piece - 1122 | 691844851 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-13T08:20:48Z |
| one-piece | One Piece 1122 | all | [Judas] One Piece - 1122 | 691844851 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-13T09:20:48Z |
| one-piece | One Piece 1122 | all | [New-raws].One.Piece-1122.[1080p].[WEB] | 563250231 | usenet | 2000:Movies, 2040:Movies/HD, 102000:, 102040: | 2024-10-13T03:55:39Z |
| one-piece | One Piece 1122 | all | [New-raws].One.Piece.-.1122.[1080p].[WEB].mkv-[N-Z-B] | 537042518 | usenet | 2000:Movies, 2040:Movies/HD, 102000:, 102040: | 2024-10-13T03:41:25Z |
| one-piece | One Piece 1122 | all | [Sick-Fansubs].One.Piece.1122.[1080p][B22A7999].mp4-[N-Z-B] | 781655845 | usenet | 2000:Movies, 2040:Movies/HD, 102000:, 102040: | 2024-10-14T00:19:16Z |
| one-piece | One Piece 1122 | all | [SubsPlease] One Piece - 1122 (1080p) [5262249D] | 1656254857 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-13T02:27:51Z |
| one-piece | One Piece 1122 | all | [SubsPlease] One Piece - 1122 (480p) [5A1BA495] | 439632496 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-13T02:12:32Z |
| one-piece | One Piece 1122 | all | [SubsPlease] One Piece - 1122 (720p) [E1A07EC0] | 845832882 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-13T02:13:28Z |
| one-piece | One Piece 1122 | all | [SubsPlease].One.Piece-1122.1080p.[5262249D] | 1579413771 | usenet | 2000:Movies, 2040:Movies/HD, 102000:, 102040: | 2024-10-13T03:53:02Z |
| one-piece | One Piece 1122 | all | [SubsPlease].One.Piece-1122.480p.[5A1BA495] | 419839923 | usenet | 2000:Movies, 2030:Movies/SD, 102000:, 102030: | 2024-10-13T02:41:14Z |
| one-piece | One Piece 1122 | all | [SubsPlease].One.Piece-1122.720p.[E1A07EC0] | 807499325 | usenet | 2000:Movies, 2040:Movies/HD, 102000:, 102040: | 2024-10-13T03:35:10Z |
| one-piece | One Piece 1122 | all | [SubsPlease].One.Piece.-.1122.(1080p).[5262249D] | 1503035357 | usenet | 2000:Movies, 2040:Movies/HD, 102000:, 102040: | 2024-10-13T16:15:02Z |
| one-piece | One Piece 1122 | all | [SubsPlease].One.Piece.-.1122.(1080p).[5262249D].mkv | 1503030424 | usenet | 2000:Movies, 2040:Movies/HD, 102000:, 102040: | 2024-10-13T16:13:39Z |
| one-piece | One Piece 1122 | all | [SubsPlease].One.Piece.-.1122.(720p).[E1A07EC0].mkv | 767773811 | usenet | 2000:Movies, 2040:Movies/HD, 102000:, 102040: | 2024-10-13T14:00:54Z |
| one-piece | One Piece 1122 | all | [SubsPlease].One.Piece.-.1122.[720p].[E1A07EC0].mkv-[N-Z-B] | 768339189 | usenet | 2000:Movies, 2040:Movies/HD, 102000:, 102040: | 2024-10-13T03:54:11Z |
| one-piece | One Piece 1122 | anime | ONE PIECE S01E1089-E1122 1080p NF WEB-DL AAC2.0 H 264-VARYG (Multi-Subs) | 30709016576 | torrent | 2020:Movies/Other, 5070:TV/Anime, 127720: | 2024-10-20T13:29:00Z |
| one-piece | One Piece 1122 | anime | One Piece S01E1109-E1122 1080p CR WEB-DL AAC2.0 H 264 DUAL-VARYG (Dual-Audio, Multi-Subs) | 21474836480 | torrent | 2020:Movies/Other, 5070:TV/Anime, 127720: | 2025-03-18T23:35:00Z |
| one-piece | One Piece 1122 | anime | One Piece S01E1122 The Last Lesson Impact Inherited REPACK 1080p CR WEB-DL AAC2.0 H 264-VARYG (Multi-Subs) | 1503238528 | torrent | 2020:Movies/Other, 5070:TV/Anime, 127720: | 2024-10-13T21:07:00Z |
| one-piece | One Piece 1122 | anime | One.Piece.S01E1122.The.Last.Lesson.Impact.Inherited.1080p.CR.WEB-DL.AAC2.0.H.264-VARYG | 1480874000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-13T02:53:25Z |
| one-piece | One Piece 1122 | anime | One.Piece.S14E1122.1080p.WEB.H264-KAWAII | 1480430000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-13T02:16:14Z |
| one-piece | One Piece 1122 | anime | One.Piece.S22E1122.1080p.CR.WEB-DL.Dual.Audio.AAC2.0.H.264-OldT | 1829795000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-03-26T20:30:07Z |
| one-piece | One Piece 1122 | anime | [ASW] One Piece - 1122 [1080p HEVC][641CF501] | 803508942 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-13T03:31:08Z |
| one-piece | One Piece 1122 | anime | [ASW].One.Piece.-.1122.[1080p.HEVC.x265.10Bit][AAC] | 803508948 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-13T02:31:08Z |
| one-piece | One Piece 1122 | anime | [Anime Land] One Piece 1122 S01 (WEBRip 1080p Hi10P AAC) RAW [A837DE64].mp4 | 1288490240 | torrent | 2020:Movies/Other, 5070:TV/Anime, 134634: | 2024-10-13T14:43:00Z |
| one-piece | One Piece 1122 | anime | [Anime Time] One Piece - 1122 [1080p][HEVC 10bit x265][AAC][Eng Sub] | 969741771 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-13T03:33:16Z |
| one-piece | One Piece 1122 | anime | [Anime.Time].One.Piece.-.1122.[1080p][HEVC.10bit.x265][AAC][Eng.Sub].[Weekly] | 969741810 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-13T02:33:16Z |
| one-piece | One Piece 1122 | anime | [DubOnly] One Piece S01E1109  - 1122 [English Dub][1080p][CR] | 20293720064 | torrent | 2020:Movies/Other, 5070:TV/Anime, 127720: | 2025-03-19T03:14:00Z |
| one-piece | One Piece 1122 | anime | [Erai-raws] One Piece - 1122 [1080p][9493F0CD] | 1664082778 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-13T02:35:43Z |
| one-piece | One Piece 1122 | anime | [Erai-raws] One Piece - 1122 [1080p][HEVC][Multiple Subtitle][2624BDED] | 1126405758 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-13T08:18:08Z |
| one-piece | One Piece 1122 | anime | [Erai-raws] One Piece - 1122 [1080p][HEVC][Multiple Subtitle][2624BDED] | 1132501995 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-13T08:19:13Z |
| one-piece | One Piece 1122 | anime | [Erai-raws] One Piece - 1122 [1080p][Multiple Subtitle][52562AF2] | 1654610527 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-13T08:21:59Z |
| one-piece | One Piece 1122 | anime | [Erai-raws] One Piece - 1122 [1080p][Multiple Subtitle][52562AF2] | 1664484762 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-13T08:23:24Z |
| one-piece | One Piece 1122 | anime | [Erai-raws] One Piece - 1122 [480p][237D1852] | 447464243 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-13T02:30:31Z |
| one-piece | One Piece 1122 | anime | [Erai-raws] One Piece - 1122 [480p][Multiple Subtitle][6554E60E] | 445379235 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-13T08:20:18Z |
| one-piece | One Piece 1122 | anime | [Erai-raws] One Piece - 1122 [480p][Multiple Subtitle][6554E60E] | 447723686 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-13T08:20:50Z |
| one-piece | One Piece 1122 | anime | [Erai-raws] One Piece - 1122 [720p][7A9500A7] | 853652286 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-13T02:28:51Z |
| one-piece | One Piece 1122 | anime | [Erai-raws] One Piece - 1122 [720p][Multiple Subtitle][4E4C3993] | 849524910 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-13T08:20:20Z |
| one-piece | One Piece 1122 | anime | [Erai-raws] One Piece - 1122 [720p][Multiple Subtitle][4E4C3993] | 853967044 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-13T08:21:16Z |
| one-piece | One Piece 1122 | anime | [Erai-raws].One.Piece-1122.[1080p][9493F0CD] | 1493079000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-13T02:54:02Z |
| one-piece | One Piece 1122 | anime | [Erai-raws].One.Piece-1122.[480p][237D1852] | 401713000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-13T02:54:15Z |
| one-piece | One Piece 1122 | anime | [Erai-raws].One.Piece-1122.[720p][7A9500A7] | 766201000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-13T02:54:35Z |
| one-piece | One Piece 1122 | anime | [Erai-raws].One.Piece.-.1122.[1080p].[ENG] | 1664083060 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-13T01:35:43Z |
| one-piece | One Piece 1122 | anime | [Erai-raws].One.Piece.-.1122.[480p].[ENG] | 447464243 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-13T01:30:31Z |
| one-piece | One Piece 1122 | anime | [Erai-raws].One.Piece.-.1122.[720p].[ENG] | 853652192 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-13T01:28:51Z |
| one-piece | One Piece 1122 | anime | [HatSubs] One Piece 1112-1122 S01 (WEB 1080p) | 19219978240 | torrent | 2020:Movies/Other, 5070:TV/Anime, 127720: | 2024-10-29T10:08:00Z |
| one-piece | One Piece 1122 | anime | [HatSubs] One Piece 1122 (WEB 1080p) [4FEADBCC] | 1667355229 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-13T16:28:29Z |
| one-piece | One Piece 1122 | anime | [HatSubs] One Piece 1122 (WEB 1080p) [4FEADBCC] | 1678294259 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-13T16:30:11Z |
| one-piece | One Piece 1122 | anime | [HatSubs] One Piece 1122 (WEB 1080p) v2 [889E0A7B] | 1668043213 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-30T01:57:27Z |
| one-piece | One Piece 1122 | anime | [HatSubs] One Piece 1122 (WEB 1080p) v2 [889E0A7B] | 1678301626 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-30T01:58:39Z |
| one-piece | One Piece 1122 | anime | [HatSubs] One Piece 1122-1133 (WEB 1080p) | 18383736608 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-06-23T14:07:15Z |
| one-piece | One Piece 1122 | anime | [HatSubs].One.Piece.1112-1122.WEB.1080p | 21865102235 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-30T00:58:39Z |
| one-piece | One Piece 1122 | anime | [Judas] One Piece - 1122 | 691844851 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-13T08:20:48Z |
| one-piece | One Piece 1122 | anime | [Judas] One Piece - 1122 | 691844851 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-13T09:20:48Z |
| one-piece | One Piece 1122 | anime | [NanakoRaws] One Piece S01  - 1122.5+1123 (CX 1920x1080 x265 AAC).mkv | 2576980480 | torrent | 2020:Movies/Other, 5070:TV/Anime, 134634: | 2025-04-06T09:18:00Z |
| one-piece | One Piece 1122 | anime | [Naruto-Kun.Hu] One Piece  - 1122 [1080p].mkv | 595276608 | torrent | 2020:Movies/Other, 5070:TV/Anime, 131088: | 2024-10-15T04:36:00Z |
| one-piece | One Piece 1122 | anime | [New-raws].One.Piece-1122.[1080p].[WEB] | 530952000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-13T02:54:51Z |
| one-piece | One Piece 1122 | anime | [SubsPlease] One Piece - 1122 (1080p) [5262249D] | 1656254857 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-13T02:27:51Z |
| one-piece | One Piece 1122 | anime | [SubsPlease] One Piece - 1122 (480p) [5A1BA495] | 439632496 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-13T02:12:32Z |
| one-piece | One Piece 1122 | anime | [SubsPlease] One Piece - 1122 (720p) [E1A07EC0] | 845832882 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-13T02:13:28Z |
| one-piece | One Piece 1122 | anime | [SubsPlease].One.Piece-1122.1080p.[5262249D] | 1486902000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-13T02:55:26Z |
| one-piece | One Piece 1122 | anime | [SubsPlease].One.Piece-1122.480p.[5A1BA495] | 395433000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-13T02:55:38Z |
| one-piece | One Piece 1122 | anime | [SubsPlease].One.Piece-1122.720p.[E1A07EC0] | 759893000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-13T02:59:06Z |
| one-piece | One Piece 1122 | anime | [SubsPlease].One.Piece.-.1122.1080p.[5262249D] | 1656254857 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-13T01:27:51Z |
| one-piece | One Piece 1122 | anime | [SubsPlease].One.Piece.-.1122.480p.[5A1BA495] | 439632623 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-13T01:12:32Z |
| one-piece | One Piece 1122 | anime | [SubsPlease].One.Piece.-.1122.720p.[E1A07EC0] | 845832929 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2024-10-13T01:13:28Z |
| pokemon | Pocket Monsters | all | Pokemon Horizons The Series S01E112-E123 1080p NF WEB-DL MULTi AAC2.0 H 264-VARYG (Pocket Monsters (2023), Multi-Audio, Multi-Subs) | 1380939748 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-26T20:15:45Z |
| pokemon | Pocket Monsters | all | [Some-Stuffs] Pocket Monsters (2023) 134 (1080p HEVC 10-bit) [E22F35C4] | 1690502228 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-04-18T04:29:46Z |
| pokemon | Pocket Monsters | all | [Some-Stuffs] Pocket Monsters (2023) 134 (1080p) [0049A5AD] | 898843647 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-04-18T04:27:03Z |
| pokemon | Pocket Monsters | all | [Some-Stuffs] Pocket Monsters (2023) 135 (1080p HEVC 10-bit) [CED82CCA] | 2025683164 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-04-25T00:57:04Z |
| pokemon | Pocket Monsters | all | [Some-Stuffs] Pocket Monsters (2023) 135 (1080p) [B304235C] | 1017815651 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-04-25T00:51:23Z |
| pokemon | Pocket Monsters | all | [Some-Stuffs] Pocket Monsters (2023) 136 (1080p HEVC 10-bit) [42CE46B1] | 1697783338 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-05-02T01:51:42Z |
| pokemon | Pocket Monsters | all | [Some-Stuffs] Pocket Monsters (2023) 136 (1080p HEVC 10-bit) [42CE46B1] | 1699609493 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-05-02T01:47:13Z |
| pokemon | Pocket Monsters | all | [Some-Stuffs] Pocket Monsters (2023) 136 (1080p) [A479F347] | 858834560 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-05-02T01:49:01Z |
| pokemon | Pocket Monsters | all | [Some-Stuffs] Pocket Monsters (2023) 136 (1080p) [A479F347] | 859303871 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-05-02T01:40:40Z |
| pokemon | Pocket Monsters | all | [Some-Stuffs] Pocket Monsters (2023) 138 (1080p HEVC 10-bit) [9E55554F] | 1524204031 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-05-30T18:02:13Z |
| pokemon | Pocket Monsters | all | [Some-Stuffs] Pocket Monsters (2023) 138 (1080p) [5CC3C668] | 803260017 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-05-30T05:39:03Z |
| pokemon | Pocket Monsters | all | [Some-Stuffs] Pocket Monsters (2023) 139 (1080p HEVC 10-bit) [F3003937] | 1182461907 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-06T03:41:08Z |
| pokemon | Pocket Monsters | all | [Some-Stuffs] Pocket Monsters (2023) 139 (1080p HEVC 10-bit) v2 [FDE9F2DC] | 1182474999 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-06T12:41:19Z |
| pokemon | Pocket Monsters | all | [Some-Stuffs] Pocket Monsters (2023) 139 (1080p) [1E6AF242] | 585687079 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-06T03:40:30Z |
| pokemon | Pocket Monsters | all | [Some-Stuffs] Pocket Monsters (2023) 139 (1080p) v2 [59CC029F] | 585689335 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-06T12:13:48Z |
| pokemon | Pocket Monsters | all | [Some-Stuffs] Pocket Monsters (2023) 140 (1080p HEVC 10-bit) [F5A0FE4E] | 1126241594 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-13T05:12:11Z |
| pokemon | Pocket Monsters | all | [Some-Stuffs] Pocket Monsters (2023) 140 (1080p HEVC 10-bit) [F5A0FE4E] | 1126987495 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-13T07:12:29Z |
| pokemon | Pocket Monsters | all | [Some-Stuffs] Pocket Monsters (2023) 140 (1080p) [C82A45E8] | 563330187 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-13T06:58:18Z |
| pokemon | Pocket Monsters | all | [Some-Stuffs] Pocket Monsters (2023) 140 (1080p) [C82A45E8] | 563448362 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-13T05:12:54Z |
| pokemon | Pocket Monsters | all | [Some-Stuffs] Pocket Monsters (2023) 141 (1080p HEVC 10-bit) [3A76E3C3] | 1635747665 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-20T05:12:56Z |
| pokemon | Pocket Monsters | all | [Some-Stuffs] Pocket Monsters (2023) 141 (1080p HEVC 10-bit) [3A76E3C3] | 1636622474 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-20T05:05:38Z |
| pokemon | Pocket Monsters | all | [Some-Stuffs] Pocket Monsters (2023) 141 (1080p) [F081AD31] | 820395851 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-20T05:11:22Z |
| pokemon | Pocket Monsters | all | [Some-Stuffs] Pocket Monsters (2023) 141 (1080p) [F081AD31] | 820738953 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-20T05:03:45Z |
| pokemon | Pocket Monsters | all | [Some-Stuffs] Pocket Monsters (2023) 142 (1080p HEVC 10-bit) [B7F32C9A] | 1262453751 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-04T04:13:33Z |
| pokemon | Pocket Monsters | all | [Some-Stuffs] Pocket Monsters (2023) 142 (1080p HEVC 10-bit) [B7F32C9A] | 1262758909 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-04T04:01:32Z |
| pokemon | Pocket Monsters | all | [Some-Stuffs] Pocket Monsters (2023) 142 (1080p) [1182CC7F] | 628022818 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-04T03:42:16Z |
| pokemon | Pocket Monsters | all | [Some-Stuffs] Pocket Monsters (2023) 142 (1080p) [1182CC7F] | 628157464 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-04T03:59:55Z |
| pokemon | Pocket Monsters | all | [Some-Stuffs] Pocket Monsters - Aim to be a Pokémon Master 03 (PM19 139) (1080p) v2 [DF5244C9] | 103009987 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-13T22:45:32Z |
| pokemon | Pocket Monsters | all | [YE] Pocket Monsters (2023) - 114v2 (BS-TX 4K 3840x2160 x265 10bit HDR AAC) | 1355422104 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-04-15T12:17:47Z |
| pokemon | Pocket Monsters | all | [YE] Pocket Monsters (2023) - 115v2 (BS-TX 4K 3840x2160 x265 10bit HDR AAC) | 832551613 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-04-15T12:19:34Z |
| pokemon | Pocket Monsters | all | [YE] Pocket Monsters (2023) - 116v2 (BS-TX 4K 3840x2160 x265 10bit HDR AAC) | 878910740 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-04-15T12:21:28Z |
| pokemon | Pocket Monsters | all | [YE] Pocket Monsters (2023) - 125v2 (BS-TX 4K 3840x2160 x265 10bit HDR AAC) | 1411161964 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-04-15T12:24:40Z |
| pokemon | Pocket Monsters | all | [YE] Pocket Monsters (2023) - 126v2 (BS-TX 4K 3840x2160 x265 10bit HDR AAC) | 921134911 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-04-15T12:26:37Z |
| pokemon | Pocket Monsters | all | [YE] Pocket Monsters (2023) - 127v2 (BS-TX 4K 3840x2160 x265 10bit HDR AAC) | 1003995451 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-04-15T12:28:47Z |
| pokemon | Pocket Monsters | all | [YE] Pocket Monsters (2023) - 128v2 (BS-TX 4K 3840x2160 x265 10bit HDR AAC) | 991224844 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-04-15T12:30:55Z |
| pokemon | Pocket Monsters | all | [YE] Pocket Monsters (2023) - 129 (BS-TX 4K 3840x2160 x265 10bit HDR AAC) | 1208435491 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-04-15T12:33:33Z |
| pokemon | Pocket Monsters | all | [YE] Pocket Monsters (2023) - 130 (BS-TX 4K 3840x2160 x265 10bit HDR AAC) | 1094509414 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-04-23T02:22:05Z |
| pokemon | Pocket Monsters | all | [YE] Pocket Monsters (2023) - 131 (BS-TX 4K 3840x2160 x265 10bit HDR AAC) | 1218746120 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-05-06T07:11:16Z |
| pokemon | Pocket Monsters | all | [YE] Pocket Monsters (2023) - 132 (BS-TX 4K 3840x2160 x265 10bit HDR AAC) | 1218742909 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-05-25T05:06:10Z |
| pokemon | Pocket Monsters | all | [YE] Pocket Monsters (2023) - 133 (BS-TX 4K 3840x2160 x265 10bit HDR AAC) | 1365265115 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-13T12:17:46Z |
| pokemon | Pocket Monsters | all | [YE] Pocket Monsters (2023) - 134 (BS-TX 4K 3840x2160 x265 10bit HDR AAC) | 1378047082 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-13T12:20:51Z |
| pokemon | Pocket Monsters | all | [YE] Pocket Monsters (2023) - 134 (TVO 1280x720 x265 10bit AAC) | 716861680 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-04-25T09:26:36Z |
| pokemon | Pocket Monsters | all | [YE] Pocket Monsters (2023) - 135 (BS-TX 4K 3840x2160 x265 10bit HDR AAC) | 1432863502 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-13T12:24:04Z |
| pokemon | Pocket Monsters | all | [YE] Pocket Monsters (2023) - 135 (TVO 1280x720 x265 10bit AAC) | 732666654 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-04-25T09:28:29Z |
| pokemon | Pocket Monsters | all | [YE] Pocket Monsters (2023) - 136 (TVO 1280x720 x265 10bit AAC) | 558724669 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-05-25T05:01:48Z |
| pokemon | Pocket Monsters | all | [YE] Pocket Monsters (2023) - 137 (TVO 1280x720 x265 10bit AAC) | 613964736 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-05-25T05:03:19Z |
| pokemon | Pocket Monsters | all | [YE] Pocket Monsters (2023) - 138 (TVO 1280x720 x265 10bit AAC) | 604986965 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T03:12:50Z |
| pokemon | Pocket Monsters | all | [YE] Pocket Monsters (2023) - 139 (TVO 1280x720 x265 10bit AAC) | 423901820 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-13T12:13:30Z |
| pokemon | Pocket Monsters | all | [YE] Pocket Monsters (2023) - 140 (TVO 1280x720 x265 10bit AAC) | 440069095 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-13T12:14:34Z |
| pokemon | Pocket Monsters | all | [YE] Pocket Monsters (2023) - 141 (TVO 1280x720 x265 10bit AAC) | 600209917 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-20T11:29:44Z |
| pokemon | Pocket Monsters | anime | Pokemon Horizons The Series S01E112-E123 1080p NF WEB-DL MULTi AAC2.0 H 264-VARYG (Pocket Monsters (2023), Multi-Audio, Multi-Subs) | 1380939748 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-26T20:15:45Z |
| pokemon | Pocket Monsters | anime | [Some-Stuffs] Pocket Monsters (2023) 134 (1080p HEVC 10-bit) [E22F35C4] | 1690502228 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-04-18T04:29:46Z |
| pokemon | Pocket Monsters | anime | [Some-Stuffs] Pocket Monsters (2023) 134 (1080p) [0049A5AD] | 898843647 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-04-18T04:27:03Z |
| pokemon | Pocket Monsters | anime | [Some-Stuffs] Pocket Monsters (2023) 135 (1080p HEVC 10-bit) [CED82CCA] | 2025683164 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-04-25T00:57:04Z |
| pokemon | Pocket Monsters | anime | [Some-Stuffs] Pocket Monsters (2023) 135 (1080p) [B304235C] | 1017815651 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-04-25T00:51:23Z |
| pokemon | Pocket Monsters | anime | [Some-Stuffs] Pocket Monsters (2023) 136 (1080p HEVC 10-bit) [42CE46B1] | 1697783338 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-05-02T01:51:42Z |
| pokemon | Pocket Monsters | anime | [Some-Stuffs] Pocket Monsters (2023) 136 (1080p HEVC 10-bit) [42CE46B1] | 1699609493 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-05-02T01:47:13Z |
| pokemon | Pocket Monsters | anime | [Some-Stuffs] Pocket Monsters (2023) 136 (1080p) [A479F347] | 858834560 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-05-02T01:49:01Z |
| pokemon | Pocket Monsters | anime | [Some-Stuffs] Pocket Monsters (2023) 136 (1080p) [A479F347] | 859303871 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-05-02T01:40:40Z |
| pokemon | Pocket Monsters | anime | [Some-Stuffs] Pocket Monsters (2023) 138 (1080p HEVC 10-bit) [9E55554F] | 1524204031 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-05-30T18:02:13Z |
| pokemon | Pocket Monsters | anime | [Some-Stuffs] Pocket Monsters (2023) 138 (1080p) [5CC3C668] | 803260017 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-05-30T05:39:03Z |
| pokemon | Pocket Monsters | anime | [Some-Stuffs] Pocket Monsters (2023) 139 (1080p HEVC 10-bit) [F3003937] | 1182461907 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-06T03:41:08Z |
| pokemon | Pocket Monsters | anime | [Some-Stuffs] Pocket Monsters (2023) 139 (1080p HEVC 10-bit) v2 [FDE9F2DC] | 1182474999 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-06T12:41:19Z |
| pokemon | Pocket Monsters | anime | [Some-Stuffs] Pocket Monsters (2023) 139 (1080p) [1E6AF242] | 585687079 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-06T03:40:30Z |
| pokemon | Pocket Monsters | anime | [Some-Stuffs] Pocket Monsters (2023) 139 (1080p) v2 [59CC029F] | 585689335 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-06T12:13:48Z |
| pokemon | Pocket Monsters | anime | [Some-Stuffs] Pocket Monsters (2023) 140 (1080p HEVC 10-bit) [F5A0FE4E] | 1126241594 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-13T05:12:11Z |
| pokemon | Pocket Monsters | anime | [Some-Stuffs] Pocket Monsters (2023) 140 (1080p HEVC 10-bit) [F5A0FE4E] | 1126987495 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-13T07:12:29Z |
| pokemon | Pocket Monsters | anime | [Some-Stuffs] Pocket Monsters (2023) 140 (1080p) [C82A45E8] | 563330187 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-13T06:58:18Z |
| pokemon | Pocket Monsters | anime | [Some-Stuffs] Pocket Monsters (2023) 140 (1080p) [C82A45E8] | 563448362 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-13T05:12:54Z |
| pokemon | Pocket Monsters | anime | [Some-Stuffs] Pocket Monsters (2023) 141 (1080p HEVC 10-bit) [3A76E3C3] | 1635747665 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-20T05:12:56Z |
| pokemon | Pocket Monsters | anime | [Some-Stuffs] Pocket Monsters (2023) 141 (1080p HEVC 10-bit) [3A76E3C3] | 1636622474 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-20T05:05:38Z |
| pokemon | Pocket Monsters | anime | [Some-Stuffs] Pocket Monsters (2023) 141 (1080p) [F081AD31] | 820395851 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-20T05:11:22Z |
| pokemon | Pocket Monsters | anime | [Some-Stuffs] Pocket Monsters (2023) 141 (1080p) [F081AD31] | 820738953 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-20T05:03:45Z |
| pokemon | Pocket Monsters | anime | [Some-Stuffs] Pocket Monsters (2023) 142 (1080p HEVC 10-bit) [B7F32C9A] | 1262453751 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-04T04:13:33Z |
| pokemon | Pocket Monsters | anime | [Some-Stuffs] Pocket Monsters (2023) 142 (1080p HEVC 10-bit) [B7F32C9A] | 1262758909 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-04T04:01:32Z |
| pokemon | Pocket Monsters | anime | [Some-Stuffs] Pocket Monsters (2023) 142 (1080p) [1182CC7F] | 628022818 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-04T03:42:16Z |
| pokemon | Pocket Monsters | anime | [Some-Stuffs] Pocket Monsters (2023) 142 (1080p) [1182CC7F] | 628157464 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-04T03:59:55Z |
| pokemon | Pocket Monsters | anime | [Some-Stuffs] Pocket Monsters - Aim to be a Pokémon Master 03 (PM19 139) (1080p) v2 [DF5244C9] | 103009987 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-13T22:45:32Z |
| pokemon | Pocket Monsters | anime | [YE] Pocket Monsters (2023) - 114v2 (BS-TX 4K 3840x2160 x265 10bit HDR AAC) | 1355422104 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-04-15T12:17:47Z |
| pokemon | Pocket Monsters | anime | [YE] Pocket Monsters (2023) - 115v2 (BS-TX 4K 3840x2160 x265 10bit HDR AAC) | 832551613 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-04-15T12:19:34Z |
| pokemon | Pocket Monsters | anime | [YE] Pocket Monsters (2023) - 116v2 (BS-TX 4K 3840x2160 x265 10bit HDR AAC) | 878910740 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-04-15T12:21:28Z |
| pokemon | Pocket Monsters | anime | [YE] Pocket Monsters (2023) - 125v2 (BS-TX 4K 3840x2160 x265 10bit HDR AAC) | 1411161964 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-04-15T12:24:40Z |
| pokemon | Pocket Monsters | anime | [YE] Pocket Monsters (2023) - 126v2 (BS-TX 4K 3840x2160 x265 10bit HDR AAC) | 921134911 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-04-15T12:26:37Z |
| pokemon | Pocket Monsters | anime | [YE] Pocket Monsters (2023) - 127v2 (BS-TX 4K 3840x2160 x265 10bit HDR AAC) | 1003995451 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-04-15T12:28:47Z |
| pokemon | Pocket Monsters | anime | [YE] Pocket Monsters (2023) - 128v2 (BS-TX 4K 3840x2160 x265 10bit HDR AAC) | 991224844 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-04-15T12:30:55Z |
| pokemon | Pocket Monsters | anime | [YE] Pocket Monsters (2023) - 129 (BS-TX 4K 3840x2160 x265 10bit HDR AAC) | 1208435491 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-04-15T12:33:33Z |
| pokemon | Pocket Monsters | anime | [YE] Pocket Monsters (2023) - 130 (BS-TX 4K 3840x2160 x265 10bit HDR AAC) | 1094509414 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-04-23T02:22:05Z |
| pokemon | Pocket Monsters | anime | [YE] Pocket Monsters (2023) - 131 (BS-TX 4K 3840x2160 x265 10bit HDR AAC) | 1218746120 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-05-06T07:11:16Z |
| pokemon | Pocket Monsters | anime | [YE] Pocket Monsters (2023) - 132 (BS-TX 4K 3840x2160 x265 10bit HDR AAC) | 1218742909 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-05-25T05:06:10Z |
| pokemon | Pocket Monsters | anime | [YE] Pocket Monsters (2023) - 133 (BS-TX 4K 3840x2160 x265 10bit HDR AAC) | 1365265115 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-13T12:17:46Z |
| pokemon | Pocket Monsters | anime | [YE] Pocket Monsters (2023) - 134 (BS-TX 4K 3840x2160 x265 10bit HDR AAC) | 1378047082 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-13T12:20:51Z |
| pokemon | Pocket Monsters | anime | [YE] Pocket Monsters (2023) - 134 (TVO 1280x720 x265 10bit AAC) | 716861680 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-04-25T09:26:36Z |
| pokemon | Pocket Monsters | anime | [YE] Pocket Monsters (2023) - 135 (BS-TX 4K 3840x2160 x265 10bit HDR AAC) | 1432863502 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-13T12:24:04Z |
| pokemon | Pocket Monsters | anime | [YE] Pocket Monsters (2023) - 135 (TVO 1280x720 x265 10bit AAC) | 732666654 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-04-25T09:28:29Z |
| pokemon | Pocket Monsters | anime | [YE] Pocket Monsters (2023) - 136 (TVO 1280x720 x265 10bit AAC) | 558724669 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-05-25T05:01:48Z |
| pokemon | Pocket Monsters | anime | [YE] Pocket Monsters (2023) - 137 (TVO 1280x720 x265 10bit AAC) | 613964736 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-05-25T05:03:19Z |
| pokemon | Pocket Monsters | anime | [YE] Pocket Monsters (2023) - 138 (TVO 1280x720 x265 10bit AAC) | 604986965 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-01T03:12:50Z |
| pokemon | Pocket Monsters | anime | [YE] Pocket Monsters (2023) - 139 (TVO 1280x720 x265 10bit AAC) | 423901820 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-13T12:13:30Z |
| pokemon | Pocket Monsters | anime | [YE] Pocket Monsters (2023) - 140 (TVO 1280x720 x265 10bit AAC) | 440069095 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-13T12:14:34Z |
| pokemon | Pocket Monsters | anime | [YE] Pocket Monsters (2023) - 141 (TVO 1280x720 x265 10bit AAC) | 600209917 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-20T11:29:44Z |
| pokemon | Pokemon | all | Already.Caught.A.Legendary.Pokemon.Crown.Tundra.Dlc.1080p.FAWE.WEB-DL.AAC2.0.H.264-FUZEER | 1042539141 | usenet | 2000:Movies, 2040:Movies/HD, 102000:, 102040: | 2026-06-16T21:02:09Z |
| pokemon | Pokemon | all | Minecraft.Pokemon.Trinity.Pixelmon.1080p.FAWE.WEB-DL.AAC2.0.H.264-FUZEER | 966757796 | usenet | 2000:Movies, 2040:Movies/HD, 102000:, 102040: | 2026-06-16T19:58:57Z |
| pokemon | Pokemon | all | Pokemon Detective Pikachu (2019) (2160p MA WEB-DL Hybrid H265 DV HDR DDP Atmos 5.1 English - HONE) | 21067590346 | usenet | 2000:Movies, 2045:Movies/UHD, 102000:, 102045: | 2026-06-13T00:33:39Z |
| pokemon | Pokemon | all | Pokemon Horizons - 46 (1920x1080 - YTV CA) | 449611092 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-05-07T02:34:23Z |
| pokemon | Pokemon | all | Pokemon Horizons - 48 (1920x1080 - YTV CA) | 516213670 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-05-07T02:38:28Z |
| pokemon | Pokemon | all | Pokemon Horizons - 49 (1920x1080 - YTV CA) | 463213281 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-05-07T02:48:32Z |
| pokemon | Pokemon | all | Pokemon Horizons The Series S01E112-E123 1080p NF WEB-DL MULTi AAC2.0 H 264-VARYG (Pocket Monsters (2023), Multi-Audio, Multi-Subs) | 1380939748 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-26T20:15:45Z |
| pokemon | Pokemon | all | Pokemon.10.Der.Aufstieg.Von.Darkrai.2007.GERMAN.DL.ANIME.1080p.BluRay.x264.DTS-HD.MA-N300 | 8759054622 | usenet | 2000:Movies, 2010:Movies/Foreign, 102000:, 102010: | 2026-05-17T05:23:05Z |
| pokemon | Pokemon | all | Pokemon.GO.w.ThinksWife.1080p.FAWE.WEB-DL.AAC2.0.H.264-FUZEER | 1192165076 | usenet | 2000:Movies, 2040:Movies/HD, 102000:, 102040: | 2026-06-16T19:57:16Z |
| pokemon | Pokemon | all | Pokemon.Horizons.The.Series.S01E112-E123.1080p.NF.WEB-DL.MULTi.AAC2.0.H.264-VARYG | 1392810672 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-26T16:51:13Z |
| pokemon | Pokemon | all | Pokemon.Horizons.The.Series.S01E112-E123.1080p.NF.WEB-DL.MULTi.AAC2.0.H.264-VARYG | 16464828942 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-06-26T16:44:36Z |
| pokemon | Pokemon | all | Pokemon.Horizons.The.Series.S01E112.Mega.Evolution-Roy.1080p.NF.WEB-DL.MULTi.AAC2.0.H.264-VARYG | 1435617335 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-06-26T16:36:44Z |
| pokemon | Pokemon | all | Pokemon.Horizons.The.Series.S01E113.Mega.Evolution-Ult.1080p.NF.WEB-DL.MULTi.AAC2.0.H.264-VARYG | 1438106078 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-06-26T16:36:10Z |
| pokemon | Pokemon | all | Pokemon.Horizons.The.Series.S01E114.Mega.Evolution-Bonds.1080p.NF.WEB-DL.MULTi.AAC2.0.H.264-VARYG | 1436863263 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-06-26T16:36:10Z |
| pokemon | Pokemon | all | Pokemon.Horizons.The.Series.S01E115.Welcome.to.Blueberry.Academy.1080p.NF.WEB-DL.MULTi.AAC2.0.H.264-VARYG | 1349530884 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-06-26T16:37:36Z |
| pokemon | Pokemon | all | Pokemon.Horizons.The.Series.S01E116.Terarium.Training.1080p.NF.WEB-DL.MULTi.AAC2.0.H.264-VARYG | 1352061307 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-06-26T16:36:08Z |
| pokemon | Pokemon | all | Pokemon.Horizons.The.Series.S01E117.Ult-imate.Training.1080p.NF.WEB-DL.MULTi.AAC2.0.H.264-VARYG | 1351121907 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-06-26T16:37:33Z |
| pokemon | Pokemon | all | Pokemon.Horizons.The.Series.S01E118.Liko.and.Hattrem.Bonded.by.Happiness.1080p.NF.WEB-DL.MULTi.AAC2.0.H.264-VARYG | 1351151219 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-06-26T16:37:30Z |
| pokemon | Pokemon | all | Pokemon.Horizons.The.Series.S01E119.Dont.Give.Up.Crocalor.1080p.NF.WEB-DL.MULTi.AAC2.0.H.264-VARYG | 1352170680 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-06-26T16:38:30Z |
| pokemon | Pokemon | all | Pokemon.Horizons.The.Series.S01E120.Dot.and.Pennys.Top-Secret.Mission.1080p.NF.WEB-DL.MULTi.AAC2.0.H.264-VARYG | 1347890514 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-06-26T16:38:16Z |
| pokemon | Pokemon | all | Pokemon.Horizons.The.Series.S01E121.The.Catcher.in.the.Sky.1080p.NF.WEB-DL.MULTi.AAC2.0.H.264-VARYG | 1348336084 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-06-26T16:37:31Z |
| pokemon | Pokemon | all | Pokemon.Horizons.The.Series.S01E122.Roy.vs.Friede.Wings.of.Fire.1080p.NF.WEB-DL.MULTi.AAC2.0.H.264-VARYG | 1350857464 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-06-26T16:37:31Z |
| pokemon | Pokemon | all | Pokemon.Horizons.The.Series.S01E123.Mochi.Mayhem.1080p.NF.WEB-DL.MULTi.AAC2.0.H.264-VARYG | 1350265945 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-06-26T16:37:28Z |
| pokemon | Pokemon | all | Pokemon.Mewtwo.Returns.2001.1080p.DVD.UPSCALE.SWE-ENG.DD.2.0.H.265-OldT | 4143977801 | usenet | 2000:Movies, 2040:Movies/HD, 102000:, 102040: | 2026-05-28T12:47:32Z |
| pokemon | Pokemon | all | Pokemon.S00E82.Distant.Blue.Sky.International.Version.1080p.NF.WEB-DL.AAC2.0.H.264-Kitsune | 1024822865 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-05-01T15:50:35Z |
| pokemon | Pokemon | all | Pokemon.S20E136.Stellar.Finale.1080p.AMZN.WEB-DL.DDP2.0.H.264-Kitsune | 1215454513 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-05-23T10:24:14Z |
| pokemon | Pokemon | all | Pokemon.S20E137.Reboot.Off.to.the.World.of.Adventure.1080p.AMZN.WEB-DL.DDP2.0.H.264-Kitsune | 1317731164 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-05-23T10:25:27Z |
| pokemon | Pokemon | all | Pokemon.S20E137.Reboot.Off.to.the.World.of.Adventure.REPACK.1080p.AMZN.WEB-DL.DDP2.0.H.264-Kitsune | 1266005742 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-05-23T17:31:43Z |
| pokemon | Pokemon | all | Pokemon.S20E138.Enter.the.Fake.Rising.Volt.Tacklers.1080p.AMZN.WEB-DL.DDP2.0.H.264-Kitsune | 1221229115 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-05-30T07:09:27Z |
| pokemon | Pokemon | all | Pokemon.To.Be.a.Pokemon.Master.S01E01.The.Road.Most.Traveled.1080p.AMZN.WEB-DL.DDP2.0.H.264-Kitsune | 1485676562 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-04-30T07:40:54Z |
| pokemon | Pokemon | all | Pokemon.To.Be.a.Pokemon.Master.S01E01.The.Road.Most.Traveled.International.Version.1080p.NF.WEB-DL.AAC2.0.H.264-Kitsune | 910042487 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-04-30T07:37:33Z |
| pokemon | Pokemon | all | Pokemon.To.Be.a.Pokemon.Master.S01E02.A.Fated.Face-Off.1080p.AMZN.WEB-DL.DDP2.0.H.264-Kitsune | 1273276426 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-04-30T07:41:06Z |
| pokemon | Pokemon | all | Pokemon.To.Be.a.Pokemon.Master.S01E02.A.Fated.Face-Off.International.Version.1080p.NF.WEB-DL.AAC2.0.H.264-Kitsune | 913369949 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-04-30T07:37:41Z |
| pokemon | Pokemon | all | Pokemon.To.Be.a.Pokemon.Master.S01E03.Must.Be.Our.Heroes.and.the.Witch.1080p.AMZN.WEB-DL.DDP2.0.H.264-Kitsune | 1222512884 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-04-30T07:41:00Z |
| pokemon | Pokemon | all | Pokemon.To.Be.a.Pokemon.Master.S01E03.Must.Be.Our.Heroes.and.the.Witch.International.Version.1080p.NF.WEB-DL.AAC2.0.H.264-Kitsune | 912780263 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-04-30T07:37:20Z |
| pokemon | Pokemon | all | Pokemon.To.Be.a.Pokemon.Master.S01E04.Bearing.Down.Easy.1080p.AMZN.WEB-DL.DDP2.0.H.264-Kitsune | 1318568083 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-04-30T07:41:55Z |
| pokemon | Pokemon | all | Pokemon.To.Be.a.Pokemon.Master.S01E04.Bearing.Down.Easy.International.Version.1080p.NF.WEB-DL.AAC2.0.H.264-Kitsune | 911724706 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-04-30T07:37:56Z |
| pokemon | Pokemon | all | Pokemon.To.Be.a.Pokemon.Master.S01E05.A.Squads.Worth.of.Passion.1080p.AMZN.WEB-DL.DDP2.0.H.264-Kitsune | 1305371938 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-04-30T07:42:01Z |
| pokemon | Pokemon | all | Pokemon.To.Be.a.Pokemon.Master.S01E06.The.Same.Moon.Now.and.Forever.1080p.AMZN.WEB-DL.DDP2.0.H.264-Kitsune | 1283299638 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-04-30T07:40:47Z |
| pokemon | Pokemon | all | Pokemon.To.Be.a.Pokemon.Master.S01E06.The.Same.Moon.Now.and.Forever.International.Version.1080p.NF.WEB-DL.AAC2.0.H.264-Kitsune | 911554576 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-04-30T07:38:06Z |
| pokemon | Pokemon | all | Pokemon.To.Be.a.Pokemon.Master.S01E07.Ride.Lapras.Ride.1080p.AMZN.WEB-DL.DDP2.0.H.264-Kitsune | 1198503858 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-04-30T07:40:35Z |
| pokemon | Pokemon | all | Pokemon.To.Be.a.Pokemon.Master.S01E08.Getting.to.the.Heart.of.It.All.1080p.AMZN.WEB-DL.DDP2.0.H.264-Kitsune | 1234347046 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-04-30T07:41:12Z |
| pokemon | Pokemon | all | Pokemon.To.Be.a.Pokemon.Master.S01E08.Getting.to.the.Heart.of.It.All.International.Version.1080p.NF.WEB-DL.AAC2.0.H.264-Kitsune | 910832639 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-04-30T07:37:09Z |
| pokemon | Pokemon | all | Pokemon.To.Be.a.Pokemon.Master.S01E09.Rocket.Revengers.1080p.AMZN.WEB-DL.DDP2.0.H.264-Kitsune | 1406712831 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-04-30T07:41:27Z |
| pokemon | Pokemon | all | Pokemon.To.Be.a.Pokemon.Master.S01E09.Rocket.Revengers.International.Version.1080p.NF.WEB-DL.AAC2.0.H.264-Kitsune | 911792517 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-04-30T07:37:14Z |
| pokemon | Pokemon | all | Pokemon.To.Be.a.Pokemon.Master.S01E10.Ash.and.Latios.1080p.AMZN.WEB-DL.DDP2.0.H.264-Kitsune | 1412874707 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-04-30T07:41:49Z |
| pokemon | Pokemon | all | Pokemon.To.Be.a.Pokemon.Master.S01E10.Ash.and.Latios.International.Version.1080p.NF.WEB-DL.AAC2.0.H.264-Kitsune | 909935174 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-04-30T07:37:25Z |
| pokemon | Pokemon | all | Pokemon.To.Be.a.Pokemon.Master.S01E11.The.Rainbow.and.the.Pokemon.Master.1080p.AMZN.WEB-DL.DDP2.0.H.264-Kitsune | 1283455639 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-04-30T07:40:41Z |
| pokemon | Pokemon | all | Pokemon.To.Be.a.Pokemon.Master.S01E11.The.Rainbow.and.the.Pokemon.Master.International.Version.1080p.NF.WEB-DL.AAC2.0.H.264-Kitsune | 913990054 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-04-30T07:38:01Z |
| pokemon | Pokemon | all | Schooled.S02E09.The.Pokemon.Society.1080p.AMZN.WEB-DL.DDP5.1.H.264-NTb | 1826862436 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-05-09T02:41:04Z |
| pokemon | Pokemon | anime | Pokemon - 0605-12x39 Diamond & Pearl 142 Galactic Battles 39 - Gone with the Windworks! [v2-ColdFusion][F6F8766B] | 557508861 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-03-12T21:34:49Z |
| pokemon | Pokemon | anime | Pokemon Horizons - 46 (1920x1080 - YTV CA) | 449611092 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-05-07T02:34:23Z |
| pokemon | Pokemon | anime | Pokemon Horizons - 48 (1920x1080 - YTV CA) | 516213670 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-05-07T02:38:28Z |
| pokemon | Pokemon | anime | Pokemon Horizons - 49 (1920x1080 - YTV CA) | 463213281 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-05-07T02:48:32Z |
| pokemon | Pokemon | anime | Pokemon Horizons The Series S01E091-E101 1080p NF WEB-DL MULTi AAC2.0 H 264-VARYG (Pocket Monsters (2023), Multi-Audio, Multi-Subs) | 698771081 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-02-26T00:15:49Z |
| pokemon | Pokemon | anime | Pokemon Horizons The Series S01E112-E123 1080p NF WEB-DL MULTi AAC2.0 H 264-VARYG (Pocket Monsters (2023), Multi-Audio, Multi-Subs) | 1380939748 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-26T20:15:45Z |
| pokemon | Pokemon | anime | Pokemon.Horizons.E101.Terastallization.vs.Mega.Evolution.1080p.NF.WEB-DL.AAC2.0.H.264 | 966549854 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-01-07T04:21:00Z |
| pokemon | Pokemon | anime | Pokemon.Horizons.The.Series.S01E090.Eyes.to.the.Skies.Once.Again | 1173733448 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-02-26T00:13:02Z |
| pokemon | Pokemon | anime | Pokemon.Horizons.The.Series.S01E090.Eyes.to.the.Skies.Once.Again | 1292894123 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-02-26T00:19:43Z |
| pokemon | Pokemon | anime | Pokemon.Horizons.The.Series.S01E091.Eyes.to.the.Skies.Once.Again | 1202495939 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-02-26T00:13:17Z |
| pokemon | Pokemon | anime | Pokemon.Horizons.The.Series.S01E091.Eyes.to.the.Skies.Once.Again | 1324637561 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-02-26T00:21:05Z |
| pokemon | Pokemon | anime | Pokemon.Horizons.The.Series.S01E092.Following.Traces.of.Laquium.1080p.NF.WEB-DL.MULTi.AAC2.0.H.264-VARYG | 1127508438 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-02-26T00:13:32Z |
| pokemon | Pokemon | anime | Pokemon.Horizons.The.Series.S01E092.Following.Traces.of.Laquium.1080p.NF.WEB-DL.MULTi.AAC2.0.H.264-VARYG | 1242203149 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-02-26T00:22:27Z |
| pokemon | Pokemon | anime | Pokemon.Horizons.The.Series.S01E093.Clash.of.the.Nidothing.Fans.1080p.NF.WEB-DL.MULTi.AAC2.0.H.264-VARYG | 1126837248 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-02-26T00:13:46Z |
| pokemon | Pokemon | anime | Pokemon.Horizons.The.Series.S01E093.Clash.of.the.Nidothing.Fans.1080p.NF.WEB-DL.MULTi.AAC2.0.H.264-VARYG | 1241531533 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-02-26T00:24:02Z |
| pokemon | Pokemon | anime | Pokemon.Horizons.The.Series.S01E094.The.Pokemon.Center.Lady.1080p.NF.WEB-DL.MULTi.AAC2.0.H.264-VARYG | 1125457707 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-02-26T00:14:00Z |
| pokemon | Pokemon | anime | Pokemon.Horizons.The.Series.S01E094.The.Pokemon.Center.Lady.1080p.NF.WEB-DL.MULTi.AAC2.0.H.264-VARYG | 1240151400 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-02-26T00:25:21Z |
| pokemon | Pokemon | anime | Pokemon.Horizons.The.Series.S01E095.The.Strong.Sphere.1080p.NF.WEB-DL.MULTi.AAC2.0.H.264-VARYG | 1126625933 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-02-26T00:14:14Z |
| pokemon | Pokemon | anime | Pokemon.Horizons.The.Series.S01E095.The.Strong.Sphere.1080p.NF.WEB-DL.MULTi.AAC2.0.H.264-VARYG | 1241319692 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-02-26T00:26:37Z |
| pokemon | Pokemon | anime | Pokemon.Horizons.The.Series.S01E096.Crash.Team.Dragon.Rampage.1080p.NF.WEB-DL.MULTi.AAC2.0.H.264-VARYG | 1125314893 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-02-26T00:14:28Z |
| pokemon | Pokemon | anime | Pokemon.Horizons.The.Series.S01E096.Crash.Team.Dragon.Rampage.1080p.NF.WEB-DL.MULTi.AAC2.0.H.264-VARYG | 1238529539 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-02-26T00:27:52Z |
| pokemon | Pokemon | anime | Pokemon.Horizons.The.Series.S01E097.The.Prankster.1080p.NF.WEB-DL.MULTi.AAC2.0.H.264-VARYG | 1125246288 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-02-26T00:14:41Z |
| pokemon | Pokemon | anime | Pokemon.Horizons.The.Series.S01E097.The.Prankster.1080p.NF.WEB-DL.MULTi.AAC2.0.H.264-VARYG | 1238451743 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-02-26T00:29:07Z |
| pokemon | Pokemon | anime | Pokemon.Horizons.The.Series.S01E098.Reunion.in.Cortondo.1080p.NF.WEB-DL.MULTi.AAC2.0.H.264-VARYG | 1127108131 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-02-26T00:14:54Z |
| pokemon | Pokemon | anime | Pokemon.Horizons.The.Series.S01E098.Reunion.in.Cortondo.1080p.NF.WEB-DL.MULTi.AAC2.0.H.264-VARYG | 1241792302 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-02-26T00:30:25Z |
| pokemon | Pokemon | anime | Pokemon.Horizons.The.Series.S01E099.Orla.Grounded.1080p.NF.WEB-DL.MULTi.AAC2.0.H.264-VARYG | 1123763015 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-02-26T00:15:08Z |
| pokemon | Pokemon | anime | Pokemon.Horizons.The.Series.S01E099.Orla.Grounded.1080p.NF.WEB-DL.MULTi.AAC2.0.H.264-VARYG | 1236971501 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-02-26T00:31:43Z |
| pokemon | Pokemon | anime | Pokemon.Horizons.The.Series.S01E100.We.Are.the.Rising | 1124490555 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-02-26T00:15:20Z |
| pokemon | Pokemon | anime | Pokemon.Horizons.The.Series.S01E100.We.Are.the.Rising | 1237699201 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-02-26T00:33:01Z |
| pokemon | Pokemon | anime | Pokemon.Horizons.The.Series.S01E101.Terastallization.vs.Mega.Evolution.1080p.NF.WEB-DL.MULTi.AAC2.0.H.264-VARYG | 1123241472 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-02-26T00:15:32Z |
| pokemon | Pokemon | anime | Pokemon.Horizons.The.Series.S01E101.Terastallization.vs.Mega.Evolution.1080p.NF.WEB-DL.MULTi.AAC2.0.H.264-VARYG | 1236454096 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-02-26T00:34:14Z |
| pokemon | Pokemon | anime | Pokemon.Horizons.The.Series.S01E102.The.Knight.in.the.Ruins.1080p.NF.WEB-DL.MULTi.AAC2.0.H.264-VARYG | 1238079377 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-03-20T16:54:03Z |
| pokemon | Pokemon | anime | Pokemon.Horizons.The.Series.S01E103.Nidothing.Love.1080p.NF.WEB-DL.MULTi.AAC2.0.H.264-VARYG | 1242042777 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-03-20T16:55:21Z |
| pokemon | Pokemon | anime | Pokemon.Horizons.The.Series.S01E104.Charcadets.Wish.1080p.NF.WEB-DL.MULTi.AAC2.0.H.264-VARYG | 1237220999 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-03-20T16:56:38Z |
| pokemon | Pokemon | anime | Pokemon.Horizons.The.Series.S01E105.Riding.the.Waves.1080p.NF.WEB-DL.MULTi.AAC2.0.H.264-VARYG | 1240871086 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-03-20T16:57:55Z |
| pokemon | Pokemon | anime | Pokemon.Horizons.The.Series.S01E106.The.Dusk.Ball.That.Wouldnt.Open.1080p.NF.WEB-DL.MULTi.AAC2.0.H.264-VARYG | 1241405571 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-03-20T16:59:12Z |
| pokemon | Pokemon | anime | Pokemon.Horizons.The.Series.S01E107.Friends.As.Two.Me.and.You.1080p.NF.WEB-DL.MULTi.AAC2.0.H.264-VARYG | 1236450549 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-03-20T17:00:28Z |
| pokemon | Pokemon | anime | Pokemon.Horizons.The.Series.S01E108.Taking.the.Next.Steps.1080p.NF.WEB-DL.MULTi.AAC2.0.H.264-VARYG | 1240296504 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-03-20T17:01:42Z |
| pokemon | Pokemon | anime | Pokemon.Horizons.The.Series.S01E109.Tinkatuffs.Hammer.Wasnt.Made.in.a.Year.1080p.NF.WEB-DL.MULTi.AAC2.0.H.264-VARYG | 1241776612 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-03-20T17:03:03Z |
| pokemon | Pokemon | anime | Pokemon.Horizons.The.Series.S01E110.The.Six.Heroes.Unleashed.1080p.NF.WEB-DL.MULTi.AAC2.0.H.264-VARYG | 1238374139 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-03-20T17:04:22Z |
| pokemon | Pokemon | anime | Pokemon.Horizons.The.Series.S01E111.Better.Farther.Stronger.1080p.NF.WEB-DL.MULTi.AAC2.0.H.264-VARYG | 1241445317 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-03-20T17:05:37Z |
| pokemon | Pokemon | anime | Pokemon.Horizons.The.Series.S01E112-E123.1080p.NF.WEB-DL.MULTi.AAC2.0.H.264-VARYG | 1392810672 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-26T16:51:13Z |
| pokemon | Pokemon | anime | Pokemon.Horizons.The.Series.S01E83.The.Truth.Revealed.1080p.NF.WEB-DL.MULTi.AAC2.0.H.264-VARYG | 1094380812 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-09-26T19:49:51Z |
| pokemon | Pokemon | anime | Pokemon.Horizons.The.Series.S01E84.Where.the.Land.Meets.the.Sky.1080p.NF.WEB-DL.MULTi.AAC2.0.H.264-VARYG | 1094564086 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-09-26T19:50:59Z |
| pokemon | Pokemon | anime | Pokemon.Horizons.The.Series.S01E85.The.Pokemon | 1091629567 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-09-26T19:52:10Z |
| pokemon | Pokemon | anime | Pokemon.Horizons.The.Series.S01E86.The.Rising | 1094120765 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-09-26T19:53:23Z |
| pokemon | Pokemon | anime | Pokemon.Horizons.The.Series.S01E87.Guided.by.the.Black.Rayquaza.1080p.NF.WEB-DL.MULTi.AAC2.0.H.264-VARYG | 1089053173 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-09-26T19:54:36Z |
| pokemon | Pokemon | anime | Pokemon.Horizons.The.Series.S01E88.The.Earthshaking.White.Zygarde.1080p.NF.WEB-DL.MULTi.AAC2.0.H.264-VARYG | 1091286401 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-09-26T19:55:48Z |
| pokemon | Pokemon | anime | Pokemon.Horizons.The.Series.S01E89.Where.the.Adventure.Leads.1080p.NF.WEB-DL.MULTi.AAC2.0.H.264-VARYG | 1156389787 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-09-26T19:57:01Z |
| pokemon | Pokemon | anime | [AriesArtist] Pokemon (1997) EP018 Beauty and The Beach [ENG DUB RECONSTRUCTION] [EA0D0AC6] | 661075670 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-10-24T20:52:28Z |
| re-zero | Re Zero | all | Re ZERO Starting Life in Another World S04E10 MULTi AD 1080p CR WEB-DL AAC2.0 x264-Tsundere-Raws (VF, FRENCH, SUBFRENCH, VOSTFR, ReZero kara Hajimeru Isekai Seikatsu, ReZero) | 158278568 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-10T22:50:10Z |
| re-zero | Re Zero | all | Re ZERO Starting Life in Another World S04E11 1080p CR WEB-DL DUAL AAC2.0 H 264-VARYG (Re Zero kara Hajimeru Isekai Seikatsu 2nd Season Part 2, Dual-Audio, Multi-Subs) | 162948255 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-17T14:33:27Z |
| re-zero | Re Zero | all | Re ZERO Starting Life in Another World S04E11 MULTi 1080p CR WEB-DL AAC2.0 x264-Tsundere-Raws (VF, FRENCH, SUBFRENCH, VOSTFR, ReZero kara Hajimeru Isekai Seikatsu, ReZero) | 160277680 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-18T00:12:40Z |
| re-zero | Re Zero | all | Re.ZERO-Starting.Life.In.Another.World.S04E11.1080p.WEB.H264-SKYANiME | 1700296793 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-06-17T19:04:27Z |
| re-zero | Re Zero | all | Re.ZERO-Starting.Life.In.Another.World.S04E11.720p.WEB.H264-SKYANiME | 894768837 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-06-17T19:21:13Z |
| re-zero | Re Zero | all | Re.ZERO.Starting.Life.in.Another.World.S04E10.1080p.WEBRip.Dual.Audio.AV1-Breeze | 1734322521 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-15T22:42:22Z |
| re-zero | Re Zero | all | Re.ZERO.Starting.Life.in.Another.World.S04E10.1080p.WEBRip.Dual.Audio.AV1-Sokudo | 783213656 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-15T22:42:02Z |
| re-zero | Re Zero | all | Re.ZERO.Starting.Life.in.Another.World.S04E11.1080p.CR.WEB-DL.DUAL.AAC2.0.H.264-VARYG | 1773396346 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-17T14:26:57Z |
| re-zero | Re Zero | all | Re.ZERO.Starting.Life.in.Another.World.S04E11.1080p.CR.WEB-DL.DUAL.AAC2.0.H.264-VARYG | 1928837721 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-06-17T14:25:19Z |
| re-zero | Re Zero | all | Re.ZERO.Starting.Life.in.Another.World.S04E11.1080p.CR.WEB-DL.MULTi.AAC2.0.H.264-VARYG | 2016114417 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-17T16:52:08Z |
| re-zero | Re Zero | all | Re.ZERO.Starting.Life.in.Another.World.S04E11.1080p.CR.WEB-DL.MULTi.AAC2.0.H.264-VARYG | 2200795709 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-06-17T17:00:46Z |
| re-zero | Re Zero | all | Re.ZERO.Starting.Life.in.Another.World.S04E11.Episode.11.1080p.CR.WEB-DL.DUAL.DDP2.0.H.264-Kitsune | 1709681374 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-06-17T14:08:36Z |
| re-zero | Re Zero | all | Re.ZERO.Starting.Life.in.Another.World.S04E11.MULTi.1080p.WEB.x264-AMB3R | 1730056170 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-06-17T14:51:48Z |
| re-zero | Re Zero | all | Re.ZERO.Starting.Life.in.Another.World.S04E11.Re.ZERO-Starting.Life.in.Another.World-1080p.CR.WEB-DL.MULTi.AAC2.0.H.264-VARYG | 2015967437 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-24T14:47:34Z |
| re-zero | Re Zero | all | Re.ZERO.Starting.Life.in.Another.World.S04E11.Re.ZERO-Starting.Life.in.Another.World-1080p.CR.WEB-DL.MULTi.AAC2.0.H.264-VARYG | 2200355329 | usenet | 5000:TV, 5040:TV/HD, 105000:, 105040: | 2026-06-24T15:15:06Z |
| re-zero | Re Zero | all | [ASW] Re Zero kara Hajimeru Isekai Seikatsu - 77 [1080p HEVC][C36D2BFD] | 200612087 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-17T16:06:14Z |
| re-zero | Re Zero | all | [ASW] Re Zero kara Hajimeru Isekai Seikatsu - 77 [1080p HEVC][C36D2BFD] | 220927081 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-17T15:41:20Z |
| re-zero | Re Zero | all | [Breeze] Re ZERO - Starting Life in Another World S04E10 [1080p AV1][Dual Audio]   Re ZERO   ReZero   Re Zero (weekly) | 159580781 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-16T00:45:11Z |
| re-zero | Re Zero | all | [DB] Re Zero kara Hajimeru Isekai Seikatsu 4th Season Part 1   Re ZERO -Starting Life in Another World- Season 4 Part 1 [Dual Audio 10bit 1080p][HEVC-x265] | 577361039 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-27T01:06:19Z |
| re-zero | Re Zero | all | [Erai-raws] Re Zero kara Hajimeru Isekai Seikatsu 3rd Season - 04 [1080p][Multiple Subtitle][F0A4E05F] | 105313164 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-16T00:11:41Z |
| re-zero | Re Zero | all | [Erai-raws] Re Zero kara Hajimeru Isekai Seikatsu 3rd Season - 04 [1080p][Multiple Subtitle][F0A4E05F] | 152575997 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-14T03:00:44Z |
| re-zero | Re Zero | all | [Erai-raws] Re Zero kara Hajimeru Isekai Seikatsu 4th Season - 10 [1080p CR WEBRip HEVC AAC][MultiSub][7008AC6F] | 682700089 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-10T18:02:25Z |
| re-zero | Re Zero | all | [Erai-raws] Re Zero kara Hajimeru Isekai Seikatsu 4th Season - 11 [1080p CR WEB-DL AVC AAC][MultiSub][2AF91E1B] | 1706719809 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-17T14:19:23Z |
| re-zero | Re Zero | all | [Erai-raws] Re Zero kara Hajimeru Isekai Seikatsu 4th Season - 11 [1080p CR WEB-DL AVC AAC][MultiSub][2AF91E1B] | 1707673970 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-17T15:21:46Z |
| re-zero | Re Zero | all | [Erai-raws] Re Zero kara Hajimeru Isekai Seikatsu 4th Season - 11 [1080p CR WEBRip HEVC AAC][MultiSub][98C2DCC6] | 522099168 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-17T16:48:25Z |
| re-zero | Re Zero | all | [Erai-raws] Re Zero kara Hajimeru Isekai Seikatsu 4th Season - 11 [1080p CR WEBRip HEVC AAC][MultiSub][98C2DCC6] | 522188667 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-17T15:49:20Z |
| re-zero | Re Zero | all | [Erai-raws] Re Zero kara Hajimeru Isekai Seikatsu 4th Season - 11 [720p CR WEB-DL AVC AAC][MultiSub][3725B72C] | 342922989 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-17T15:08:45Z |
| re-zero | Re Zero | all | [FLE] Re ZERO Starting Life in Another World - S04E10 (WEB 1080p HEVC E-AC-3) [Dual Audio] [00C5F5BE] | 2358403477 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-14T17:22:10Z |
| re-zero | Re Zero | all | [FLE] Re ZERO Starting Life in Another World - S04E11 (WEB 1080p HEVC E-AC-3) [Dual Audio] [0036291E] | 1039295626 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-26T18:22:01Z |
| re-zero | Re Zero | all | [FLE] Re ZERO Starting Life in Another World - S04E11 (WEB 1080p HEVC E-AC-3) [Dual Audio] [0036291E] | 1143663407 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-26T13:13:28Z |
| re-zero | Re Zero | all | [Feibanyama] ReZERO Starting Life in Another World S04E10 [IQIYI WebRip 2160p HEVC AAC Multi-Audio Multi-Subs] (Re Zero kara Hajimeru Isekai Seikatsu) | 174454170 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-21T09:54:36Z |
| re-zero | Re Zero | all | [Judas] Re.Zero - S04E11 | 283844555 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-17T15:40:20Z |
| re-zero | Re Zero | all | [Onalrie] Re Zero kara Hajimeru Isekai Seikatsu - S04E11 [1080p WEBRip AV1] | 168587346 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-17T15:10:14Z |
| re-zero | Re Zero | all | [Onalrie] Re Zero kara Hajimeru Isekai Seikatsu - S04E11 [1080p WEBRip AV1] | 169082437 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-17T15:51:05Z |
| re-zero | Re Zero | all | [SubsPlease] Re Zero kara Hajimeru Isekai Seikatsu - 65 (1080p) [743EBD8B] | 164096465 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-08T20:45:10Z |
| re-zero | Re Zero | all | [SubsPlease] Re Zero kara Hajimeru Isekai Seikatsu - 77 (1080p) [F7DAEC64] | 1700601663 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-17T14:15:27Z |
| re-zero | Re Zero | all | [SubsPlease] Re Zero kara Hajimeru Isekai Seikatsu - 77 (1080p) [F7DAEC64] | 1700949559 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-17T15:28:31Z |
| re-zero | Re Zero | all | [SubsPlease] Re Zero kara Hajimeru Isekai Seikatsu - 77 (720p) [E00DF851] | 872242478 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-17T15:34:30Z |
| re-zero | Re Zero | all | [ToonsHub] ReZERO -Starting Life in Another World- S04E11 1080p CR WEB-DL DUAL AAC2.0 H.264 (Re Zero kara Hajimeru Isekai Seikatsu, Dual-Audio, Multi-Subs) | 162940596 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-17T14:48:09Z |
| re-zero | Re Zero | all | [ToonsHub] ReZERO -Starting Life in Another World- S04E11 1080p CR WEB-DL MULTi AAC2.0 H.264 (Re Zero kara Hajimeru Isekai Seikatsu, Multi-Audio, Multi-Subs) | 185212273 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-17T16:04:57Z |
| re-zero | Re Zero | all | [VARYG] Re ZERO Starting Life in Another World S04E11 1080p CR WEB-DL MULTi AAC2.0 H.264 (Re Zero kara Hajimeru Isekai Seikatsu, Multi-Subs) | 185920623 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-17T17:49:11Z |
| re-zero | Re Zero | all | [Yameii] Re ZERO, Starting Life in Another World - S04E10 [English Dub] [CR WEB-DL 720p H264 AAC] [79AD2AE2] | 766474066 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-10T20:31:26Z |
| re-zero | Re Zero | all | [Yameii] Re ZERO, Starting Life in Another World - S04E11 [English Dub] [CR WEB-DL 1080p H264 AAC] [F7A0C8EE] | 1547856458 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-17T15:47:56Z |
| re-zero | Re Zero | all | [Yameii] Re ZERO, Starting Life in Another World - S04E11 [English Dub] [CR WEB-DL 1080p H264 AAC] [F7A0C8EE] | 1703777628 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-17T14:42:11Z |
| re-zero | Re Zero | all | [Yameii] Re ZERO, Starting Life in Another World - S04E11 [English Dub] [CR WEB-DL 1080p H264 AAC] [F7A0C8EE] | 1717498274 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-17T14:10:47Z |
| re-zero | Re Zero | all | [Yameii] Re ZERO, Starting Life in Another World - S04E11 [English Dub] [CR WEB-DL 1080p H264 AAC] [F7A0C8EE] (Re Zero kara Hajimeru Isekai Seikatsu Season 4   S4) | 156931799 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-17T15:49:09Z |
| re-zero | Re Zero | all | [Yameii] Re ZERO, Starting Life in Another World - S04E11 [English Dub] [CR WEB-DL 720p H264 AAC] [57B9D1DC] | 795328470 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-17T14:20:58Z |
| re-zero | Re Zero | all | [Yameii] Re ZERO, Starting Life in Another World - S04E11 [English Dub] [CR WEB-DL 720p H264 AAC] [57B9D1DC] | 890411707 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-17T14:08:17Z |
| re-zero | Re Zero | all | [Z-A] Re Zero kara Hajimeru Isekai Seikatsu - S04E10 (WEB 1080p AAC) | 159559929 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-16T01:12:28Z |
| re-zero | Re Zero | all | [Z-A] Re Zero kara Hajimeru Isekai Seikatsu - S04E10 (WEB 1080p AAC) [4549F3CC] | 1574654222 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-16T01:11:30Z |
| re-zero | Re Zero | anime | Re ZERO Starting Life in Another World S04E10 MULTi AD 1080p CR WEB-DL AAC2.0 x264-Tsundere-Raws (VF, FRENCH, SUBFRENCH, VOSTFR, ReZero kara Hajimeru Isekai Seikatsu, ReZero) | 158278568 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-10T22:50:10Z |
| re-zero | Re Zero | anime | Re ZERO Starting Life in Another World S04E11 1080p CR WEB-DL DUAL AAC2.0 H 264-VARYG (Re Zero kara Hajimeru Isekai Seikatsu 2nd Season Part 2, Dual-Audio, Multi-Subs) | 162948255 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-17T14:33:27Z |
| re-zero | Re Zero | anime | Re ZERO Starting Life in Another World S04E11 MULTi 1080p CR WEB-DL AAC2.0 x264-Tsundere-Raws (VF, FRENCH, SUBFRENCH, VOSTFR, ReZero kara Hajimeru Isekai Seikatsu, ReZero) | 160277680 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-18T00:12:40Z |
| re-zero | Re Zero | anime | Re.ZERO.Starting.Life.in.Another.World.S04E10.1080p.WEBRip.Dual.Audio.AV1-Breeze | 1734322521 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-15T22:42:22Z |
| re-zero | Re Zero | anime | Re.ZERO.Starting.Life.in.Another.World.S04E10.1080p.WEBRip.Dual.Audio.AV1-Sokudo | 783213656 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-15T22:42:02Z |
| re-zero | Re Zero | anime | Re.ZERO.Starting.Life.in.Another.World.S04E11.1080p.CR.WEB-DL.DUAL.AAC2.0.H.264-VARYG | 1773396346 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-17T14:26:57Z |
| re-zero | Re Zero | anime | Re.ZERO.Starting.Life.in.Another.World.S04E11.1080p.CR.WEB-DL.MULTi.AAC2.0.H.264-VARYG | 2016114417 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-17T16:52:08Z |
| re-zero | Re Zero | anime | Re.ZERO.Starting.Life.in.Another.World.S04E11.Re.ZERO-Starting.Life.in.Another.World-1080p.CR.WEB-DL.MULTi.AAC2.0.H.264-VARYG | 2015967437 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-24T14:47:34Z |
| re-zero | Re Zero | anime | [ASW] Re Zero kara Hajimeru Isekai Seikatsu - 76 [1080p HEVC][DEC7A29E] | 403655074 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-10T16:05:23Z |
| re-zero | Re Zero | anime | [ASW] Re Zero kara Hajimeru Isekai Seikatsu - 77 [1080p HEVC][C36D2BFD] | 200612087 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-17T16:06:14Z |
| re-zero | Re Zero | anime | [ASW] Re Zero kara Hajimeru Isekai Seikatsu - 77 [1080p HEVC][C36D2BFD] | 220927081 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-17T15:41:20Z |
| re-zero | Re Zero | anime | [Breeze] Re ZERO - Starting Life in Another World S04E10 [1080p AV1][Dual Audio]   Re ZERO   ReZero   Re Zero (weekly) | 159580781 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-16T00:45:11Z |
| re-zero | Re Zero | anime | [DB] Re Zero kara Hajimeru Isekai Seikatsu 4th Season Part 1   Re ZERO -Starting Life in Another World- Season 4 Part 1 [Dual Audio 10bit 1080p][HEVC-x265] | 577361039 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-27T01:06:19Z |
| re-zero | Re Zero | anime | [Erai-raws] Re Zero kara Hajimeru Isekai Seikatsu 3rd Season - 04 [1080p][Multiple Subtitle][F0A4E05F] | 105313164 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-16T00:11:41Z |
| re-zero | Re Zero | anime | [Erai-raws] Re Zero kara Hajimeru Isekai Seikatsu 3rd Season - 04 [1080p][Multiple Subtitle][F0A4E05F] | 152575997 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-14T03:00:44Z |
| re-zero | Re Zero | anime | [Erai-raws] Re Zero kara Hajimeru Isekai Seikatsu 4th Season - 10 [1080p CR WEB-DL AVC AAC][MultiSub][24DC5CD5] | 1648307309 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-10T15:34:20Z |
| re-zero | Re Zero | anime | [Erai-raws] Re Zero kara Hajimeru Isekai Seikatsu 4th Season - 10 [1080p CR WEBRip HEVC AAC][MultiSub][7008AC6F] | 682700089 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-10T18:02:25Z |
| re-zero | Re Zero | anime | [Erai-raws] Re Zero kara Hajimeru Isekai Seikatsu 4th Season - 10 [1080p CR WEBRip HEVC AAC][MultiSub][7008AC6F] | 682820487 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-10T16:47:45Z |
| re-zero | Re Zero | anime | [Erai-raws] Re Zero kara Hajimeru Isekai Seikatsu 4th Season - 10 [720p CR WEB-DL AVC AAC][MultiSub][91822E93] | 500570960 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-10T15:26:33Z |
| re-zero | Re Zero | anime | [Erai-raws] Re Zero kara Hajimeru Isekai Seikatsu 4th Season - 11 [1080p CR WEB-DL AVC AAC][MultiSub][2AF91E1B] | 1706719809 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-17T14:19:23Z |
| re-zero | Re Zero | anime | [Erai-raws] Re Zero kara Hajimeru Isekai Seikatsu 4th Season - 11 [1080p CR WEB-DL AVC AAC][MultiSub][2AF91E1B] | 1707673970 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-17T15:21:46Z |
| re-zero | Re Zero | anime | [Erai-raws] Re Zero kara Hajimeru Isekai Seikatsu 4th Season - 11 [1080p CR WEBRip HEVC AAC][MultiSub][98C2DCC6] | 522099168 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-17T16:48:25Z |
| re-zero | Re Zero | anime | [Erai-raws] Re Zero kara Hajimeru Isekai Seikatsu 4th Season - 11 [1080p CR WEBRip HEVC AAC][MultiSub][98C2DCC6] | 522188667 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-17T15:49:20Z |
| re-zero | Re Zero | anime | [Erai-raws] Re Zero kara Hajimeru Isekai Seikatsu 4th Season - 11 [720p CR WEB-DL AVC AAC][MultiSub][3725B72C] | 342922989 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-17T15:08:45Z |
| re-zero | Re Zero | anime | [FLE] Re ZERO Starting Life in Another World - S04E10 (WEB 1080p HEVC E-AC-3) [Dual Audio] [00C5F5BE] | 2358403477 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-14T17:22:10Z |
| re-zero | Re Zero | anime | [FLE] Re ZERO Starting Life in Another World - S04E11 (WEB 1080p HEVC E-AC-3) [Dual Audio] [0036291E] | 1039295626 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-26T18:22:01Z |
| re-zero | Re Zero | anime | [FLE] Re ZERO Starting Life in Another World - S04E11 (WEB 1080p HEVC E-AC-3) [Dual Audio] [0036291E] | 1143663407 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-26T13:13:28Z |
| re-zero | Re Zero | anime | [Feibanyama] ReZERO Starting Life in Another World S04E10 [IQIYI WebRip 2160p HEVC AAC Multi-Audio Multi-Subs] (Re Zero kara Hajimeru Isekai Seikatsu) | 174454170 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-21T09:54:36Z |
| re-zero | Re Zero | anime | [Judas] Re.Zero - S04E11 | 283844555 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-17T15:40:20Z |
| re-zero | Re Zero | anime | [Onalrie] Re Zero kara Hajimeru Isekai Seikatsu - S04E10 [1080p WEBRip AV1] | 245344889 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-10T15:56:45Z |
| re-zero | Re Zero | anime | [Onalrie] Re Zero kara Hajimeru Isekai Seikatsu - S04E11 [1080p WEBRip AV1] | 168587346 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-17T15:10:14Z |
| re-zero | Re Zero | anime | [Onalrie] Re Zero kara Hajimeru Isekai Seikatsu - S04E11 [1080p WEBRip AV1] | 169082437 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-17T15:51:05Z |
| re-zero | Re Zero | anime | [SubsPlease] Re Zero kara Hajimeru Isekai Seikatsu - 65 (1080p) [743EBD8B] | 164096465 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-07-08T20:45:10Z |
| re-zero | Re Zero | anime | [SubsPlease] Re Zero kara Hajimeru Isekai Seikatsu - 76 (720p) [F2FF47F7] | 841101513 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-10T15:32:50Z |
| re-zero | Re Zero | anime | [SubsPlease] Re Zero kara Hajimeru Isekai Seikatsu - 77 (1080p) [F7DAEC64] | 1700601663 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-17T14:15:27Z |
| re-zero | Re Zero | anime | [SubsPlease] Re Zero kara Hajimeru Isekai Seikatsu - 77 (1080p) [F7DAEC64] | 1700949559 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-17T15:28:31Z |
| re-zero | Re Zero | anime | [SubsPlease] Re Zero kara Hajimeru Isekai Seikatsu - 77 (720p) [E00DF851] | 872242478 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-17T15:34:30Z |
| re-zero | Re Zero | anime | [ToonsHub] ReZERO -Starting Life in Another World- S04E11 1080p CR WEB-DL DUAL AAC2.0 H.264 (Re Zero kara Hajimeru Isekai Seikatsu, Dual-Audio, Multi-Subs) | 162940596 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-17T14:48:09Z |
| re-zero | Re Zero | anime | [ToonsHub] ReZERO -Starting Life in Another World- S04E11 1080p CR WEB-DL MULTi AAC2.0 H.264 (Re Zero kara Hajimeru Isekai Seikatsu, Multi-Audio, Multi-Subs) | 185212273 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-17T16:04:57Z |
| re-zero | Re Zero | anime | [VARYG] Re ZERO Starting Life in Another World S04E11 1080p CR WEB-DL MULTi AAC2.0 H.264 (Re Zero kara Hajimeru Isekai Seikatsu, Multi-Subs) | 185920623 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-17T17:49:11Z |
| re-zero | Re Zero | anime | [Yameii] Re ZERO, Starting Life in Another World - S04E10 [English Dub] [CR WEB-DL 720p H264 AAC] [79AD2AE2] | 766474066 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-10T20:31:26Z |
| re-zero | Re Zero | anime | [Yameii] Re ZERO, Starting Life in Another World - S04E10 [English Dub] [CR WEB-DL 720p H264 AAC] [79AD2AE2] | 859294418 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-10T17:21:21Z |
| re-zero | Re Zero | anime | [Yameii] Re ZERO, Starting Life in Another World - S04E11 [English Dub] [CR WEB-DL 1080p H264 AAC] [F7A0C8EE] | 1547856458 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-17T15:47:56Z |
| re-zero | Re Zero | anime | [Yameii] Re ZERO, Starting Life in Another World - S04E11 [English Dub] [CR WEB-DL 1080p H264 AAC] [F7A0C8EE] | 1703777628 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-17T14:42:11Z |
| re-zero | Re Zero | anime | [Yameii] Re ZERO, Starting Life in Another World - S04E11 [English Dub] [CR WEB-DL 1080p H264 AAC] [F7A0C8EE] | 1717498274 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-17T14:10:47Z |
| re-zero | Re Zero | anime | [Yameii] Re ZERO, Starting Life in Another World - S04E11 [English Dub] [CR WEB-DL 1080p H264 AAC] [F7A0C8EE] (Re Zero kara Hajimeru Isekai Seikatsu Season 4   S4) | 156931799 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-17T15:49:09Z |
| re-zero | Re Zero | anime | [Yameii] Re ZERO, Starting Life in Another World - S04E11 [English Dub] [CR WEB-DL 720p H264 AAC] [57B9D1DC] | 795328470 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-17T14:20:58Z |
| re-zero | Re Zero | anime | [Yameii] Re ZERO, Starting Life in Another World - S04E11 [English Dub] [CR WEB-DL 720p H264 AAC] [57B9D1DC] | 890411707 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-17T14:08:17Z |
| re-zero | Re Zero | anime | [Z-A] Re Zero kara Hajimeru Isekai Seikatsu - S04E10 (WEB 1080p AAC) | 159559929 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-16T01:12:28Z |
| re-zero | Re Zero | anime | [Z-A] Re Zero kara Hajimeru Isekai Seikatsu - S04E10 (WEB 1080p AAC) [4549F3CC] | 1574654222 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-06-16T01:11:30Z |
| re-zero | Re Zero Season 2 | all | [Anime Time] Re Zero Season 2 (Part 1) [Dual Audio][BD][1080p][HEVC 10bit x265][Opus][Eng Sub] | 5834041085 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-06-17T07:16:15Z |
| re-zero | Re Zero Season 2 | all | [Anime Time] Re Zero Season 2 [Dual Audio][BD][1080p][HEVC 10bit x265][AAC][Eng Sub] | 12452846267 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-08-03T16:30:24Z |
| re-zero | Re Zero Season 2 | all | [Beatrice-Raws] Re Zero - Season 2 - Starting Life in Another World [BDRip 1920x1080 HEVC TrueHD] | 427293032 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-16T05:28:33Z |
| re-zero | Re Zero Season 2 | all | [Beatrice-Raws] Re Zero - Season 2 - Starting Life in Another World [BDRip 1920x1080 HEVC TrueHD] | 5790478788 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-04-01T08:04:03Z |
| re-zero | Re Zero Season 2 | all | [Beatrice-Raws] Re Zero - Season 2 - Starting Life in Another World [BDRip 1920x1080 HEVC TrueHD] (1) | 5711550133 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-16T05:27:58Z |
| re-zero | Re Zero Season 2 | all | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 05 [CR-Dub 1080p x264 AAC] [D93B0650] | 1730775753 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2020-09-23T21:16:15Z |
| re-zero | Re Zero Season 2 | all | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 06 [CR-Dub 1080p x264 AAC] [ECA8FA7B] | 1728609707 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2020-09-30T21:12:32Z |
| re-zero | Re Zero Season 2 | all | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 06 [CR-Dub 720p x264 AAC] [77BB85E7] | 880007018 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2020-09-30T21:15:04Z |
| re-zero | Re Zero Season 2 | all | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 07 [CR-Dub 1080p x264 AAC] [09483152] | 1747462223 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2020-10-07T21:16:16Z |
| re-zero | Re Zero Season 2 | all | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 07 [CR-Dub 720p x264 AAC] [E4E37561] | 890850012 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2020-10-07T21:15:21Z |
| re-zero | Re Zero Season 2 | all | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 08 [CR-Dub 1080p x264 AAC] [B1C2CFE9] | 1592822599 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2020-10-14T21:16:52Z |
| re-zero | Re Zero Season 2 | all | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 08 [CR-Dub 1080p x264 AAC] [B1C2CFE9] | 1592847539 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2020-10-15T09:20:27Z |
| re-zero | Re Zero Season 2 | all | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 08 [CR-Dub 720p x264 AAC] [4665C182] | 811248675 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2020-10-14T21:13:57Z |
| re-zero | Re Zero Season 2 | all | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 08 [CR-Dub 720p x264 AAC] [4665C182] | 811255770 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2020-10-15T09:21:00Z |
| re-zero | Re Zero Season 2 | all | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 09 [CR-Dub 1080p x264 AAC] [6CE2AB2D] | 1631759715 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2020-10-21T21:33:33Z |
| re-zero | Re Zero Season 2 | all | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 09 [CR-Dub 720p x264 AAC] [7C31A4A8] | 827216102 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2020-10-21T21:31:15Z |
| re-zero | Re Zero Season 2 | all | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 10 [CR-Dub 1080p x264 AAC] [79BF03A1] | 1748527438 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2020-10-28T21:00:30Z |
| re-zero | Re Zero Season 2 | all | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 10 [CR-Dub 720p x264 AAC] [CDD7CB27] | 889841286 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2020-10-28T20:57:53Z |
| re-zero | Re Zero Season 2 | all | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 11 [CR-Dub 1080p x264 AAC] [43A81A20] | 1727867833 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2020-11-04T21:19:56Z |
| re-zero | Re Zero Season 2 | all | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 11 [CR-Dub 720p x264 AAC] [94E00C7A] | 876911217 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2020-11-04T21:15:05Z |
| re-zero | Re Zero Season 2 | all | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 12 [CR-Dub 1080p x264 AAC] [6450D848] | 1780922987 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2020-11-11T21:21:59Z |
| re-zero | Re Zero Season 2 | all | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 12 [CR-Dub 720p x264 AAC] [5F7EABC7] | 906669376 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2020-11-11T21:17:19Z |
| re-zero | Re Zero Season 2 | all | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 13 END [CR-Dub 1080p x264 AAC] [0D6C2488] | 1784645606 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2020-11-19T04:26:57Z |
| re-zero | Re Zero Season 2 | all | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 13 END [CR-Dub 1080p x264 AAC] [5886D947] | 1786055801 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2020-11-18T21:42:43Z |
| re-zero | Re Zero Season 2 | all | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 13 END [CR-Dub 720p x264 AAC] [2B44186A] | 906710376 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2020-11-18T21:37:19Z |
| re-zero | Re Zero Season 2 | all | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 13 END [CR-Dub 720p x264 AAC] [509877BE] | 905234635 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2020-11-19T04:16:39Z |
| re-zero | Re Zero Season 2 | all | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 14 [CR-Dub 1080p x264 AAC] [42A91AB8] | 1941257566 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-03-03T21:14:37Z |
| re-zero | Re Zero Season 2 | all | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 14 [CR-Dub 720p x264 AAC] [1D8D74AF] | 984416220 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-03-03T21:14:03Z |
| re-zero | Re Zero Season 2 | all | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 15 [CR-Dub 1080p x264 AAC] [5CA99EB6] | 1896254641 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-03-10T21:20:55Z |
| re-zero | Re Zero Season 2 | all | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 15 [CR-Dub 720p x264 AAC] [57F3C5E8] | 960681163 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-03-10T21:22:15Z |
| re-zero | Re Zero Season 2 | all | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 16 [CR-Dub 1080p x264 AAC] [18087E67] | 2042605458 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-03-17T20:17:55Z |
| re-zero | Re Zero Season 2 | all | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 16 [CR-Dub 720p x264 AAC] [F2FFC692] | 1036560361 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-03-17T20:17:14Z |
| re-zero | Re Zero Season 2 | all | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 17 [CR-Dub 1080p x264 AAC] [2F29C9C8] | 2046097255 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-03-24T20:20:16Z |
| re-zero | Re Zero Season 2 | all | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 17 [CR-Dub 720p x264 AAC] [EB944255] | 1038698916 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-03-24T20:19:29Z |
| re-zero | Re Zero Season 2 | all | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 18 [CR-Dub 1080p x264 AAC] [F07FF779] | 2035720007 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-03-31T21:19:50Z |
| re-zero | Re Zero Season 2 | all | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 18 [CR-Dub 720p x264 AAC] [521FA60E] | 1038497914 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-03-31T21:21:44Z |
| re-zero | Re Zero Season 2 | all | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 19 [CR-Dub 1080p x264 AAC] [2C96FA55] | 2039649240 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-04-07T21:16:37Z |
| re-zero | Re Zero Season 2 | all | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 19 [CR-Dub 720p x264 AAC] [D3F240A2] | 1035273442 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-04-07T21:16:19Z |
| re-zero | Re Zero Season 2 | all | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 20 [CR-Dub 1080p x264 AAC] [2A7D564B] | 2035824073 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-04-14T23:09:22Z |
| re-zero | Re Zero Season 2 | all | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 20 [CR-Dub 720p x264 AAC] [B1226C26] | 1035655475 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-04-14T23:02:00Z |
| re-zero | Re Zero Season 2 | all | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 21 [CR-Dub 1080p x264 AAC] [9DB99A5E] | 2039871694 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-04-21T21:20:43Z |
| re-zero | Re Zero Season 2 | all | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 21 [CR-Dub 720p x264 AAC] [62E55CE5] | 1038128313 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-04-21T21:19:38Z |
| re-zero | Re Zero Season 2 | all | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 22 [CR-Dub 1080p x264 AAC] [080B431B] | 2003482718 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-04-28T21:14:10Z |
| re-zero | Re Zero Season 2 | all | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 22 [CR-Dub 720p x264 AAC] [E9CBACBB] | 1019634939 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-04-28T21:15:13Z |
| re-zero | Re Zero Season 2 | all | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 23 [CR-Dub 1080p x264 AAC] [C7D27D70] | 2034212190 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-05-05T21:41:22Z |
| re-zero | Re Zero Season 2 | all | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 23 [CR-Dub 720p x264 AAC] [8456C12B] | 1037481073 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-05-05T21:43:32Z |
| re-zero | Re Zero Season 2 | all | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 24 [CR-Dub 1080p x264 AAC] [618C39FE] | 2040433680 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-05-12T22:03:45Z |
| re-zero | Re Zero Season 2 | all | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 24 [CR-Dub 720p x264 AAC] [193DFA78] | 1035674151 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-05-12T22:10:32Z |
| re-zero | Re Zero Season 2 | all | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 25 END [CR-Dub 1080p x264 AAC] [700FD01E] | 2039846246 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-05-19T21:14:36Z |
| re-zero | Re Zero Season 2 | all | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 25 END [CR-Dub 720p x264 AAC] [EBFC674C] | 1035603272 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-05-19T21:13:00Z |
| re-zero | Re Zero Season 2 | anime | [Anime Time] Re Zero Season 2 (Part 1) [Dual Audio][BD][1080p][HEVC 10bit x265][Opus][Eng Sub] | 5834041085 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-06-17T07:16:15Z |
| re-zero | Re Zero Season 2 | anime | [Anime Time] Re Zero Season 2 [Dual Audio][BD][1080p][HEVC 10bit x265][AAC][Eng Sub] | 12452846267 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-08-03T16:30:24Z |
| re-zero | Re Zero Season 2 | anime | [Beatrice-Raws] Re Zero - Season 2 - Starting Life in Another World [BDRip 1920x1080 HEVC TrueHD] | 427293032 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-16T05:28:33Z |
| re-zero | Re Zero Season 2 | anime | [Beatrice-Raws] Re Zero - Season 2 - Starting Life in Another World [BDRip 1920x1080 HEVC TrueHD] | 5790478788 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-04-01T08:04:03Z |
| re-zero | Re Zero Season 2 | anime | [Beatrice-Raws] Re Zero - Season 2 - Starting Life in Another World [BDRip 1920x1080 HEVC TrueHD] (1) | 5711550133 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-16T05:27:58Z |
| re-zero | Re Zero Season 2 | anime | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 05 [CR-Dub 1080p x264 AAC] [D93B0650] | 1730775753 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2020-09-23T21:16:15Z |
| re-zero | Re Zero Season 2 | anime | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 06 [CR-Dub 1080p x264 AAC] [ECA8FA7B] | 1728609707 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2020-09-30T21:12:32Z |
| re-zero | Re Zero Season 2 | anime | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 06 [CR-Dub 720p x264 AAC] [77BB85E7] | 880007018 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2020-09-30T21:15:04Z |
| re-zero | Re Zero Season 2 | anime | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 07 [CR-Dub 1080p x264 AAC] [09483152] | 1747462223 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2020-10-07T21:16:16Z |
| re-zero | Re Zero Season 2 | anime | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 07 [CR-Dub 720p x264 AAC] [E4E37561] | 890850012 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2020-10-07T21:15:21Z |
| re-zero | Re Zero Season 2 | anime | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 08 [CR-Dub 1080p x264 AAC] [B1C2CFE9] | 1592822599 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2020-10-14T21:16:52Z |
| re-zero | Re Zero Season 2 | anime | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 08 [CR-Dub 1080p x264 AAC] [B1C2CFE9] | 1592847539 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2020-10-15T09:20:27Z |
| re-zero | Re Zero Season 2 | anime | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 08 [CR-Dub 720p x264 AAC] [4665C182] | 811248675 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2020-10-14T21:13:57Z |
| re-zero | Re Zero Season 2 | anime | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 08 [CR-Dub 720p x264 AAC] [4665C182] | 811255770 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2020-10-15T09:21:00Z |
| re-zero | Re Zero Season 2 | anime | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 09 [CR-Dub 1080p x264 AAC] [6CE2AB2D] | 1631759715 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2020-10-21T21:33:33Z |
| re-zero | Re Zero Season 2 | anime | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 09 [CR-Dub 720p x264 AAC] [7C31A4A8] | 827216102 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2020-10-21T21:31:15Z |
| re-zero | Re Zero Season 2 | anime | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 10 [CR-Dub 1080p x264 AAC] [79BF03A1] | 1748527438 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2020-10-28T21:00:30Z |
| re-zero | Re Zero Season 2 | anime | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 10 [CR-Dub 720p x264 AAC] [CDD7CB27] | 889841286 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2020-10-28T20:57:53Z |
| re-zero | Re Zero Season 2 | anime | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 11 [CR-Dub 1080p x264 AAC] [43A81A20] | 1727867833 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2020-11-04T21:19:56Z |
| re-zero | Re Zero Season 2 | anime | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 11 [CR-Dub 720p x264 AAC] [94E00C7A] | 876911217 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2020-11-04T21:15:05Z |
| re-zero | Re Zero Season 2 | anime | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 12 [CR-Dub 1080p x264 AAC] [6450D848] | 1780922987 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2020-11-11T21:21:59Z |
| re-zero | Re Zero Season 2 | anime | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 12 [CR-Dub 720p x264 AAC] [5F7EABC7] | 906669376 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2020-11-11T21:17:19Z |
| re-zero | Re Zero Season 2 | anime | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 13 END [CR-Dub 1080p x264 AAC] [0D6C2488] | 1784645606 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2020-11-19T04:26:57Z |
| re-zero | Re Zero Season 2 | anime | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 13 END [CR-Dub 1080p x264 AAC] [5886D947] | 1786055801 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2020-11-18T21:42:43Z |
| re-zero | Re Zero Season 2 | anime | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 13 END [CR-Dub 720p x264 AAC] [2B44186A] | 906710376 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2020-11-18T21:37:19Z |
| re-zero | Re Zero Season 2 | anime | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 13 END [CR-Dub 720p x264 AAC] [509877BE] | 905234635 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2020-11-19T04:16:39Z |
| re-zero | Re Zero Season 2 | anime | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 14 [CR-Dub 1080p x264 AAC] [42A91AB8] | 1941257566 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-03-03T21:14:37Z |
| re-zero | Re Zero Season 2 | anime | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 14 [CR-Dub 720p x264 AAC] [1D8D74AF] | 984416220 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-03-03T21:14:03Z |
| re-zero | Re Zero Season 2 | anime | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 15 [CR-Dub 1080p x264 AAC] [5CA99EB6] | 1896254641 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-03-10T21:20:55Z |
| re-zero | Re Zero Season 2 | anime | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 15 [CR-Dub 720p x264 AAC] [57F3C5E8] | 960681163 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-03-10T21:22:15Z |
| re-zero | Re Zero Season 2 | anime | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 16 [CR-Dub 1080p x264 AAC] [18087E67] | 2042605458 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-03-17T20:17:55Z |
| re-zero | Re Zero Season 2 | anime | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 16 [CR-Dub 720p x264 AAC] [F2FFC692] | 1036560361 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-03-17T20:17:14Z |
| re-zero | Re Zero Season 2 | anime | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 17 [CR-Dub 1080p x264 AAC] [2F29C9C8] | 2046097255 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-03-24T20:20:16Z |
| re-zero | Re Zero Season 2 | anime | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 17 [CR-Dub 720p x264 AAC] [EB944255] | 1038698916 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-03-24T20:19:29Z |
| re-zero | Re Zero Season 2 | anime | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 18 [CR-Dub 1080p x264 AAC] [F07FF779] | 2035720007 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-03-31T21:19:50Z |
| re-zero | Re Zero Season 2 | anime | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 18 [CR-Dub 720p x264 AAC] [521FA60E] | 1038497914 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-03-31T21:21:44Z |
| re-zero | Re Zero Season 2 | anime | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 19 [CR-Dub 1080p x264 AAC] [2C96FA55] | 2039649240 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-04-07T21:16:37Z |
| re-zero | Re Zero Season 2 | anime | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 19 [CR-Dub 720p x264 AAC] [D3F240A2] | 1035273442 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-04-07T21:16:19Z |
| re-zero | Re Zero Season 2 | anime | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 20 [CR-Dub 1080p x264 AAC] [2A7D564B] | 2035824073 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-04-14T23:09:22Z |
| re-zero | Re Zero Season 2 | anime | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 20 [CR-Dub 720p x264 AAC] [B1226C26] | 1035655475 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-04-14T23:02:00Z |
| re-zero | Re Zero Season 2 | anime | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 21 [CR-Dub 1080p x264 AAC] [9DB99A5E] | 2039871694 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-04-21T21:20:43Z |
| re-zero | Re Zero Season 2 | anime | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 21 [CR-Dub 720p x264 AAC] [62E55CE5] | 1038128313 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-04-21T21:19:38Z |
| re-zero | Re Zero Season 2 | anime | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 22 [CR-Dub 1080p x264 AAC] [080B431B] | 2003482718 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-04-28T21:14:10Z |
| re-zero | Re Zero Season 2 | anime | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 22 [CR-Dub 720p x264 AAC] [E9CBACBB] | 1019634939 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-04-28T21:15:13Z |
| re-zero | Re Zero Season 2 | anime | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 23 [CR-Dub 1080p x264 AAC] [C7D27D70] | 2034212190 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-05-05T21:41:22Z |
| re-zero | Re Zero Season 2 | anime | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 23 [CR-Dub 720p x264 AAC] [8456C12B] | 1037481073 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-05-05T21:43:32Z |
| re-zero | Re Zero Season 2 | anime | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 24 [CR-Dub 1080p x264 AAC] [618C39FE] | 2040433680 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-05-12T22:03:45Z |
| re-zero | Re Zero Season 2 | anime | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 24 [CR-Dub 720p x264 AAC] [193DFA78] | 1035674151 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-05-12T22:10:32Z |
| re-zero | Re Zero Season 2 | anime | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 25 END [CR-Dub 1080p x264 AAC] [700FD01E] | 2039846246 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-05-19T21:14:36Z |
| re-zero | Re Zero Season 2 | anime | [Golumpa] Re ZERO -Starting Life in Another World- Season 2 - 25 END [CR-Dub 720p x264 AAC] [EBFC674C] | 1035603272 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-05-19T21:13:00Z |
| your-name | Kimi no Na wa | all | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E03 - ENG UNCUT 1080p WEB H.264 -NanDesuKa (FUNi) | 746795000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:16:02Z |
| your-name | Kimi no Na wa | all | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E03 - ENG UNCUT 720p WEB H.264 -NanDesuKa (FUNi) | 440451000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:14:43Z |
| your-name | Kimi no Na wa | all | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E03 - UNCUT 1080p WEB H.264 -NanDesuKa (FUNi) | 769559000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:46:59Z |
| your-name | Kimi no Na wa | all | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E04 - ENG UNCUT 1080p WEB H.264 -NanDesuKa (FUNi) | 670470000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:20:30Z |
| your-name | Kimi no Na wa | all | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E04 - ENG UNCUT 720p WEB H.264 -NanDesuKa (FUNi) | 429445000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:17:01Z |
| your-name | Kimi no Na wa | all | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E04 - UNCUT 1080p WEB H.264 -NanDesuKa (FUNi) | 623590000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:49:01Z |
| your-name | Kimi no Na wa | all | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E05 - UNCUT 1080p WEB H.264 -NanDesuKa (FUNi) | 878298000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:51:02Z |
| your-name | Kimi no Na wa | all | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E05 - UNCUT 540p WEB H.264 -NanDesuKa (FUNi) | 186091000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:04:27Z |
| your-name | Kimi no Na wa | all | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E06 - ENG UNCUT 1080p WEB H.264 -NanDesuKa (FUNi) | 689985000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:23:13Z |
| your-name | Kimi no Na wa | all | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E06 - ENG UNCUT 720p WEB H.264 -NanDesuKa (FUNi) | 396650000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:19:40Z |
| your-name | Kimi no Na wa | all | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E06 - UNCUT 1080p WEB H.264 -NanDesuKa (FUNi) | 654567000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:52:53Z |
| your-name | Kimi no Na wa | all | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E06 - UNCUT 540p WEB H.264 -NanDesuKa (FUNi) | 172798000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:05:17Z |
| your-name | Kimi no Na wa | all | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E07 - ENG UNCUT 1080p WEB H.264 -NanDesuKa (FUNi) | 612291000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:25:42Z |
| your-name | Kimi no Na wa | all | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E07 - ENG UNCUT 720p WEB H.264 -NanDesuKa (FUNi) | 421314000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:21:37Z |
| your-name | Kimi no Na wa | all | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E07 - UNCUT 540p WEB H.264 -NanDesuKa (FUNi) | 197720000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:06:19Z |
| your-name | Kimi no Na wa | all | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E08 - UNCUT 1080p WEB H.264 -NanDesuKa (FUNi) | 695848000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:57:02Z |
| your-name | Kimi no Na wa | all | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E08 - UNCUT 540p WEB H.264 -NanDesuKa (FUNi) | 195910000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:07:39Z |
| your-name | Kimi no Na wa | all | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E09 - ENG UNCUT 1080p WEB H.264 -NanDesuKa (FUNi) | 739482000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:28:15Z |
| your-name | Kimi no Na wa | all | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E09 - ENG UNCUT 720p WEB H.264 -NanDesuKa (FUNi) | 402243000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:23:18Z |
| your-name | Kimi no Na wa | all | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E09 - UNCUT 1080p WEB H.264 -NanDesuKa (FUNi) | 804101000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:59:02Z |
| your-name | Kimi no Na wa | all | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E09 - UNCUT 540p WEB H.264 -NanDesuKa (FUNi) | 177945000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:08:50Z |
| your-name | Kimi no Na wa | all | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E10 - ENG UNCUT 1080p WEB H.264 -NanDesuKa (FUNi) | 757693000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:30:58Z |
| your-name | Kimi no Na wa | all | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E10 - ENG UNCUT 720p WEB H.264 -NanDesuKa (FUNi) | 367670000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:24:47Z |
| your-name | Kimi no Na wa | all | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E11 - ENG UNCUT 1080p WEB H.264 -NanDesuKa (FUNi) | 687270000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:33:53Z |
| your-name | Kimi no Na wa | all | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E11 - ENG UNCUT 720p WEB H.264 -NanDesuKa (FUNi) | 443560000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:26:12Z |
| your-name | Kimi no Na wa | all | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E11 - UNCUT 1080p WEB H.264 -NanDesuKa (FUNi) | 953864000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T22:00:56Z |
| your-name | Kimi no Na wa | all | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E11 - UNCUT 540p WEB H.264 -NanDesuKa (FUNi) | 215712000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:09:42Z |
| your-name | Kimi no Na wa | all | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E11 - UNCUT 720p WEB H.264 -NanDesuKa (FUNi) | 348767000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:04:54Z |
| your-name | Kimi no Na wa | all | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E12 - ENG UNCUT 1080p WEB H.264 -NanDesuKa (FUNi) | 851143000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:36:59Z |
| your-name | Kimi no Na wa | all | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E12 - ENG UNCUT 720p WEB H.264 -NanDesuKa (FUNi) | 411027000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:27:46Z |
| your-name | Kimi no Na wa | all | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E12 - UNCUT 1080p WEB H.264 -NanDesuKa (FUNi) | 738566000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T22:03:04Z |
| your-name | Kimi no Na wa | all | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E12 - UNCUT 540p WEB H.264 -NanDesuKa (FUNi) | 227325000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:10:33Z |
| your-name | Kimi no Na wa | all | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E12 - UNCUT 720p WEB H.264 -NanDesuKa (FUNi) | 410491000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:07:22Z |
| your-name | Kimi no Na wa | all | Kimi.no.Mana.wa.Rina.Witch.[WEB.1080p.x265.HEVC.WMV].EngSubs | 1626285000 | usenet | 6000:XXX, 6070:XXX/Other, 106000:, 106070: | 2024-03-12T09:56:25Z |
| your-name | Kimi no Na wa | all | Kimi.no.na.wa.aka.Your.Name.2016.BluRay.1080p.DTS-HD.MA.5.1.AVC.REMUX-FraMeSToR | 28639212000 | usenet | 2000:Movies, 2010:Movies/Foreign, 102000:, 102010: | 2021-12-11T02:55:36Z |
| your-name | Kimi no Na wa | all | Kimi.no.na.wa.aka.Your.Name.2016.UHD.BluRay.2160p.DTS-HD.MA.5.1.HEVC.REMUX-FraMeSToR | 54309057000 | usenet | 2000:Movies, 2010:Movies/Foreign, 102000:, 102010: | 2022-01-16T07:47:57Z |
| your-name | Kimi no Na wa | all | SKE48 - kono hi no chime wo wasurenai [Limited Edition] - 12 sono saki ni kimi ga ita (kenkyuusei) | 31305000 | usenet | 3000:Audio, 3040:Audio/Lossless, 103000:, 103040: | 2021-12-22T23:16:31Z |
| your-name | Kimi no Na wa | all | [MegaMTBB] Kimi no Na wa. [2016] [BD 1080p] [CE49A996] | 16318871000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-02-10T02:56:25Z |
| your-name | Kimi no Na wa | all | [MiniMTBB] Kimi no Na wa. [2016] [BD 1080p] [C8319553] | 2290527000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-02-10T02:50:39Z |
| your-name | Kimi no Na wa | all | [MiniMTBB] Kimi no Na wa. [2016] [v2] [BD 1080p] [EEB45FD2] | 1866779000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-02-12T22:24:03Z |
| your-name | Kimi no Na wa | all | [Moozzi2] Kimi no Na wa. (BD 1920x1080 x.264 DTS-HDMAx4) | 10822680000 | usenet | 2000:Movies, 2010:Movies/Foreign, 102000:, 102010: | 2024-06-30T09:21:15Z |
| your-name | Kimi no Na wa | all | [Moozzi2] Kimi no Na wa. (BD 1920x1080 x.264-10Bit DTS-HDMAx4) | 12924274000 | usenet | 2000:Movies, 2010:Movies/Foreign, 102000:, 102010: | 2024-06-30T09:22:09Z |
| your-name | Kimi no Na wa | all | [Moozzi2] Kimi no Na wa. [ 1080p Ver. ]-Movie + Tokuten BD | 47299023000 | usenet | 2000:Movies, 2010:Movies/Foreign, 102000:, 102010: | 2025-08-29T07:02:44Z |
| your-name | Kimi no Na wa | all | [Moozzi2] Kimi no Na wa. [ 10Bit Ver. ]-Movie + Tokuten BD | 58141900000 | usenet | 2000:Movies, 2010:Movies/Foreign, 102000:, 102010: | 2025-08-29T07:38:18Z |
| your-name | Kimi no Na wa | all | [Moozzi2] Kimi no Na wa. [BD 1920x1080 x.264 DTS-HDMAx4] | 10822680000 | usenet | 2000:Movies, 2010:Movies/Foreign, 102000:, 102010: | 2025-08-29T06:48:46Z |
| your-name | Kimi no Na wa | all | [Moozzi2] Kimi no Na wa. [BD 1920x1080 x.264-10Bit DTS-HDMAx4] | 12924321000 | usenet | 2000:Movies, 2010:Movies/Foreign, 102000:, 102010: | 2025-08-29T07:12:08Z |
| your-name | Kimi no Na wa | all | [Moozzi2] Shigatsu wa Kimi no Uso-Finale Event [BD 1920x1080 x.264 Flac] | 8315300000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-09-11T22:45:23Z |
| your-name | Kimi no Na wa | all | [Moozzi2] Shigatsu wa Kimi no Uso-Finale Event-Event + SP | 11325736000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-09-11T22:46:36Z |
| your-name | Kimi no Na wa | all | [The-Nut] Kimi no Na wa \| Your Name [BD UHD AV1 HDR Opus] | 1801257000 | usenet | 2000:Movies, 2010:Movies/Foreign, 102000:, 102010: | 2023-03-08T03:42:49Z |
| your-name | Kimi no Na wa | all | murashita kozo - seiryou aichoban - 09 owaranai kimi no natsu | 25168000 | usenet | 3000:Audio, 3040:Audio/Lossless, 103000:, 103040: | 2024-05-20T10:11:13Z |
| your-name | Kimi no Na wa | anime | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E03 - ENG UNCUT 1080p WEB H.264 -NanDesuKa (FUNi) | 746795000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:16:02Z |
| your-name | Kimi no Na wa | anime | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E03 - ENG UNCUT 720p WEB H.264 -NanDesuKa (FUNi) | 440451000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:14:43Z |
| your-name | Kimi no Na wa | anime | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E03 - UNCUT 1080p WEB H.264 -NanDesuKa (FUNi) | 769559000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:46:59Z |
| your-name | Kimi no Na wa | anime | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E03 - UNCUT 540p WEB H.264 -NanDesuKa (FUNi) | 225082000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:01:47Z |
| your-name | Kimi no Na wa | anime | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E04 - ENG UNCUT 1080p WEB H.264 -NanDesuKa (FUNi) | 670470000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:20:30Z |
| your-name | Kimi no Na wa | anime | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E04 - ENG UNCUT 720p WEB H.264 -NanDesuKa (FUNi) | 429445000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:17:01Z |
| your-name | Kimi no Na wa | anime | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E04 - UNCUT 1080p WEB H.264 -NanDesuKa (FUNi) | 623590000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:49:01Z |
| your-name | Kimi no Na wa | anime | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E04 - UNCUT 540p WEB H.264 -NanDesuKa (FUNi) | 180123000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:03:12Z |
| your-name | Kimi no Na wa | anime | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E05 - UNCUT 1080p WEB H.264 -NanDesuKa (FUNi) | 878298000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:51:02Z |
| your-name | Kimi no Na wa | anime | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E05 - UNCUT 540p WEB H.264 -NanDesuKa (FUNi) | 186091000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:04:27Z |
| your-name | Kimi no Na wa | anime | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E06 - ENG UNCUT 1080p WEB H.264 -NanDesuKa (FUNi) | 689985000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:23:13Z |
| your-name | Kimi no Na wa | anime | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E06 - ENG UNCUT 540p WEB H.264 -NanDesuKa (FUNi) | 161932000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T20:53:01Z |
| your-name | Kimi no Na wa | anime | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E06 - ENG UNCUT 720p WEB H.264 -NanDesuKa (FUNi) | 396650000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:19:40Z |
| your-name | Kimi no Na wa | anime | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E06 - UNCUT 1080p WEB H.264 -NanDesuKa (FUNi) | 654567000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:52:53Z |
| your-name | Kimi no Na wa | anime | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E06 - UNCUT 540p WEB H.264 -NanDesuKa (FUNi) | 172798000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:05:17Z |
| your-name | Kimi no Na wa | anime | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E06 - UNCUT 720p WEB H.264 -NanDesuKa (FUNi) | 370597000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T20:54:40Z |
| your-name | Kimi no Na wa | anime | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E07 - ENG UNCUT 1080p WEB H.264 -NanDesuKa (FUNi) | 612291000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:25:42Z |
| your-name | Kimi no Na wa | anime | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E07 - ENG UNCUT 540p WEB H.264 -NanDesuKa (FUNi) | 212369000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T20:53:57Z |
| your-name | Kimi no Na wa | anime | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E07 - ENG UNCUT 720p WEB H.264 -NanDesuKa (FUNi) | 421314000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:21:37Z |
| your-name | Kimi no Na wa | anime | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E07 - UNCUT 540p WEB H.264 -NanDesuKa (FUNi) | 197720000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:06:19Z |
| your-name | Kimi no Na wa | anime | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E07 - UNCUT 720p WEB H.264 -NanDesuKa (FUNi) | 458058000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T20:56:44Z |
| your-name | Kimi no Na wa | anime | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E08 - UNCUT 1080p WEB H.264 -NanDesuKa (FUNi) | 695848000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:57:02Z |
| your-name | Kimi no Na wa | anime | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E08 - UNCUT 540p WEB H.264 -NanDesuKa (FUNi) | 195910000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:07:39Z |
| your-name | Kimi no Na wa | anime | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E08 - UNCUT 720p WEB H.264 -NanDesuKa (FUNi) | 416173000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T20:59:26Z |
| your-name | Kimi no Na wa | anime | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E09 - ENG UNCUT 1080p WEB H.264 -NanDesuKa (FUNi) | 739482000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:28:15Z |
| your-name | Kimi no Na wa | anime | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E09 - ENG UNCUT 540p WEB H.264 -NanDesuKa (FUNi) | 198706000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T20:54:55Z |
| your-name | Kimi no Na wa | anime | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E09 - ENG UNCUT 720p WEB H.264 -NanDesuKa (FUNi) | 402243000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:23:18Z |
| your-name | Kimi no Na wa | anime | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E09 - UNCUT 1080p WEB H.264 -NanDesuKa (FUNi) | 804101000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:59:02Z |
| your-name | Kimi no Na wa | anime | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E09 - UNCUT 540p WEB H.264 -NanDesuKa (FUNi) | 177945000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:08:50Z |
| your-name | Kimi no Na wa | anime | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E09 - UNCUT 720p WEB H.264 -NanDesuKa (FUNi) | 421912000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:02:34Z |
| your-name | Kimi no Na wa | anime | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E10 - ENG UNCUT 1080p WEB H.264 -NanDesuKa (FUNi) | 757693000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:30:58Z |
| your-name | Kimi no Na wa | anime | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E10 - ENG UNCUT 540p WEB H.264 -NanDesuKa (FUNi) | 237108000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T20:55:52Z |
| your-name | Kimi no Na wa | anime | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E10 - ENG UNCUT 720p WEB H.264 -NanDesuKa (FUNi) | 367670000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:24:47Z |
| your-name | Kimi no Na wa | anime | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E11 - ENG UNCUT 1080p WEB H.264 -NanDesuKa (FUNi) | 687270000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:33:53Z |
| your-name | Kimi no Na wa | anime | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E11 - ENG UNCUT 540p WEB H.264 -NanDesuKa (FUNi) | 201982000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T20:56:58Z |
| your-name | Kimi no Na wa | anime | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E11 - ENG UNCUT 720p WEB H.264 -NanDesuKa (FUNi) | 443560000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:26:12Z |
| your-name | Kimi no Na wa | anime | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E11 - UNCUT 1080p WEB H.264 -NanDesuKa (FUNi) | 953864000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T22:00:56Z |
| your-name | Kimi no Na wa | anime | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E11 - UNCUT 540p WEB H.264 -NanDesuKa (FUNi) | 215712000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:09:42Z |
| your-name | Kimi no Na wa | anime | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E11 - UNCUT 720p WEB H.264 -NanDesuKa (FUNi) | 348767000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:04:54Z |
| your-name | Kimi no Na wa | anime | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E12 - ENG UNCUT 1080p WEB H.264 -NanDesuKa (FUNi) | 851143000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:36:59Z |
| your-name | Kimi no Na wa | anime | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E12 - ENG UNCUT 540p WEB H.264 -NanDesuKa (FUNi) | 234710000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T20:58:28Z |
| your-name | Kimi no Na wa | anime | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E12 - ENG UNCUT 720p WEB H.264 -NanDesuKa (FUNi) | 411027000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:27:46Z |
| your-name | Kimi no Na wa | anime | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E12 - UNCUT 1080p WEB H.264 -NanDesuKa (FUNi) | 738566000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T22:03:04Z |
| your-name | Kimi no Na wa | anime | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E12 - UNCUT 540p WEB H.264 -NanDesuKa (FUNi) | 227325000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:10:33Z |
| your-name | Kimi no Na wa | anime | Kimi to Boku no Saigo no Senjou, Aruiwa Sekai ga Hajimaru Seisen - S01E12 - UNCUT 720p WEB H.264 -NanDesuKa (FUNi) | 410491000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-11-03T21:07:22Z |
| your-name | Kimi no Na wa | anime | [MegaMTBB] Kimi no Na wa. [2016] [BD 1080p] [CE49A996] | 16318871000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-02-10T02:56:25Z |
| your-name | Kimi no Na wa | anime | [MiniMTBB] Kimi no Na wa. [2016] [BD 1080p] [C8319553] | 2290527000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-02-10T02:50:39Z |
| your-name | Kimi no Na wa | anime | [MiniMTBB] Kimi no Na wa. [2016] [v2] [BD 1080p] [EEB45FD2] | 1866779000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2026-02-12T22:24:03Z |
| your-name | Kimi no Na wa | anime | [Moozzi2] Shigatsu wa Kimi no Uso-Finale Event [BD 1920x1080 x.264 Flac] | 8315300000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-09-11T22:45:23Z |
| your-name | Kimi no Na wa | anime | [Moozzi2] Shigatsu wa Kimi no Uso-Finale Event-Event + SP | 11325736000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2025-09-11T22:46:36Z |
| your-name | Your Name 2016 | all | IDW-Sounds.Of.Your.Name.2016.Hybrid.Comic.eBook-BitBook | 399997000 | usenet | 7000:Books, 7030:Books/Comics, 107000:, 107030: | 2021-09-27T23:08:51Z |
| your-name | Your Name 2016 | all | Kimi.no.na.wa.aka.Your.Name.2016.BluRay.1080p.DTS-HD.MA.5.1.AVC.REMUX-FraMeSToR | 28639212000 | usenet | 2000:Movies, 2010:Movies/Foreign, 102000:, 102010: | 2021-12-11T02:55:36Z |
| your-name | Your Name 2016 | all | Kimi.no.na.wa.aka.Your.Name.2016.UHD.BluRay.2160p.DTS-HD.MA.5.1.HEVC.REMUX-FraMeSToR | 54309057000 | usenet | 2000:Movies, 2010:Movies/Foreign, 102000:, 102010: | 2022-01-16T07:47:57Z |
| your-name | Your Name 2016 | all | Tia London--Scream Your Name Out Single-WEB-2016-WUS | 11635000 | usenet | 3000:Audio, 3010:Audio/MP3, 103000:, 103010: | 2024-08-25T00:27:33Z |
| your-name | Your Name 2016 | all | Your Name (2016) 1080p 10bits Eng - Ch - Jap subtitles BluRay x265 10bits AAC 5.1 - Deathrow | 6719898000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2019-10-28T18:10:37Z |
| your-name | Your Name 2016 | all | Your Name 2016 English Dubbed 1080p BluRay x264 [1.5GB] [Kimi no Na wa] | 1759138000 | usenet | 2000:Movies, 2050:Movies/BluRay, 102000:, 102050: | 2018-07-27T13:05:17Z |
| your-name | Your Name 2016 | all | Your Name 2016 English Dubbed 720p BluRay x264 [780MB] [Kimi no Na wa] | 894937000 | usenet | 2000:Movies, 2050:Movies/BluRay, 102000:, 102050: | 2018-07-27T13:03:57Z |
| your-name | Your Name 2016 | all | Your Name [2016] MULTi VFI 2160p 10bit 4KLight HDR BluRay DTS-HD MA 5.1 x265-QTZ | 5894427000 | usenet | 2000:Movies, 2010:Movies/Foreign, 102000:, 102010: | 2026-01-16T08:58:02Z |
| your-name | Your Name 2016 | all | Your Name. (2016) + Special Features [1080p x265 HEVC 10bit BluRay Dual Audio AAC 5.1] [Prof] | 10692237000 | usenet | 2000:Movies, 2050:Movies/BluRay, 102000:, 102050: | 2019-10-22T17:05:41Z |
| your-name | Your Name 2016 | all | Your Name. (2016) [BD 1080p] [Dub - Japanese , English , Arabic] [Sub - English , Arabic] | 1897861000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-10-25T12:52:29Z |
| your-name | Your Name 2016 | all | Your Name.2016.[Bluray 1080p][10bit][H264][AAC 2.0][Japanese][PLSUB+ENSUB][881CD8B7] | 7116794000 | usenet | 2000:Movies, 2010:Movies/Foreign, 102000:, 102010: | 2025-01-06T07:37:18Z |
| your-name | Your Name 2016 | all | Your.Name.2016.+.Special.Features.[1080p.x265.HEVC.10bit.BluRay.Dual.Audio.AAC.5.1].[Prof] | 5523980000 | usenet | 2000:Movies, 2050:Movies/BluRay, 102000:, 102050: | 2019-10-22T16:58:34Z |
| your-name | Your Name 2016 | all | Your.Name.2016.1080p.10bits.Eng-Ch-Jap.subtitles.BluRay.x265.10bits.AAC.5.1-Deathrow | 6771405000 | usenet | 2000:Movies, 2010:Movies/Foreign, 102000:, 102010: | 2019-10-28T18:10:41Z |
| your-name | Your Name 2016 | all | Your.Name.2016.1080p.AMZN.WEB-DL.DDP5.1.H.264.DUAL-gris | 8262260000 | usenet | 2000:Movies, 2010:Movies/Foreign, 102000:, 102010: | 2025-01-25T03:17:36Z |
| your-name | Your Name 2016 | all | Your.Name.2016.1080p.AMZN.WEB-DL.DDP5.1.H.264.DUAL-gris | 8262260000 | usenet | 2000:Movies, 2010:Movies/Foreign, 102000:, 102010: | 2025-01-28T20:54:13Z |
| your-name | Your Name 2016 | all | Your.Name.2016.1080p.BluRay.x264 | 1880084000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-03-11T12:33:14Z |
| your-name | Your Name 2016 | all | Your.Name.2016.1080p.BluRay.x264-[YTS.AM] | 1852856000 | usenet | 2000:Movies, 2050:Movies/BluRay, 102000:, 102050: | 2020-04-12T19:35:44Z |
| your-name | Your Name 2016 | all | Your.Name.2016.1080p.x265.Tri-Audio.Ita.Eng.Jap[Rady] | 13314532000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2020-11-16T03:02:16Z |
| your-name | Your Name 2016 | all | Your.Name.2016.2160p.BDRip.AAC.5.1.HDR10.x265.10bit-MarkII | 1781494000 | usenet | 2000:Movies, 2010:Movies/Foreign, 102000:, 102010: | 2022-01-30T18:13:29Z |
| your-name | Your Name 2016 | all | Your.Name.2016.2160p.BluRay.REMUX.DTS-HD.MA.5.1.DV.HDR.H.265-SasukeducK | 53941193000 | usenet | 2000:Movies, 2045:Movies/UHD, 102000:, 102045: | 2024-10-08T20:54:23Z |
| your-name | Your Name 2016 | all | Your.Name.2016.2160p.Opus.AV1 | 1416136000 | usenet | 2000:Movies, 2045:Movies/UHD, 102000:, 102045: | 2024-10-08T23:03:58Z |
| your-name | Your Name 2016 | all | Your.Name.2016.2160p.UHD.BluRay.AAC5.1.x265 | 4325185000 | usenet | 2000:Movies, 2045:Movies/UHD, 102000:, 102045: | 2019-03-10T16:47:39Z |
| your-name | Your Name 2016 | all | Your.Name.2016.BluRay.Remux.1080p.AVC.DTS.HD.MA.5.1-HiFi-AsRequested | 29748720000 | usenet | 2000:Movies, 2010:Movies/Foreign, 102000:, 102010: | 2022-03-06T09:49:04Z |
| your-name | Your Name 2016 | all | Your.Name.2016.Bluray.1080p.DDP.5.1.x264-hallowed | 5952524000 | usenet | 2000:Movies, 2050:Movies/BluRay, 102000:, 102050: | 2024-06-10T15:17:52Z |
| your-name | Your Name 2016 | all | Your.Name.2016.DUBBED.1080p.BluRay.H264.AAC | 2398903000 | usenet | 2000:Movies, 2050:Movies/BluRay, 102000:, 102050: | 2023-06-26T01:05:28Z |
| your-name | Your Name 2016 | all | Your.Name.2016.DUBBED.1080p.BluRay.x265 | 1951401000 | usenet | 2000:Movies, 2050:Movies/BluRay, 102000:, 102050: | 2023-09-05T21:45:04Z |
| your-name | Your Name 2016 | all | Your.Name.2016.DUBBED.1080p.BluRay.x265 | 1951401000 | usenet | 2000:Movies, 2050:Movies/BluRay, 102000:, 102050: | 2023-09-05T23:06:08Z |
| your-name | Your Name 2016 | all | Your.Name.2016.DVD5-NoGroup | 5764061000 | usenet | 2000:Movies, 2030:Movies/SD, 102000:, 102030: | 2018-07-05T20:00:09Z |
| your-name | Your Name 2016 | all | Your.Name.2016.GERMAN.DL.FLAC.1080p.Bluray.x264-SEELE | 14160506000 | usenet | 2000:Movies, 2010:Movies/Foreign, 102000:, 102010: | 2022-12-10T22:05:03Z |
| your-name | Your Name 2016 | all | Your.Name.2016.HKG.UHD.BluRay.Remux.2160p.HEVC.HDR.DTS-HD.MA.5.1-TaS0-AsRequested | 56493209000 | usenet | 2000:Movies, 2045:Movies/UHD, 102000:, 102045: | 2022-03-06T12:36:43Z |
| your-name | Your Name 2016 | all | Your.Name.2016.JPN.Hybrid.2160p.UHD.Blu-ray.Remux.AVC.DTS-HD.MA.5.1-BluDragon-AsRequested | 65981062000 | usenet | 2000:Movies, 2045:Movies/UHD, 102000:, 102045: | 2022-03-11T11:22:20Z |
| your-name | Your Name 2016 | all | Your.Name.2016.MULTi.2160p.UHD.BluRay.x265-SHiNiGAMiUHD | 10720908000 | usenet | 2000:Movies, 2045:Movies/UHD, 102000:, 102045: | 2021-07-18T15:22:20Z |
| your-name | Your Name 2016 | all | Your.Name.2016.PROPER.BluRay.1080p.REMUX.DTS-HD.MA.5.1.AVC-FraMeSToR-AsRequested | 33232389000 | usenet | 2000:Movies, 2050:Movies/BluRay, 102000:, 102050: | 2022-03-06T13:10:19Z |
| your-name | Your Name 2016 | all | Your.Name.2016.PROPER.UHD.BluRay.2160p.DTS-HD.MA.5.1.HEVC.REMUX-FraMeSToR | 54034946000 | usenet | 2000:Movies, 2045:Movies/UHD, 102000:, 102045: | 2023-03-12T00:07:40Z |
| your-name | Your Name 2016 | all | Your.Name.2016.PROPER.UHD.BluRay.2160p.DTS-HD.MA.5.1.HEVC.REMUX-FraMeSToR-AsRequested | 56245776000 | usenet | 2000:Movies, 2045:Movies/UHD, 102000:, 102045: | 2022-03-06T17:48:50Z |
| your-name | Your Name 2016 | all | Your.Name.2016.UHD.BluRay.2160p.DDP.5.1.HDR.x265-hallowed | 10798527000 | usenet | 2000:Movies, 2045:Movies/UHD, 102000:, 102045: | 2024-06-10T15:22:38Z |
| your-name | Your Name 2016 | all | Your.Name.2016.[1080p.x265.HEVC.10bit.BluRay.Dual.Audio.AAC.5.1].[Prof] | 5249424000 | usenet | 2000:Movies, 2050:Movies/BluRay, 102000:, 102050: | 2019-10-22T17:05:41Z |
| your-name | Your Name 2016 | all | [AnimeRG] Your Name (2016) [1080p BD 10bit] [Dual Audio 5.1 Channels] [JRR] (Kimi No Na Wa) | 1756495000 | usenet | 2000:Movies, 2040:Movies/HD, 102000:, 102040: | 2019-10-25T06:29:24Z |
| your-name | Your Name 2016 | all | [AnimeRG] Your Name (2016) [720p BD 10bit] [Dual Audio] [JRR] (Kimi no Na wa) | 892729000 | usenet | 2000:Movies, 2040:Movies/HD, 102000:, 102040: | 2019-10-25T08:16:39Z |
| your-name | Your Name 2016 | all | [AnimeRG].Your.Name.2016.[1080p.BD.10bit].[Dual.Audio.5.1.Channels].[JRR].Kimi.No.Na.Wa | 1769647000 | usenet | 2000:Movies, 2040:Movies/HD, 102000:, 102040: | 2019-10-25T06:29:23Z |
| your-name | Your Name 2016 | all | [AnimeRG].Your.Name.2016.[720p.BD.10bit].[Dual.Audio].[JRR].Kimi.no.Na.wa | 899455000 | usenet | 2000:Movies, 2040:Movies/HD, 102000:, 102040: | 2019-10-25T08:16:39Z |
| your-name | Your Name 2016 | all | [BlackRabbit] Your Name. [2016] [Bluray-2160p][Opus 5.1][Dual Audio][AV1] | 1925472000 | usenet | 2000:Movies, 2010:Movies/Foreign, 102000:, 102010: | 2026-04-06T13:38:45Z |
| your-name | Your Name 2016 | all | [FAV] Your Name. (2016) [BD 540p x264 AAC] [E5D72C1C] | 755858000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-03-08T19:59:31Z |
| your-name | Your Name 2016 | all | [FAV].Your.Name.2016.[BD.540p.x264.AAC].[E5D72C1C] | 737286000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-03-08T19:15:03Z |
| your-name | Your Name 2016 | all | [NoobSubs] your name. 2016 (1080p Blu-ray 8bit AC3) | 4654607000 | usenet | 2000:Movies, 2050:Movies/BluRay, 102000:, 102050: | 2018-07-21T22:08:11Z |
| your-name | Your Name 2016 | all | [NoobSubs] your name. 2016 (1080p Blu-ray 8bit AC3)-Obfuscated | 4729757000 | usenet | 2000:Movies, 2050:Movies/BluRay, 102000:, 102050: | 2018-07-21T23:02:48Z |
| your-name | Your Name 2016 | all | [NoobSubs] your name. 2016 (1080p Blu-ray 8bit Dual Audio)[818630D3] | 7020178000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2018-04-11T11:34:34Z |
| your-name | Your Name 2016 | all | [NoobSubs] your name. 2016 (2160p 4k Ultra Blu-ray HDR10 Dual Audio)[0731BD8C]-Obfuscated | 15656257000 | usenet | 2000:Movies, 2045:Movies/UHD, 102000:, 102045: | 2018-04-11T22:37:22Z |
| your-name | Your Name 2016 | all | [NoobSubs].your.name.2016.1080p.Blu-ray.8bit.Dual.Audio[818630D3] | 7034960000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2018-04-11T11:34:34Z |
| your-name | Your Name 2016 | all | [NoobSubs].your.name.2016.1080p.Blu-ray.Dual.Audio.8bit.AC3[AF224105] | 6357544000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2018-04-11T10:37:15Z |
| your-name | Your Name 2016 | anime | ????????your name.2016.HDrip.1080P HC eng sub AAC x264 | 4597845000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2017-02-07T20:49:19Z |
| your-name | Your Name 2016 | anime | Dragon Raja The Blazing Dawn S02E19 Your Real Name 1080p CR WEB-DL AAC2.0 H 264-VARYG (Long Zu, Multi-Subs) | 1503238528 | torrent | 2020:Movies/Other, 5070:TV/Anime, 127720: | 2025-11-07T12:14:00Z |
| your-name | Your Name 2016 | anime | Kimi.no.na.wa.A.K.A.Your.Name.2016.JAPANESE.1080p.10bit.BluRay.6CH.x265.HEVC-PSA | 852639000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2017-07-28T16:49:23Z |
| your-name | Your Name 2016 | anime | Natsumes Book of Friends S07E11 Tell Me Your Name 1080p CR WEB-DL AAC2.0 H 264 DUAL-VARYG (Natsume Yuujinchou, Dual-Audio, Multi-Subs) | 1503238528 | torrent | 2020:Movies/Other, 5070:TV/Anime, 127720: | 2025-01-20T23:10:00Z |
| your-name | Your Name 2016 | anime | Natsumes Book of Friends S07E11 Tell Me Your Name 1080p CR WEB-DL AAC2.0 H 264-VARYG (Natsume Yuujinchou, Multi-Subs) | 1503238528 | torrent | 2020:Movies/Other, 5070:TV/Anime, 127720: | 2024-12-16T18:02:00Z |
| your-name | Your Name 2016 | anime | Your Name (2016) (Latino) | 5476083200 | torrent | 2020:Movies/Other, 5070:TV/Anime, 131088: | 2024-12-01T16:11:00Z |
| your-name | Your Name 2016 | anime | Your Name (2016) 1080p 10bits Eng - Ch - Jap subtitles BluRay x265 10bits AAC 5.1 - Deathrow | 6719898000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2019-10-28T18:10:37Z |
| your-name | Your Name 2016 | anime | Your Name (Kimi no Na wa) (2016) [BD 1080p Hi10P 5.1 AAC dual-audio][kuchikirukia] | 6208536000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2017-10-31T03:51:05Z |
| your-name | Your Name 2016 | anime | Your Name (Kimi no Na wa) (2016) [BD 1080p Hi10P 5.1 AAC dual-audio][kuchikirukia]v2 | 6220025000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2017-10-31T15:38:14Z |
| your-name | Your Name 2016 | anime | Your Name (Kimi no Na wa) (2016) [BD 1080p Hi10P 5.1 AAC dual-audio][kuchikirukia]v3 | 6204470000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2017-11-01T20:37:36Z |
| your-name | Your Name 2016 | anime | Your Name (Kimi no Na wa) (2016) [BD 1080p Hi10P 5.1 AAC][kuchikirukia] | 5668978000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2017-07-27T18:00:42Z |
| your-name | Your Name 2016 | anime | Your Name (Kimi no Na wa) (2016) [BD 1080p Hi10P 5.1 AAC][kuchikirukia]v2 | 5671614000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2017-07-28T00:13:04Z |
| your-name | Your Name 2016 | anime | Your Name (Kimi no Na wa) (2016) [BD 1080p Hi10P 5.1 AAC][kuchikirukia]v3 | 5670956000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2017-07-29T16:26:08Z |
| your-name | Your Name 2016 | anime | Your Name (Kimi no Na wa) (2016) [Dual Audio][10bit HEVC][BD 720p][MeGaTroN] | 704244000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2017-12-29T14:43:31Z |
| your-name | Your Name 2016 | anime | Your Name 2016 2160p HMAX WEB-DL DTS-HD MA 5 1 DV H 265-DRX | 13958643712 | torrent | 2020:Movies/Other, 5070:TV/Anime, 127720: | 2025-11-13T06:57:00Z |
| your-name | Your Name 2016 | anime | Your Name railing the autistic girl's asshole in the back of a packed theater edition | 49177374720 | torrent | 2020:Movies/Other, 5070:TV/Anime, 127720: | 2026-02-14T17:59:00Z |
| your-name | Your Name 2016 | anime | Your Name. (2016) [BD 1080p] [Dub - Japanese , English , Arabic] [Sub - English , Arabic] | 1897861000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-10-25T12:52:29Z |
| your-name | Your Name 2016 | anime | Your Name. - Kimi no Na wa. (2016) 2016 [DCPrip.1080p.FLAC.ITA.TRUEHD.AC3.JPN.Subs.Ita.Eng.v3] [11.7GB] [stress] | 12670153728 | torrent | 2020:Movies/Other, 5070:TV/Anime, 131088: | 2026-03-04T21:21:00Z |
| your-name | Your Name 2016 | anime | Your.Name.2016.1080p.Blu-Ray.10-Bit.FLAC.x264-iAHD | 5802914000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2017-08-02T05:39:59Z |
| your-name | Your Name 2016 | anime | Your.Name.2016.1080p.BluRay.x264 | 1880084000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-03-11T12:33:14Z |
| your-name | Your Name 2016 | anime | Your.Name.2016.1080p.x265.Tri-Audio.Ita.Eng.Jap[Rady] | 13314532000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2020-11-16T03:02:16Z |
| your-name | Your Name 2016 | anime | Your.Name.2016.2160p.BluRay.REMUX.DTS-HD.MA.5.1.DV.HDR.H.265-SasukeducK (Kimi no Na wa. - 君の名は。) | 52828098560 | torrent | 2020:Movies/Other, 5070:TV/Anime, 127720: | 2024-10-08T08:16:00Z |
| your-name | Your Name 2016 | anime | Your.Name.2016.MULTI.BDMV.1080p.AVC-MaitreAnonyme | 39728447488 | torrent | 2020:Movies/Other, 5070:TV/Anime, 131088: | 2026-01-02T14:59:00Z |
| your-name | Your Name 2016 | anime | Your.Name.2016.MULTI.BDMV.2160p.HEVC-MaitreAnonyme | 41446432768 | torrent | 2020:Movies/Other, 5070:TV/Anime, 127720: | 2026-01-02T14:25:00Z |
| your-name | Your Name 2016 | anime | Your.Name.Kimi.no.Na.wa.2016.[BD.1080p.Hi10P.5.1.AAC][kuchikirukia]v3 | 5686376000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2017-07-29T16:26:08Z |
| your-name | Your Name 2016 | anime | Your.Name.Kimi.no.Na.wa.2016.[Dual.Audio][10bit.HEVC][BD.720p][MeGaTroN] | 704435000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2017-12-29T14:43:31Z |
| your-name | Your Name 2016 | anime | [Beatrice-Raws] Kimi no Na wa S01 (Your Name) 2016 [DCPrip 1922x1080 HEVC TrueHD]_rev.mkv | 10844792832 | torrent | 2020:Movies/Other, 5070:TV/Anime, 134634: | 2026-03-04T18:53:00Z |
| your-name | Your Name 2016 | anime | [BlackRose] Your Name. S01 (2016) (BD 1080p H.264 10-bit Opus) 2016 [Dual-Audio] \| Kimi no Na wa. | 7194070016 | torrent | 2020:Movies/Other, 5070:TV/Anime, 127720: | 2026-04-09T03:48:00Z |
| your-name | Your Name 2016 | anime | [BlackRose] Your Name. S01 (2016) (BD 1080p HEVC 10-bit Opus) 2016 [Dual-Audio] \| Kimi no Na wa. | 13421772800 | torrent | 2020:Movies/Other, 5070:TV/Anime, 127720: | 2026-04-09T03:47:00Z |
| your-name | Your Name 2016 | anime | [Blood Moon Dragon] Kimi no Na wa S01 (Your Name) 2016 [2016] 1280x720p.mp4 GREEK SUBS | 1717986944 | torrent | 2020:Movies/Other, 5070:TV/Anime, 131088: | 2023-08-28T16:54:00Z |
| your-name | Your Name 2016 | anime | [DB] Kimi no Na wa. \| Your Name. 2016 S01 [Dual Audio 10bit BD1080p][HEVC-x265] | 4402341376 | torrent | 2020:Movies/Other, 5070:TV/Anime, 127720: | 2024-08-22T07:45:00Z |
| your-name | Your Name 2016 | anime | [DB] Makoto Shinkai Movie Collection 2016 [Dual Audio 10bit BD1080p][HEVC-x265] (The Place Promised in Our Early Days+5 Centimeters per Second+Children Who Chase Lost Voices+The Garden of Words+Your Name.+Weathering with You+Suzume no Tojimari) | 22978074624 | torrent | 2020:Movies/Other, 5070:TV/Anime, 127720: | 2024-12-02T09:28:00Z |
| your-name | Your Name 2016 | anime | [FAV] Your Name. (2016) [BD 540p x264 AAC] [E5D72C1C] | 755858000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-03-08T19:59:31Z |
| your-name | Your Name 2016 | anime | [FAV].Your.Name.2016.[BD.540p.x264.AAC].[E5D72C1C] | 737286000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2021-03-08T19:15:03Z |
| your-name | Your Name 2016 | anime | [FS]_Kimi_no_Na_wa_ S01 (Your_Name)_ 2016 [BD_1080p_x264_AAC][Sub_Esp][MP4] | 4402341376 | torrent | 2020:Movies/Other, 5070:TV/Anime, 131088: | 2026-04-01T04:34:00Z |
| your-name | Your Name 2016 | anime | [FS]_Kimi_no_Na_wa_ S01 (Your_Name)_ 2016 [BD_720p_x264_AAC][Sub_Esp][MP4] | 1610612736 | torrent | 2020:Movies/Other, 5070:TV/Anime, 131088: | 2026-04-22T04:23:00Z |
| your-name | Your Name 2016 | anime | [Judas] Kimi no Na wa (Your Name) 2016 [BD 1080p][HEVC x265 10bit][Dual-Audio][Multi-Subs] (Movie) | 2469606144 | torrent | 2020:Movies/Other, 5070:TV/Anime, 127720: | 2026-05-09T15:10:00Z |
| your-name | Your Name 2016 | anime | [MegaMTBB] Kimi no Na wa. S01 (2016) (BD 1080p) \| your name. | 14388140032 | torrent | 2020:Movies/Other, 5070:TV/Anime, 127720: | 2026-02-10T01:44:00Z |
| your-name | Your Name 2016 | anime | [MiniMTBB] Kimi no Na wa. S01 (2016) (BD 1080p) \| your name. | 1610612736 | torrent | 2020:Movies/Other, 5070:TV/Anime, 127720: | 2026-02-12T17:25:00Z |
| your-name | Your Name 2016 | anime | [NoobSubs] your name. 2016 (1080p Blu-ray 8bit Dual Audio)[818630D3] | 7020178000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2018-04-11T11:34:34Z |
| your-name | Your Name 2016 | anime | [NoobSubs] your name. 2016 (1080p Blu-ray Dual Audio 8bit AC3)[AF224105] | 6344137000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2018-04-11T10:37:15Z |
| your-name | Your Name 2016 | anime | [NoobSubs] your name. 2016 (1440p 2k Ultra Blu-ray i422 HDR10 Dual Audio)[F7B32C84] | 5661288000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2018-04-11T09:29:02Z |
| your-name | Your Name 2016 | anime | [NoobSubs].your.name.2016.1080p.Blu-ray.8bit.Dual.Audio[818630D3] | 7034960000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2018-04-11T11:34:34Z |
| your-name | Your Name 2016 | anime | [NoobSubs].your.name.2016.1080p.Blu-ray.Dual.Audio.8bit.AC3[AF224105] | 6357544000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2018-04-11T10:37:15Z |
| your-name | Your Name 2016 | anime | [NoobSubs].your.name.2016.1440p.2k.Ultra.Blu-ray.i422.HDR10.Dual.Audio[F7B32C84] | 5674273000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2018-04-11T09:28:57Z |
| your-name | Your Name 2016 | anime | [The-Nut] Kimi no Na wa \| Your Name 2016 S01 [BD UHD AV1 HDR Opus] | 1610612736 | torrent | 2020:Movies/Other, 5070:TV/Anime, 127720: | 2023-03-08T00:45:00Z |
| your-name | Your Name 2016 | anime | [Tohsaka] Kimi no Na wa S01 (Your Name) MULTi VF/VOSTFR (BD 1080p) (FRENCH) v2 | 8053063680 | torrent | 2020:Movies/Other, 5070:TV/Anime, 131088: | 2025-06-19T14:56:00Z |
| your-name | Your Name 2016 | anime | [izzybell] Your Name. S01 (2016) 2016 [1080p] [Dual-Audio] [DCP + BD] [x265] [FLAC] | 20078972928 | torrent | 2020:Movies/Other, 5070:TV/Anime, 127720: | 2026-02-11T01:55:00Z |
| your-name | Your Name 2016 | anime | your name 2016 1080 | 4596937000 | usenet | 5000:TV, 5070:TV/Anime, 105000:, 105070: | 2017-03-13T03:26:31Z |
| your-name | Your Name 2016 | anime | your name. (2016) English, Arabic, French, Portuguese subs from JFF 2016 [Multi-Subs only] \| Kimi no Na wa | 356659 | torrent | 2020:Movies/Other, 5070:TV/Anime, 127720: | 2026-02-26T09:22:00Z |

## Provider decision

Decision: `tmdb_sufficient`

A0 status: `pass`

Recommended next action: Proceed to A1 with TMDB as the metadata provider.

## Future behavior contracts: 24 recorded

Status: `recorded_for_future_phases`

| ID | Phase | Kind |
| --- | --- | --- |
| absolute-over-99 | A2 | release |
| absolute-over-999-v2-crc | A2 | release |
| ambiguous-bare-number | A2 | release |
| ambiguous-coordinate-needs-mapping | A1 | resolver |
| anime-movie-release | A2 | release |
| coordinate-to-many | A1 | resolver |
| coordinates-to-one | A1 | resolver |
| cross-season-batch | A2 | release |
| dual-audio-dub-ass-markers | A2 | release |
| duplicate-target-needs-mapping | A3 | preflight |
| episode-zero | A2 | release |
| explicit-extra-can-ignore | A3 | preflight |
| nced-extra | A2 | release |
| ncop-extra | A2 | release |
| ona-not-automatically-special | A2 | release |
| ordinary-cour-sxxeyy | A2 | release |
| outside-reservation-needs-mapping | A3 | preflight |
| ova-typed-special | A2 | release |
| provider-renumbering-preserves-active-work | A1 | snapshot |
| recap-is-story-candidate | A2 | release |
| sidecar-does-not-count-as-video | A3 | preflight |
| split-cour-absolute-range | A2 | release |
| trailer-extra | A2 | release |
| unknown-video-needs-mapping | A3 | preflight |
