defmodule Cinder.Indexers.Definitions.UpdateRun do
  @moduledoc """
  The last run of the definitions update job (#1669): one row, id 1, that each run overwrites.
  Only `Cinder.Indexers.Definitions.Updater` writes it.

  `outcome` is `:applied` or `:unchanged` for a success, the set state a refused answer left
  (`:cinder_too_old`, `:shrank`, `:first_too_small`), or `:failed`, whose closed tag `error`
  holds as an Erlang term. `commit` is the commit the run saw upstream, nil when the fetch
  failed. `last_success_at` is the end of the last successful run, and `first_failure_at` the
  end of the first run that failed since then, nil after a success.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @doc "The id of the one row."
  @spec id() :: pos_integer()
  def id, do: 1

  @doc "The `error` column for a run's outcome: the tag of `{:failed, tag}`, nil otherwise."
  @spec encode_error(term()) :: binary() | nil
  def encode_error({:failed, tag}), do: :erlang.term_to_binary(tag)
  def encode_error(_outcome), do: nil

  @doc "The closed tag of a failed run, nil for any other run or none."
  @spec error(t() | nil) :: term()
  def error(%__MODULE__{outcome: :failed, error: error}),
    do: :erlang.binary_to_term(error, [:safe])

  def error(_run), do: nil

  @primary_key {:id, :integer, autogenerate: false}
  schema "definitions_update_run" do
    field :started_at, :utc_datetime
    field :ended_at, :utc_datetime

    field :outcome, Ecto.Enum,
      values: [:applied, :unchanged, :cinder_too_old, :shrank, :first_too_small, :failed]

    field :commit, :string
    field :error, :binary
    field :last_success_at, :utc_datetime
    field :first_failure_at, :utc_datetime
  end
end
