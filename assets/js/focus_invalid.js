// A `focus-invalid` push names the element to focus: a rejected /settings or /setup save, and
// the indexers table's dialogs when one closes or refuses a save. Each closed `<details>` around
// it opens first: a retry whose render changes nothing patches no disclosure, so a group the
// admin closed after the first rejection stays closed, and a field hidden inside it takes no
// focus (#1662). A /settings save clears the flash first, so its retry's patch sets the group's
// `open` again too.
export function focusInvalid(doc, id) {
  const field = doc.getElementById(id)
  if (!field) return

  for (let group = field.closest("details"); group; group = group.parentElement?.closest("details")) {
    group.open = true
  }

  field.focus()
}
