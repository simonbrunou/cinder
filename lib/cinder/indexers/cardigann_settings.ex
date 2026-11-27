defmodule Cinder.Indexers.CardigannSettings do
  @moduledoc """
  The stored values of a Cardigann configured indexer, checked against a loaded definition
  (#1668; #1620 points 2 and 3). Pure: `Cinder.Indexers` calls it inside its write transaction.

  A `text` or `password` setting's value is a secret, stored in the row's ciphertext
  (`Cinder.Indexers.Secrets`). A `checkbox` value is a boolean and a `select` value one of its
  option keys, both stored plain in `settings`. `info` and `info_*` settings store nothing.

  - `create/3` stores every declared setting's effective value: the typed one, else the copy's
    default. A blank secret stores the default, or empty text with none; a checkbox's default
    reads `true` only for `"true"`, and a select with no default takes its first option.
  - An edit checks its input against the running copy. A stored value keeps the class it was
    saved under, so a plain key stays plain and a secret key stays secret after an update
    retypes its setting. `secret_fields/3` lists the keys a secret input may set or clear.
  - `switch/5` rebuilds every value for another file's copy, carrying a stored value by name.
  - A refusal is `{:error, field, validation}`: `:settings_keys` for a key the copy does not
    declare, `:settings_values` for a value of the wrong kind, `:select_option` for a select
    value outside its options, and `:secret_fields` from `Cinder.Indexers.Secrets.merge/3`.
  """

  alias Cinder.Indexers.Secrets

  @secret_types ["text", "password"]
  @plain_types ["checkbox", "select"]

  @type refusal :: {:error, :settings | :secrets, atom()}

  @doc """
  The plain settings and secret values a new row stores, from the plain `input` (a map of
  checkbox and select values) and the secret `secrets` input (as `Secrets.merge/3` reads it).
  """
  @spec create(map(), map(), map()) :: {:ok, map(), Secrets.values()} | refusal()
  def create(definition, input, secrets) do
    names = names(definition, @secret_types)

    with {:ok, plain} <- plain_values(definition, %{}, MapSet.new(), input),
         {:ok, typed} <- merge_secrets({:ok, %{}}, secrets, names),
         :ok <- check_secret_values(definition, typed) do
      defaults = Map.new(names, &{&1, default(definition, &1)})
      {:ok, Map.merge(plain_defaults(definition), plain), Map.merge(defaults, typed)}
    end
  end

  @doc """
  The plain settings and secret values a Switch to the copy `definition` stores (#1907; #1616
  rule 7), from the indexer's stored `plain` settings and `secrets`, the plain `input` and the
  secret input `secret_input`. Each setting `definition` declares takes, first match: the typed
  value; for a secret, the default when its Clear box is ticked; the stored value of the same
  name and class (plain or secret) when it passes `definition`'s check for that setting and, for
  a plain value, the setting has its type (a boolean for a checkbox, text for a select); the
  copy's default as `create/3` reads it. A stored value `definition` does not declare is dropped.

  With `secrets` `:unreadable` (the stored ones do not decrypt), nothing carries: the secret input
  must set or clear every `text` and `password` setting `definition` declares, as
  `Secrets.merge/3` reads it, else the Switch is refused as `:secrets_unreadable`.
  """
  @spec switch(map(), map(), Secrets.values() | :unreadable, map(), map()) ::
          {:ok, map(), Secrets.values()} | refusal()
  def switch(definition, plain, :unreadable, input, secret_input) do
    names = names(definition, @secret_types)

    with {:ok, plain, _secrets} <- switch(definition, plain, %{}, input, %{}) do
      case edit_secrets(definition, :unreadable, secret_input, names) do
        {:changed, values, _changed} -> {:ok, plain, values}
        :unchanged when names == [] -> {:ok, plain, %{}}
        :unchanged -> {:error, :secrets, :secrets_unreadable}
        {:error, _field, _validation} = refusal -> refusal
      end
    end
  end

  def switch(definition, plain, secrets, input, secret_input) do
    names = names(definition, @secret_types)

    # A stored checkbox value is a boolean and a select value text, so a value carries only to
    # a setting of its own type: a select option named "true" never becomes a ticked checkbox.
    carried_plain =
      for {key, value} <- plain,
          %{type: type} = setting <- [setting(definition, key)],
          type == plain_type(value),
          match?({:ok, _}, check(setting, value)),
          into: %{},
          do: {key, value}

    carried_secrets =
      for {key, value} <- secrets,
          key in names,
          match?({:ok, _}, check(setting(definition, key), value)),
          into: %{},
          do: {key, value}

    start = Map.merge(Map.new(names, &{&1, default(definition, &1)}), carried_secrets)

    with {:ok, plain} <-
           plain_values(
             definition,
             Map.merge(plain_defaults(definition), carried_plain),
             MapSet.new(),
             input
           ) do
      case edit_secrets(definition, {:ok, start}, secret_input, names) do
        :unchanged -> {:ok, plain, start}
        {:changed, values, _changed} -> {:ok, plain, values}
        {:error, _field, _validation} = refusal -> refusal
      end
    end
  end

  @doc """
  The plain settings an edit stores: the `stored` ones with `input` merged in, each key a
  plain setting the running copy declares and not a key `secret_keys` holds. A key stored plain
  keeps that class whatever type the running copy gives it.
  """
  @spec edit_plain(map(), map(), MapSet.t(), map()) :: {:ok, map()} | refusal()
  def edit_plain(definition, stored, secret_keys, input),
    do: plain_values(definition, stored, secret_keys, input)

  @doc """
  The keys a secret input may set or clear on an edit: the running copy's `text` and `password`
  settings that are not stored plain, and the stored secret keys it still declares. A secret save
  drops a stored secret the running copy no longer declares (#1620 point 6).
  """
  @spec secret_fields(map(), map(), {:ok, Secrets.values()} | :unreadable) :: [String.t()]
  def secret_fields(definition, plain, stored) do
    declared = names(definition, :all)

    stored_keys =
      case stored do
        {:ok, values} -> Enum.filter(Map.keys(values), &(&1 in declared))
        :unreadable -> []
      end

    (Enum.reject(names(definition, @secret_types), &Map.has_key?(plain, &1)) ++ stored_keys)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Applies a secret input on an edit with `Secrets.merge/3`, then puts back the running copy's
  default, or empty text, for each field it cleared, and checks each set value against the
  running copy's type for its key.
  """
  @spec edit_secrets(map(), {:ok, Secrets.values()} | :unreadable, map(), [String.t()]) ::
          :unchanged | {:changed, Secrets.values(), [String.t()]} | refusal()
  def edit_secrets(definition, stored, input, fields) do
    case Secrets.merge(stored, input, fields) do
      :unchanged ->
        :unchanged

      {:error, tag} ->
        {:error, :secrets, if(tag == :unreadable, do: :secrets_unreadable, else: :secret_fields)}

      {:changed, values, changed} ->
        with :ok <- check_secret_values(definition, values),
             do: {:changed, with_cleared_defaults(definition, values, changed, fields), changed}
    end
  end

  # A field the input cleared reverts to the running copy's default, or empty text.
  defp with_cleared_defaults(definition, values, changed, fields) do
    cleared = for field <- changed, field in fields, not Map.has_key?(values, field), do: field
    Map.merge(Map.new(cleared, &{&1, default(definition, &1)}), values)
  end

  defp merge_secrets(stored, input, fields) do
    case Secrets.merge(stored, input, fields) do
      :unchanged -> {:ok, %{}}
      {:changed, values, _fields} -> {:ok, values}
      {:error, _tag} -> {:error, :secrets, :secret_fields}
    end
  end

  # A value set under a secret key is checked as its running type reads it.
  defp check_secret_values(definition, values) do
    Enum.reduce_while(values, :ok, fn {key, value}, :ok ->
      case check(setting(definition, key), value) do
        {:ok, _value} -> {:cont, :ok}
        {:error, validation} -> {:halt, {:error, :secrets, validation}}
      end
    end)
  end

  defp plain_type(value) when is_boolean(value), do: "checkbox"
  defp plain_type(value) when is_binary(value), do: "select"
  defp plain_type(_value), do: nil

  defp plain_values(_definition, stored, _secret_keys, input) when input == %{}, do: {:ok, stored}

  defp plain_values(definition, stored, secret_keys, input) when is_map(input) do
    allowed = MapSet.new(names(definition, @plain_types) ++ Map.keys(stored))

    Enum.reduce_while(input, {:ok, stored}, fn {key, value}, {:ok, acc} ->
      key = if is_atom(key), do: Atom.to_string(key), else: key

      case plain_value(definition, allowed, secret_keys, key, value) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        {:error, validation} -> {:halt, {:error, :settings, validation}}
      end
    end)
  end

  defp plain_values(_definition, _stored, _secret_keys, _input),
    do: {:error, :settings, :settings_values}

  defp plain_value(definition, allowed, secret_keys, key, value) do
    if MapSet.member?(allowed, key) and not MapSet.member?(secret_keys, key),
      do: check(setting(definition, key), value),
      else: {:error, :settings_keys}
  end

  defp check(nil, _value), do: {:error, :settings_keys}
  defp check(%{type: "checkbox"}, value) when is_boolean(value), do: {:ok, value}
  defp check(%{type: "checkbox"}, "true"), do: {:ok, true}
  defp check(%{type: "checkbox"}, "false"), do: {:ok, false}
  defp check(%{type: "checkbox"}, _value), do: {:error, :settings_values}

  defp check(%{type: "select", options: options}, value) do
    if is_binary(value) and Enum.any?(options, &(elem(&1, 0) == value)),
      do: {:ok, value},
      else: {:error, :select_option}
  end

  defp check(%{type: type}, value) when type in @secret_types do
    if is_binary(value) and String.valid?(value),
      do: {:ok, value},
      else: {:error, :settings_values}
  end

  # An `info` setting, or a type the engine does not know, stores nothing.
  defp check(_setting, _value), do: {:error, :settings_keys}

  defp plain_defaults(definition) do
    for %{type: type, name: name} = setting <- definition.settings || [],
        type in @plain_types,
        into: %{},
        do: {name, plain_default(setting)}
  end

  defp plain_default(%{type: "checkbox", default: default}), do: default == "true"

  defp plain_default(%{type: "select", default: default, options: options}) do
    cond do
      is_binary(default) -> default
      options != [] -> options |> hd() |> elem(0)
      true -> nil
    end
  end

  # The setting names of `types` the definition declares; `:all` for every stored type.
  defp names(definition, :all), do: names(definition, @secret_types ++ @plain_types)

  defp names(definition, types) do
    for %{type: type, name: name} <- definition.settings || [], type in types, do: name
  end

  @doc "The running copy's default for `key`, or empty text with none."
  @spec default(map(), String.t()) :: String.t()
  def default(definition, key) do
    case setting(definition, key) do
      %{default: default} when is_binary(default) -> default
      _none -> ""
    end
  end

  defp setting(definition, key), do: Enum.find(definition.settings || [], &(&1.name == key))
end
