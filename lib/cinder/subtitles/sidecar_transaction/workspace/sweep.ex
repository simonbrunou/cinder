defmodule Cinder.Subtitles.SidecarTransaction.Workspace.Sweep do
  @moduledoc false
  # One sweep's progress: the workspaces it removed, the removals it may still try, and its
  # candidates, `{:unindexed, paths}` until the first workspace holding bytes indexes them by
  # size (`%{size => [path]}`).
  @enforce_keys [:budget, :candidates]
  defstruct [:budget, :candidates, removed: 0]
end
