# appIs

Asserts which app is currently in the foreground.

## Functions

| function | description |
|---|---|
| `appIs(id, waitSeconds: 15)` | Asserts the foreground app equals `id` (iOS bundle ID / Android package name), polling up to `waitSeconds`. |

## Example

```swift
tap("#open_maps_btn")
appIs("com.example.maps")
```

## Notes

- Write the bundle ID / package name directly — there is no nickname mechanism.
- On Android, a failure includes the actual foreground package name in the message. On iOS there
  is no way to read the foreground bundle ID, so a failure message does not include it.

### Link
- [index](../index.md)
