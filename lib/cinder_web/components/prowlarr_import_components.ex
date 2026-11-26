defmodule CinderWeb.ProwlarrImportComponents do
  @moduledoc """
  The Import from Prowlarr dialog's content in `CinderWeb.IndexersComponent` (#1674), for each
  phase of a `CinderWeb.ProwlarrImportDialog`: the message of a failed preview with Close, the
  preview's form, and the report. The component renders it inside its `<.portal>` and
  `<.focus_wrap>`, and handles its events: `import_change`, `import_submit` and `close`.

  Each preview row is a `<fieldset>` named by Prowlarr's name. A tickable row has its tick (a
  direct row's "Import", a through-Prowlarr row's unticked "Add it through Prowlarr"), its
  name, and, for a direct row whose key Prowlarr masks, its API key input
  `secrets[<Prowlarr id>][api_key]` with `phx-update="ignore"` and an id new with each preview
  (`CinderWeb.ProwlarrImportDialog.secret_id/2`). A greyed row (held, already imported or
  refused) has no input. Each box posts the hidden `false` that `CinderWeb.CoreComponents.input/1`
  puts before it, so an unticked box still says so.
  """
  use Phoenix.Component
  use Gettext, backend: CinderWeb.Gettext

  import CinderWeb.CoreComponents, only: [button: 1, input: 1]

  alias CinderWeb.{ProwlarrImportDialog, ProwlarrImportText}
  alias Phoenix.LiveView.JS

  attr :dialog, :map, required: true
  attr :myself, :any, required: true

  def import_step(%{dialog: %{phase: :message}} = assigns) do
    ~H"""
    <div id="import-dialog-message" class="space-y-4" phx-mounted={JS.focus_first()}>
      <.import_title />
      <p id="import-message" role="alert" class="alert alert-warning text-sm">
        {ProwlarrImportText.error(@dialog.error)}
      </p>
      <.close_button myself={@myself} />
    </div>
    """
  end

  def import_step(%{dialog: %{phase: :report}} = assigns) do
    assigns = assign(assigns, testing: ProwlarrImportText.testing(assigns.dialog.report))

    ~H"""
    <div id="import-dialog-report" class="space-y-4" phx-mounted={JS.focus_first()}>
      <.import_title />
      <ul id="import-report" class="list-disc space-y-1 pl-5 text-sm">
        <li :for={row <- @dialog.report.created} id={"import-report-#{row.prowlarr_id}"}>
          {ProwlarrImportText.created(row)}
        </li>
        <li :for={name <- @dialog.skipped} class="import-report-skipped">
          {ProwlarrImportText.skipped(name)}
        </li>
      </ul>
      <p :if={@testing} id="import-report-testing" class="text-sm">{@testing}</p>
      <p id="import-report-source" class="text-sm">
        {gettext("The indexer source stays as it was.")}
      </p>
      <.close_button
        myself={@myself}
        describedby={
          Enum.join(
            ["import-report"] ++
              List.wrap(@testing && "import-report-testing") ++
              ["import-report-source"],
            " "
          )
        }
      />
    </div>
    """
  end

  def import_step(%{dialog: %{phase: :preview}} = assigns) do
    ~H"""
    <div id="import-dialog-preview" class="space-y-4" phx-mounted={JS.focus_first()}>
      <.import_title />
      <.form
        for={%{}}
        id="indexer-import-form"
        phx-change="import_change"
        phx-submit="import_submit"
        phx-target={@myself}
        class="space-y-3"
      >
        <p
          :if={@dialog.alert}
          id="import-alert"
          role="alert"
          tabindex="-1"
          class="alert alert-warning text-sm"
        >
          {alert_text(@dialog.alert)}
        </p>
        <p :if={@dialog.preview.rows == []} id="import-empty" class="text-sm">
          {gettext("Prowlarr has no indexer.")}
        </p>
        <.import_row
          :for={row <- @dialog.preview.rows}
          row={row}
          dialog={@dialog}
          choice={@dialog.choices[row.prowlarr_id]}
          errors={Map.get(@dialog.row_errors, row.prowlarr_id, [])}
        />
        <div class="mt-4 flex flex-wrap justify-end gap-2">
          <.button type="button" variant="ghost" id="import-close" phx-click={close_js(@myself)}>
            {gettext("Cancel")}
          </.button>
          <.button
            :if={@dialog.choices != %{}}
            type="submit"
            id="import-submit"
            phx-disable-with={gettext("Importing…")}
          >
            {gettext("Import")}
          </.button>
        </div>
      </.form>
    </div>
    """
  end

  attr :row, :map, required: true
  attr :dialog, :map, required: true
  attr :choice, :map, default: nil
  attr :errors, :list, default: []

  defp import_row(assigns) do
    row = assigns.row
    id = row.prowlarr_id

    assigns =
      assign(assigns,
        id: id,
        reasons: ProwlarrImportText.reasons(row),
        not_carried: ProwlarrImportText.not_carried(row),
        via?: ProwlarrImportDialog.via_input?(row),
        key?: ProwlarrImportDialog.key_input?(row),
        secret_id: assigns.choice && ProwlarrImportDialog.secret_id(assigns.dialog, id),
        error_id: "import-row-#{id}-errors",
        name_invalid?: Enum.any?(assigns.errors, &name_error?/1)
      )

    ~H"""
    <fieldset
      id={"import-row-#{@id}"}
      class={[
        "rounded-box border border-base-content/20 p-3",
        !@choice && "import-row-greyed bg-base-200 text-base-content/60"
      ]}
    >
      <legend class="px-1 font-medium">{@row.name}</legend>
      <p id={"import-row-#{@id}-becomes"} class="text-sm">{ProwlarrImportText.becomes(@row)}</p>
      <ul :if={@reasons != []} id={"import-row-#{@id}-reasons"} class="list-disc pl-5 text-sm">
        <li :for={reason <- @reasons}>{reason}</li>
      </ul>
      <p :if={@not_carried} id={"import-row-#{@id}-notes"} class="text-xs text-base-content/70">
        {@not_carried}
      </p>
      <div :if={@choice} class="mt-2 space-y-2">
        <.input
          :if={!@via?}
          type="checkbox"
          id={"import-row-#{@id}-ticked"}
          name={"rows[#{@id}][ticked]"}
          label={gettext("Import")}
          checked={@choice.ticked}
        />
        <.input
          :if={@via?}
          type="checkbox"
          id={"import-row-#{@id}-via"}
          name={"rows[#{@id}][via_prowlarr]"}
          label={gettext("Add it through Prowlarr")}
          checked={@choice.via_prowlarr}
        />
        <.input
          type="text"
          id={ProwlarrImportDialog.name_id(@id)}
          name={"rows[#{@id}][name]"}
          value={@choice.name}
          label={gettext("Name in Cinder")}
          autocomplete="off"
          aria-describedby={@errors != [] && @error_id}
          aria-invalid={@name_invalid? && "true"}
        />
        <.input
          :if={@key?}
          type="password"
          id={@secret_id}
          name={"secrets[#{@id}][api_key]"}
          value={nil}
          label={gettext("API key")}
          placeholder={gettext("Leave blank to create it disabled")}
          autocomplete="off"
          phx-update="ignore"
        />
      </div>
      <div
        :if={@errors != []}
        id={@error_id}
        role="alert"
        class="import-row-error mt-2 text-sm text-error"
      >
        <ul>
          <li :for={error <- @errors}>{ProwlarrImportText.row_error(error)}</li>
        </ul>
      </div>
    </fieldset>
    """
  end

  defp import_title(assigns) do
    ~H"""
    <h2 id="indexer-dialog-title" class="text-lg font-semibold">
      {gettext("Import from Prowlarr")}
    </h2>
    """
  end

  attr :myself, :any, required: true
  attr :describedby, :string, default: nil

  defp close_button(assigns) do
    ~H"""
    <div class="flex justify-end">
      <.button
        type="button"
        id="import-close"
        phx-click={close_js(@myself)}
        aria-describedby={@describedby}
      >
        {gettext("Close")}
      </.button>
    </div>
    """
  end

  # The codes a row error gives for its name, which mark the name input invalid.
  defp name_error?(code),
    do:
      code in [:name_required, :name_taken, :name_duplicate, :name_conflict] or
        match?({:name, _validation}, code)

  defp alert_text(:changed), do: ProwlarrImportText.error(:changed)
  defp alert_text({:error, tag}), do: ProwlarrImportText.error(tag)

  defp close_js(myself), do: JS.push("close", target: myself)
end
