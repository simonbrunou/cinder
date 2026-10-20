defmodule Cinder.Settings.Definition do
  @moduledoc """
  One setting definition: everything `Cinder.Settings` knows about one settings key. The
  `/settings` form, the validator, the save planner and the env overlay all read the same
  definition, so a key's group, label, rejection message and env target cannot drift apart.

  `Cinder.Settings.Registry` holds the catalogue; `Cinder.Settings.Shape` gives each `shape`
  its behaviour in every pass.

  - `shape` decides how a stored value reaches the form and the env, and what counts as invalid.
  - `group` is the `/settings` disclosure the key lives in: an atom of `Registry.groups/0`,
    `:anime` (its own disclosure), or `nil` for a key edited outside the main form.
  - `label` is self-describing (it names the key in the rejection flash): an English msgid, or
    `{template, bindings}` whose binding values are msgids too.
  - `message` explains a rejected value; `nil` uses the shape's message.
  - `target` is where the overlay writes the value: `{:module, module, field}` (a field of a
    `config :cinder, module` keyword list), `{:env, key}` (a flat `:cinder` key),
    `{:writer, name}` (a composite value one overlay writer assembles) or `nil` (read live from
    the store).
  - `bootstrap` is `:base` when a missing row falls back to the captured env value, and
    `{:base, value}` when it falls back to `value` if that captured value is nil (a writer slot
    the bootstrap keyword list lacks).
  - `save` is `:form` (planned from the submitted form), `:always` (written on every form save,
    `params[key]` or the shape's default), `:read_only` (shown, never saved by the form) or
    `:direct` (written only through `Cinder.Settings.put/2`).
  - `render` is `:field` (the generic `setting_field`), `:custom` (an input written by hand on
    `/settings`) or `:none` (no input). Every key but a `:none` one has an input named after it.
  - `check` names a cross-field rule: `:cutoff_in_preferred` or `:languages_for_require`.
  - `env_placeholder` shows the effective env value as the input placeholder when no row exists.
  - `kind` and `slot` identify a per-kind or per-part definition (`:movies`, `:min_size`). For a
    `{:writer, name}` target, `slot` is the field it fills in the writer's keyword list (`:ssl`).
  """

  alias Cinder.LibraryKind
  alias Cinder.Settings.Shape

  @type label :: String.t() | {String.t(), keyword(String.t())}

  @type t :: %__MODULE__{
          key: String.t(),
          shape: term(),
          group: atom() | nil,
          label: label() | nil,
          message: String.t() | nil,
          target: {:module, module(), atom()} | {:env, atom()} | {:writer, atom()} | nil,
          bootstrap: :base | {:base, term()} | :none,
          save: :form | :always | :read_only | :direct,
          render: :field | :custom | :none,
          check: :cutoff_in_preferred | :languages_for_require | nil,
          env_placeholder: boolean(),
          kind: atom() | nil,
          slot: atom() | nil,
          placeholder: String.t(),
          help: String.t() | nil,
          inputmode: String.t() | nil
        }

  @enforce_keys [:key, :shape]
  defstruct [
    :key,
    :shape,
    :group,
    :label,
    :message,
    :target,
    :check,
    :kind,
    :slot,
    :help,
    :inputmode,
    bootstrap: :none,
    save: :form,
    render: :custom,
    env_placeholder: false,
    placeholder: ""
  ]

  @doc "Builds a definition, rejecting unknown options at compile time."
  def new(key, shape, opts \\ []), do: struct!(__MODULE__, [key: key, shape: shape] ++ opts)

  @doc """
  A setting the generic `setting_field` renders, stored at `{module, field}` (with its effective
  env value as the placeholder unless it is secret) or at a flat `:cinder` key. `shape:` defaults
  to `:text`.
  """
  def field(key, target, opts) do
    {shape, opts} = Keyword.pop(opts, :shape, :text)

    target_opts =
      case target do
        {module, field} -> [target: {:module, module, field}, env_placeholder: shape != :secret]
        env_key when is_atom(env_key) -> [target: {:env, env_key}]
      end

    new(key, shape, [render: :field] ++ target_opts ++ opts)
  end

  @doc """
  The settings key of a per-kind definition. Library roots derive from the kind's root role
  (`:ebook` keeps `books_library_path`); release rules and Plex sections from the kind itself.
  """
  def kind_key(kind, slot) when slot in [:library_path, :anime_library_path],
    do: "#{LibraryKind.root_role(kind)}_#{slot}"

  def kind_key(kind, slot), do: "#{kind}_#{slot}"

  @doc "Whether the store encrypts this key at rest."
  def secret?(%__MODULE__{shape: shape}), do: shape == :secret

  @doc "Whether `Cinder.Settings.save_form/1` can reject this key."
  def validated?(%__MODULE__{save: save} = definition) when save in [:form, :always],
    do: Shape.validates?(definition.shape) or not is_nil(definition.check)

  def validated?(%__MODULE__{}), do: false

  @doc "The message shown for a rejected value: the definition's own, else its shape's."
  def message(%__MODULE__{message: nil, shape: shape}), do: Shape.message(shape)
  def message(%__MODULE__{message: message}), do: message
end
