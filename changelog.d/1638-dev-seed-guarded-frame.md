### Internal
- **The dev seed runs again (#1638).** `priv/repo/seeds.exs`, which `mix ecto.setup`, `mix setup`
  and `mix ecto.reset` run, now makes its writes in one `Cinder.GuardedWrite.transaction/2`
  instead of a raw `Repo.transaction/1`. Before, the `Cinder.GuardedWrite.transaction/2` frame
  that `Catalog.create_grab/5` opens raised `ArgumentError` inside the raw one, the seed rolled
  back, and `mix ecto.setup` exited 1 and left a new dev database with no admin. The seed writes
  only in the dev env, so production is unchanged.
