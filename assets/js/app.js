// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/cinder"
import topbar from "../vendor/topbar"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

const DisclosureState = {
  beforeUpdate() {
    this.wasOpen = this.el.open
  },
  updated() {
    this.el.open = this.el.dataset.forceOpen === "true" || this.wasOpen
  },
}

const formControls = form => Array.from(form.elements)
  .filter(({type}) => !["button", "file", "reset", "submit"].includes(type))

/* Module-scope memory: survives hook remounts. status_badge renders a <span> for resting
   states and a <div> with a <progress> for in-flight ones, so a status change can swap the
   element type and remount the hook — per-instance state would lose the previous status. */
const kindleSeen = new Map()

const Kindle = {
  mounted() {
    const prev = kindleSeen.get(this.el.id)
    kindleSeen.set(this.el.id, this.el.dataset.kindle)
    // First sighting of this id on this page => record only, never flare on initial load.
    if (prev !== undefined && prev !== this.el.dataset.kindle) this.kindle()
  },
  updated() {
    const next = this.el.dataset.kindle
    if (next === kindleSeen.get(this.el.id)) return
    kindleSeen.set(this.el.id, next)
    this.kindle()
  },
  kindle() {
    this.el.classList.remove("is-kindled")
    void this.el.offsetWidth
    this.el.classList.add("is-kindled")
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.el.classList.remove("is-kindled"), 1400)
  },
  destroyed() {
    // Deliberately keep the kindleSeen entry: surviving remount is the point.
    clearTimeout(this.timer)
  },
}

// Posters arrive over the network at unpredictable times: an initial page load, a live
// navigation/patch, a bare PubSub-driven re-render that inserts a brand-new node (no
// page-loading event fires for that case at all), or a patch that changes a poster's src.
// Fade in only the ones that were not already cached; a cached grid must render instantly. No
// per-card hook and no generated ids — processPoster is applied to every matching <img>,
// wherever it came from.
const revealPoster = img => img.classList.add("poster-shown")

// A failed poster (TMDB 404, blocked CDN, offline) must hide and expose the gradient/box
// placeholder markup already painted behind it (core_components.ex media_card/detail_poster,
// discover_components.ex cast_strip) rather than the browser's broken-image glyph + alt text.
const hidePoster = img => img.classList.add("poster-broken")

// img.complete is true both when the image finished loading AND when it already failed (a
// cached 404, a fast/synchronous failure) — naturalWidth is 0 only in the failure case. This
// is the one reliable synchronous test, and it must run before any "complete → already fine"
// shortcut or the most common failure case (already failed before this code runs) is missed.
const posterHasFailed = img => img.complete && img.naturalWidth === 0

const posterSelector = "img[data-poster]:not([data-poster-seen])"

const processPoster = img => {
  img.dataset.posterSeen = "1"
  if (posterHasFailed(img)) { hidePoster(img); return }
  if (img.complete) return
  img.classList.add("poster-fade")
  img.addEventListener("load", () => revealPoster(img), {once: true})
  img.addEventListener("error", () => hidePoster(img), {once: true})
  // The image can finish (either way) between the complete check and the listener attach.
  if (posterHasFailed(img)) { hidePoster(img); return }
  if (img.complete) revealPoster(img)
  // Last resort: a stalled request must never leave the poster invisible.
  setTimeout(() => revealPoster(img), 3000)
}

const fadeUncachedPosters = () => {
  document.querySelectorAll(posterSelector).forEach(processPoster)
}

// The classes above that only app.js adds; the server never renders them.
const posterClientClasses = ["poster-fade", "poster-shown", "poster-broken"]

// LiveView patches an <img> it keeps by copying the server-rendered attributes onto it, which
// drops data-poster-seen and the client classes. That happens to every poster whose parent a
// diff re-renders: the status badge is media_card's slot, so a status change re-renders the
// whole card (#702). A failed poster would then show the broken-image glyph and alt text
// again. onBeforeElUpdated runs before that copy, so writing the client state onto the
// incoming element (toEl) carries it across the patch, the way LiveView's own
// JS.ignore_attributes does. The listeners and the 3-second reveal processPoster set up stay
// on the element, which LiveView keeps. Only while the src stays the same: a new src is a new
// image, so the patch drops the old one's state and sweepPatchedPosters processes it again.
const keepPosterState = (fromEl, toEl) => {
  if (!fromEl.matches("img[data-poster][data-poster-seen]")) return
  if (fromEl.getAttribute("src") !== toEl.getAttribute("src")) return
  toEl.dataset.posterSeen = fromEl.dataset.posterSeen
  posterClientClasses
    .filter(name => fromEl.classList.contains(name))
    .forEach(name => toEl.classList.add(name))
}

// A plain server-pushed diff from a handle_info/assign (dashboard polling, a PubSub-driven
// movie/request row insert) never touches liveSocket.connect() or a phx:page-loading-* event —
// those only fire for full joins, live navigation, and reconnects. onPatchEnd is LiveView's own
// per-patch hook, called once a patch is in the DOM with the element it patched. Every poster
// that patch inserted, or whose src it changed, lacks data-poster-seen there; a poster whose
// state keepPosterState carried keeps it, so the sweep skips it. data-poster-seen also keeps
// this idempotent against the startup/page-loading-stop sweeps below.
const sweepPatchedPosters = container => {
  if (container.matches(posterSelector)) processPoster(container)
  container.querySelectorAll(posterSelector).forEach(processPoster)
}

const FormState = {
  mounted() {
    this.revision = this.el.dataset.formRevision
  },
  beforeUpdate() {
    this.controls = formControls(this.el)
      .map(({name, type, value, checked}) => ({name, type, value, checked}))
  },
  updated() {
    const revision = this.el.dataset.formRevision

    if (revision === this.revision) {
      formControls(this.el).forEach((control, index) => {
        const saved = this.controls[index]

        if (!saved || control.name !== saved.name || control.type !== saved.type) return

        if (["checkbox", "radio"].includes(control.type)) {
          control.checked = saved.checked
        } else if (control.type !== "file") {
          control.value = saved.value
        }
      })
    }

    this.revision = revision
    this.controls = undefined
  },
}

// Passkeys (#1560). WebAuthn hands binary fields over as ArrayBuffers; Cinder sends and reads
// them as base64url without padding.
const toBase64url = buffer => {
  let text = ""
  new Uint8Array(buffer).forEach(byte => { text += String.fromCharCode(byte) })
  return btoa(text).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
}

const fromBase64url = value => {
  const base64 = value.replace(/-/g, "+").replace(/_/g, "/")
  const text = atob(base64 + "=".repeat((4 - base64.length % 4) % 4))
  return Uint8Array.from(text, char => char.charCodeAt(0))
}

const passkeySupported = () =>
  typeof window.PublicKeyCredential === "function" && !!navigator.credentials

// A cancelled dialog or an unusable browser ends the ceremony in the page; the LiveView shows
// the message. The error's own text never leaves the browser.
const passkeyFailure = error =>
  error && error.name === "NotSupportedError" ? "unsupported" : "failed"

// The report is best effort: a page that lost its connection cannot show the message anyway.
const reportPasskeyFailure = (hook, reason) =>
  hook.pushEvent("passkey_failed", {reason}).catch(() => {})

// Log-in page: fetch the options from the controller (which keeps the challenge's handle in the
// session), ask the browser for a passkey, then submit the form with the answer.
const PasskeySignIn = {
  mounted() {
    this.button = this.el.querySelector("[data-passkey-start]")
    this.onClick = () => this.start()
    this.button.addEventListener("click", this.onClick)
  },
  destroyed() {
    this.button.removeEventListener("click", this.onClick)
  },
  async start() {
    if (!passkeySupported()) return reportPasskeyFailure(this, "unsupported")
    this.button.disabled = true

    try {
      const response = await fetch(this.el.dataset.optionsUrl, {
        method: "POST",
        headers: {"x-csrf-token": csrfToken},
        credentials: "same-origin",
      })
      if (!response.ok) throw new Error("options")
      const {publicKey} = await response.json()

      const credential = await navigator.credentials.get({
        publicKey: {...publicKey, challenge: fromBase64url(publicKey.challenge)},
      })

      const answer = credential.response
      const fields = {
        id: toBase64url(credential.rawId),
        authenticatorData: toBase64url(answer.authenticatorData),
        clientDataJSON: toBase64url(answer.clientDataJSON),
        signature: toBase64url(answer.signature),
        userHandle: answer.userHandle ? toBase64url(answer.userHandle) : "",
      }
      Object.entries(fields).forEach(([field, value]) => {
        this.el.querySelector(`[data-passkey-field="${field}"]`).value = value
      })
      this.el.submit()
    } catch (error) {
      this.button.disabled = false
      reportPasskeyFailure(this, passkeyFailure(error))
    }
  },
}

// Settings page: ask the LiveView for the options, run the browser's creation dialog, then send
// the attestation back. Every field goes under "passkey", which the server's logs filter.
const PasskeyRegister = {
  mounted() {
    FormState.mounted.call(this)
    this.onSubmit = event => {
      event.preventDefault()
      this.start()
    }
    this.el.addEventListener("submit", this.onSubmit)
  },
  // The typed name survives a patch (an error on another field, a flash) as FormState keeps it.
  beforeUpdate() {
    FormState.beforeUpdate.call(this)
  },
  updated() {
    FormState.updated.call(this)
  },
  destroyed() {
    this.el.removeEventListener("submit", this.onSubmit)
  },
  // The hook outlives a rejoin, and a push the dropped socket cut short settles only at its own
  // timeout (30 s). Let a press start a new ceremony now, unless the browser's dialog is open:
  // the new one replaces the current one, and the old one stops at its next step.
  reconnected() {
    if (this.inDialog) return
    this.busy = false
    this.ceremony = undefined
  },
  // One current ceremony: a submit while it runs is dropped, and `busy` clears on every way it
  // ends. A rejoin outside the dialog replaces it (`reconnected()` above); a replaced ceremony
  // leaves `busy` and the name field alone. The pushes use the promise form: with a callback,
  // LiveView never calls back for a push that fails (a disconnected view, a server error, a
  // timeout).
  async start() {
    if (this.busy) return
    if (!passkeySupported()) return reportPasskeyFailure(this, "unsupported")
    const nameInput = this.el.querySelector("input[name='name']")
    const name = nameInput.value
    const ceremony = {}
    const current = () => this.ceremony === ceremony
    this.ceremony = ceremony
    this.busy = true

    try {
      const reply = await this.pushEvent("passkey_registration_options", {passkey: {name}})
      if (!reply.ok || !current()) return

      let response
      try {
        const {publicKey} = reply
        this.inDialog = true
        const credential = await navigator.credentials.create({
          publicKey: {
            ...publicKey,
            challenge: fromBase64url(publicKey.challenge),
            user: {...publicKey.user, id: fromBase64url(publicKey.user.id)},
            excludeCredentials: publicKey.excludeCredentials
              .map(entry => ({...entry, id: fromBase64url(entry.id)})),
          },
        })
        response = {
          attestationObject: toBase64url(credential.response.attestationObject),
          clientDataJSON: toBase64url(credential.response.clientDataJSON),
        }
      } catch (error) {
        return reportPasskeyFailure(this, passkeyFailure(error))
      } finally {
        this.inDialog = false
      }

      const saved = await this.pushEvent("passkey_register", {
        passkey: {handle: reply.handle, name, response},
      })
      if (saved.ok && current()) nameInput.value = ""
    } catch (_pushFailed) {
      // A failed push ends the ceremony with no reply to show; the user can press the button again.
    } finally {
      if (current()) this.busy = false
    }
  },
}

const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, DisclosureState, FormState, Kindle, PasskeySignIn, PasskeyRegister},
  dom: {onBeforeElUpdated: keepPosterState, onPatchEnd: sweepPatchedPosters},
})

// Show progress bar on live navigation and form submits
// The bar is the most frequently seen motion in the app; it must be the ember accent, and it
// must follow a runtime theme switch (root.html.heex rewrites data-theme on phx:set-theme).
const themeTopbar = () => {
  const ember = getComputedStyle(document.documentElement).getPropertyValue("--color-primary").trim()
  topbar.config({
    barColors: {0: ember || "#e06c2b"},
    barThickness: 2,
    shadowColor: "transparent",
  })
}
themeTopbar()
window.addEventListener("phx:set-theme", () => requestAnimationFrame(themeTopbar))
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())
// Cleared on page-loading-start to bound growth across navigations — without this the map
// would keep an entry per badge id ever seen for the life of the tab. But phx:page-loading-*
// fires for five distinct events (view.ts join/displayError, live_socket.ts historyRedirect/
// pushLinkPatch/pageshow-reload), and only "initial" (fresh join) and "redirect" (new View,
// including the full-page pageshow reload) actually destroy the mounted hooks. "patch" (same-
// View live navigation) and "error" (same-View reconnect after a drop) leave badges mounted,
// so clearing here would erase their history out from under them: the next updated() would
// compare data-kindle against undefined, never match, and flare on a status that never changed.
window.addEventListener("phx:page-loading-start", ({detail}) => {
  if (detail?.kind === "initial" || detail?.kind === "redirect") kindleSeen.clear()
})
window.addEventListener("phx:page-loading-stop", fadeUncachedPosters)
window.addEventListener("phx:focus-invalid", ({detail: {id}}) => {
  requestAnimationFrame(() => document.getElementById(id)?.focus())
})

// connect if there are any LiveViews on the page
liveSocket.connect()
fadeUncachedPosters()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// "/" focuses the Discover search input unless the user is already typing in a field.
window.addEventListener("keydown", e => {
  if (
    e.key !== "/" ||
    ["INPUT", "TEXTAREA"].includes(e.target.tagName) ||
    e.target.isContentEditable
  )
    return

  const query = document.getElementById("query")
  if (query) {
    e.preventDefault()
    query.focus()
  }
})

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}
