# verify

Groups several assertions into one reported check.

## Functions

| function | description |
|---|---|
| `verify(message) { }` | Runs the block and records it as one check step named `message`. Passes when one or more assertion commands (`exist` / `notExist` / the text-value-id-this-app assertions) inside the block all succeed. |

## Example

```swift
verify("Order info is correct") {
    select("#order_id").textIs(orderNumber ?? "")
    exist("#order_total")
}
```

## Notes

- **A block with zero assertions is neither passed nor failed — it's `inconclusive`.** This
  catches the case where you meant to verify something but the block doesn't actually assert
  anything. `inconclusive` does not abort the scenario; the report and log show it with a ❓ and
  a note.
- If a command inside the block fails, the scenario aborts as usual.

### Link
- [index](../index.md)
