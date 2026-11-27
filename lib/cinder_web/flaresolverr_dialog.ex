defmodule CinderWeb.FlareSolverrDialog do
  @moduledoc """
  The FlareSolverr URL of `CinderWeb.IndexersComponent` (#1682, #1625 point 7): the line under
  the indexers table, "FlareSolverr: <URL> · Edit" or "FlareSolverr: not set · Set", and the
  dialog its button opens in the component's portal, whose state this module keeps and saves.

  The dialog is a map with `step: :flaresolverr`, `value` (the text in the field), `error` (a
  refusal's words, or nil) and `in_use` (the count a clear showed, or nil). Its input posts under
  `flaresolverr[url]`: `/settings` renders no input named after the `flaresolverr_url` key, whose
  definition is `render: :none`. `save/2` saves through `Cinder.Indexers.FlareSolverrUrl.put/1`.
  A blank value clears the URL. While a URL is saved and enabled Cardigann indexers have their
  FlareSolverr toggle on, the first blank save shows their count, and a second blank save
  clears it.
  """
  use CinderWeb, :html

  alias Cinder.Indexers
  alias Cinder.Indexers.FlareSolverrUrl
  alias CinderWeb.IndexerFormText

  @doc "The URL line's state: the saved URL, or nil."
  @spec url() :: String.t() | nil
  def url, do: FlareSolverrUrl.get()

  @doc "The dialog, its field holding the saved URL."
  @spec open() :: map()
  def open, do: %{step: :flaresolverr, value: url() || "", error: nil, in_use: nil}

  @doc "Keeps the typed value of a `phx-change` event; a change drops a shown count."
  @spec change(map(), map()) :: map()
  def change(dialog, params), do: %{dialog | value: typed(params), in_use: nil}

  @doc """
  Saves the typed value: `{:ok, notice}`, or `{:error, dialog}` holding the refusal or the count
  a clear shows first.
  """
  @spec save(map(), map()) :: {:ok, String.t()} | {:error, map()}
  def save(dialog, params) do
    value = typed(params)
    dialog = %{dialog | value: value, error: nil}
    in_use = if String.trim(value) == "" and url() != nil, do: in_use(), else: 0

    cond do
      in_use > 0 and dialog.in_use == nil ->
        {:error, %{dialog | in_use: in_use}}

      FlareSolverrUrl.put(value) == :ok ->
        {:ok, notice(url())}

      true ->
        {:error, %{dialog | error: IndexerFormText.flaresolverr_url(:invalid), in_use: nil}}
    end
  end

  defp typed(%{"flaresolverr" => %{"url" => value}}) when is_binary(value), do: value
  defp typed(_params), do: ""

  # A Newznab or Torznab row with the toggle on reads "Not supported: FlareSolverr" and never
  # calls the URL.
  defp in_use,
    do: Enum.count(Indexers.list(), &(&1.enabled and &1.flaresolverr and &1.type == :cardigann))

  @doc """
  The dialog's form: its value as `flaresolverr[url]`, carrying the refusal's words, which
  `translate_error/1` of `CinderWeb.CoreComponents` answers unchanged (see
  `CinderWeb.IndexerDialog.to_form/1`).
  """
  @spec url_form(map()) :: Phoenix.HTML.Form.t()
  def url_form(dialog) do
    errors = if dialog.error, do: [url: {dialog.error, []}], else: []
    to_form(%{"url" => dialog.value}, as: :flaresolverr, errors: errors)
  end

  defp notice(nil), do: gettext("FlareSolverr URL cleared.")
  defp notice(_url), do: gettext("FlareSolverr URL saved.")

  attr :url, :string, default: nil
  attr :myself, :any, required: true

  @doc "The line under the indexers table, with the button that opens the dialog."
  def flaresolverr_line(assigns) do
    ~H"""
    <p id="indexers-flaresolverr-line" class="flex flex-wrap items-center gap-2 text-sm">
      <span :if={@url}>{gettext("FlareSolverr: %{url}", url: @url)}</span>
      <span :if={!@url}>{gettext("FlareSolverr: not set")}</span>
      <span aria-hidden="true">·</span>
      <.button
        type="button"
        variant="ghost"
        size="xs"
        id="indexers-flaresolverr"
        phx-click="open_flaresolverr"
        phx-target={@myself}
        aria-label={
          if @url, do: gettext("Edit the FlareSolverr URL"), else: gettext("Set the FlareSolverr URL")
        }
      >
        {if @url, do: gettext("Edit"), else: gettext("Set")}
      </.button>
    </p>
    """
  end

  attr :dialog, :map, required: true
  attr :myself, :any, required: true

  @doc "The dialog's content: the URL field, its help, a refusal or the count, and the buttons."
  def flaresolverr_step(assigns) do
    ~H"""
    <div id="indexer-dialog-flaresolverr" class="space-y-4" phx-mounted={JS.focus_first()}>
      <h2 id="indexer-dialog-title" class="text-lg font-semibold">{gettext("FlareSolverr URL")}</h2>
      <.form
        :let={f}
        for={url_form(@dialog)}
        id="flaresolverr-form"
        phx-change="flaresolverr_change"
        phx-submit="flaresolverr_save"
        phx-target={@myself}
      >
        <.input
          field={f[:url]}
          type="text"
          id="flaresolverr-url"
          label={gettext("FlareSolverr URL")}
          inputmode="url"
          autocomplete="off"
          aria-describedby="flaresolverr-help"
        />
        <p id="flaresolverr-help" class="-mt-1 mb-2 text-xs text-base-content/70">
          {gettext(
            "FlareSolverr's browser runs each site's JavaScript and can reach your local network. Run it where it cannot."
          )}
        </p>
        <p
          :if={@dialog.in_use}
          id="flaresolverr-in-use"
          role="alert"
          class="alert alert-warning mb-2 text-sm"
        >
          {ngettext(
            "%{count} enabled indexer uses FlareSolverr.",
            "%{count} enabled indexers use FlareSolverr.",
            @dialog.in_use
          )}
        </p>
        <div class="mt-4 flex flex-wrap justify-end gap-2">
          <.button type="button" variant="ghost" phx-click={JS.push("close", target: @myself)}>
            {gettext("Cancel")}
          </.button>
          <.button type="submit" id="flaresolverr-save">
            {if @dialog.in_use, do: gettext("Clear it"), else: gettext("Save")}
          </.button>
        </div>
      </.form>
    </div>
    """
  end
end
