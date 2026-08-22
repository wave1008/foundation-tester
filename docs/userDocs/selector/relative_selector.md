# Relative Selector

A relative selector points at a candidate by its position relative to an anchor element,
for screens where the target has no id or reliable label of its own (e.g. a switch next to
a text label, with no id on the switch).

## Basic form: anchor comes first

```swift
tap("Notification:rightSwitch")
```

Unlike a plain directional description, the **anchor is written first**, then a colon, then
the direction (`right` / `left` / `above` / `below`) plus an optional type suffix
(`Button` / `Image` / `Input` / `Label` / `Switch` / `Widget`). This resolves to: the
nearest `.switch` that is in the band extending from `Notification` in the `right`
direction. **If no candidate matches, the selector fails** — it does not fall back to
"closest thing available," since that would silently grab a different element once the
layout changes.

Leaving off the type suffix (`Notification:right`) defaults to `.widget` (any element with a
confirmed interactive role — this avoids matching layout containers).

## Ordinal

```swift
tap("Quantity:right(2)")
```

Picks the 2nd-nearest candidate in that direction (1-origin, default 1).

## Arbitrary filter

```swift
tap("#a:below(.button&&Item)")
```

Instead of a type suffix, the direction can take any selector expression as its filter.
`||` inside the filter takes the union of all matching candidates first, then picks the
nearest one overall — `:right(.button||.switch)` means "the nearest of either a button or a
switch."

## Chaining

```swift
tap("Heading:right:belowButton")
```

Each step's result becomes the anchor for the next step.

## Wrapping the anchor in `<...>`

```swift
tap("<Change&&.button>:right(Quantity)")
```

The Shirates canonical form wraps the anchor in angle brackets. This is optional syntax
sugar — it parses to the same result as writing the anchor unwrapped — but makes a
multi-word anchor easier to read at a glance.

## Scope

```swift
tap("#row >> Quantity:rightButton")
```

A scope (`>>`) can precede a relative selector; it narrows both the anchor and the
candidates to inside the scoped container.

## Notation not implemented

Compared to Shirates(Classic)'s relative selector vocabulary:

- **`:inner*`** — covered by the ancestor `>>` descendant scope instead.
- **`:next*` / `:pre*`** (tree-order neighbor) and **`:parent`** (child pointing at its
  parent) are **not implemented**. `:right`/`:below`/etc. approximate "next item" for a
  single-column layout, but can pick the wrong row once content wraps or is arranged in a
  grid.
- **`:flow` / `:vflow`** (flow-based grouping) are **not implemented** — they require an
  arbitrary row-grouping threshold with no principled default.

See [docs/shirates-parity.md](../../shirates-parity.md) for the full comparison and current
status of each.

### Link
- [index](../index.md)
