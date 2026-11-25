# #1665: ci.yml's `container` job runs this file's text through `bin/cinder rpc` in the booted
# release, as the image's user. It starts two parser workers with
# `Cinder.Indexers.ParserWorker.run/3`, each from the release's own ERTS, which no other CI run
# reaches: the `test` job starts them from the dev shell's OTP. The last line it prints is
# `PARSER_WORKER_CHECK:ok` only when `td b` answers its one row and `td:has(b[border=1])`, which
# ends lexbor with a segmentation fault, answers `{:error, :crash}`. Any other result prints
# `PARSER_WORKER_CHECK:failed` with both results, and a raise makes the rpc exit 1. The job's
# step fails unless the rpc exits 0 and prints the `ok` line.
# test/cinder/indexers/parser_worker_check_script_test.exs runs this file against the real
# worker and a stub.
alias Cinder.Indexers.ParserWorker

html = "<table><tr><td><b>x</b></td></tr></table>"
field = %{name: "t", selector: nil, attribute: nil, remove: [], case: []}
rows = ParserWorker.run(html, %{rows: "td b", fields: [field]}, deadline_ms: 30_000)
crash = ParserWorker.run(html, %{rows: "td:has(b[border=1])", fields: []}, deadline_ms: 30_000)

case {rows, crash} do
  {{:ok, [[{"t", "x"}]]}, {:error, :crash}} ->
    IO.puts("td b answered its row and td:has(b[border=1]) ended its worker as :crash")
    IO.puts("PARSER_WORKER_CHECK:ok")

  other ->
    IO.puts(
      "PARSER_WORKER_CHECK:failed #{inspect(other, limit: :infinity, printable_limit: :infinity)}"
    )
end
