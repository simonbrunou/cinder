defmodule Cinder.DefinitionFixtures do
  @moduledoc """
  Cardigann definitions written for Cinder's tests, mirror answers built from them, and Cardigann
  configured indexers pinned to them (#1668). Every definition is JSON, which the loader reads
  as YAML.

  The mirror holds `tracker.yml` beside 100 filler names, so a first answer passes the 100-name
  floor. `check/1` is the load check the applies run: the pure loader, with the verdict a test
  asks for. The real loader reads every copy with a search path or a setting as not supported,
  since no search feature is on yet, so `check/1` clears `unsupported` unless the
  definition's `id` ends in `-ns`, which keeps `[:html_search]`.
  """

  import ExUnit.Assertions
  import Ecto.Query, only: [from: 2]

  alias Cinder.Indexers
  alias Cinder.Indexers.{ConfiguredIndexer, Secrets}
  alias Cinder.Indexers.Definitions
  alias Cinder.Indexers.Definitions.{Copy, Loader, Pin, Set}
  alias Cinder.Indexers.Definitions.Set.{DefinitionFile, Versions}
  alias Cinder.Repo

  @link "https://tracker.invalid/"

  @doc "The base URL every pinned indexer stores: the first link of `definition/1`."
  def link, do: @link

  @doc """
  The settings of `definition/1`: `username` and `password` with no default, `apikey` with the
  public default `public-key`, a checkbox, a select and an `info` setting naming a wiki URL.
  """
  def settings do
    [
      %{"name" => "username", "type" => "text", "label" => "Username"},
      %{"name" => "password", "type" => "password", "label" => "Password"},
      %{"name" => "apikey", "type" => "text", "label" => "API key", "default" => "public-key"},
      %{
        "name" => "freeleech",
        "type" => "checkbox",
        "label" => "Freeleech",
        "default" => "false"
      },
      %{
        "name" => "sort",
        "type" => "select",
        "label" => "Sort",
        "default" => "date",
        "options" => %{"date" => "Date", "size" => "Size"}
      },
      %{
        "name" => "info",
        "type" => "info",
        "label" => "Help",
        "default" => ~s(<a href="https://wiki.invalid/help">help</a>)
      }
    ]
  end

  @doc """
  The bytes of a definition with id `id`: links `https://tracker.invalid/`, `settings/0`, and a
  search path under `{{ .Config.sitelink }}`. `extra` replaces root keys.
  """
  def definition(id \\ "tracker", extra \\ %{}) do
    %{
      "id" => id,
      "name" => "Cinder Test #{id}",
      "description" => "Written for Cinder's tests",
      "language" => "en-US",
      "type" => "private",
      "encoding" => "UTF-8",
      "links" => [@link],
      "settings" => settings(),
      "caps" => %{"modes" => %{"search" => ["q"]}},
      "search" => %{
        "paths" => [%{"path" => "{{ .Config.sitelink }}browse"}],
        "rows" => %{"selector" => "tr"},
        "fields" => %{"title" => %{"selector" => "a"}}
      }
    }
    |> Map.merge(extra)
    |> Jason.encode!()
  end

  @doc "Bytes the loader refuses, unique per `tag`."
  def failing(tag), do: "id: [#{tag}"

  @doc "The git blob hash of `bytes`."
  def blob_sha(bytes),
    do: :crypto.hash(:sha, "blob #{byte_size(bytes)}\0" <> bytes) |> Base.encode16(case: :lower)

  @doc "One file of an answer."
  def file(folder, name, bytes),
    do: %DefinitionFile{folder: folder, name: name, blob_sha: blob_sha(bytes), bytes: bytes}

  @doc "The load check the applies run, as the moduledoc says."
  def check(bytes) do
    case Loader.load(bytes) do
      {:ok, definition} ->
        unsupported = if String.ends_with?(definition.id, "-ns"), do: [:html_search], else: []
        {:ok, %{definition | unsupported: unsupported}}

      error ->
        error
    end
  end

  @doc """
  Applies an answer holding the 100 fillers and `files` (`{folder, name, bytes}`), at a new
  commit, and returns the apply's answer.
  """
  def apply_files(files, opts \\ []) do
    fillers = for i <- 1..100, do: file("v11", "filler-#{i}.yml", definition("filler-#{i}"))
    extra = for {folder, name, bytes} <- files, do: file(folder, name, bytes)

    commit =
      :crypto.hash(:sha, Integer.to_string(System.unique_integer()))
      |> Base.encode16(case: :lower)

    Definitions.apply_set(
      %Set{
        commit: commit,
        versions: %Versions{
          min: 11,
          max: 12,
          values: %{"MIN_VERSION" => "11", "MAX_VERSION" => "12"}
        },
        files: fillers ++ extra
      },
      Keyword.merge([check: &check/1], opts)
    )
  end

  @doc "Applies an answer whose `tracker.yml` in `v11` holds `bytes`."
  def mirror!(bytes, more \\ []) do
    assert {:ok, {:loaded, _}} = apply_files([{"v11", "tracker.yml", bytes} | more])
    :ok
  end

  @doc """
  Creates a Cardigann configured indexer pinned to the mirror's `tracker.yml`, with the plain
  `settings` and the secret input `secrets`.
  """
  def cardigann!(bytes, secrets \\ %{}, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          name: "Cardigann #{System.unique_integer([:positive])}",
          type: :cardigann,
          definition: "tracker.yml",
          definition_blob_sha: blob_sha(bytes),
          base_url: @link
        },
        overrides
      )

    {:ok, row} = Indexers.create(nil, attrs, secrets)
    row
  end

  @doc """
  Replaces the indexer's stored secrets with a ciphertext sealed for another id, which
  `Cinder.Indexers.Secrets.open/1` reads as unreadable.
  """
  def undecryptable!(%ConfiguredIndexer{id: id}) do
    {1, _} =
      Repo.update_all(
        from(c in ConfiguredIndexer, where: c.id == ^id),
        set: [secrets_ciphertext: Secrets.seal(id + 1_000_000, %{"password" => "hunter2"})]
      )

    :ok
  end

  @doc """
  What the indexer's pin holds: the running and held copies' blob hashes and the hold.
  """
  def pin(%ConfiguredIndexer{id: id}) do
    pin = Repo.get!(Pin, id)

    %{
      running: sha_of(pin.running_copy_id),
      held: sha_of(pin.held_copy_id),
      hold: pin.hold && :erlang.binary_to_term(pin.hold)
    }
  end

  defp sha_of(nil), do: nil
  defp sha_of(id), do: Repo.get!(Copy, id).blob_sha
end
