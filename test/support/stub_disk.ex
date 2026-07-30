defmodule Cinder.Test.StubDisk do
  @moduledoc """
  Permissive `Cinder.Disk.Prober` for the suite: reports abundant free space by default, so the
  free-disk guards never fire and no test probes a real disk. A disk-guard test drives specific
  outcomes by setting `:disk_stats_stub` (async: false, restore in on_exit):

    * a `{:ok, stats}` / `{:error, reason}` tuple returned for every path, or
    * a 1-arity function `path -> result` for per-path control.
  """

  @behaviour Cinder.Disk.Prober

  # 1 TB free / 2 TB total — well above any guard threshold.
  @abundant {:ok, %{free_bytes: 1_099_511_627_776, total_bytes: 2_199_023_255_552}}

  @impl Cinder.Disk.Prober
  def stats(path) do
    case Application.get_env(:cinder, :disk_stats_stub) do
      fun when is_function(fun, 1) -> fun.(path)
      {:ok, _stats} = ok -> ok
      {:error, _reason} = error -> error
      _unset -> @abundant
    end
  end
end
