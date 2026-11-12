# Tells the merging agent whether the CI run that a merge starts on `main` repeats the PR run
# (AGENTS.md "Merge authority"). Run it in the test env, after `git fetch origin`:
#
#     MIX_ENV=test mix run --no-start scripts/check-push-repeats-pr.exs <pushed SHA>
#
# The check is `Cinder.PushRepeatsPr` (test/support/push_repeats_pr.ex), whose moduledoc lists
# what it reads, what it allows and what it cannot see. Exit 0: the push run repeats the PR run.
# Exit 1: it printed a difference. Exit 2: it could not check. Wait on main's run unless exit 0.

if Code.ensure_loaded?(Cinder.PushRepeatsPr) do
  System.halt(Cinder.PushRepeatsPr.main(System.argv()))
else
  IO.puts(:stderr, "check-push-repeats-pr: Cinder.PushRepeatsPr is not compiled; run with MIX_ENV=test")
  System.halt(2)
end
