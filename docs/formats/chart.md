# Chart spec

A chart spec is a small JSON document an agent writes (or a person edits)
to draw a chart artifact. It is a subset of Vega-Lite's ideas:
`data` to plot, a `mark` to draw each row with, an `encoding` that maps
fields to channels (x, y, colour…), and optional `transform`s run first.

```json
{
  "title": "Revenue by month",
  "data": { "path": "data/sales.csv", "query": "from sales | where region != 'EU'" },
  "mark": { "type": "bar", "stack": true },
  "encoding": {
    "x": { "field": "month", "type": "temporal", "timeUnit": "month" },
    "y": { "field": "revenue", "type": "quantitative", "aggregate": "sum", "format": "si" },
    "color": { "field": "region", "type": "nominal" },
    "tooltip": [{ "field": "region", "type": "nominal" }, { "field": "revenue", "type": "quantitative", "aggregate": "sum" }]
  },
  "width": 600,
  "height": 320
}
```

Reading is strict. An unknown key is an error that lists the allowed keys,
and every error starts with the JSON path of the problem, so a model can
fix its spec from the message alone:

```
encoding.y.type: expected one of quantitative|nominal|ordinal|temporal
encoding.colour: unknown key; allowed: x, y, x2, y2, color, size, shape, opacity, text, tooltip, detail
transform[0].as: required
```

The JSON Schema is [`chart.schema.json`](chart.schema.json); the artifact
tools (`artifact_create`, `artifact_update`) carry it as the schema of
their `spec` field. The reader checks more than the schema can say (for
example that `sum` needs a quantitative field). Implementation:
`packages/agents/src/chart/` (spec E13.F07.S01.T03).

## Top level

| Key | Value |
| --- | --- |
| `data` | Required. Where the rows come from (below). |
| `mark` | Required. A mark name, or a mark object (below). |
| `encoding` | Channels (below). |
| `transform` | A list of transforms, run in order before encoding. |
| `title`, `description` | Text. The title is drawn above the chart and names it for screen readers; the description is for readers of the spec. |
| `width`, `height` | 10 to 10,000 logical pixels. Default: the pane's size. |
| `$schema` | Ignored (`"zg-chart/1"` by convention). |

## Data

Exactly one of:

- `"values": [{…}, …]`: rows inline, at most 100,000. Numbers, strings,
  booleans and null; ISO dates and date-times in strings are read as
  times by temporal fields.
- `"artifact": "A-…"`: a table artifact.
- `"path": "data/sales.csv"`: a workspace data file (CSV, TSV, JSON or
  NDJSON), optionally with `"query"` in the
  [data query language](data-query.md).

Artifacts and files are loaded through the app's data source.

## Marks

`bar`, `line`, `area`, `point`, `circle`, `square`, `rule`, `rect`,
`tick`, `text`. As an object, a mark also takes:

| Key | Value |
| --- | --- |
| `type` | The mark name. |
| `stack` | Bars and areas: `true` stacks (the default when a colour splits them), `false` overlays, `"group"` puts bars side by side. |
| `color` | `"#rrggbb"` or `"#rgb"`, for every mark (when no colour channel). |
| `opacity` | 0 to 1. |
| `size` | Point area in square pixels; text size in pixels. |
| `strokeWidth` | Line width (default 2). |
| `filled` | Points: filled or outlined. |
| `point` | Lines: also draw a dot at each point. |

## Encoding

Channels: `x`, `y`, `x2`, `y2` (bar and rule ends, bin ends), `color`,
`size`, `shape`, `opacity`, `text`, plus lists `tooltip` and `detail`
(extra fields that split lines and areas into series). Each channel is a
field definition:

| Key | Value |
| --- | --- |
| `field` | A column name (required unless `aggregate` is `count`). |
| `type` | Required: `quantitative`, `nominal`, `ordinal` or `temporal`. |
| `aggregate` | `count`, `sum`, `mean`, `median`, `min`, `max`, `distinct`. The other channels' fields become the group. |
| `bin` | `true` or `{ "maxbins": n }` (2 to 1000, default 10): quantitative fields only. |
| `timeUnit` | `year`, `quarter`, `month`, `week`, `day`, `hour`: temporal fields only. |
| `sort` | `ascending` (default), `descending`, `none` (data order), or by the other axis: `x`, `-x`, `y`, `-y`. |
| `title` | Axis or legend title (default: the field, with its aggregate). |
| `scale` | `{ "type": "linear" \| "log" \| "time" \| "band" \| "point", "zero": bool, "domain": [min, max], "zone": "utc" \| "local" }`. |
| `axis` | `null` hides it; else `{ "title", "grid": bool, "format", "labels": bool }`. |
| `legend` | `false` (or `null`) hides the colour legend. |
| `format` | Numbers: `auto`, `si` (1.5k, 2M), `percent`, `plain`. |
| `value` | A constant (number or string) instead of a field; takes no other key. |

## Transforms

Each is an object with exactly one of these keys:

| Transform | Example |
| --- | --- |
| `filter` | `{ "filter": "revenue > 0 and region != 'EU'" }` (a query-language expression; equality is `==`) |
| `calculate` | `{ "calculate": "revenue / units", "as": "price" }` |
| `bin` | `{ "bin": { "maxbins": 30 }, "field": "price", "as": "p" }` (adds `p` and `p_end`) |
| `timeUnit` | `{ "timeUnit": "week", "field": "day", "as": "wk" }` |
| `aggregate` | `{ "aggregate": [{ "op": "sum", "field": "revenue", "as": "total" }], "groupby": ["region"] }` |
| `fold` | `{ "fold": ["q1", "q2"], "as": ["quarter", "value"] }` (wide to long; `as` defaults to `key`, `value`) |

## Scales, axes and legends

- **Position scales.** Quantitative fields are linear, with zero
  included for bars and areas unless `"zero": false`. Temporal fields are
  time scales in UTC, or the app's zone with `"zone": "local"`; under
  bars, rects and ticks they are bands of periods (one per `timeUnit`
  value) unless binned. Nominal and ordinal fields are bands for bars and
  rects (padding 0.1), and points otherwise. `log` and the others are
  chosen with `scale.type`.
- **Ticks** are "nice" numbers: 1, 2, 2.5 or 5 × 10ᵏ. Time ticks step
  through 1 s up to 1 year by the range, and are labelled with what
  changes (`09:00`, `Feb`, `2026`). When labels would overlap, every other
  one is dropped until none do.
- **Colour.** Categories use a 10-colour, colour-blind-safe palette (the
  theme's, Tableau 10 by default); quantitative colour uses a sequential ramp, with a gradient
  legend.
- **Layout.** Title on top, legend on the right (wrapping into columns),
  and axis margins measured from their labels. The plot takes the rest.

## Large data

- Lines and areas with more than 4 points per plot pixel keep, per pixel
  column, the first, last, lowest and highest point (M4). That draws the
  same line as every point, and a 1,000,000-point line chart draws in
  under 4 ms (`chart/line_1m_frame` bench).
- Points beyond 200,000 are a deterministic, stratified sample, and the
  chart shows a "sampled" badge.

## Hover

Moving the pointer over the chart shows a tooltip for the nearest mark
within 8 pixels. It lists the `tooltip` fields, or else every encoded
field, formatted like the axes.
