# Selector Expression

A selector is a single string. This page is the full reference for the notation; command
usage is in [docs/commands.md](../../commands.md).

## Notation table

Combination strength (tightest first): `&&` > `>>` > `||`.

| Notation | Meaning |
|---|---|
| `#login_btn` | accessibility id (exact match). **If no element matches by identifier, placeholder is tried instead** (input fields swap id/placeholder depending on the read path — see [WebView elements](./webview.md)) |
| `#login*` / `#*login*` / `#*btn` | id starts-with / contains / ends-with (full form: `idStartsWith=` `idContains=` `idEndsWith=`) |
| `Log In` | label (**exact match only**; full form `text=Log In`) |
| `*Log*` / `Log*` / `*In` | label contains / starts-with / ends-with (full form `textContains=` `textStartsWith=` `textEndsWith=`) |
| `textMatches=^Row [0-9]+$` / `idMatches=^row_[0-9]+$` | regular expression (**substring match** — write `^…$` for a full match) |
| `.button` / `.button[2]` | type + ordinal (**1-origin**: `.button[2]` is the 2nd Button; the 1st can be written `.button` or `.button[1]`) |
| `.switch#id` / `.switch&&Label` | type combined with id/label (useful to narrow a value assertion by type) |
| `#save&&.button&&enabled=true` | **`&&` = AND**. Attributes: `text` `value` `placeholder` `id` `type` `pos` `checked` `enabled`. Only `text`/`value`/`placeholder`/`id` support match modes (`Contains`/`StartsWith`/`EndsWith`/`Matches`); `type`/`pos`/`checked`/`enabled` are exact-match only |
| `(Save\|OK)` / `text=(Save\|OK)` | **OR inside a filter**. Equivalent to `Save\|\|OK` (in a relative-selector argument you write the parentheses yourself: `:right((Save\|OK))`) |
| `.button&&text!=Cancel` / `.button&&!Cancel` | **negated filter** (`!value` is the short form). `textContains!=`, `!#id`, `!.button` also work. **A clause of only a negation, or a negated ordinal, cannot be written** |
| `.input` / `.widget` | type aliases (`.input` = textField\|secureTextField; `.widget` = the 5 roles shared across OSes) |
| `#list >> .clickable[2]` | **scope** (ancestor >> descendant). Ordinals are counted within the scope, so screen chrome or scroll position doesn't shift them. **The ancestor must be exposed in the app's accessibility tree** — a collapsed container (e.g. Flutter's `MergeSemantics`) hides its descendants and can't be scoped into |
| `Notification:rightSwitch` | **relative selector** (**anchor comes first**). The nearest candidate in that direction within the anchor's band; fails if none matches — see [Relative selector](./relative_selector.md) |
| `Quantity:right(2)` / `#a:below(.button&&Item)` / `Heading:right:belowButton` | ordinal / arbitrary filter / chained relative selector |
| `<Change&&.button>:right(Quantity)` | anchor wrapped in `<...>` (Shirates canonical form; optional, makes the anchor's extent easier to read) |
| `=#a raw label starting with #` | `=` escape, forces label interpretation (also used for labels containing `>>` `&&` `:right` `*`) |

## Short-form / full-form equivalence

| Short form | Full form | Meaning |
|---|---|---|
| `Label` | `text=Label` | exact match (no implicit substring fallback) |
| `*word*` / `word*` / `*word` | `textContains=` / `textStartsWith=` / `textEndsWith=` | substring match |
| — | `textMatches=^…$` | regex (substring; write `^…$` for a full match) |
| `#id` | `id=` | id (exact) |
| `#foo*` / `#*foo*` / `#*foo` | `idStartsWith=` / `idContains=` / `idEndsWith=` | id substring match |
| — | `idMatches=^…$` | id regex (substring) |
| `.type` | `type=` | type name (lowercase first letter) |
| `[n]` | `pos=n` | ordinal within the candidate set (1-origin) |
| — | `value=` / `placeholder=` | value / placeholder (same match modes as `text`/`id`) |
| — | `checked=true\|false` / `enabled=true\|false` | state (`checked=false` also matches elements with no checked state at all) |
| `(a\|b)` | `text=(a\|b)` | **OR inside a filter** |
| `!value` | `attr!=value` | **negated filter** |

## `||` selects a union, not an AND

`||` takes the **union of candidate sets**; when a command needs exactly one element, it
picks the **first clause, in order** that resolves. This means `#login_btn||Log In` also
acts as a heal fallback chain — if the id ever changes, the label clause still resolves.
Priority is effectively: id > label > type+index.

## Rules that produce a syntax error before touching a device

Misspellings, unsupported notation (`:near`, `:parent`, …), non-numeric ordinals (`[abc]`),
and unbalanced parentheses are all rejected up front — a typo is never silently treated as a
literal label (which would let `notExist` pass for the wrong reason). An **unknown filter
name** (`name=value`) is allowed as a raw label (e.g. `notify=off`), *except* when it's
close enough to a known filter name to look like a typo (a prefix relationship, a
case-only difference, a one-character difference at 6+ characters, or a known base name
followed directly by an uppercase letter, e.g. `idPrefix=`) — those are rejected instead of
silently becoming a label.

## Type vocabulary

Type names are lowercase (`.button`, `.staticText`, not `.Button`). `.input` and `.widget`
are aliases; see [Typed selector](./typed_selector.md) for the compile-time-checked
equivalent of this same notation.

### Link
- [index](../index.md)
