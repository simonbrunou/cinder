defmodule Cinder.CodeHealth.NativeClockReadsTest do
  # #1932: a Native grab counted a 429's limit end from `DateTime.utc_now/0` in
  # `Cinder.Download.Client.DownloadCheck`, while `IndexerStatus.record/3` capped and stored it at
  # `Native.now/0`, the clock `config :cinder, Native, clock:` replaces. Tests pin that clock, so
  # the two agreed only until the wall clock moved a day past the pin: then every tree failed three
  # `CardigannGrabTest` tests, `main` included, and every thread's CI with them.
  #
  # A module on Native's clock path calls `Native.now/0` or one of `@clock_takers`, the public
  # functions of `@clock_modules` that take a `now`, matched by name at any arity: a call to
  # `IndexerState.list/0`, which reads `Native.now/0` itself, puts its caller on the path too.
  # Such a module reads the wall clock only as the default of Native's clock:
  # `Keyword.get(_, :clock, &DateTime.utc_now/0)` or `Keyword.get_lazy(_, :now,
  # &DateTime.utc_now/0)`, the two forms `lib/` uses today. Anything else, another key or
  # another `Keyword` function included, fails: read `Native.now/0` once and pass it on.
  #
  # The check reads each module's function bodies from the debug info in its `.beam`, as Erlang
  # abstract code, where the compiler has expanded every alias, import and pipe (the
  # `.beam` route of docs/agents/testing.md, as `series_identity_sync_calls_test.exs`). It
  # matches a module and a function name side by side in one tuple or list, which is how a remote
  # call, a capture and `apply/3` hold them. A fixture below shows each form it catches. A `.beam`
  # without debug info fails. Forms the check does not see include: a module or function name
  # built at runtime (`Module.concat/1`, `String.to_atom/1`), a read in a doc, a comment or a
  # string, a read at compile time in the module body (`@at DateTime.utc_now()`), and a module
  # that reaches the clock path only through another module's function, such as a helper that
  # returns `DateTime.utc_now()` to a caller that passes it on. A fixture shows each. A module
  # off the path passes too when it compares a Native reading it got as data with the wall
  # clock, such as `Cinder.Download.Poller` and `TvPoller` with `{:indexers_backing_off,
  # retry_at}`, through the `hold_search/2` that `PollerSkeleton` compiles into them, or
  # passes the wall clock to a function value, such as the `request` of `Cardigann.copy/1`, or to
  # a `now` outside `@clock_modules`, such as `Cardigann.Template.render/3`'s. #1907's
  # `Indexers.sent_today/1` passed it to that `request`; `Cinder.Indexers` is on the path through
  # its call to `IndexerState.passes_gate?/0`.
  #
  # Not async: `compile/1` sets global compiler options (`compiler_options_test.exs`).
  use ExUnit.Case, async: false

  alias Cinder.Acquisition.Indexer.NewznabAnswer
  alias Cinder.Acquisition.IndexerSource.Native

  alias Cinder.Acquisition.IndexerSource.Native.{
    IndexerCaptchas,
    IndexerCookies,
    IndexerState,
    IndexerStatus
  }

  # `NewznabAnswer` and the four `Native.Indexer*` modules. Other modules take a Native reading
  # too, such as `CinderWeb.IndexerStateText.detail/2`, and a call to them puts no module on
  # the path.
  @clock_modules [NewznabAnswer, IndexerStatus, IndexerState, IndexerCaptchas, IndexerCookies]

  # Their public functions that take a `now`, which "@clock_takers is every public function ..."
  # derives from the parameter names.
  @clock_takers [
    {NewznabAnswer, :classify, 4},
    {NewznabAnswer, :classify_caps, 4},
    {NewznabAnswer, :limit_until, 2},
    {NewznabAnswer, :read, 2},
    {NewznabAnswer, :read_caps, 2},
    {IndexerStatus, :gate, 2},
    {IndexerStatus, :record, 3},
    {IndexerStatus, :record_test, 3},
    {IndexerStatus, :transition, 3},
    {IndexerState, :health, 2},
    {IndexerState, :list, 1},
    {IndexerState, :passes_gate?, 1},
    {IndexerCaptchas, :live?, 4},
    {IndexerCaptchas, :store, 3},
    {IndexerCaptchas, :take, 4},
    {IndexerCookies, :read, 2},
    {IndexerCookies, :store_login, 3}
  ]

  @wall_clock [
    {DateTime, :utc_now},
    {DateTime, :now},
    {DateTime, :now!},
    {NaiveDateTime, :utc_now},
    {NaiveDateTime, :local_now},
    {Date, :utc_today},
    {Time, :utc_now},
    {System, :os_time},
    {System, :system_time},
    {:os, :system_time},
    {:os, :timestamp},
    {:erlang, :system_time},
    {:erlang, :timestamp},
    {:erlang, :now},
    {:erlang, :localtime},
    {:erlang, :universaltime},
    {:erlang, :date},
    {:erlang, :time},
    {:calendar, :universal_time},
    {:calendar, :local_time}
  ]

  # `Keyword` function => the key whose default may be `&DateTime.utc_now/0`.
  @clock_defaults %{get: :clock, get_lazy: :now}

  test "a module on Native's clock path reads the wall clock only as its clock's default" do
    {:ok, modules} = :application.get_key(:cinder, :modules)

    problems =
      for module <- modules,
          {:module, ^module} = Code.ensure_loaded(module),
          problem <- wall_clock_reads(object_code(module)),
          do: problem

    assert problems == [],
           "these functions read the wall clock in a module on Native's clock path (#1932):\n  " <>
             Enum.join(problems, "\n  ") <>
             "\nRead Native.now/0 once and pass that reading on, or move the read to a " <>
             "module off the path."
  end

  test "@clock_takers is every public function of @clock_modules that takes a now" do
    derived =
      for module <- @clock_modules,
          {name, arity} <- now_takers(object_code(module)),
          do: {module, name, arity}

    assert Enum.sort(derived) == Enum.sort(@clock_takers),
           "set @clock_takers to these functions, each with a parameter named now:\n  " <>
             Enum.map_join(Enum.sort(derived), "\n  ", &inspect/1)
  end

  describe "the path check" do
    test "takes each clock taker, Native.now/0 included, as the path" do
      for {{module, name, arity}, index} <- Enum.with_index([{Native, :now, 0} | @clock_takers]) do
        args = Enum.map_join(1..arity//1, ", ", &"a#{&1}")

        binary =
          compile_one(
            :"taker_#{index}",
            "def f(#{args}), do: #{inspect(module)}.#{name}(#{args})\n" <>
              "def g, do: DateTime.utc_now()"
          )

        problems = wall_clock_reads(binary)

        assert match?([_], problems),
               "#{inspect(module)}.#{name} was not the path: #{inspect(problems)}"

        [problem] = problems
        assert problem =~ "g/0 reads DateTime.utc_now"
      end
    end

    test "takes a capture and apply/3 of a clock taker as the path" do
      forms = %{
        capture: "def f, do: &Cinder.Acquisition.IndexerSource.Native.now/0",
        apply: "def f, do: apply(Cinder.Acquisition.IndexerSource.Native, :now, [])",
        aliased:
          "alias Cinder.Acquisition.IndexerSource.Native.IndexerStatus, as: S\n" <>
            "def f(status, now), do: S.gate(status, now)"
      }

      for {form, body} <- forms do
        binary = compile_one(:"path_#{form}", body <> "\ndef g, do: DateTime.utc_now()")
        problems = wall_clock_reads(binary)
        assert match?([_], problems), "the #{form} form was not the path: #{inspect(problems)}"
      end
    end

    test "leaves a module off the path, one that calls another function of a clock module included" do
      for {tag, body} <- [
            off: "def f, do: :ok",
            other_function:
              "def f(class), do: Cinder.Acquisition.Indexer.NewznabAnswer.reason(class)",
            reading_as_data:
              "def f({:indexers_backing_off, at}), do: DateTime.compare(DateTime.utc_now(), at)",
            function_value: "def f(request), do: request.(%{}, DateTime.utc_now())",
            other_now_taker:
              "def f(t, v), do: Cinder.Acquisition.Indexer.Cardigann.Template.render(t, v, " <>
                "DateTime.utc_now())"
          ] do
        binary = compile_one(:"off_#{tag}", body <> "\ndef g, do: DateTime.utc_now()")
        assert wall_clock_reads(binary) == [], "the #{tag} module was on the path"
      end
    end
  end

  describe "the read check" do
    test "fails each wall-clock read on the path" do
      reads = %{
        utc_now: "DateTime.utc_now()",
        utc_now_unit: "DateTime.utc_now(:second)",
        now: ~S|DateTime.now("Etc/UTC")|,
        now_bang: ~S|DateTime.now!("Etc/UTC")|,
        naive_utc_now: "NaiveDateTime.utc_now()",
        naive_local_now: "NaiveDateTime.local_now()",
        utc_today: "Date.utc_today()",
        time_utc_now: "Time.utc_now()",
        os_time: "System.os_time(:second)",
        system_time: "System.system_time(:second)",
        os_system_time: ":os.system_time()",
        os_timestamp: ":os.timestamp()",
        erlang_system_time: ":erlang.system_time()",
        erlang_timestamp: ":erlang.timestamp()",
        erlang_now: "apply(:erlang, :now, [])",
        erlang_localtime: ":erlang.localtime()",
        erlang_universaltime: ":erlang.universaltime()",
        erlang_date: ":erlang.date()",
        erlang_time: ":erlang.time()",
        universal_time: ":calendar.universal_time()",
        local_time: ":calendar.local_time()"
      }

      for {tag, read} <- reads do
        binary = compile_one(:"read_#{tag}", on_path("def g, do: #{read}"))
        problems = wall_clock_reads(binary)
        assert match?([_], problems), "the #{tag} read gave #{inspect(problems)}"
      end
    end

    test "fails each form that holds the read" do
      forms = %{
        capture: "def g, do: &DateTime.utc_now/0",
        apply: "def g, do: apply(DateTime, :utc_now, [])",
        imported: "import DateTime, only: [utc_now: 0]\ndef g, do: utc_now()",
        split_across_lines: "def g do\n  DateTime\n  .utc_now()\nend",
        piped: "def g, do: :second |> DateTime.utc_now()",
        private: "def g, do: h()\ndefp h, do: DateTime.utc_now()",
        default_argument: "def g(at \\\\ DateTime.utc_now()), do: at",
        other_key: "def g(opts), do: Keyword.get(opts, :at, &DateTime.utc_now/0)",
        other_function: "def g(opts), do: Keyword.get_lazy(opts, :clock, &DateTime.utc_now/0)",
        other_default: "def g(opts), do: Keyword.get(opts, :clock, &DateTime.utc_now/1)",
        called_default: "def g(opts), do: Keyword.get(opts, :clock, DateTime.utc_now())",
        read_in_options:
          "def g, do: Keyword.get([at: DateTime.utc_now()], :clock, &DateTime.utc_now/0)"
      }

      for {tag, body} <- forms do
        binary = compile_one(:"form_#{tag}", on_path(body))
        assert wall_clock_reads(binary) != [], "the #{tag} form passed"
      end
    end

    test "fails #1932's read, a wall clock passed to NewznabAnswer.classify/4 from another function" do
      binary =
        compile_one(:issue_1932, """
        def check_classified(answer, opts) do
          sort(answer, Keyword.fetch!(opts, :error_tag), DateTime.utc_now())
        end

        defp sort(answer, _tag, now),
          do: Cinder.Acquisition.Indexer.NewznabAnswer.classify(answer.status, %{}, "", now)
        """)

      assert [problem] = wall_clock_reads(binary)
      assert problem =~ "check_classified/2 reads DateTime.utc_now"
    end

    test "passes the clock defaults lib/ uses, direct and piped" do
      binary =
        compile_one(
          :defaults,
          on_path("""
          def g(config), do: Keyword.get(config, :clock, &DateTime.utc_now/0).()

          def h, do: :cinder |> Application.get_env(:x, []) |> Keyword.get(:clock, &DateTime.utc_now/0)

          def i(opts), do: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
          """)
        )

      assert wall_clock_reads(binary) == []
    end

    test "does not see the forms its header lists as unseen" do
      compile_one(:helper, "def utc, do: DateTime.utc_now()")

      unseen = %{
        concat: "def g, do: apply(Module.concat([DateTime]), :utc_now, [])",
        to_atom: ~S|def g, do: apply(DateTime, String.to_atom("utc_now"), [])|,
        string: ~S|def g, do: "DateTime.utc_now()"|,
        comment: "# DateTime.utc_now()\ndef g, do: :ok",
        doc: "@doc \"Reads DateTime.utc_now/0.\"\ndef g, do: :ok",
        compile_time: "@at DateTime.utc_now()\ndef g, do: @at",
        helper: "def g, do: #{name(:helper)}.utc()"
      }

      for {form, body} <- unseen do
        binary = compile_one(:"unseen_#{form}", on_path(body))
        assert wall_clock_reads(binary) == [], "the #{form} form was seen"
      end
    end

    # `:beam_lib.strip/1` drops the debug info chunk, as in `series_identity_sync_calls_test.exs`.
    test "fails a .beam without debug info" do
      {:ok, {_, stripped}} = :no_debug_info |> compile_one(on_path("")) |> :beam_lib.strip()

      assert [problem] = wall_clock_reads(stripped)
      assert problem =~ "cannot read the debug info"
    end
  end

  describe "the now-taker list" do
    test "reads a parameter named now at any depth, with or without an underscore" do
      binary =
        compile_one(:takers, """
        def bare(now), do: now
        def ignored(_now), do: :ok
        def matched(%DateTime{} = now, x), do: {now, x}
        def defaulted(x, now \\\\ nil), do: {x, now}
        def other(at), do: at
        defp private(now), do: now
        def calls_private, do: private(nil)
        """)

      assert binary |> now_takers() |> Enum.sort() == [
               {:bare, 1},
               {:defaulted, 2},
               {:ignored, 1},
               {:matched, 2}
             ]
    end
  end

  # A module on the path: it calls a clock taker.
  defp on_path(body),
    do: "def on_path, do: Cinder.Acquisition.IndexerSource.Native.now()\n" <> body

  # Each wall-clock read outside a clock default, by function, when the module is on the path.
  defp wall_clock_reads(binary) do
    module = module_name(binary)

    case abstract_code(module, binary) do
      {:ok, forms} ->
        functions = for {:function, _line, _name, _arity, _clauses} = form <- forms, do: form
        if Enum.any?(functions, &on_path?/1), do: read_lines(module, functions), else: []

      error ->
        ["#{inspect(module)}: cannot read the debug info in its .beam (#{inspect(error)})"]
    end
  end

  defp read_lines(module, functions) do
    for {:function, _line, name, arity, clauses} <- functions,
        {m, f} <- reads(clauses),
        do: "#{inspect(module)}.#{name}/#{arity} reads #{inspect(m)}.#{f}"
  end

  defp on_path?(form) do
    takers = [{Native, :now} | Enum.map(@clock_takers, fn {m, f, _arity} -> {m, f} end)]
    form |> pairs() |> Enum.any?(&(&1 in takers))
  end

  # The wall-clock `{module, function}` pairs a term holds, skipping the capture a clock default
  # holds but still reading that call's other arguments.
  defp reads(term), do: term |> pairs() |> Enum.filter(&(&1 in @wall_clock))

  # Every `{module, function}` that a remote call, a capture or `apply/3` holds: two atoms side by
  # side in one tuple or list.
  defp pairs(
         {:call, _, {:remote, _, {:atom, _, Keyword}, {:atom, _, function}},
          [
            source,
            {:atom, _, key},
            {:fun, _, {:function, {:atom, _, DateTime}, {:atom, _, :utc_now}, {:integer, _, 0}}}
          ]}
       ) do
    if Map.get(@clock_defaults, function) == key,
      do: pairs(source),
      else: [{DateTime, :utc_now} | pairs(source)]
  end

  defp pairs(term) when is_tuple(term), do: term |> Tuple.to_list() |> pairs()

  defp pairs(term) when is_list(term) do
    adjacent =
      for [{:atom, _, module}, {:atom, _, function}] <- Enum.chunk_every(term, 2, 1, :discard),
          do: {module, function}

    adjacent ++ Enum.flat_map(term, &pairs/1)
  end

  defp pairs(_term), do: []

  # The exported functions with a parameter named `now` in any clause.
  defp now_takers(binary) do
    module = module_name(binary)
    {:ok, forms} = abstract_code(module, binary)
    exports = for {:attribute, _, :export, list} <- forms, export <- list, do: export

    for {:function, _line, name, arity, clauses} <- forms,
        {name, arity} in exports,
        Enum.any?(clauses, fn {:clause, _, args, _, _} -> :now in var_names(args) end),
        do: {name, arity}
  end

  defp var_names({:var, _, name}) do
    [name |> Atom.to_string() |> String.trim_leading("_") |> String.replace(~r/@\d+$/, "")]
    |> Enum.map(&String.to_atom/1)
  end

  defp var_names(term) when is_tuple(term), do: term |> Tuple.to_list() |> var_names()
  defp var_names(term) when is_list(term), do: Enum.flat_map(term, &var_names/1)
  defp var_names(_term), do: []

  # Anything but a readable Elixir debug info chunk falls through as the error.
  defp abstract_code(module, binary) do
    with {:ok, {^module, [debug_info: {:debug_info_v1, backend, data}]}} <-
           :beam_lib.chunks(binary, [:debug_info]) do
      backend.debug_info(:erlang_v1, module, data, [])
    end
  end

  defp module_name(binary), do: binary |> :beam_lib.info() |> Keyword.fetch!(:module)

  defp object_code(module) do
    {^module, binary, _path} = :code.get_object_code(module)
    binary
  end

  defp compile_one(tag, body) do
    [{_, binary}] = compile("defmodule #{name(tag)} do\n#{body}\nend\n")
    binary
  end

  # The same options `SeriesIdentitySyncCallsTest` sets. Both modules are not async, so no other
  # compile runs while they are set.
  defp compile(source) do
    previous = Code.compiler_options(debug_info: true, docs: true)

    beams =
      try do
        Code.compile_string(source)
      after
        Code.compiler_options(previous)
      end

    on_exit(fn ->
      for {module, _} <- beams do
        :code.purge(module)
        :code.delete(module)
      end
    end)

    beams
  end

  defp name(tag),
    do: "Cinder.CodeHealth.NativeClockReadsTest.Fixture.#{Macro.camelize("#{tag}")}"
end
