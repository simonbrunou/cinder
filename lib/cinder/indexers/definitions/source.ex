defmodule Cinder.Indexers.Definitions.Source do
  @moduledoc """
  Where the Cardigann definitions come from: the `master` branch of Prowlarr/Indexers (#1666,
  part of #1610). `Cinder.Indexers.Definitions.Source.GitHub` is the adapter, and the
  `:indexer_definitions_source` key names it, read with `Application.fetch_env!/2` on each call.

  `fetch/1` is the one fetch: it reads `master`'s commit and, when that is not the stored set's,
  downloads the commit's zip and reads it with `Cinder.Indexers.Definitions.Archive.read/2`.
  `Cinder.Indexers.Definitions.Updater` schedules it and stores the result (#1669).

  Every error is a closed tag, never a URL, a header or a body, so a caller can store and show
  it: `{:http_status, status}` for a status other than 200, `:timeout`, `:too_large`,
  `:transport`, `:no_master_ref`, `:invalid_commit`, and the reader's tags.
  """

  alias Cinder.Indexers.Definitions.{Archive, Set}

  @typedoc "A git commit id: 40 lowercase hex characters."
  @type commit :: String.t()

  @type error ::
          {:http_status, non_neg_integer()}
          | :timeout
          | :too_large
          | :transport
          | :no_master_ref
          | :invalid_commit

  @doc """
  The tag of each `error`: `:http_status` stands for `{:http_status, status}`, the others for
  themselves.
  """
  @spec error_tags() :: [atom()]
  def error_tags,
    do: [:http_status, :timeout, :too_large, :transport, :no_master_ref, :invalid_commit]

  @doc "Reads the commit `master` names."
  @callback master_commit() :: {:ok, commit()} | {:error, error()}

  @doc "Downloads the zip of `commit`, refusing a commit that is not 40 lowercase hex characters."
  @callback download(commit()) :: {:ok, binary()} | {:error, error()}

  @doc """
  Answers `:unchanged` when `master` still names `stored_commit`, without downloading anything.
  Otherwise, `stored_commit` being nil before the first load, downloads `master`'s zip and reads
  it.
  """
  @spec fetch(commit() | nil) ::
          :unchanged | {:ok, commit(), Set.t()} | {:error, error() | Archive.reason()}
  def fetch(stored_commit) do
    source = Application.fetch_env!(:cinder, :indexer_definitions_source)

    case source.master_commit() do
      {:ok, ^stored_commit} -> :unchanged
      {:ok, commit} -> download_and_read(source, commit)
      {:error, _reason} = error -> error
    end
  end

  defp download_and_read(source, commit) do
    with {:ok, zip} <- source.download(commit),
         {:ok, set} <- Archive.read(zip, commit) do
      {:ok, commit, set}
    end
  end
end
