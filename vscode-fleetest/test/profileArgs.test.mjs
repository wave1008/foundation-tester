import assert from "node:assert/strict";
import { test } from "node:test";
import { profileArgs } from "../src/profileArgs";

test("profileArgs: 選択中なら --profile を付け、未選択・空白のみなら何も足さない", () => {
  assert.deepEqual(profileArgs(" local "), ["--profile", "local"]);
  assert.deepEqual(profileArgs(""), []);
  assert.deepEqual(profileArgs("   "), []);
});
