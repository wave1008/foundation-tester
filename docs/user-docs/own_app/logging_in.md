# Testing an app that needs a login

[in Japanese(日本語)](logging_in_ja.md)

Register a test account for your own app (for example the test project myshop) and put the login steps together.

## 1. Put the passwords in place (write this yourself)

Keep passwords out of the repository, in a file on this Mac. Do not have the AI assistant write it.

Write it in `~/.config/fleetest/dataset/<test project name>/accounts.json`. For the test project `myshop`, that is:

`~/.config/fleetest/dataset/myshop/accounts.json`:

```json
{
  "[account1]": { "password": "..." }
}
```

## 2. Register the account and put the login together

### Prompt for the AI

```text
In the fleetest test project myshop, register a test account of my app as [account1] (do not write the password; it is in ~/.config/fleetest/dataset/myshop/accounts.json on this Mac).
Put the login steps into a custom command named login that takes the account with account(). Undo whatever state remains after logging in in each test's afterEach.
```

## 3. Use separate accounts per test

If several devices use the same account at the same time, server-side state such as the cart or order history gets mixed up and tests fail.

### Prompt for the AI

```text
In the fleetest test project myshop, check whether scenarios that change server-side state share an account.
If they do, change them so that each scenario uses its own account. List the accounts that are missing (I will put the passwords in place).
```

## Keep passwords out of reports (optional)

By default, typed passwords stay as they are in reports and run logs. If you write `"redactAccountValues": true` yourself in
`~/.config/fleetest/config.json` on this Mac, the values from `account()` are replaced with `***` (text visible in screenshots cannot be hidden).

More:

- [Test data and accounts](../reference/commands/dataset.md)
- [Custom commands](../reference/testclass/custom_commands.md)
- [Handy features for writing test code](../reference/writing/helpers.md)

Next: [Creating and running tests](creating_and_running.md)

### Link
- [index](../index.md)
