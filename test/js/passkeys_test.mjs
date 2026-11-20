// The passkey hooks of assets/js/passkeys.js, driven with a stubbed browser and LiveView.
// test/cinder_web/js_hooks_test.exs runs this file with `node --test`.
//
// `pushEvent` below behaves like LiveView 1.2.9's ViewHook.pushEvent: without a callback it
// returns the push's promise, which rejects when the push cannot be delivered (a disconnected
// view, a server error, a timeout); with a callback it calls it on a reply and swallows a
// rejection, so the callback never runs for a failed push. A push sent before a rejoin gets no
// reply and settles only at its own timeout (30 s), long after the hook's `reconnected()` ran.
import assert from "node:assert/strict"
import {beforeEach, test} from "node:test"
import {PasskeyRegister, PasskeySignIn} from "../../assets/js/passkeys.js"

const unhandled = []
process.on("unhandledRejection", error => unhandled.push(String(error && error.message)))

const settle = () => new Promise(resolve => setTimeout(resolve, 20))

const deferred = () => {
  let resolve, reject
  const promise = new Promise((res, rej) => { resolve = res; reject = rej })
  return {promise, resolve, reject}
}

const disconnected = () => Promise.reject(new Error("unable to push hook event. LiveView not connected"))

const browser = {creates: 0, openDialogs: 0, maxOpenDialogs: 0, create: null, get: null, asked: null}

const credential = () => ({
  rawId: new Uint8Array([1]).buffer,
  response: {
    attestationObject: new Uint8Array([2]).buffer,
    clientDataJSON: new Uint8Array([3]).buffer,
    authenticatorData: new Uint8Array([4]).buffer,
    signature: new Uint8Array([5]).buffer,
    userHandle: null,
  },
})

beforeEach(() => {
  unhandled.length = 0
  Object.assign(browser, {creates: 0, openDialogs: 0, maxOpenDialogs: 0, asked: null})
  browser.create = async () => credential()
  browser.get = async () => credential()
  globalThis.window = {PublicKeyCredential: function PublicKeyCredential() {}}
  Object.defineProperty(globalThis, "navigator", {
    configurable: true,
    value: {
      credentials: {
        create: async options => {
          browser.asked = options
          browser.creates++
          browser.openDialogs++
          browser.maxOpenDialogs = Math.max(browser.maxOpenDialogs, browser.openDialogs)
          try { return await browser.create(options) } finally { browser.openDialogs-- }
        },
        get: options => { browser.asked = options; return browser.get(options) },
      },
    },
  })
})

const options = {
  ok: true,
  handle: "h",
  publicKey: {challenge: "AQ", user: {id: "Ag", name: "a"}, excludeCredentials: [{id: "Aw"}]},
}

// `server(event, payload)` answers each push with a promise.
function mountRegister(server) {
  const input = {value: "Phone"}
  const pushes = []
  const payloads = []
  const hook = Object.create(PasskeyRegister)
  hook.el = {querySelector: () => input, addEventListener() {}, removeEventListener() {}, dataset: {}}
  hook.pushEvent = (event, payload, onReply) => {
    pushes.push(payload && payload.reason ? `${event}:${payload.reason}` : event)
    payloads.push(payload)
    const reply = server(event, payload)
    if (onReply === undefined) return reply
    reply.then(onReply).catch(() => {})
  }
  hook.mounted()
  return {hook, input, pushes, payloads}
}

const answers = (register = {ok: true}) => event =>
  Promise.resolve(event === "passkey_registration_options" ? options : register)

test("a saved passkey clears the name and frees the button, and a second quick press is dropped", async () => {
  const {hook, input, pushes, payloads} = mountRegister(answers())
  hook.start()
  hook.start()
  await settle()
  assert.deepEqual(pushes, ["passkey_registration_options", "passkey_register"])
  assert.equal(input.value, "")
  assert.equal(hook.busy, false)
  // The options' base64url fields reach the browser as bytes, and its answer goes back encoded.
  const {publicKey} = browser.asked
  assert.deepEqual([...publicKey.challenge], [1])
  assert.deepEqual([...publicKey.user.id], [2])
  assert.deepEqual([...publicKey.excludeCredentials[0].id], [3])
  assert.deepEqual(payloads, [
    {passkey: {name: "Phone"}},
    {passkey: {handle: "h", name: "Phone", response: {attestationObject: "Ag", clientDataJSON: "Aw"}}},
  ])
})

test("refused options keep the typed name and free the button", async () => {
  const {hook, input, pushes} = mountRegister(() => Promise.resolve({ok: false}))
  hook.start()
  await settle()
  assert.deepEqual(pushes, ["passkey_registration_options"])
  assert.equal(input.value, "Phone")
  assert.equal(hook.busy, false)
  assert.equal(browser.creates, 0)
})

test("a refused registration keeps the typed name and frees the button", async () => {
  const {hook, input} = mountRegister(answers({ok: false}))
  hook.start()
  await settle()
  assert.equal(input.value, "Phone")
  assert.equal(hook.busy, false)
})

test("an options push that cannot be delivered frees the button", async () => {
  const {hook} = mountRegister(disconnected)
  hook.start()
  await settle()
  assert.equal(hook.busy, false)
  assert.deepEqual(unhandled, [])
})

test("a registration push that cannot be delivered frees the button for a new ceremony", async () => {
  let down = true
  const {hook, pushes} = mountRegister(event =>
    event === "passkey_registration_options" ? Promise.resolve(options) : (down ? disconnected() : Promise.resolve({ok: true})))
  hook.start()
  await settle()
  assert.equal(hook.busy, false)
  down = false
  hook.start()
  await settle()
  assert.deepEqual(pushes, [
    "passkey_registration_options", "passkey_register", "passkey_registration_options", "passkey_register",
  ])
  assert.equal(browser.creates, 2)
})

test("a cancelled dialog reports failed, and a browser without WebAuthn reports unsupported", async () => {
  browser.create = async () => { throw Object.assign(new Error("cancelled"), {name: "NotAllowedError"}) }
  const cancelled = mountRegister(answers())
  cancelled.hook.start()
  await settle()
  assert.deepEqual(cancelled.pushes, ["passkey_registration_options", "passkey_failed:failed"])
  assert.equal(cancelled.hook.busy, false)

  delete globalThis.window.PublicKeyCredential
  const unsupported = mountRegister(answers())
  unsupported.hook.start()
  await settle()
  assert.deepEqual(unsupported.pushes, ["passkey_failed:unsupported"])
})

test("a browser that refuses the passkey type reports unsupported", async () => {
  browser.create = async () => { throw Object.assign(new Error("no"), {name: "NotSupportedError"}) }
  const {hook, pushes} = mountRegister(answers())
  hook.start()
  await settle()
  assert.deepEqual(pushes, ["passkey_registration_options", "passkey_failed:unsupported"])
})

test("a throw after the dialog closes reports failed", async () => {
  browser.create = async () => null
  const {hook, pushes, input} = mountRegister(answers())
  hook.start()
  await settle()
  assert.deepEqual(pushes, ["passkey_registration_options", "passkey_failed:failed"])
  assert.equal(input.value, "Phone")
  assert.equal(hook.busy, false)
  assert.deepEqual(unhandled, [])
})

test("failure reports on a disconnected view leave no unhandled rejection", async () => {
  delete globalThis.window.PublicKeyCredential
  mountRegister(disconnected).hook.start()
  await settle()

  globalThis.window.PublicKeyCredential = function PublicKeyCredential() {}
  browser.create = async () => { throw Object.assign(new Error("cancelled"), {name: "NotAllowedError"}) }
  const {hook} = mountRegister(event =>
    event === "passkey_registration_options" ? Promise.resolve(options) : disconnected())
  hook.start()
  await settle()
  assert.equal(hook.busy, false)
  assert.deepEqual(unhandled, [])
})

test("a rejoin outside the dialog frees a ceremony stuck on its options push", async () => {
  const stuck = deferred()
  let pushesSent = 0
  const {hook, pushes} = mountRegister(event => (++pushesSent === 1 ? stuck.promise : answers()(event)))
  hook.start()
  await settle()
  assert.equal(hook.busy, true)
  hook.reconnected()
  assert.equal(hook.busy, false)
  hook.start()
  await settle()
  assert.deepEqual(pushes, ["passkey_registration_options", "passkey_registration_options", "passkey_register"])
})

test("a rejoin after the dialog closed frees a ceremony stuck on its registration push", async () => {
  const stuck = deferred()
  const {hook} = mountRegister(event =>
    event === "passkey_registration_options" ? Promise.resolve(options) : stuck.promise)
  hook.start()
  await settle()
  assert.equal(hook.busy, true)
  hook.reconnected()
  assert.equal(hook.busy, false)
})

test("a rejoin while the dialog is open keeps the button busy, so a press opens no second dialog", async () => {
  browser.create = () => new Promise(() => {})
  const {hook} = mountRegister(answers())
  hook.start()
  await settle()
  hook.reconnected()
  assert.equal(hook.busy, true)
  hook.start()
  await settle()
  assert.equal(browser.creates, 1)
})

// Ceremony 1's push (options, or registration after its dialog) is cut short by a rejoin; the
// user starts ceremony 2 with a new name, whose dialog is open when ceremony 1's push settles at
// last.
for (const [stage, reply] of [["passkey_registration_options", options], ["passkey_register", {ok: true}]]) {
  for (const [late, settleLate] of [
    ["times out", stuck => stuck.reject(new Error("push timeout"))],
    ["gets its reply", stuck => stuck.resolve(reply)],
  ]) {
    test(`a replaced ceremony whose ${stage} push ${late} leaves the current one alone`, async () => {
      browser.create = async () => (browser.creates === 1 && stage === "passkey_register" ? credential() : new Promise(() => {}))
      const stuck = deferred()
      let stuckSent = false
      const {hook, input} = mountRegister(event => {
        if (event === stage && !stuckSent) { stuckSent = true; return stuck.promise }
        return answers()(event)
      })
      hook.start()
      await settle()
      hook.reconnected()
      input.value = "Laptop"
      hook.start()
      await settle()
      settleLate(stuck)
      await settle()
      assert.equal(hook.busy, true)
      assert.equal(browser.openDialogs, 1)
      assert.equal(browser.maxOpenDialogs, 1)
      assert.equal(input.value, "Laptop")
      assert.deepEqual(unhandled, [])
    })
  }
}

function mountSignIn({fetchReply, push}) {
  const button = {disabled: false, addEventListener() {}, removeEventListener() {}}
  const fields = {}
  const pushes = []
  const requests = []
  let submitted = false
  globalThis.document = {
    querySelector: () => ({getAttribute: name => (name === "content" ? "csrf-token-value" : null)}),
  }
  globalThis.fetch = async (url, init) => {
    requests.push({url, init})
    return fetchReply()
  }
  const hook = Object.create(PasskeySignIn)
  hook.el = {
    dataset: {optionsUrl: "/users/log-in/passkey/options"},
    querySelector: selector => {
      if (selector === "[data-passkey-start]") return button
      const field = selector.match(/data-passkey-field="(\w+)"/)[1]
      return (fields[field] ??= {value: ""})
    },
    submit: () => { submitted = true },
  }
  hook.pushEvent = (event, payload, onReply) => {
    pushes.push(`${event}:${payload.reason}`)
    const reply = push()
    if (onReply === undefined) return reply
    reply.then(onReply).catch(() => {})
  }
  hook.mounted()
  return {hook, button, fields, pushes, requests, submitted: () => submitted}
}

test("sign-in posts for options with the CSRF token, fills the form and submits it", async () => {
  const dialog = deferred()
  browser.get = () => dialog.promise
  const signIn = mountSignIn({
    fetchReply: () => ({ok: true, json: async () => ({publicKey: {challenge: "AQ"}})}),
    push: () => Promise.resolve({}),
  })
  const ceremony = signIn.hook.start()
  await settle()
  assert.equal(signIn.button.disabled, true)
  const [{url, init}] = signIn.requests
  assert.equal(url, "/users/log-in/passkey/options")
  assert.equal(init.method, "POST")
  assert.equal(init.credentials, "same-origin")
  assert.equal(init.headers["x-csrf-token"], "csrf-token-value")
  assert.deepEqual([...browser.asked.publicKey.challenge], [1])

  const answer = credential()
  answer.response.userHandle = new Uint8Array([6]).buffer
  dialog.resolve(answer)
  await ceremony
  assert.deepEqual(
    Object.fromEntries(Object.entries(signIn.fields).map(([field, {value}]) => [field, value])),
    {id: "AQ", authenticatorData: "BA", clientDataJSON: "Aw", signature: "BQ", userHandle: "Bg"},
  )
  assert.equal(signIn.submitted(), true)
  assert.deepEqual(signIn.pushes, [])
})

test("a sign-in with no user handle sends an empty one", async () => {
  const signIn = mountSignIn({
    fetchReply: () => ({ok: true, json: async () => ({publicKey: {challenge: "AQ"}})}),
    push: () => Promise.resolve({}),
  })
  await signIn.hook.start()
  assert.equal(signIn.fields.userHandle.value, "")
  assert.equal(signIn.submitted(), true)
})

test("a sign-in failure re-enables the button and reports it, with no unhandled rejection offline", async () => {
  const signIn = mountSignIn({fetchReply: () => ({ok: false}), push: disconnected})
  await signIn.hook.start()
  await settle()
  assert.equal(signIn.button.disabled, false)
  assert.deepEqual(signIn.pushes, ["passkey_failed:failed"])

  delete globalThis.window.PublicKeyCredential
  const unsupported = mountSignIn({fetchReply: () => ({ok: false}), push: disconnected})
  await unsupported.hook.start()
  await settle()
  assert.deepEqual(unsupported.pushes, ["passkey_failed:unsupported"])
  assert.equal(unsupported.requests.length, 0)
  assert.deepEqual(unhandled, [])
})
