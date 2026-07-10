# Season disclosures

## Goal

Reduce clutter on the TV series detail page by hiding each season's episode tree until the
viewer opens that season.

## Design

Wrap every season on `CinderWeb.SeriesDetailLive` in a native HTML `<details>` disclosure. Its
`<summary>` shows the season name and monitored-episode count. The disclosure has no `open`
attribute, so every season—including specials—starts collapsed whenever the detail page renders.

The existing season actions, manual-search panel, confirmation panel, and episode list remain
inside the expanded content. Native disclosure behavior supplies keyboard access and state
handling; no LiveView event, JavaScript, or persisted preference is added.

## Verification

Add a LiveView regression test that asserts a season renders as a `<details>` element without an
`open` attribute. Run the focused test and the project's `mix test` alias.
