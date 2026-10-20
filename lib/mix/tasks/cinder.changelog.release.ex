defmodule Mix.Tasks.Cinder.Changelog.Release do
  @shortdoc "Fold changelog.d/ into a dated CHANGELOG.md section for the mix.exs version"
  @moduledoc """
  Folds every fragment in `changelog.d/`, and the entries still under `## [Unreleased]`, into a
  `## [<version>] - <date>` section of `CHANGELOG.md`, then deletes the fragments. The version is
  the one in `mix.exs`, so bump it first.

      mix cinder.changelog.release [--date YYYY-MM-DD]

  `--date` defaults to today (UTC). Nothing is written when a fragment is malformed. A fragment
  that cannot be deleted stops the task with a `File.Error` after `CHANGELOG.md` is written:
  delete it and the fragments still in `changelog.d/` by hand.
  """
  use Mix.Task

  alias Cinder.Changelog

  @impl true
  def run(args), do: run(args, File.cwd!())

  @doc "Runs the task on the checkout at `root`."
  def run(args, root) do
    {opts, rest} = OptionParser.parse!(args, strict: [date: :string])

    if rest != [] do
      Mix.raise("mix cinder.changelog.release takes no arguments; bump `version:` in mix.exs")
    end

    version = Mix.Project.config()[:version]

    case Changelog.release(root, version, date(opts[:date])) do
      {:ok, fragments} ->
        Mix.shell().info(
          "CHANGELOG.md: added [#{version}] from #{length(fragments)} fragment(s). Read the " <>
            "new section, then commit it with the deleted fragments."
        )

      {:error, problems} ->
        Mix.raise("No release written:\n  " <> Enum.join(problems, "\n  "))
    end
  end

  defp date(nil), do: Date.utc_today()

  defp date(text) do
    case Date.from_iso8601(text) do
      {:ok, date} -> date
      {:error, _} -> Mix.raise("--date must be YYYY-MM-DD, got #{inspect(text)}")
    end
  end
end
