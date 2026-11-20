import {FormState} from "./form_state.js"

const csrfToken = () =>
  document.querySelector("meta[name='csrf-token']").getAttribute("content")

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
export const PasskeySignIn = {
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
        headers: {"x-csrf-token": csrfToken()},
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
export const PasskeyRegister = {
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
