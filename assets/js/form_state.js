const formControls = form => Array.from(form.elements)
  .filter(({type}) => !["button", "file", "reset", "submit"].includes(type))

export const FormState = {
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
