# Data query language

The data query language is how the grid's advanced filter, chart specs and
the agent's data tools ask questions of a dataset (CSV, TSV, JSON or
NDJSON). A query is a pipeline: one stage per `|`, each taking the rows of
the stage before.

```
from "sales.csv"
| where country == "DE" and revenue > 1000 and date >= 2025-01-01
| derive month = trunc(date, "month")
| group month, product { revenue = sum(revenue), n = count() }
| join "regions.csv" on country == code left
| sort -revenue
| limit 20
```

The language reads data and never changes it: there's no stage that writes,
deletes or runs a program. Implementation: `packages/agents/src/data/query/`
(spec E13.F06.S02.T01). Execution is E13.F06.S02.T03.

## Lexical rules

- Whitespace is free, and `#` comments run to the end of the line.
- **Keywords** are case-insensitive: `from where derive select group sort
  limit join on left sample and or not in between is null true false case
  when then else end`.
- **Identifiers** (column and dataset names) are case-sensitive. They contain
  letters, digits, `_` and non-ASCII bytes, and don't start with a digit.
- **Quoting names.** Any other name, or a keyword, goes in backticks, with a
  doubled backtick standing for one: `` `order id` ``, `` `where` ``,
  `` `a``b` ``.
  - Where only a name can appear (`from`, `join`, sort and group keys,
    the left side of `name = …`), a quoted string is accepted too:
    `from "sales.csv"`.
  - In an expression, a quoted string is always a string literal.
- **Strings** use `"…"` or `'…'`, with the escapes `\"`, `\'`, `\\`, `\n`,
  `\t` and `\r`.
- **Numbers.** Ints are 64-bit. Floats are written with `.` or an exponent
  (`1.5`, `.5`, `2e3`).
- **Dates and datetimes.** Unquoted `YYYY-MM-DD` is a date. A datetime is
  `YYYY-MM-DDTHH:MM:SS[.fff][Z|±HH:MM]`, normalized to UTC.
- **Operators:** `+ - * / %`, `== != <> < <= > >=` (`<>` is `!=`), `=` in
  bindings, `( ) [ ] { } , |`.

## Grammar

```
query    = stage { "|" stage }
stage    = "from" name                       (first stage only; optional)
         | "where" expr
         | "derive" binding { "," binding }  (adds or replaces columns)
         | "select" item { "," item }        (the new column list)
         | "group" [ key { "," key } ] "{" binding { "," binding } [","] "}"
         | "sort" skey { "," skey }
         | "limit" INT
         | "sample" INT
         | "join" name "on" column "==" column [ "left" ]
binding  = name "=" expr
item     = binding | expr                    (a bare expr is named after its
                                              column, else exprN)
skey     = [ "-" | "+" ] name [ "asc" | "desc" ]
expr     = or
or       = and { "or" and }
and      = not { "and" not }
not      = "not" not | cmp
cmp      = sum [ ( "==" | "!=" | "<" | "<=" | ">" | ">=" ) sum
               | [ "not" ] "in" "[" [ expr { "," expr } ] "]"
               | [ "not" ] "between" sum "and" sum
               | "is" [ "not" ] "null" ]
sum      = product { ( "+" | "-" ) product }
product  = unary { ( "*" | "/" | "%" ) unary }
unary    = "-" unary | primary
primary  = literal | name | func "(" [ expr { "," expr } ] ")"
         | "(" expr ")"
         | "case" { "when" expr "then" expr } [ "else" expr ] "end"
```

Comparisons don't chain: `a < b < c` is an error, so write
`a < b and b < c` (or `b between a and c`). Without `from`, the query runs
on the dataset in view.

## Types

| Type | Values |
|---|---|
| `int` | 64-bit integers |
| `float` | 64-bit floats (decimal columns too) |
| `string` | text |
| `bool` | `true`, `false` |
| `date` | calendar days |
| `datetime` | UTC instants, millisecond precision |
| `null` | missing values; every column can hold null |

Columns take the types that type inference gave them (E13.F06.S01.T03).

### Operator rules

- **Comparisons.** Values compare when their types are the same, both
  numeric, or both temporal. Null compares with anything.
- **Arithmetic.**
  - Arithmetic needs numbers. `/` always gives a float. `int op int` gives
    an int; any float operand makes the result a float.
  - Dates and datetimes: `date ± int` adds days and `date - date` gives
    days.
  - `string + string` concatenates.
- **Logic.** `and`, `or` and `not` take bools. `where` and `when` need a
  bool.
- **Branches.** `case` branches and `coalesce` arguments must share a type.
  Int and float unify to float, and date and datetime unify to datetime.

### Functions

| Function | Type |
|---|---|
| `lower(s)`, `upper(s)` | string → string |
| `contains(s, t)`, `starts_with(s, t)`, `ends_with(s, t)`, `regex_match(s, re)` | strings → bool |
| `length(s)` | string → int |
| `substr(s, start[, len])` | string, int, int → string |
| `year(d)`, `month(d)`, `day(d)` | date → int |
| `trunc(d, "unit")` | date → date (datetime → datetime) |
| `date_diff(a, b[, "unit"])` | dates → int (days by default) |
| `abs(x)`, `floor(x)`, `ceil(x)`, `round(x[, digits])` | number → number |
| `log(x)`, `sqrt(x)` | number → float |
| `coalesce(a, b, …)` | first non-null |

Units are `year`, `quarter`, `month`, `week`, `day`, `hour`, `minute` and
`second`. Function names are case-insensitive.

### Aggregates

Aggregates are only allowed in `group { … }`:

| Aggregate | Result |
|---|---|
| `count()` | rows |
| `count(x)` | non-null values |
| `count_distinct(x)` | distinct values |
| `sum(x)` | int for int columns, else float |
| `avg(x)`, `median(x)`, `stddev(x)` | float |
| `p(x, q)` | the q-quantile, where q is a literal between 0 and 1 |
| `min(x)`, `max(x)` | the type of `x` |

## Errors

Every error is one line with a byte span, `message at start..end`, for
example:

```
cannot compare string to int at 19..29
unknown column `amout` (did you mean `amount`?) at 19..24
comparisons can't be chained; use `and` at 12..13
```

Limits:
- Queries are at most 64 KiB.
- Expressions nest at most 128 deep, counting parentheses, calls and every
  link of an operator chain.

## Canonical form

`formatQuery` prints a query in canonical form:
- keywords in lowercase;
- ` | ` between stages and one space around operators;
- descending sort keys as `-col`;
- only the parentheses that precedence needs;
- strings in double quotes;
- names in backticks when needed;
- datetimes in UTC with a `Z`.

Parsing the canonical form gives back the same tree.

## Planning

`plan` resolves names against a catalog and type-checks every expression,
then shapes the pipeline for execution:

- **Column pruning.** `needed_columns` lists the source columns that any
  stage reads or the output keeps. Only those are parsed.
- **Predicate pushdown.**
  - Which conjuncts move: the `where` conjuncts that use only raw source
    columns, before any stage that changes rows (`group`, `select`,
    `join`, `sort`, …) or replaces a source column.
  - Where they go: `filter`, which is checked on raw fields before rows
    are materialized.
- **Constant folding.** Operators whose operands are all literals are
  evaluated at plan time.
- **Top-k.** `sort … | limit k` becomes one `topk` stage.

## Execution

`execute` runs a plan over open datasets and streams the result to a sink
in batches. The source splits into morsels of 64 k rows that worker
threads take in turn. Each worker parses only the needed columns, and the
pushed-down filter's columns first. Rows then flow through the streaming
stages (`where`, `derive`, `select`, `join`) into the first blocking
stage (`group`, `sort`, top-k, `limit`, `sample`), whose per-worker
states merge at the end. Everything after that runs in memory.

### Semantics

- **Nulls** follow SQL. An operator or function of a null gives null.
  The exceptions are `is null`, `coalesce`, and the three-valued `and`
  and `or`. `where` keeps a row only when its condition is true, and
  `x in [..]` with a null in the list is null rather than false.
- **Errors in values** give null rather than failing the query. That
  covers division or modulo by zero, integer overflow, the square root
  or log of a negative number, and a pattern that doesn't compile.
- **`date_diff(a, b)`** is `b − a`, truncated toward zero, in days
  unless a unit is given. Months, quarters and years count whole
  calendar units: a month is whole once the day of month (and time) is
  reached.
- **Sorting.** Nulls sort last in both directions, and ties keep their
  input order.
- **Groups** come out in the order of their first row. Group keys
  compare nulls as equal, and `1` equals `1.0`.
- **Joins.** A left row's matches come in the joined dataset's order.
  Null keys never match. A `left` join keeps an unmatched row, with
  nulls on the right.
- **`sample n`** keeps the n rows whose order hashes lowest, in input
  order. The same query over the same data always picks the same rows,
  however many threads run it.
- **Approximation.** `count_distinct` is exact up to 1 M distinct
  values per group and a HyperLogLog sketch beyond that. `median` and
  `p` are exact up to 1 M values per group and a t-digest beyond that.
  The stats say when a sketch answered.

Every result is deterministic and the same for any thread count: rows
carry their input order through the stages, and every merge resolves
ties by it.

### Guards

| Guard | Default | Error |
| --- | --- | --- |
| `max_mem`: kept rows, groups, sketches and join tables | 1 GiB | `QueryTooLarge` (add a filter or a limit; nothing spills to disk) |
| Join table rows | 10 M | `JoinTooLarge` |
| `max_rows_out` | 1 M | none: the result is cut, and the stats say `truncated` |
| `cancel` | — | `Canceled`, checked every 1024 rows |
