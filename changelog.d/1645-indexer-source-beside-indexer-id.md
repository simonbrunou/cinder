### Internal
- **Download intents and TV block rows record the indexer's source beside its id (#1645).** A
  new download intent stores the release's `indexer_source` when it is a string and its
  `credentials_version` when it is an integer, beside the integer indexer id it already stored.
  An intent with no stored source reads as Prowlarr's. `blocked_releases` gains an
  `indexer_source` column, and its migration sets it to `prowlarr` on every row that holds an
  indexer id. When Cinder tries to block a TV release its search picked that is refused for good,
  the row records the intent's indexer id with the intent's source, `prowlarr` for an intent that
  stored an id and no source, and neither when the intent stored no id.
  `Catalog.block_series_release/4` takes that pair as `{source, indexer_id}` in place of a bare
  id. Such a row blocks its title only in a search result from its source whose indexer id is
  the row's or unknown, and a result with no source reads as Prowlarr's.
  `Cinder.Acquisition`'s `deduplicate_tv_releases/1` and `Cinder.Acquisition.Anime`'s
  `deduplicate/2` keep one result of a link per indexer source and id, and fold a copy with no
  indexer id only into a copy of its link from its own source. `Download.grab_movie/2`,
  `grab_episodes/3` and `grab_book_target/2` adopt an intent already stored for their target
  only when the offered release also has the intent's source and indexer id, and for a native
  indexer its credentials version, besides what they compared before (the title, protocol, link,
  episodes and flags). Otherwise they answer `:download_intent_busy`. Under Prowlarr alone, that
  adds one busy answer: a copy of the stored link whose indexer id differs from the intent's, or
  which only one of the two has, that the grab adopted before when everything else matched.
