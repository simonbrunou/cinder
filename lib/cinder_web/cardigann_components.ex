defmodule CinderWeb.CardigannComponents do
  @moduledoc """
  The Cardigann parts of `CinderWeb.IndexersComponent` (#1676, #1625 points 3, 4, 5 and 8): the
  definitions line under the indexers table, the Cardigann sites of the add list, the Cardigann
  form of `CinderWeb.CardigannDialog`, and the Accept update confirm. Each event names
  `myself`, the indexers component.

  Definition text (a site's name, description, language, links, setting labels, option labels
  and `info` text) is shown as written, never through gettext, and always escaped: an `info`
  text's `<a href=...>` shows as text, and no tag of it becomes an element.
  """
  use CinderWeb, :html

  alias CinderWeb.{CardigannDialog, DefinitionText, IndexerCaptcha, LiveHelpers}

  @doc """
  The words of a time on the definitions line: "14:07", or "Nov 27 at 14:07" on another
  household day.
  """
  @spec when_phrase(DateTime.t(), DateTime.t()) :: String.t()
  def when_phrase(datetime, now) do
    case LiveHelpers.household_time_parts(datetime, now) do
      {nil, time} -> time
      {date, time} -> gettext("%{date} at %{time}", date: date, time: time)
    end
  end

  defp failing_since(detail, line),
    do: gettext("Update failing since %{date}", date: when_phrase(detail.since, line.now))

  attr :line, :map, required: true, doc: "`state`, `checked_at`, `running?`, `now`, `notice`"
  attr :myself, :any, required: true

  @doc """
  The definitions line: the loaded set's count, commit and last check with Update now, else
  "Indexer definitions not loaded yet" with the last fetch error and Retry; the failing badge
  past 72 hours; the shrink, first-load and too-old alerts; and how the last run ended.
  """
  def definitions_line(assigns) do
    {kind, detail} = assigns.line.state
    loaded = loaded_of(assigns.line.state)

    assigns =
      assign(assigns,
        kind: kind,
        detail: detail,
        loaded: loaded,
        error: error_of(assigns.line.state)
      )

    ~H"""
    <div id="indexer-definitions" class="space-y-2 text-sm">
      <div
        :if={@loaded == nil}
        id="indexer-definitions-not-loaded"
        role="alert"
        class="alert alert-warning flex flex-wrap items-center gap-2"
      >
        <span>{gettext("Indexer definitions not loaded yet")}</span>
        <span :if={@error} id="indexer-definitions-error">{DefinitionText.fetch_error(@error)}</span>
        <.update_button line={@line} myself={@myself} label={gettext("Retry")} />
      </div>

      <p :if={@loaded} id="indexer-definitions-loaded" class="flex flex-wrap items-center gap-2">
        <span>
          {ngettext(
            "Indexer definitions: %{count} loaded at %{commit}, checked %{time}",
            "Indexer definitions: %{count} loaded at %{commit}, checked %{time}",
            @loaded.count,
            commit: String.slice(@loaded.commit, 0, 8),
            time: when_phrase(@line.checked_at || @loaded.loaded_at, @line.now)
          )}
        </span>
        <span aria-hidden="true">·</span>
        <.update_button line={@line} myself={@myself} label={gettext("Update now")} />
        <span
          :if={@kind == :update_failing}
          id="indexer-definitions-failing"
          class="inline-flex flex-wrap items-center gap-1"
        >
          <.status_badge kind={:health} status={{:warning, failing_since(@detail, @line)}} />
          {failing_since(@detail, @line)}
        </span>
      </p>
      <p :if={@loaded && @error} id="indexer-definitions-error" class="text-base-content/70">
        {DefinitionText.fetch_error(@error)}
      </p>

      <div
        :if={@kind in [:shrank, :first_too_small]}
        id="indexer-definitions-smaller"
        role="alert"
        class="alert alert-warning flex flex-wrap items-center gap-2"
      >
        <span :if={@kind == :shrank}>
          {gettext("The upstream answer shrank by %{percent}%.", percent: @detail.percent)}
        </span>
        <span :if={@kind == :first_too_small}>
          {ngettext(
            "The upstream answer holds only %{count} definition, too few for a first load.",
            "The upstream answer holds only %{count} definitions, too few for a first load.",
            @detail.count
          )}
        </span>
        <.button
          type="button"
          size="sm"
          variant="warning"
          id="indexer-definitions-accept-smaller"
          phx-click="accept_smaller_set"
          phx-target={@myself}
        >
          {gettext("Accept smaller set")}
        </.button>
      </div>

      <p
        :if={@kind == :cinder_too_old}
        id="indexer-definitions-too-old"
        role="alert"
        class="alert alert-error"
      >
        {gettext("Cinder is too old for current definitions")}
      </p>

      <p id="indexer-definitions-notice" role="status">{@line.notice}</p>
    </div>
    """
  end

  attr :line, :map, required: true
  attr :myself, :any, required: true
  attr :label, :string, required: true

  defp update_button(assigns) do
    ~H"""
    <.button
      type="button"
      variant="neutral"
      size="sm"
      id="indexer-definitions-update"
      phx-click="update_definitions"
      phx-target={@myself}
      disabled={@line.running?}
    >
      <span :if={@line.running?} class="loading loading-spinner loading-xs" aria-hidden="true" />
      {@label}
    </.button>
    """
  end

  defp loaded_of({:loaded, loaded}), do: loaded
  defp loaded_of({:never_loaded, _detail}), do: nil
  defp loaded_of({_kind, %{loaded: loaded}}), do: loaded

  defp error_of({kind, %{error: error}}) when kind in [:never_loaded, :update_failing], do: error
  defp error_of(_state), do: nil

  attr :entries, :list, required: true, doc: "the add list's Cardigann entries, `entries/2`"
  attr :myself, :any, required: true

  @doc """
  The add list's Cardigann sites, as `<li>` items after the generic entries: a site that loads is
  a button; one that reads not supported, fails to load or is not checked yet is greyed with
  `aria-disabled="true"` and no click.
  """
  def definition_entries(assigns) do
    ~H"""
    <li :for={entry <- @entries}>
      <button
        :if={entry.result == :loads}
        type="button"
        id={"indexer-definition-#{entry.index}"}
        phx-click="pick_definition"
        phx-value-name={entry.file}
        phx-target={@myself}
        class="w-full rounded-box border border-base-content/20 p-3 text-left hover:bg-base-200 focus-visible:outline-2 focus-visible:outline-(--color-focus-ring)"
      >
        <.entry_text entry={entry} />
      </button>
      <div
        :if={entry.result != :loads}
        id={"indexer-definition-#{entry.index}"}
        aria-disabled="true"
        class="w-full rounded-box border border-base-content/10 p-3 text-left opacity-60"
      >
        <.entry_text entry={entry} />
        <span class="block text-sm" id={"indexer-definition-#{entry.index}-reason"}>
          {unavailable(entry.result)}
        </span>
      </div>
    </li>
    """
  end

  attr :entry, :map, required: true

  defp entry_text(assigns) do
    ~H"""
    <span class="block font-medium break-words">{@entry.title}</span>
    <span class="block text-xs text-base-content/70">
      {privacy(@entry.privacy)}<span :if={@entry.language}> · {@entry.language}</span>
    </span>
    <span :if={@entry.description} class="block text-sm break-words text-base-content/70">
      {@entry.description}
    </span>
    """
  end

  defp unavailable({:not_supported, [feature | _rest]}),
    do: gettext("Not supported: %{feature}", feature: DefinitionText.feature(feature))

  defp unavailable({:fails, _reason}), do: gettext("Doesn't load on this version of Cinder")
  defp unavailable(_unchecked), do: gettext("Not checked yet")

  @doc "The words of a definition's privacy type, nil for a type the loader does not know."
  @spec privacy(String.t() | nil) :: String.t() | nil
  def privacy("public"), do: gettext("Public")
  def privacy("semi-private"), do: gettext("Semi-private")
  def privacy("private"), do: gettext("Private")
  def privacy(_type), do: nil

  @doc """
  The add list's Cardigann entries: the mirror's definitions (`Definitions.picker/0`) sorted by
  name, the file name standing in for a copy with no stored name, each whose name or description
  holds `query`, case aside. `index` is the entry's place in the whole sorted list, which its
  element id names.
  """
  @spec entries([map()], String.t()) :: [map()]
  def entries(picker, query) do
    needle = query |> String.trim() |> String.downcase()

    picker
    |> Enum.map(&Map.merge(&1, %{file: &1.name, title: &1.title || &1.name}))
    |> Enum.sort_by(&{String.downcase(&1.title), &1.file})
    |> Enum.with_index(&Map.put(&1, :index, &2))
    |> Enum.filter(fn entry ->
      String.contains?(String.downcase(entry.title), needle) or
        String.contains?(String.downcase(entry.description || ""), needle)
    end)
  end

  @doc "The words of a credential host a confirm lists."
  @spec host(String.t() | {:unknown, String.t()}) :: String.t()
  def host({:unknown, url}),
    do: gettext("%{url}, an address Cinder works out only when it searches", url: url)

  def host(host) when is_binary(host), do: host

  # Why a Switch's form lists no hosts: the save would refuse the input it holds.
  defp hosts_unknown({:error, {:secrets, :secrets_unreadable}}),
    do:
      gettext(
        "Re-enter every secret to see the hosts this Switch would send the indexer's credentials to."
      )

  defp hosts_unknown({:error, _reason}),
    do:
      gettext(
        "Cinder can't list the hosts this Switch would send the indexer's credentials to: the save would refuse the form as it is."
      )

  attr :dialog, :map, required: true
  attr :captcha, :map, default: nil, doc: "the Edit dialog's captcha (`CinderWeb.IndexerCaptcha`)"
  attr :myself, :any, required: true

  @doc "The Cardigann form of the Add, Edit and Switch dialogs (`CinderWeb.CardigannDialog`)."
  def cardigann_form(assigns) do
    dialog = assigns.dialog

    assigns =
      assign(assigns,
        form: CardigannDialog.to_form(dialog),
        errors: dialog.errors,
        controls: CardigannDialog.controls(dialog),
        options: CardigannDialog.base_url_options(dialog)
      )

    ~H"""
    <div id={"indexer-dialog-#{@dialog.mode}"} class="space-y-4" phx-mounted={JS.focus_first()}>
      <h2 id="indexer-dialog-title" class="text-lg font-semibold">{title(@dialog)}</h2>
      <.form
        for={@form}
        id="indexer-form"
        phx-change="change"
        phx-submit="save"
        phx-target={@myself}
      >
        <p
          :if={@dialog.stale?}
          id="indexer-form-stale"
          role="alert"
          class="alert alert-warning mb-2 text-sm"
        >
          {gettext("This indexer changed in another tab: reload it before saving.")}
        </p>
        <p
          :if={@dialog.saved == :unreadable and not @dialog.broken?}
          id="indexer-form-unreadable"
          role="alert"
          class="alert alert-warning mb-2 text-sm"
        >
          {gettext(
            "This indexer's saved secrets can't be decrypted. Type every secret again, or tick its Clear box, before you save a secret."
          )}
        </p>
        <p
          :if={@dialog.broken?}
          id="indexer-form-broken"
          role="alert"
          class="alert alert-warning mb-2 text-sm"
        >
          {gettext(
            "This site's definition no longer loads on this version of Cinder: only the name, priority and Enabled can change."
          )}
        </p>
        <%!-- The save sends the digest of the list drawn here, so a submit that leaves before a
        change's re-render sends the list the admin saw, and the store refuses it. --%>
        <input
          :if={@dialog.mode == :switch}
          type="hidden"
          name="switch_hosts_digest"
          id="indexer-form-hosts-digest"
          value={CardigannDialog.shown_digest(@dialog.hosts)}
        />
        <div :if={@dialog.mode == :switch} id="indexer-form-hosts-region" aria-live="polite">
          <div
            :if={is_list(@dialog.hosts) and @dialog.hosts != []}
            id="indexer-form-hosts"
            class="alert alert-warning mb-2 block text-sm"
          >
            <p>
              {gettext(
                "The new definition would send this indexer's credentials to these hosts, which it does not send them to today:"
              )}
            </p>
            <ul class="list-disc pl-5">
              <li :for={host <- @dialog.hosts} class="break-all">{host(host)}</li>
            </ul>
          </div>
          <p
            :if={match?({:error, _}, @dialog.hosts)}
            id="indexer-form-hosts-unknown"
            class="alert alert-warning mb-2 text-sm"
          >
            {hosts_unknown(@dialog.hosts)}
          </p>
        </div>
        <p
          :for={message <- @errors[:form] || []}
          role="alert"
          class="indexer-form-error mb-2 text-sm text-error"
        >
          {message}
        </p>

        <.input
          field={@form[:name]}
          id="indexer-form-name"
          label={gettext("Name")}
          autocomplete="off"
        />
        <p class="mb-2 text-sm">
          <span class="text-base-content/70">{gettext("Kind:")}</span>
          <span id="indexer-form-kind" class="break-words">
            {gettext("Cardigann (%{definition})", definition: @dialog.definition)}
          </span>
        </p>
        <.input
          :if={not @dialog.broken?}
          type="select"
          field={@form[:base_url]}
          id="indexer-form-base-url"
          label={gettext("Base URL")}
          options={@options}
        />

        <.setting
          :for={{index, setting, control} <- @controls}
          dialog={@dialog}
          index={index}
          setting={setting}
          control={control}
        />

        <p
          :if={@dialog.mode == :add and CardigannDialog.captcha?(@dialog)}
          id="indexer-form-captcha-after-save"
          class="mb-2 text-sm"
        >
          {gettext("Save this indexer first, then solve its captcha here.")}
        </p>
        <.captcha
          :if={@dialog.mode == :edit and CardigannDialog.captcha?(@dialog)}
          dialog={@dialog}
          captcha={@captcha}
          myself={@myself}
        />

        <.input
          type="number"
          field={@form[:priority]}
          id="indexer-form-priority"
          label={gettext("Priority")}
          aria-describedby="indexer-form-priority-help"
        />
        <p id="indexer-form-priority-help" class="-mt-1 mb-2 text-xs text-base-content/70">
          {gettext("1 to 50. A lower number comes first in results.")}
        </p>
        <.input
          type="checkbox"
          field={@form[:enabled]}
          id="indexer-form-enabled"
          label={gettext("Enabled")}
        />

        <p class="mt-2 text-sm text-base-content/70">
          {gettext("Cinder tests an enabled indexer when you save it.")}
        </p>
        <p
          :if={@dialog.mode != :add}
          id="indexer-form-drops"
          class="mt-1 text-sm text-base-content/70"
        >
          {drops_text(@dialog.mode)}
        </p>

        <div class="mt-4 flex flex-wrap justify-end gap-2">
          <.button
            :if={@dialog.mode == :add}
            type="button"
            variant="ghost"
            id="indexer-form-back"
            phx-click="back"
            phx-target={@myself}
          >
            {gettext("Back")}
          </.button>
          <.button type="button" variant="ghost" phx-click={JS.push("close", target: @myself)}>
            {gettext("Cancel")}
          </.button>
          <.button type="submit" id="indexer-form-save">{save_label(@dialog.mode)}</.button>
        </div>
      </.form>
    </div>
    """
  end

  attr :dialog, :map, required: true
  attr :captcha, :map, default: nil
  attr :myself, :any, required: true

  # The Edit dialog's captcha (#1681). One button loads it and loads a new one; it is disabled
  # while a load runs, and the load's end moves focus to the answer input or back to it. The
  # answer input posts under `captcha`, which `config :phoenix, :filter_parameters` filters from
  # the logs. Its id is new on each load (`CinderWeb.IndexerCaptcha`), and `phx-update="ignore"`
  # keeps what the admin typed through every other patch of the dialog.
  defp captcha(assigns) do
    assigns =
      assign(assigns,
        loading?: IndexerCaptcha.loading?(assigns.captcha),
        shown?: IndexerCaptcha.shown?(assigns.captcha),
        message: assigns.captcha && assigns.captcha.message
      )

    ~H"""
    <fieldset id="indexer-form-captcha" class="fieldset mb-2">
      <legend class="fieldset-legend">{gettext("Captcha")}</legend>
      <p class="text-sm text-base-content/70">
        {gettext(
          "The site asks for a captcha at login. Show it, type its answer, then save: Cinder logs in with the answer."
        )}
      </p>
      <p :if={@message} id="indexer-form-captcha-message" role="alert" class="text-sm text-error">
        {@message}
      </p>
      <img
        :if={@shown?}
        id="indexer-form-captcha-image"
        src={@captcha.src}
        alt={gettext("Captcha from %{name}", name: @dialog.values["name"])}
        class="max-w-full rounded-box border border-base-content/20 bg-base-100"
      />
      <.input
        :if={@shown?}
        type="text"
        id={IndexerCaptcha.answer_id(@captcha)}
        name="captcha[answer]"
        value={nil}
        label={gettext("Captcha answer")}
        autocomplete="off"
        phx-update="ignore"
      />
      <div>
        <.button
          type="button"
          variant="neutral"
          size="sm"
          id="indexer-form-captcha-load"
          phx-click="load_captcha"
          phx-target={@myself}
          disabled={@loading?}
        >
          <span :if={@loading?} class="loading loading-spinner loading-xs" aria-hidden="true" />
          {if @shown?, do: gettext("New captcha"), else: gettext("Show captcha")}
        </.button>
      </div>
    </fieldset>
    """
  end

  defp title(%{mode: :add}), do: gettext("Add indexer")
  defp title(%{mode: :edit}), do: gettext("Edit indexer")
  # The file name, as the row's "replaced by" line and Switch button name it.
  defp title(%{mode: :switch, definition: name}), do: gettext("Switch to %{name}", name: name)

  # A Switch raises `credentials_version` whatever it changes (`Cinder.Indexers`), so it drops
  # every waiting grab (`Cinder.Download.GrabFailure`).
  defp drops_text(:switch),
    do:
      gettext(
        "Switching drops this indexer's grabs still waiting to be sent: movies and episodes search again, books wait for you."
      )

  defp drops_text(_edit),
    do:
      gettext(
        "A new base URL or any changed credential drops this indexer's grabs still waiting to be sent: movies and episodes search again, books wait for you."
      )

  defp save_label(:add), do: gettext("Save and test")
  defp save_label(:edit), do: gettext("Save")
  defp save_label(:switch), do: gettext("Switch and save")

  attr :dialog, :map, required: true
  attr :index, :integer, required: true
  attr :setting, :map, required: true
  attr :control, :atom, required: true

  # One setting of the copy, its label as written, or its name when the label is empty.
  defp setting(%{control: :secret} = assigns) do
    assigns =
      assign(assigns,
        saved?: CardigannDialog.saved?(assigns.dialog, assigns.setting.name),
        id: CardigannDialog.secret_id(assigns.dialog, assigns.index)
      )

    ~H"""
    <.input
      type="password"
      id={@id}
      name={"secrets[#{@setting.name}]"}
      value={nil}
      label={CardigannDialog.label(@setting)}
      placeholder={secret_placeholder(@saved?, @setting.default)}
      autocomplete="off"
      phx-update="ignore"
    />
    <.input
      :if={@saved?}
      type="checkbox"
      id={"indexer-form-setting-#{@index}-clear"}
      name={"secrets[clear_#{@setting.name}]"}
      label={gettext("Clear saved %{setting}", setting: CardigannDialog.label(@setting))}
      checked={@dialog.values["clear"][@setting.name] == "true"}
    />
    """
  end

  defp setting(%{control: :checkbox} = assigns) do
    ~H"""
    <.input
      type="checkbox"
      id={"indexer-form-setting-#{@index}"}
      name={"indexer[settings][#{@setting.name}]"}
      label={CardigannDialog.label(@setting)}
      checked={@dialog.values["settings"][@setting.name] == "true"}
    />
    """
  end

  defp setting(%{control: :select} = assigns) do
    ~H"""
    <.input
      type="select"
      id={"indexer-form-setting-#{@index}"}
      name={"indexer[settings][#{@setting.name}]"}
      label={CardigannDialog.label(@setting)}
      options={CardigannDialog.options(@setting)}
      value={@dialog.values["settings"][@setting.name]}
    />
    """
  end

  defp setting(%{control: :plain_text} = assigns) do
    ~H"""
    <.input
      id={"indexer-form-setting-#{@index}"}
      name={"indexer[settings][#{@setting.name}]"}
      label={CardigannDialog.label(@setting)}
      value={@dialog.values["settings"][@setting.name]}
      autocomplete="off"
    />
    """
  end

  defp setting(%{control: :info} = assigns) do
    ~H"""
    <div id={"indexer-form-setting-#{@index}"} class="mb-2 text-sm">
      <p :if={CardigannDialog.text?(@setting.label)} class="font-medium">{@setting.label}</p>
      <p
        :if={CardigannDialog.text?(@setting.default)}
        class="break-words whitespace-pre-line"
      >
        {@setting.default}
      </p>
    </div>
    """
  end

  # How to copy a site's cookie: no v11 definition gives its `info_cookie` setting a label or a
  # text, so the form words it, under the setting's own label when it has one.
  defp setting(%{control: :cookie_help} = assigns) do
    ~H"""
    <div id={"indexer-form-setting-#{@index}"} class="mb-2 text-sm">
      <p class="font-medium">
        {if CardigannDialog.text?(@setting.label),
          do: @setting.label,
          else: gettext("How to get the cookie")}
      </p>
      <p class="break-words">
        {gettext(
          "Log in to the site in your browser, open its developer tools (F12), reload a page of the site in the Network tab, and copy the value of that request's Cookie header, everything after \"Cookie: \", into the cookie field."
        )}
      </p>
    </div>
    """
  end

  defp setting(%{control: :label} = assigns) do
    ~H"""
    <p
      :if={CardigannDialog.text?(@setting.label)}
      id={"indexer-form-setting-#{@index}"}
      class="mb-2 text-sm"
    >
      {@setting.label}
    </p>
    """
  end

  defp secret_placeholder(true, _default), do: gettext("•••• saved (leave blank to keep)")
  defp secret_placeholder(false, default) when default in [nil, ""], do: ""

  defp secret_placeholder(false, default),
    do: gettext("Default: %{default}", default: default)

  attr :dialog, :map, required: true
  attr :myself, :any, required: true

  @doc """
  The Accept update confirm (#1616 rules 5 and 6): the held copy's reason and the credential
  hosts it adds, or the "changed while you were reading" line once the held copy changed.
  """
  def accept_step(assigns) do
    ~H"""
    <div id="indexer-dialog-accept" class="space-y-4" phx-mounted={JS.focus_first()}>
      <h2 id="indexer-dialog-title" class="text-lg font-semibold">
        {gettext("Accept the definition update of %{name}?", name: @dialog.name)}
      </h2>
      <p :if={@dialog.changed?} id="indexer-accept-changed" role="alert" class="alert alert-warning">
        {gettext("This update changed while you were reading: check it again.")}
      </p>
      <p :if={@dialog.message} id="indexer-accept-message" role="alert" class="text-sm text-error">
        {@dialog.message}
      </p>
      <div :if={@dialog.held} id="indexer-accept-held" class="space-y-2 text-sm">
        <p id="indexer-accept-reason">
          {gettext("Cinder held it because %{reason}.",
            reason: DefinitionText.hold_reason(@dialog.held.reason)
          )}
        </p>
        <div :if={@dialog.held.hosts != []}>
          <p>{gettext("It would send this indexer's credentials to:")}</p>
          <ul id="indexer-accept-hosts" class="list-disc pl-5">
            <li :for={host <- @dialog.held.hosts} class="break-all">{host(host)}</li>
          </ul>
        </div>
        <p :if={@dialog.held.hosts == []} id="indexer-accept-no-hosts">
          {gettext("It sends this indexer's credentials to no new host.")}
        </p>
      </div>
      <div class="flex flex-wrap justify-end gap-2">
        <.button
          type="button"
          variant="ghost"
          id="indexer-accept-cancel"
          phx-click={JS.push("close", target: @myself)}
        >
          {gettext("Cancel")}
        </.button>
        <.button
          :if={@dialog.held}
          type="button"
          id="indexer-accept-confirm"
          phx-click="accept_update"
          phx-target={@myself}
        >
          {gettext("Accept update")}
        </.button>
      </div>
    </div>
    """
  end
end
