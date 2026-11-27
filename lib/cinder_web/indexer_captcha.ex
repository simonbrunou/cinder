defmodule CinderWeb.IndexerCaptcha do
  @moduledoc """
  The captcha of a Cardigann Edit dialog in `CinderWeb.IndexersComponent` (#1681): the state
  the component keeps beside the dialog, what a load's answer makes of it, and the check a save
  with an answer passes first.

  The state is nil before any load, else a map holding the indexer `id`, a `key` new on each
  load, which names the answer input so the browser keeps what it holds across patches
  (`phx-update="ignore"`), the `state` (`:loading`, `:shown` or `:error`), and for a shown
  image the load's `token` and the image as a `data:` URI (`src`), and a `message` the dialog
  shows in a `role="alert"` line. The answer never enters it: a save reads it from its params
  (`answer/1`) and hands it on inside a function (`check/3`).
  """
  use Gettext, backend: CinderWeb.Gettext

  alias Cinder.Acquisition.IndexerSource.Native
  alias CinderWeb.{CardigannDialog, DefinitionText, IndexerStateText}

  @doc "The state of a load of the configured indexer `id` that starts now."
  @spec loading(pos_integer()) :: map()
  def loading(id),
    do: %{
      id: id,
      key: System.unique_integer([:positive]),
      state: :loading,
      token: nil,
      src: nil,
      message: nil
    }

  @doc "Whether `captcha` holds a load still running."
  @spec loading?(map() | nil) :: boolean()
  def loading?(captcha), do: match?(%{state: :loading}, captcha)

  @doc "Whether `captcha` shows an image."
  @spec shown?(map() | nil) :: boolean()
  def shown?(captcha), do: match?(%{state: :shown}, captcha)

  @doc "The id of the answer input of `captcha`."
  @spec answer_id(map()) :: String.t()
  def answer_id(%{key: key}), do: "indexer-form-captcha-answer-#{key}"

  @doc """
  What the answer of `Native.load_captcha/1` makes of the loading `captcha`, for the indexer
  named `name`: the image shown, or the error worded.
  """
  @spec loaded(map(), term(), String.t()) :: map()
  def loaded(captcha, {:ok, %{token: token, mime: mime, image: image}}, _name),
    do: %{
      captcha
      | state: :shown,
        token: token,
        src: "data:#{mime};base64,#{image}",
        message: nil
    }

  def loaded(captcha, {:error, reason}, name), do: failed(captcha, message(reason, name))
  def loaded(captcha, _other, name), do: failed(captcha, message(:crashed, name))

  defp failed(captcha, message),
    do: %{captcha | state: :error, token: nil, src: nil, message: message}

  @doc "`captcha` with `message` shown, and its image kept."
  @spec say(map(), String.t()) :: map()
  def say(captcha, message), do: %{captcha | message: message}

  @doc """
  The words for an error of `Native.load_captcha/1` for the indexer named `name`: a code of the
  captcha's own through `CinderWeb.DefinitionText.captcha_error/1`, else the failure's cause.
  """
  @spec message(term(), String.t()) :: String.t()
  def message(:not_found, name), do: gettext("%{name} no longer exists.", name: name)

  def message(:undecryptable_secrets, _name), do: IndexerStateText.detail(:undecryptable, nil)

  def message({:not_supported, _feature} = state, _name), do: IndexerStateText.detail(state, nil)

  def message(:not_written, _name), do: gettext("The captcha could not be kept. Try again.")

  def message(:deadline, _name),
    do: gettext("The captcha could not be loaded: the site did not answer in time.")

  def message(:crashed, _name), do: gettext("The captcha could not be loaded. Try again.")

  def message(reason, _name) do
    DefinitionText.captcha_error(reason) ||
      gettext("The captcha could not be loaded: %{cause}.", cause: IndexerStateText.cause(reason))
  end

  @doc """
  The answer of a save's `params`, trimmed: nil for none, a blank one, or a payload of another
  shape.
  """
  @spec answer(map()) :: String.t() | nil
  def answer(%{"captcha" => %{"answer" => answer}}) when is_binary(answer) do
    case String.trim(answer) do
      "" -> nil
      answer -> answer
    end
  end

  def answer(_params), do: nil

  @doc """
  The check a save of the Edit `dialog` with `params` passes while `captcha` shows an image of
  that indexer: nil when the save carries no answer, or no image of this dialog's indexer shows;
  `{:answer, token, fun}` when the answer can go, `fun` answering it; `{:refused, captcha}` when
  the save moves the base URL, under which the image's session was loaded, or the session no
  longer serves an answer (`Native.captcha_live?/2`). The check writes nothing.
  """
  @spec check(map() | nil, map(), map()) ::
          nil | {:answer, String.t(), (-> String.t())} | {:refused, map()}
  def check(
        %{state: :shown, id: id, token: _token} = captcha,
        %{mode: :edit, id: id} = dialog,
        params
      ) do
    case answer(params) do
      nil -> nil
      answer -> answered(captcha, dialog, params, answer)
    end
  end

  def check(_captcha, _dialog, _params), do: nil

  defp answered(%{id: id, token: token} = captcha, dialog, params, answer) do
    cond do
      CardigannDialog.change(dialog, params).values["base_url"] != dialog.stored_base_url ->
        {:refused, say(captcha, gettext("Save the new base URL first, then show a new captcha."))}

      not Native.captcha_live?(id, token) ->
        {:refused, failed(captcha, gettext("This captcha expired: show a new one."))}

      true ->
        {:answer, token, fn -> answer end}
    end
  end
end
