# Cinder runs Cardigann definitions with its own Elixir engine

Native indexers let Cinder search without Prowlarr (map #1610). A Newznab or Torznab indexer
answers one API call per search. A Cardigann indexer, such as Nyaa.si or Torrent9, is searched
through a YAML indexer definition that tells an engine how to scrape the site's pages. Prowlarr
serves 584 such definitions and states no licence for them. 583 come from Jackett, whose only
licence is GPL-2.0 (#1611).

Cinder writes its own engine in Elixir. It covers the whole Cardigann schema that Prowlarr
reads: v11, and v12 for a definition that has moved to it. Cinder builds it in slices: Nyaa.si
and Torrent9 first, then the rest of the public feature set, then logins, then captcha, then
FlareSolverr (#1615). Its parsers are `yaml_elixir` (moved to runtime), `lazy_html` for HTML,
`saxy` with Floki's matcher for XML, and `jason` with a small path walker for JSON. Regexes
run on `:re` behind a .NET translation layer. Templates, .NET date formats and legacy charsets
are code of Cinder's own.

## Considered options

- Prowlarr's C# engine compiled to WebAssembly, as Mydia's optional engine does. Mydia's docs
  report that it matched Prowlarr on 44 of 44 public trackers. It costs a 68 MB download and
  about 500 MB of memory (#1612).
- Mydia's Elixir engine, about 20,000 lines on `lazy_html`. Mydia's docs report 28 of 44 public
  trackers matching Prowlarr. Mydia is AGPL-3.0. Cinder copies none of its code, and reads Mydia
  and Prowlarr's C# as references only (#1615).
- A sidecar such as Jackett, reached over Torznab. Native indexers include generic Torznab, which
  can reach a Jackett instance (#1615). A sidecar keeps a second service beside Cinder, which
  native indexers make unneeded for a household without a C# indexer or a proxy (#1610).

## Consequences

- The definitions are untrusted input. Every request a definition makes goes through
  `Cinder.HTTPPolicy`'s untrusted path. Every regex runs as `:re.run` with an explicit
  `match_limit` and `:report_errors`. YAML anchors and aliases are refused before parsing.
- `lazy_html` 0.1.15 ends the VM with a segmentation fault on a parse error inside `:has()`,
  `:is()` or `:where()`, or next to one in the same compound selector (reported upstream as
  dashbitco/lazy_html#48). 0.1.13, the version in Cinder's lock, crashed on the selectors #1612
  tried. A CSS comment can hide such an error from a structural check (#1615). So every `lazy_html`
  call runs in a separate OS process, one per HTML document, never shared between indexers.
- A definition that uses a feature the engine has not built yet loads as
  `not supported: <feature>`.
- The 54 indexers Prowlarr implements in C# are out of scope. So are per-indexer proxies, since
  a proxy resolves DNS itself, past `Cinder.HTTPPolicy`'s pinning. A household that needs either
  keeps Prowlarr as its indexer source, or points a generic Torznab indexer at Jackett.
