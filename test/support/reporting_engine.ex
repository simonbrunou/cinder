defmodule Cinder.Test.ReportingEngine do
  @moduledoc """
  Subtitle sync engine stub that exports `sync/5` — the arity a real engine exports — and reports
  the formats `Cinder.Subtitles.Sync` derived for the reference and the sidecar to the configured
  owner. Copies its input to its output, so the analysis lands as `aligned`.

  `Cinder.Subtitles.Sync.EngineMock` cannot cover this: Mox generates it from the behaviour, which
  declares `sync/3` only, so the format arguments never reach it. They matter — the engine reads a
  reference as subtitles (and can infer a framerate ratio from durations) only when it is told the
  reference is subtitles, since both files reach it as extension-less descriptor paths.
  """
  @behaviour Cinder.Subtitles.Sync.Engine

  @impl true
  def sync(reference, input, output), do: sync(reference, input, output, "", "")

  def sync(_reference, input, output, reference_extension, input_extension) do
    %{owner: owner} = Application.fetch_env!(:cinder, :subtitle_sync_engine_report)
    send(owner, {:engine_formats, reference_extension, input_extension})
    File.write!(output, File.read!(input))
    {:ok, %{score: 30.0, offset_ms: 0, rate: 1.0}}
  end
end
