# kagi research access

`kagi search "query" [count]` returns title, url and snippet per result, ten
by default. `kagi read <url>...` returns pages as markdown, ten urls per
request.

A search costs $0.012 per request whatever `count` asks for, and a page costs
$0.004 whether or not it shared a request with nine others. So widen a search
instead of repeating it: `kagi search "query" 40` bills the same as the
default, while a rephrased follow-up bills again. What limits `count` is
context, not the invoice. Batching urls into one `kagi read` buys round trips
rather than money, so still read only the pages the snippets justify. Pages
run to tens of kilobytes, so pipe one through `grep` or `head -c` when you
want one fact from it.

Every call reports what it spent, and that lands in the session cost in the
footer. Reading a page goes through Kagi's extractor rather than fetching it
directly, which is why research needs no `--web`. A URL that must be fetched
directly still does.
