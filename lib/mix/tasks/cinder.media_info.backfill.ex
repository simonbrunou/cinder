defmodule Mix.Tasks.Cinder.MediaInfo.Backfill do
  @shortdoc "Backfill audio/subtitle language info onto already-imported media"
  @moduledoc @shortdoc
  use Mix.Task

  alias Cinder.Library.Backfill

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")
    Backfill.run()
    Mix.shell().info("Media-info backfill complete.")
  end
end
