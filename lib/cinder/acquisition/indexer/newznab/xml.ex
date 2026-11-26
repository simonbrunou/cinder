defmodule Cinder.Acquisition.Indexer.Newznab.XML do
  @moduledoc """
  Reads a Newznab or Torznab answer body, an untrusted document, as XML: the `t=caps` answer
  here (`Cinder.Acquisition.Indexer.Newznab.Caps`), and the search answers of #1653.

  `parse/1` answers `{:ok, element}` in `Saxy.SimpleForm`'s shape (`{name, attributes,
  children}`) or `{:error, :bad_response}`, and never raises.

  ## No document type declaration

  Saxy skips a document type declaration without a word and parses the rest, so the refusal is
  this module's own: a body that holds `<!DOCTYPE` is refused before Saxy reads a byte of it.
  That also refuses the text inside a comment or a CDATA section, which no Newznab answer needs.
  Saxy refuses any other spelling of the declaration, such as `<!doctype`, and an entity
  declaration outside one, as malformed. No declared entity is ever expanded: Saxy expands only
  character references and the five predefined entities, and keeps any other entity reference
  as its text (`expand_entity: :keep`).
  """

  @type element :: {String.t(), [{String.t(), String.t()}], [element() | String.t()]}

  @declaration "<!DOCTYPE"

  @doc "Parses `body` as one XML document; see the moduledoc."
  @spec parse(term()) :: {:ok, element()} | {:error, :bad_response}
  def parse(body) when is_binary(body) do
    if String.contains?(body, @declaration),
      do: {:error, :bad_response},
      else: simple_form(body)
  end

  def parse(_body), do: {:error, :bad_response}

  # Saxy answers a malformed document with an error; the rescue keeps any raise on input it did
  # not expect from crashing the search.
  defp simple_form(body) do
    case Saxy.SimpleForm.parse_string(body, expand_entity: :keep) do
      {:ok, {name, attributes, children}} -> {:ok, {name, attributes, children}}
      _error -> {:error, :bad_response}
    end
  rescue
    _exception -> {:error, :bad_response}
  end

  @doc "The child elements of `element`, its text left out."
  @spec elements(element()) :: [element()]
  def elements({_name, _attributes, children}), do: for({_, _, _} = child <- children, do: child)

  @doc "The first child element of `element` named `name`, or nil."
  @spec child(element(), String.t()) :: element() | nil
  def child(element, name),
    do: Enum.find(elements(element), &match?({^name, _attributes, _children}, &1))

  @doc "The value of `element`'s attribute `name`, or nil."
  @spec attribute(element(), String.t()) :: String.t() | nil
  def attribute({_name, attributes, _children}, name) do
    case List.keyfind(attributes, name, 0) do
      {^name, value} -> value
      nil -> nil
    end
  end

  @max_digits 18

  @doc """
  `text`, trimmed, as a non-negative integer of at most 18 digits, else nil. A longer number is
  none, so no digit run is converted whole: past the BEAM's integer limit `Integer.parse/1`
  raises.
  """
  @spec integer(term()) :: non_neg_integer() | nil
  def integer(text) when is_binary(text) do
    text = String.trim(text)

    with true <- byte_size(text) <= @max_digits + 1,
         {value, ""} when value >= 0 and value < 1_000_000_000_000_000_000 <- Integer.parse(text) do
      value
    else
      _invalid -> nil
    end
  end

  def integer(_text), do: nil
end
