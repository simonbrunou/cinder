### Internal
- **A Cardigann `re_replace` escapes each `$` in a value its replacement inserts (#1728).** The
  `re_replace` step of `Cardigann.Filters.apply/4` now escapes each `$` in a value its replacement
  template inserts (`$` becomes `$$`) before the replacement is read as .NET replacement syntax.
  An inserted `$0` now stays `$0` where it gave the match, and an inserted `` $` `` or `${x}`
  stays as those characters where the chain returned a `not_supported` error. A `$` written in
  the replacement itself is still .NET syntax. A `$` written right before an inserted value still
  joins with it: before an inserted `0` it gives the match, and before an inserted `$0` it now
  gives `$` and the match where it gave `$0` (#1786). Only a Cardigann indexer's search
  or Test and `mix cinder.definitions.canary` run these filters.
