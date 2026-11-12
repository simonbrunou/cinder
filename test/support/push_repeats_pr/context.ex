defmodule Cinder.PushRepeatsPr.Context do
  @moduledoc false
  # Where the walk stands in one YAML file: its path, whether a workflow's allowances apply
  # there, and the job and the step it is inside.
  defstruct [:path, :workflow?, :job, :step]
end
