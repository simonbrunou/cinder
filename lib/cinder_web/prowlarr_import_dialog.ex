defmodule CinderWeb.ProwlarrImportDialog do
  @moduledoc """
  The state of the Import from Prowlarr dialog in `CinderWeb.IndexersComponent` (#1674), and its
  commit through `Cinder.Indexers.ProwlarrImport`.

  An import dialog is a map with `step: :import` and a `phase`:

    * `:message`: the preview failed, and `error` holds `ProwlarrImport.preview/0`'s tag
      (`:not_configured` with no saved Prowlarr URL or key, or a read's tag);
    * `:preview`: `preview` holds the preview, `choices` the admin's choices for each tickable
      row by Prowlarr id (`ticked`, the typed `name`, `via_prowlarr`), `row_errors` the codes a
      refused commit gave each row, and `alert` a refusal shown above the rows: `:changed` or
      `{:error, tag}`. A through-Prowlarr row has one box, "Add it through Prowlarr", which
      ticks it with `via_prowlarr: true`; a direct row's tick leaves `via_prowlarr` false;
    * `:report`: `report` holds the commit's report and `skipped` the names of the rows the
      preview showed as already imported. The preview is dropped.

  `flaresolverr_offer` is the preview's `flaresolverr_host` while Cinder has no FlareSolverr URL
  saved, else nil (#1682). The preview then renders the box `flaresolverr[save]`, unticked, and
  `flaresolverr_save` keeps its tick. `submit/3` asks the commit to save the host only while
  both are set. A forged tick with no offer saves nothing, and the commit saves nothing either
  once a URL is saved.

  `token` is new for each preview. Each API key input's id is built from it and the row
  (`secret_id/2`), and carries `phx-update="ignore"`: the browser keeps what it holds across the
  `phx-change` re-renders, and a new preview renders new, empty inputs.

  A direct Cardigann row renders one input per secret setting Prowlarr masks
  (`Cinder.Indexers.ProwlarrImport.Row`'s `secret_inputs`, #1675), named
  `secrets[<Prowlarr id>][<setting>]`, each with an id built from the token, the row and its
  place (`cardigann_secret_id/3`), and `phx-update="ignore"` too.

  No secret value enters the dialog. `change/2` reads only the `rows` params. `submit/3` reads
  the `api_key` of `secrets[<Prowlarr id>]` straight from the submit's params, for each ticked
  direct row whose key Prowlarr masks, the rows that render a key input, and the masked
  settings of each ticked Cardigann row with secret inputs, and hands them to
  `ProwlarrImport.commit/4`. No other row's secrets, and no other setting's, are read. Each
  payload is client-controlled: the params are read under the ids of the held preview's tickable
  rows, so another id changes nothing, and so does a value that is not a map where a map goes or
  text where text goes, save the secrets of a ticked row with a key or secret input: a `secrets`
  param or a row's secrets that are not a map, or an `api_key` or masked setting that is not
  text, the commit refuses on that row.
  """

  alias Cinder.Indexers.{FlareSolverrUrl, ProwlarrImport}
  alias Cinder.Indexers.ProwlarrImport.{Preview, Row}

  @doc "Reads Prowlarr's preview: a dialog on its preview, or on the message of its error."
  @spec open() :: map()
  def open do
    case ProwlarrImport.preview() do
      {:ok, preview} -> on_preview(preview, nil)
      {:error, tag} -> %{base(:message) | error: tag}
    end
  end

  defp base(phase) do
    %{
      step: :import,
      phase: phase,
      error: nil,
      preview: nil,
      token: nil,
      choices: %{},
      via_ids: MapSet.new(),
      key_ids: MapSet.new(),
      secret_fields: %{},
      row_errors: %{},
      alert: nil,
      report: nil,
      skipped: [],
      flaresolverr_offer: nil,
      flaresolverr_save: false
    }
  end

  defp on_preview(%Preview{} = preview, alert) do
    tickable = Enum.filter(preview.rows, & &1.tickable)

    %{
      base(:preview)
      | preview: preview,
        token: System.unique_integer([:positive]),
        choices:
          Map.new(tickable, fn row ->
            {row.prowlarr_id, %{ticked: row.default_ticked, name: row.name, via_prowlarr: false}}
          end),
        via_ids: ids(tickable, &via_input?/1),
        key_ids: ids(tickable, &key_input?/1),
        secret_fields:
          for(
            row <- tickable,
            row.secret_inputs != [],
            into: %{},
            do: {row.prowlarr_id, Enum.map(row.secret_inputs, & &1.field)}
          ),
        alert: alert,
        flaresolverr_offer: if(FlareSolverrUrl.get() == nil, do: preview.flaresolverr_host)
    }
  end

  defp ids(rows, keep?),
    do: for(row <- rows, keep?.(row), into: MapSet.new(), do: row.prowlarr_id)

  @doc "Whether the row renders an API key input: a direct row whose key Prowlarr masks."
  @spec key_input?(Row.t()) :: boolean()
  def key_input?(%Row{state: :direct, key: :masked, tickable: true}), do: true
  def key_input?(_row), do: false

  @doc """
  Whether the row's one box is "Add it through Prowlarr", which ticks it through Prowlarr,
  rather than "Import".
  """
  @spec via_input?(Row.t()) :: boolean()
  def via_input?(%Row{state: state}), do: state == :via_prowlarr

  @doc "The id of the API key input of the row `prowlarr_id`, new with each preview."
  @spec secret_id(map(), pos_integer()) :: String.t()
  def secret_id(dialog, prowlarr_id), do: "import-key-#{dialog.token}-#{prowlarr_id}"

  @doc """
  The id of the input of the row `prowlarr_id`'s secret setting at `index` in its
  `secret_inputs`, new with each preview. A setting's name comes from the definition, so the id
  uses its place.
  """
  @spec cardigann_secret_id(map(), pos_integer(), non_neg_integer()) :: String.t()
  def cardigann_secret_id(dialog, prowlarr_id, index),
    do: "import-secret-#{dialog.token}-#{prowlarr_id}-#{index}"

  @doc "The id of the name input of the row `prowlarr_id`."
  @spec name_id(pos_integer()) :: String.t()
  def name_id(prowlarr_id), do: "import-row-#{prowlarr_id}-name"

  @doc """
  The id of the element a refused submit moves focus to: the alert above the rows when there is
  one, else the name of the first row with an error, else nil.
  """
  @spec focus_id(map()) :: String.t() | nil
  def focus_id(%{alert: alert}) when alert != nil, do: "import-alert"

  def focus_id(dialog) do
    case Enum.find(dialog.preview.rows, &Map.has_key?(dialog.row_errors, &1.prowlarr_id)) do
      %{prowlarr_id: id} -> name_id(id)
      nil -> nil
    end
  end

  @doc "Keeps the ticks, names and through-Prowlarr opt-ins of a `phx-change` event's `params`."
  @spec change(map(), map()) :: map()
  def change(%{phase: :preview} = dialog, params) do
    rows = map_at(params, "rows")

    choices =
      Map.new(dialog.choices, fn {id, choice} ->
        input = map_at(rows, Integer.to_string(id))
        {id, typed(choice, input, MapSet.member?(dialog.via_ids, id))}
      end)

    save =
      case flag(map_at(params, "flaresolverr")["save"]) do
        {:ok, on} -> dialog.flaresolverr_offer != nil and on
        :error -> dialog.flaresolverr_save
      end

    %{dialog | choices: choices, flaresolverr_save: save}
  end

  def change(dialog, _params), do: dialog

  defp map_at(%{} = map, key) do
    case Map.get(map, key) do
      %{} = value -> value
      _other -> %{}
    end
  end

  # A through-Prowlarr row's one box ticks it through Prowlarr; a direct row's tick never does.
  defp typed(choice, input, via?) do
    choice =
      case {via?, flag(input["via_prowlarr"]), flag(input["ticked"])} do
        {true, {:ok, on}, _ticked} -> %{choice | ticked: on, via_prowlarr: on}
        {false, _via, {:ok, on}} -> %{choice | ticked: on}
        _other -> choice
      end

    case input["name"] do
      name when is_binary(name) -> %{choice | name: name}
      _other -> choice
    end
  end

  defp flag(value) when value in ["true", "false"], do: {:ok, value == "true"}
  defp flag(_value), do: :error

  @doc """
  Commits the dialog's choices, with the typed values of `params`, as `actor`. Answers
  `{:ok, dialog}` on the report once the import committed, else `{:error, dialog}`: on a new
  preview after a change, on the rows' errors, or with the refusal in `alert`.
  """
  @spec submit(map(), term(), map()) :: {:ok, map()} | {:error, map()}
  def submit(%{phase: :preview} = dialog, actor, params) do
    dialog = change(dialog, params)

    save? = dialog.flaresolverr_offer != nil and dialog.flaresolverr_save
    opts = [save_flaresolverr_url: save?]

    case ProwlarrImport.commit(dialog.preview, choices(dialog, params), actor, opts) do
      {:ok, report} ->
        {:ok,
         %{
           dialog
           | phase: :report,
             report: report,
             skipped: skipped(dialog.preview),
             preview: nil,
             choices: %{}
         }}

      {:error, {:changed, preview}} ->
        {:error, on_preview(preview, :changed)}

      {:error, {:rows, errors}} ->
        {:error, offer_kept(%{dialog | row_errors: errors, alert: nil})}

      {:error, tag} ->
        {:error, offer_kept(%{dialog | row_errors: %{}, alert: {:error, tag}})}
    end
  end

  # A batch refused after the tick saved the URL, or after a URL was saved elsewhere, offers it
  # no more.
  defp offer_kept(dialog) do
    if FlareSolverrUrl.get() == nil,
      do: dialog,
      else: %{dialog | flaresolverr_offer: nil, flaresolverr_save: false}
  end

  # Each tickable row's choice, with the typed key of a ticked row that renders a key input and
  # the typed secrets of a ticked Cardigann row that renders secret inputs.
  defp choices(dialog, params) do
    Map.new(dialog.choices, fn {id, choice} ->
      secrets =
        cond do
          not choice.ticked -> %{}
          MapSet.member?(dialog.key_ids, id) -> typed_key(params, id)
          fields = dialog.secret_fields[id] -> typed_secrets(params, id, fields)
          true -> %{}
        end

      {id, Map.put(choice, :secrets, secrets)}
    end)
  end

  # Only the row's masked settings; a value that is not a map goes to the commit, as for a key.
  defp typed_secrets(%{"secrets" => %{} = secrets}, id, fields) do
    case Map.get(secrets, Integer.to_string(id), %{}) do
      %{} = row -> Map.take(row, fields)
      _other -> :invalid
    end
  end

  defp typed_secrets(%{"secrets" => _not_a_map}, _id, _fields), do: :invalid
  defp typed_secrets(_params, _id, _fields), do: %{}

  # Only the `api_key` posted for the row. A `secrets` param or a row's secrets that are not a
  # map go to the commit, which refuses them as `:secret_invalid`; no `secrets` param is none.
  defp typed_key(%{"secrets" => %{} = secrets}, id) do
    case Map.get(secrets, Integer.to_string(id), %{}) do
      %{} = row -> Map.take(row, ["api_key"])
      _other -> :invalid
    end
  end

  defp typed_key(%{"secrets" => _not_a_map}, _id), do: :invalid
  defp typed_key(_params, _id), do: %{}

  defp skipped(preview),
    do: for(row <- preview.rows, row.state == :already_imported, do: row.name)
end
