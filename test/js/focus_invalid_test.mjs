// `focusInvalid/2` of assets/js/focus_invalid.js, driven with a stubbed document whose elements
// answer `closest("details")` as a page nesting them would. test/cinder_web/js_hooks_test.exs
// runs this file with `node --test`.
import assert from "node:assert/strict"
import {test} from "node:test"
import {focusInvalid} from "../../assets/js/focus_invalid.js"

// An element whose `closest("details")` is the nearest `<details>` at or above it, as in a page.
const element = (tag, parent, log) => {
  const el = {
    tag,
    open: false,
    parentElement: parent,
    closest: selector => {
      assert.equal(selector, "details")
      for (let node = el; node; node = node.parentElement) if (node.tag === "details") return node
      return null
    },
    focus: () => log.push(["focus", el.tag, ...openStates()]),
  }
  return el
}

let openStates = () => []

const doc = byId => ({getElementById: id => byId[id] || null})

test("opens each closed disclosure around the field before it focuses the field", () => {
  const log = []
  const outer = element("details", null, log)
  const inner = element("details", element("div", outer, log), log)
  const field = element("select", element("div", inner, log), log)
  openStates = () => [outer.open, inner.open]

  focusInvalid(doc({indexer_source: field}), "indexer_source")

  assert.deepEqual(log, [["focus", "select", true, true]])
})

test("focuses a field with no disclosure around it", () => {
  const log = []
  const field = element("input", element("form", null, log), log)
  openStates = () => []

  focusInvalid(doc({household_timezone: field}), "household_timezone")

  assert.deepEqual(log, [["focus", "input"]])
})

test("does nothing for an id the page does not hold", () => {
  assert.equal(focusInvalid(doc({}), "gone"), undefined)
})
