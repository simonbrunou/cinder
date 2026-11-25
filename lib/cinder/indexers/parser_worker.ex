defmodule Cinder.Indexers.ParserWorker do
  @moduledoc ~S"""
  Runs CSS selectors on one HTML document with `lazy_html` in a separate OS process (#1665, part
  of #1610; threat model "CSS selectors and `lazy_html`" on #1615). lexbor, the C library under
  `lazy_html`, ends its VM with a segmentation fault on some selectors, so the VM that runs Cinder
  never calls `LazyHTML`: this module is the only one under `lib/` that names it
  (`test/code_health/lazy_html_caller_test.exs`), and only its `child/0` calls it, in the worker.

  One worker per HTML document: `run/3` sends the page and an extraction plan, reads the field
  values, and the worker exits. `check_selectors/2` runs a definition copy's selectors on a small
  fixed document in one throwaway worker. A worker is never reused, so it is never shared between
  indexers.

  ## The worker

  It starts from the running system's own ERTS, `erl_path/0`:
  `<:code.root_dir()>/erts-<:erlang.system_info(:version)>/bin/erl`, which a Mix release and an
  OTP install both hold, never from `mix` or `elixir`. Its boot file is the OTP install's
  `bin/no_dot_erlang` when the root holds one, and otherwise the release's `start_clean`, beside
  the boot file the running release started from, which loads every application of the release
  and starts only `kernel` and `stdlib`. A VM with neither, such as one started with no `-boot`
  from a root without `bin/no_dot_erlang`, still names `bin/no_dot_erlang`; that worker stops
  during boot, and every call that starts a worker answers `:crash`. The worker then keeps on its
  code path only `kernel`, `stdlib`, `elixir`, `lazy_html` and `cinder`, starts no Cinder
  application and reads no config file: `-config` is never passed. It runs under `env -i` with
  only `PATH` and `ERL_CRASH_DUMP_BYTES=0` set, so no secret reaches its environment or
  arguments. Another process of the same OS user can still read the calling VM's environment from
  `/proc`, so the worker isolates crashes, not secrets (#1715).

  The page and the plan go in on its stdin as one Erlang external term behind a 4-byte length.
  The answer comes back on file descriptor 3, which the shell that starts `erl` points at the
  pipe the caller reads, while it points the worker's stdout at `/dev/null`. The VM prints to its
  stdout on its own: in the release image, every start prints an `=ESOCK WARNING MSG` about a
  missing `libsctp.so.1` there, ahead of any answer. The answer uses the same framing as the
  input, but a flat binary format of this module's own: an external term decoded with `[:safe]`
  can still grow far past its byte size (a list of small integers takes 16 bytes per input byte).
  `run/3` and `check_selectors/2` read that format in linear time and refuse anything else as
  `:crash`.

  ## Bounds

  - the caller's deadline (`run/3`'s `:deadline_ms`, `check_deadline_ms/0` for a check), at which
    `Cinder.BoundedCommand` kills the worker's process group: `:timeout`;
  - `max_output_bytes/0` bytes of answer: `:output_too_large`;
  - `max_memory_bytes/0` of resident memory, read every `memory_poll_ms/0` from
    `/proc/<os pid>/status` (`VmRSS`, in kB, so no page size is assumed; the issue names `statm`,
    which counts the same pages): `:memory`. A spike between two reads goes unseen, so the worker
    also runs under `ulimit -v` of `address_space_kib/0`: the BEAM needs about 2 GiB of address
    space to start (#1665's runs), which rules out a tighter limit;
  - `ulimit -t` of the deadline in whole seconds plus 2, so a worker whose caller died spins
    for at most that much CPU time. The worker also halts on its own one second after the
    deadline once it has read its input;
  - `ulimit -c 0`, so a crash leaves no core file.

  A worker that exits on a signal or non-zero, closes its stdin before reading it all, or answers
  something this module cannot read is `:crash`; the calling VM goes on.

  ## The plan

  `%{rows: selector, fields: [field]}`, each field `%{name:, selector:, attribute:, remove:,
  case:}`: `selector` nil reads the row itself, and otherwise matches the row itself first, then
  its first descendant, as Prowlarr's `dom.Matches(sel) ? dom : QuerySelector(dom, sel)` does;
  `attribute` nil reads the text, with every descendant that a `remove` selector matches taken out
  first; a non-empty `case` reports the first of its selectors that matches the element or a
  descendant, as `{:case, selector}`, or nil. Every selector first goes through
  `Cinder.Indexers.Selector.compile/2`, whose `:contains()` rewrite the worker applies: it gives
  the marker attribute to every element whose text holds the needle. `run/3` runs each selector
  whole: the parts `compile/2` splits off are for the load check, so a `:has()` lexbor cannot
  parse ends the worker, as `td:has(b[border=1])` does.

  Tests point `config :cinder, :parser_worker_erl` at a stub in place of `erl_path/0`.
  """

  alias Cinder.BoundedCommand
  alias Cinder.Indexers.Selector

  @max_output_bytes 4_194_304
  @max_memory_bytes 536_870_912
  @memory_poll_ms 50
  @address_space_kib 4_194_304
  @check_deadline_ms 30_000
  @max_check_workers 2
  @slot_retry_ms 50

  # The document every check worker runs its selectors on.
  @check_document "<html><head><title>x</title></head><body><form><input name=\"x\"></form>" <>
                    "<table><tr><td><a href=\"x\"><b>x</b></a></td></tr></table></body></html>"

  # `ulimit -c 0`: a worker lexbor crashes writes no core file, which a page that crashes it on
  # every search would otherwise repeat at up to the address-space limit each time. The answer
  # goes out on descriptor 3 and the VM's own stdout to /dev/null (moduledoc).
  @limits ~S|ulimit -c 0 && ulimit -v "$1" && ulimit -t "$2" && shift 2 && | <>
            ~S|exec 3>&1 1>/dev/null && exec "$@"|

  @type field :: %{
          name: String.t(),
          selector: String.t() | nil,
          attribute: String.t() | nil,
          remove: [String.t()],
          case: [String.t()]
        }
  @type plan :: %{rows: String.t(), fields: [field()]}
  @type value :: String.t() | {:case, String.t()} | nil
  @type failure :: :crash | :timeout | :memory | :output_too_large
  @type where :: :rows | {:field, non_neg_integer()}

  @doc "The answer cap in bytes: past it the worker is killed and the answer is `:output_too_large`."
  @spec max_output_bytes() :: pos_integer()
  def max_output_bytes, do: @max_output_bytes

  @doc "The resident memory cap in bytes: past it the worker is killed and the answer is `:memory`."
  @spec max_memory_bytes() :: pos_integer()
  def max_memory_bytes, do: @max_memory_bytes

  @doc "How often the worker's resident memory is read, in milliseconds."
  @spec memory_poll_ms() :: pos_integer()
  def memory_poll_ms, do: @memory_poll_ms

  @doc "The worker's `ulimit -v`, in KiB."
  @spec address_space_kib() :: pos_integer()
  def address_space_kib, do: @address_space_kib

  @doc "The deadline of a `check_selectors/2` worker, in milliseconds."
  @spec check_deadline_ms() :: pos_integer()
  def check_deadline_ms, do: @check_deadline_ms

  @doc "How many `check_selectors/2` workers run at once on this node; the others wait."
  @spec max_check_workers() :: pos_integer()
  def max_check_workers, do: @max_check_workers

  @doc "The `erl` the worker starts from: the running system's own ERTS."
  @spec erl_path() :: String.t()
  def erl_path do
    Path.join([
      List.to_string(:code.root_dir()),
      "erts-#{:erlang.system_info(:version)}",
      "bin",
      "erl"
    ])
  end

  @doc """
  Runs `plan` on `html` in a new worker and answers one list of `{name, value}` per row, in plan
  order. `opts` takes `:deadline_ms` (required), and `:max_memory_bytes` and
  `:max_output_bytes` in place of the defaults. A selector the gate refuses answers
  `{:error, {:refused, where}}` before any worker starts. One the gate passes and lexbor refuses
  answers the same once the worker queries it. The worker skips each selector a row never
  reaches: every field selector when no row matches, a field's `case` keys and `remove` selectors
  when its selector found nothing, the `case` keys after one that matched, and `remove` selectors
  on a field with a `case` key or an attribute. A selector that crashes lexbor answers `:crash`.
  """
  @spec run(binary(), plan(), keyword()) ::
          {:ok, [[{String.t(), value()}]]} | {:error, failure() | {:refused, where()}}
  def run(html, %{rows: rows, fields: fields} = plan, opts) when is_binary(html) do
    deadline_ms = Keyword.fetch!(opts, :deadline_ms)
    token = new_token()

    # Each compiled selector's marker tag names its place: "r" the rows, "f<i>" field i's
    # selector, "x<i>-<j>" its j-th `remove` selector, "k<i>-<j>" its j-th `case` key.
    with {:ok, rows_compiled} <- compile_at(rows, token, "r", :rows),
         {:ok, compiled_fields} <- compile_fields(fields, token) do
      marks = marks([rows_compiled | Enum.flat_map(compiled_fields, &elem(&1, 1))])

      input =
        {:run, html, rows_compiled.selector,
         Enum.map(compiled_fields, fn {field, _compiled} -> field end), marks,
         if(Enum.any?(fields, &(&1.remove != [])), do: "cinder-#{token}-n"), deadline_ms}

      with {:ok, answer} <- start(input, deadline_ms, opts) do
        read_rows(answer, plan)
      end
    end
  end

  @doc """
  Runs each of `selectors` through the gate, then those that pass in one new worker on a small
  fixed document: each part `Selector.compile/2` splits off alone, then the whole. Answers each
  selector with `:ok`, the gate's refusal, or `:refused` when lexbor refused a part or the whole;
  or the worker's failure, which then stands for every selector it ran. At most
  `max_check_workers/0` such workers run at once on this node: a call waits for a slot, and each
  slot frees within its holder's deadline. `opts` takes `:deadline_ms`, `:max_memory_bytes` and
  `:max_output_bytes` in place of the defaults.
  """
  @spec check_selectors([String.t()], keyword()) ::
          {:ok, [{String.t(), :ok | :refused | Selector.refusal()}]} | {:error, failure()}
  def check_selectors(selectors, opts \\ []) when is_list(selectors) do
    token = new_token()

    gated =
      selectors
      |> Enum.with_index()
      |> Enum.map(fn {selector, i} -> {selector, Selector.compile(selector, "#{token}-#{i}")} end)

    case for({_selector, {:ok, compiled}} <- gated, do: compiled) do
      [] -> {:ok, Enum.map(gated, fn {selector, {:error, reason}} -> {selector, reason} end)}
      to_run -> check_in_worker(gated, to_run, opts)
    end
  end

  defp check_in_worker(gated, to_run, opts) do
    deadline_ms = Keyword.get(opts, :deadline_ms, @check_deadline_ms)
    items = Enum.map(to_run, &(&1.parts ++ [&1.whole]))
    input = {:check, @check_document, items, marks(to_run), deadline_ms}

    with {:ok, answer} <- with_check_slot(fn -> start(input, deadline_ms, opts) end),
         {:ok, verdicts} <- read_check(answer, length(items)) do
      {results, []} =
        Enum.map_reduce(gated, verdicts, fn
          {selector, {:ok, _compiled}}, [verdict | rest] -> {{selector, verdict}, rest}
          {selector, {:error, reason}}, rest -> {{selector, reason}, rest}
        end)

      {:ok, results}
    end
  end

  ## Compiling the plan

  defp compile_at(nil, _token, _tag, _where), do: {:ok, %{selector: nil, needles: []}}

  defp compile_at(selector, token, tag, where) do
    prefix = "#{token}-#{tag}"

    case Selector.compile(selector, prefix) do
      {:ok, compiled} -> {:ok, %{selector: compiled.whole, needles: needles(prefix, compiled)}}
      {:error, _reason} -> {:error, {:refused, where}}
    end
  end

  defp compile_fields(fields, token) do
    fields
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {field, i}, {:ok, acc} ->
      case compile_field(field, i, token) do
        {:ok, compiled} -> {:cont, {:ok, [compiled | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, compiled} -> {:ok, Enum.reverse(compiled)}
      error -> error
    end
  end

  defp compile_field(field, i, token) do
    where = {:field, i}

    with {:ok, selector} <- compile_at(field.selector, token, "f#{i}", where),
         {:ok, removes} <- compile_list(field.remove, token, "x#{i}", where),
         {:ok, cases} <- compile_list(field.case, token, "k#{i}", where) do
      worker_field = {
        selector.selector,
        field.attribute,
        Enum.map(removes, & &1.selector),
        Enum.map(cases, & &1.selector)
      }

      {:ok, {worker_field, [selector | removes ++ cases]}}
    end
  end

  defp compile_list(selectors, token, tag, where) do
    selectors
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {selector, j}, {:ok, acc} ->
      case compile_at(selector, token, "#{tag}-#{j}", where) do
        {:ok, compiled} -> {:cont, {:ok, [compiled | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, compiled} -> {:ok, Enum.reverse(compiled)}
      error -> error
    end
  end

  defp needles(prefix, compiled) do
    compiled.needles
    |> Enum.with_index()
    |> Enum.map(fn {needle, n} -> {Selector.marker(prefix, n), needle} end)
  end

  defp marks(compiled), do: Enum.flat_map(compiled, & &1.needles)

  # 128 random bits in lowercase hex: a page cannot guess the marker attribute names.
  defp new_token, do: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

  ## Starting the worker

  defp start(input, deadline_ms, opts) do
    payload = :erlang.term_to_binary(input)
    max_memory = Keyword.get(opts, :max_memory_bytes, @max_memory_bytes)
    max_output = Keyword.get(opts, :max_output_bytes, @max_output_bytes)

    result =
      BoundedCommand.run("env", command_args(deadline_ms), deadline_ms,
        input: <<byte_size(payload)::32, payload::binary>>,
        max_output_bytes: max_output,
        check: {@memory_poll_ms, &memory_check(&1, max_memory)}
      )

    case result do
      {:ok, output, 0} -> unframe(output)
      {:ok, _output, _status} -> {:error, :crash}
      {:error, {:timeout, _output}} -> {:error, :timeout}
      {:error, {:halted, :memory}} -> {:error, :memory}
      {:error, :output_too_large} -> {:error, :output_too_large}
      {:error, _other} -> {:error, :crash}
    end
  end

  @doc false
  # The full argument list `run/3` hands `env`; public for its test.
  @spec command_args(pos_integer()) :: [String.t()]
  def command_args(deadline_ms) do
    erl = Application.get_env(:cinder, :parser_worker_erl) || erl_path()
    cpu_seconds = div(deadline_ms + 999, 1000) + 2

    ["-i", "PATH=" <> System.get_env("PATH", "/usr/bin:/bin"), "ERL_CRASH_DUMP_BYTES=0"] ++
      ["/bin/sh", "-c", @limits, "sh", Integer.to_string(@address_space_kib)] ++
      [Integer.to_string(cpu_seconds), erl] ++
      ["-noshell", "-noinput", "+S", "1:1", "+fnu"] ++
      boot_args() ++
      Enum.flat_map([:elixir, :lazy_html, :cinder], &["-pa", ebin(&1)]) ++
      ["-run", Atom.to_string(__MODULE__), "child"]
  end

  defp ebin(app), do: Path.join(List.to_string(:code.lib_dir(app)), "ebin")

  defp boot_args do
    root = List.to_string(:code.root_dir())
    otp_boot = Path.join([root, "bin", "no_dot_erlang"])

    cond do
      File.regular?(otp_boot <> ".boot", [:raw]) ->
        ["-boot", otp_boot]

      match?({:ok, [[_boot]]}, :init.get_argument(:boot)) ->
        {:ok, [[boot]]} = :init.get_argument(:boot)
        start_clean = Path.join(Path.dirname(List.to_string(boot)), "start_clean")
        ["-boot", start_clean, "-boot_var", "RELEASE_LIB", Path.join(root, "lib")]

      true ->
        ["-boot", otp_boot]
    end
  end

  # A status file that is gone or holds no VmRSS line belongs to a worker that is exiting, which
  # the port reports on its own.
  defp memory_check(os_pid, max_bytes) do
    with {:ok, status} <- :file.read_file(~c"/proc/#{os_pid}/status", [:raw]),
         [_line, kb] <- Regex.run(~r/^VmRSS:\s+(\d+) kB$/m, status),
         true <- String.to_integer(kb) * 1024 > max_bytes do
      {:halt, :memory}
    else
      _under_cap_or_unread -> :ok
    end
  end

  # Each slot is a `:global` lock on this node, held by the calling process and freed when the
  # call returns or the process ends. A call that finds every slot taken retries.
  defp with_check_slot(fun) do
    slot = take_slot()

    try do
      fun.()
    after
      :global.del_lock({{__MODULE__, :check_slot, slot}, self()}, [node()])
    end
  end

  defp take_slot do
    found =
      Enum.find(1..@max_check_workers, fn slot ->
        :global.set_lock({{__MODULE__, :check_slot, slot}, self()}, [node()], 0)
      end)

    if found do
      found
    else
      Process.sleep(@slot_retry_ms)
      take_slot()
    end
  end

  ## Reading the answer

  defp unframe(<<size::32, answer::binary-size(size)>>), do: {:ok, answer}
  defp unframe(_output), do: {:error, :crash}

  defp read_rows(<<?X, 0::32>>, _plan), do: {:error, {:refused, :rows}}

  defp read_rows(<<?X, index::32>>, %{fields: fields}) when index <= length(fields),
    do: {:error, {:refused, {:field, index - 1}}}

  # A row of a plan with no fields takes no bytes, so the count alone is bounded here.
  defp read_rows(<<?R, count::32, width::32, values::binary>>, %{fields: fields})
       when width == length(fields) and (width > 0 or count <= @max_output_bytes) do
    names = Enum.map(fields, & &1.name)

    with {:ok, flat} <- read_values(values, count * width, []),
         {:ok, flat} <- resolve_cases(flat, fields) do
      rows =
        if width == 0,
          do: List.duplicate([], count),
          else: flat |> Enum.chunk_every(width) |> Enum.map(&Enum.zip(names, &1))

      {:ok, rows}
    else
      :error -> {:error, :crash}
    end
  end

  defp read_rows(_answer, _plan), do: {:error, :crash}

  defp read_values(<<>>, 0, acc), do: {:ok, Enum.reverse(acc)}
  defp read_values(_rest, 0, _acc), do: :error
  defp read_values(<<0, rest::binary>>, n, acc), do: read_values(rest, n - 1, [nil | acc])

  defp read_values(<<1, size::32, text::binary-size(size), rest::binary>>, n, acc),
    do: read_values(rest, n - 1, [text | acc])

  defp read_values(<<2, index::32, rest::binary>>, n, acc),
    do: read_values(rest, n - 1, [{:case, index} | acc])

  defp read_values(_rest, _n, _acc), do: :error

  # The values run row by row, each row in plan order. A case index names one of its own
  # field's case selectors, or the answer is not the worker's.
  defp resolve_cases([], _fields), do: {:ok, []}

  defp resolve_cases(flat, fields) do
    flat
    |> Enum.zip(Stream.cycle(fields))
    |> Enum.reduce_while({:ok, []}, fn
      {{:case, index}, %{case: cases}}, {:ok, acc} when index < length(cases) ->
        {:cont, {:ok, [{:case, Enum.at(cases, index)} | acc]}}

      {{:case, _index}, _field}, _acc ->
        {:halt, :error}

      {value, _field}, {:ok, acc} ->
        {:cont, {:ok, [value | acc]}}
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end
  end

  defp read_check(<<?C, count::32, verdicts::binary-size(count)>>, count) do
    verdicts
    |> :binary.bin_to_list()
    |> Enum.reduce_while([], fn
      0, acc -> {:cont, [:ok | acc]}
      1, acc -> {:cont, [:refused | acc]}
      _byte, _acc -> {:halt, :error}
    end)
    |> case do
      :error -> {:error, :crash}
      list -> {:ok, Enum.reverse(list)}
    end
  end

  defp read_check(_answer, _count), do: {:error, :crash}

  ## The worker side: runs in the worker VM only, from `-run`.

  @doc false
  def child do
    keep_code_paths()
    port = :erlang.open_port({:fd, 0, 3}, [:binary, {:packet, 4}, :eof])

    receive do
      {^port, {:data, payload}} ->
        input = :erlang.binary_to_term(payload)
        halt_after(elem(input, tuple_size(input) - 1) + 1000)
        answer = answer(input)
        :erlang.port_command(port, answer)
        :erlang.port_close(port)
        :erlang.halt(0)

      {^port, :eof} ->
        :erlang.halt(1)
    end
  catch
    _kind, _reason -> :erlang.halt(2)
  end

  defp keep_code_paths do
    [:kernel, :stdlib, :elixir, :lazy_html, :cinder]
    |> Enum.map(&:filename.join(:code.lib_dir(&1), ~c"ebin"))
    |> :code.set_path()
  end

  defp halt_after(ms) do
    spawn(fn ->
      Process.sleep(ms)
      :erlang.halt(3)
    end)
  end

  defp answer({:run, html, rows, fields, marks, number_attribute, _deadline_ms}) do
    document = html |> LazyHTML.from_document() |> mark(marks, number_attribute)

    rows =
      document
      |> query(rows, 0)
      |> Enum.map(fn row ->
        fields
        |> Enum.with_index(1)
        |> Enum.map(fn {field, where} -> field_value(row, field, number_attribute, where) end)
      end)

    width = length(fields)
    values = for row <- rows, value <- row, do: encode_value(value)
    IO.iodata_to_binary([?R, <<length(rows)::32, width::32>>, values])
  catch
    :throw, {__MODULE__, :refused, where} -> <<?X, where::32>>
  end

  defp answer({:check, html, items, marks, _deadline_ms}) do
    document = html |> LazyHTML.from_document() |> mark(marks, nil)

    verdicts =
      for selectors <- items do
        if Enum.all?(selectors, &runs?(document, &1)), do: 0, else: 1
      end

    <<?C, length(items)::32, :binary.list_to_bin(verdicts)::binary>>
  end

  defp runs?(document, selector) do
    _ = LazyHTML.query(document, selector)
    true
  rescue
    ArgumentError -> false
  end

  defp query(lazy, selector, where) do
    LazyHTML.query(lazy, selector)
  rescue
    ArgumentError -> throw({__MODULE__, :refused, where})
  end

  defp field_value(row, {selector, attribute, removes, cases}, number_attribute, where) do
    case field_element(row, selector, where) do
      nil -> nil
      element when cases != [] -> case_value(element, cases, where)
      element when attribute != nil -> element |> LazyHTML.attribute(attribute) |> List.first()
      element when removes != [] -> text_without(element, removes, number_attribute, where)
      element -> LazyHTML.text(element)
    end
  end

  defp field_element(row, nil, _where), do: row

  # `LazyHTML.query/2` matches the element itself too, ahead of its descendants in document order,
  # so its first match is Prowlarr's `dom.Matches(sel) ? dom : QuerySelector(dom, sel)`.
  defp field_element(row, selector, where),
    do: row |> query(selector, where) |> Enum.take(1) |> List.first()

  defp case_value(element, cases, where) do
    cases
    |> Enum.find_index(&(not Enum.empty?(query(element, &1, where))))
    |> case do
      nil -> nil
      index -> {:case, index}
    end
  end

  # `LazyHTML.query/2` also matches the element itself, which `remove` leaves in place: Prowlarr removes
  # what `QuerySelectorAll` on the element finds, its descendants.
  defp text_without(element, removes, number_attribute, where) do
    [own] = LazyHTML.attribute(element, number_attribute)

    removed =
      removes
      |> Enum.flat_map(&LazyHTML.attribute(query(element, &1, where), number_attribute))
      |> MapSet.new()
      |> MapSet.delete(own)

    element |> LazyHTML.to_tree() |> tree_text(number_attribute, removed) |> IO.iodata_to_binary()
  end

  defp tree_text(nodes, number_attribute, removed) when is_list(nodes),
    do: Enum.map(nodes, &tree_text(&1, number_attribute, removed))

  defp tree_text(text, _number_attribute, _removed) when is_binary(text), do: text

  defp tree_text({tag, attributes, children}, number_attribute, removed) when is_binary(tag) do
    case List.keyfind(attributes, number_attribute, 0) do
      {_name, number} ->
        if MapSet.member?(removed, number),
          do: [],
          else: tree_text(children, number_attribute, removed)

      nil ->
        tree_text(children, number_attribute, removed)
    end
  end

  defp tree_text(_comment, _number_attribute, _removed), do: []

  defp encode_value(nil), do: <<0>>
  defp encode_value(text) when is_binary(text), do: <<1, byte_size(text)::32, text::binary>>
  defp encode_value({:case, index}), do: <<2, index::32>>

  # Gives each element the marker attribute of every needle its text holds, and, when the plan
  # removes anything, its number under `number_attribute`. A document with neither stays as parsed.
  defp mark(document, [], nil), do: document

  defp mark(document, marks, number_attribute) do
    {tree, _text, _next} = mark_nodes(LazyHTML.to_tree(document), marks, number_attribute, 0)
    LazyHTML.from_tree(tree)
  end

  defp mark_nodes(nodes, marks, number_attribute, next) do
    {marked, {texts, next}} =
      Enum.map_reduce(nodes, {[], next}, fn node, {texts, next} ->
        {node, text, next} = mark_node(node, marks, number_attribute, next)
        {node, {[texts | text], next}}
      end)

    {marked, texts, next}
  end

  defp mark_node(text, _marks, _number_attribute, next) when is_binary(text),
    do: {text, text, next}

  defp mark_node({tag, attributes, children}, marks, number_attribute, next)
       when is_binary(tag) do
    own = next
    {children, texts, next} = mark_nodes(children, marks, number_attribute, next + 1)
    text = IO.iodata_to_binary(texts)
    added = for {name, needle} <- marks, String.contains?(text, needle), do: {name, ""}
    numbered = if number_attribute, do: [{number_attribute, Integer.to_string(own)}], else: []
    {{tag, attributes ++ added ++ numbered, children}, text, next}
  end

  defp mark_node(other, _marks, _number_attribute, next), do: {other, [], next}
end
