# Product

## Register
product

## Users
Two audiences share one instance, with very different fluency:

- **The admin / self-hoster.** Technical. Runs the single container, wires Prowlarr / qBittorrent
  or SABnzbd / Jellyfin or Plex, reads the size-band and hardlink rules, watches the pipeline.
  Their job: stand the thing up once, then approve requests and trust it to run unattended. They
  need precision — exact pipeline state, which service is unreachable and why, what got parked.
- **Household requesters.** Non-technical (a partner, a roommate, a parent). They open the app,
  search for a movie or show, and ask for it. Their job: "request the thing, see where it's at."
  They never touch a download client or a regex. They should never see acquisition jargon.

The whole product is one self-hosted instance for one household: low concurrency, a single
admin who approves, a handful of requesters who ask. Success is the requester forgetting Cinder
exists until the thing they wanted is in Jellyfin.

## Product Purpose
Cinder replaces the **Radarr + Sonarr + Seerr** loop for one household with a single
Phoenix/LiveView app on SQLite — one container, no external database. A household member
requests a movie or TV season → an admin approves (their own requests auto-approve) → Cinder
finds the best release through the indexer, hands it to the download client, then hardlinks and
renames the finished file into the Jellyfin/Plex layout and triggers a scan. Background pollers
advance each request through its state machine and broadcast live over PubSub.

Success looks like: a stranger installs the container, the first-run wizard validates every
service before it lets them finish, household members request through a plain search-and-ask
flow, the admin approves from a queue, and titles land in the media server without anyone
SSHing in or editing a config file. It collapses three power-user tools into one calm,
self-explaining instance.

## Brand Personality
**Calm, trustworthy, unfussy.**

Voice: plain and direct, sentence case, no exclamation marks or hype. State is named, not
dramatized — "Searching", "Downloading", "No match", "Import failed", "Unreachable". Failures
are honest and specific (a parked download says why; an unreachable service shows the reason on
hover) rather than smoothed over. The "ember on charcoal" palette — a single warm ember accent
on near-black charcoal — sets the mood: a quiet, dark workshop with one warm signal light, not a
flashy console. Emotional goal: the requester feels at ease ("I asked, it's handled"); the admin
feels in control ("I can see exactly what's happening and why"). The tool earns trust by being
boringly legible about its own pipeline.

## Anti-references
- **Generic SaaS dashboard slop.** No KPI-card grids of vanity metrics, no gradient hero
  banners, no purple-blue startup gradients, no decorative charts. Cinder shows pipeline state,
  not a marketing dashboard.
- **The neon-on-black "self-hosted tool" cliché.** No saturated cyan/lime glow, no terminal-green
  matrix aesthetic, no RGB-gamer chrome. The dark theme is a muted charcoal with one restrained
  ember accent — warmth, not neon.
- **The *arr power-user jargon wall.** This ships to strangers and non-technical housemates.
  No dense tables of quality profiles, custom formats, indexer priorities, and release flags
  thrown at a first-time user. Acquisition internals (scoring, size bands, infohashes) stay on
  admin surfaces; the requester sees a poster, a title, and a state.
- **Loud, animated, attention-seeking UI.** No bouncing, no confetti, no autoplay motion, no
  novelty for its own sake. Motion is functional (show/hide, a spinner) and disappears under
  reduced-motion.
- **Color-only status.** Never a bare colored dot. Every state carries an icon and a word.

## Design Principles
1. **The tool disappears into the task.** A requester's job is "ask for a thing and see where
   it's at"; an admin's is "approve, and know what's happening." The interface serves those two
   jobs and adds nothing speculative. Earned familiarity (Linear/Stripe-grade quiet competence)
   over novelty — the same patterns everywhere so the UI becomes invisible.
2. **Honest about state — never color alone.** Pipeline state is the product's core information.
   Every status is a single source of truth (`status_badge`) rendered as icon **+** word **+**
   color, never color alone; failures name their reason. The user always knows where a request
   is and why it stalled.
3. **Plain language for the household, precision for the admin.** Two registers in one app.
   Requesters get plain words and a poster grid with no acquisition jargon; admins get exact
   state, service health with reasons, parked-item detail. Sensitive surfaces and internals are
   role-gated, not just hidden.
4. **Consistency is the affordance.** One button vocabulary, one input vocabulary, one badge
   component, one poster card, one empty-state. A new screen is assembled from the existing
   `core_components`, not reinvented — so behavior is predictable and the household learns the
   app once.
5. **Quiet by default; the ember is the signal.** A single warm accent across both themes marks
   what matters (the brand mark, the active nav item, primary actions). Everything else recedes
   into charcoal/paper so the one thing worth attention reads instantly.

## Accessibility & Inclusion
- Target **WCAG 2.2 AA**. Mixed-technical-literacy household: clarity is an accessibility
  requirement, not a nicety.
- **Reduced motion is already respected globally** — a single `prefers-reduced-motion` reset in
  `app.css` neutralizes every transition/animation; new motion inherits this for free.
- **Never color alone.** Status is always icon + text + color (`status_badge`); error inputs
  pair the error color with an icon and a message.
- **Keyboard + screen reader.** A skip-to-content link, `aria-current="page"` on active nav,
  `aria-label` on every icon-only control (menu toggle, theme buttons, flash close), `role`/
  `aria-live` on flashes and the inline confirm box, visible `focus-visible` outlines on the
  ember accent. Icon-only controls must carry an accessible name.
- **First-class light theme + system preference.** Dark is the default/hero, but light is a
  full peer (not an afterthought), with a system option; theme applies before first paint to
  avoid a flash.
- **Internationalized.** All copy goes through gettext with a visible locale switcher that works
  logged-out; nothing user-facing is hardcoded English.
