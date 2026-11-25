defmodule Cinder.Indexers.Secrets do
  @moduledoc """
  A configured indexer's secrets: one ciphertext per row, `NULL` when the row has none.

  The plaintext is a JSON object naming its scope (`"indexer_secrets"`), the row's id and the
  values: `{"scope": "indexer_secrets", "id": 7, "values": {"api_key": "..."}}`. Cloak's AES-GCM
  uses one constant AAD, so without the scope and id a ciphertext copied to another row would
  decrypt there. `open/1` reads a scope or id that does not match its row as unreadable.

  Secret inputs arrive as one map, as a form's `secrets` param would carry them: `"<field>"`
  with a value to set (blank keeps the stored one) and `"clear_<field>"` with a truthy flag to
  clear it. A typed value wins over a ticked clear, as `/settings` does it
  (`Cinder.Settings.Shape.plan/3`).
  """

  alias Cinder.Indexers.ConfiguredIndexer
  alias Cinder.SecretCodec
  alias Cinder.Settings.Shape

  @scope "indexer_secrets"

  @type values :: %{optional(String.t()) => String.t()}

  @doc "The ciphertext that stores `values` for the row `id`; `nil` for no values."
  @spec seal(pos_integer(), values()) :: binary() | nil
  def seal(_id, values) when values == %{}, do: nil

  def seal(id, values) when is_integer(id) and is_map(values),
    do: SecretCodec.encode(Jason.encode!(%{"scope" => @scope, "id" => id, "values" => values}))

  @doc """
  The row's secret values: `{:ok, %{}}` for a row with none, `{:ok, values}`, or `:unreadable`
  when the ciphertext does not decrypt or names another scope or row.
  """
  @spec open(ConfiguredIndexer.t()) :: {:ok, values()} | :unreadable
  def open(%ConfiguredIndexer{id: id, secrets_ciphertext: ciphertext}) do
    case SecretCodec.decode(ciphertext) do
      :absent -> {:ok, %{}}
      :unreadable -> :unreadable
      {:ok, json} -> read_envelope(json, id)
    end
  end

  # The pin compares the id exactly, so 1.0 does not read as row 1; a row with no id yet reads
  # nothing.
  defp read_envelope(json, id) when is_integer(id) do
    with {:ok, %{"scope" => @scope, "id" => ^id, "values" => values} = envelope}
         when map_size(envelope) == 3 and is_map(values) <- Jason.decode(json),
         true <- Enum.all?(values, fn {_field, value} -> text?(value) end) do
      {:ok, values}
    else
      _ -> :unreadable
    end
  end

  defp read_envelope(_json, _id), do: :unreadable

  defp text?(value), do: is_binary(value) and String.valid?(value)

  @doc """
  Applies secret `input` to the `stored` values (what `open/1` answered) for a type whose secret
  fields are `fields`.

  Answers `:unchanged` when the input sets nothing and clears no stored field, `{:changed, values,
  changed_fields}` otherwise, or `{:error, :invalid}` for an input key that is not a string or an
  atom naming one of `fields` or its `clear_` flag, or a value that is not UTF-8 text. A typed
  value counts as a change even when it equals the stored one: re-entering a key the indexer had
  rejected is how an admin says it works again. A secret save also drops a stored field `fields`
  no longer names. On `:unreadable` stored values, only an input that sets or clears every field
  changes them; any other set or clear answers `{:error, :unreadable}`, and an input that sets
  and clears nothing answers `:unchanged`.
  """
  @spec merge({:ok, values()} | :unreadable, map(), [String.t()]) ::
          :unchanged | {:changed, values(), [String.t()]} | {:error, :invalid | :unreadable}
  def merge(stored, input, fields) do
    case operations(input, fields) do
      {:ok, ops} -> apply_operations(stored, ops, fields)
      :error -> {:error, :invalid}
    end
  end

  defp apply_operations(_stored, ops, _fields) when ops == %{}, do: :unchanged

  defp apply_operations(:unreadable, ops, fields) do
    if Enum.sort(Map.keys(ops)) == Enum.sort(fields),
      do: {:changed, set_values(ops), Enum.sort(fields)},
      else: {:error, :unreadable}
  end

  defp apply_operations({:ok, old}, ops, fields) do
    set = Map.keys(set_values(ops))
    cleared = Enum.filter(cleared(ops), &Map.has_key?(old, &1))

    if set == [] and cleared == [] do
      :unchanged
    else
      new = old |> Map.merge(set_values(ops)) |> Map.drop(cleared) |> Map.take(fields)
      undeclared = Map.keys(old) -- fields
      {:changed, new, Enum.sort(Enum.uniq(set ++ cleared ++ undeclared))}
    end
  end

  defp set_values(ops), do: for({f, {:set, value}} <- ops, into: %{}, do: {f, value})
  defp cleared(ops), do: for({f, :clear} <- ops, do: f)

  # Each field's operation: {:set, value} or :clear; a field with neither is left out.
  defp operations(input, fields) do
    input = Map.new(input, fn {key, value} -> {key_name(key), value} end)
    allowed = fields ++ Enum.map(fields, &("clear_" <> &1))

    if Enum.all?(input, fn {key, value} -> key in allowed and valid_input?(key, value) end),
      do: {:ok, Enum.reduce(fields, %{}, &put_operation(&2, &1, operation(input, &1)))},
      else: :error
  end

  # A string or atom key names a field; any other key names none, so the allowlist refuses it.
  defp key_name(key) when is_binary(key), do: key
  defp key_name(key) when is_atom(key), do: Atom.to_string(key)
  defp key_name(_key), do: nil

  defp put_operation(ops, _field, nil), do: ops
  defp put_operation(ops, field, op), do: Map.put(ops, field, op)

  defp valid_input?("clear_" <> _field, _flag), do: true

  # A value that is not UTF-8 text would make `Jason.encode!/1` raise with its bytes in the message.
  defp valid_input?(_field, value), do: is_nil(value) or text?(value)

  # A value is set as typed; only a blank one (whitespace included) keeps the stored value.
  defp operation(input, field) do
    typed = input[field] || ""

    cond do
      String.trim(typed) != "" -> {:set, typed}
      Shape.truthy?(input["clear_" <> field]) -> :clear
      true -> nil
    end
  end
end
