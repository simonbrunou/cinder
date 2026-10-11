defmodule Cinder.Download.EndpointVetter do
  @moduledoc """
  Vets the hosts embedded in a torrent/magnet (trackers, web seeds) before a download client
  is handed the file, under a hard bound on DNS work.

  A `.torrent` can carry hundreds of thousands of distinct hostnames and a slow nameserver
  stalls every lookup, so the work done on Cinder's behalf is capped three ways: hosts are
  deduplicated, only the first `max_hosts/0` unique ones are looked at (the rest are treated
  as forbidden), and all lookups run concurrently under ONE overall deadline — a host that
  has not resolved by then is dropped like any other forbidden host.
  """

  alias Cinder.HTTPPolicy

  @max_hosts 50
  @deadline_ms 8_000

  @doc "Maximum number of unique hosts vetted per torrent/magnet."
  @spec max_hosts() :: pos_integer()
  def max_hosts, do: @max_hosts

  @doc """
  Returns the `MapSet` of hosts out of the first `max_hosts/0` unique `hosts` that
  `HTTPPolicy.validate_untrusted_host/2` approves within `deadline` milliseconds.
  `resolver` is the injectable DNS resolver (`nil` = the real one).
  """
  @spec allowed_hosts([String.t()], HTTPPolicy.resolver() | nil, non_neg_integer()) ::
          MapSet.t(String.t())
  def allowed_hosts(hosts, resolver, deadline \\ @deadline_ms) do
    hosts
    |> Enum.uniq()
    |> Enum.take(@max_hosts)
    |> Enum.map(fn host -> {host, Task.async(fn -> validate(host, resolver) end)} end)
    |> collect(deadline)
  end

  defp validate(host, nil), do: HTTPPolicy.validate_untrusted_host(host)
  defp validate(host, resolver), do: HTTPPolicy.validate_untrusted_host(host, resolver)

  defp collect(entries, deadline) do
    {hosts, tasks} = Enum.unzip(entries)

    hosts
    |> Enum.zip(Task.yield_many(tasks, deadline))
    |> Enum.flat_map(fn
      {host, {_task, {:ok, :ok}}} ->
        [host]

      {_host, {task, nil}} ->
        Task.shutdown(task, :brutal_kill)
        []

      _other ->
        []
    end)
    |> MapSet.new()
  end
end
