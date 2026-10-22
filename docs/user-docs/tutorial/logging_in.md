# Testing an app that needs a login

[in Japanese(日本語)](logging_in_ja.md)

Register test accounts and put the login steps in one place.

## 1. Put the passwords in place (write this yourself)

Keep passwords out of the repository, in a file on this Mac. Do not have the AI assistant write it.

Write it in `~/.config/fleetest/dataset/<test project name>/accounts.json`. For the test project `myshop`, that is:

`~/.config/fleetest/dataset/myshop/accounts.json`:

```json
{
  "[account1]": { "password": "..." },
  "[account2]": { "password": "..." }
}
```

## 2. Register the accounts and put the login in one place

### Prompt for the AI

```text
Register test accounts in the fleetest test project myshop.
In TestProjects/myshop/dataset/accounts.json, register [account1] with id alice@example.com and [account2] with id bob@example.com,
and do not write the passwords (they are in ~/.config/fleetest/dataset/myshop/accounts.json on this Mac).
Put the My Shop login steps into a custom command named login that takes the account with account().
```

What you'll see: the scenarios contain neither IDs nor passwords, only calls such as `login` and `account("[account1].id")`.

## 3. Use separate accounts when running in parallel

If several devices use the same account at the same time, server-side state such as the cart or history gets mixed up and tests fail.

### Prompt for the AI

```text
In the fleetest test project myshop, check whether scenarios that change server-side state, such as the cart or order history, share an account.
If they do, change them so that each scenario uses its own account. List the accounts that are missing (I will put the passwords in place).
```

## Keep passwords out of reports (optional)

By default, typed passwords stay as they are in reports and run logs. If you write `"redactAccountValues": true` yourself in
`~/.config/fleetest/config.json` on this Mac, the values from `account()` are replaced with `***` (text visible in screenshots cannot be hidden).

More: [Test data and accounts](../reference/commands/dataset.md) / [Custom commands](../reference/testclass/custom_commands.md) / [Handy features for writing test code](../reference/writing/helpers.md)

Next: [Creating tests](creating_tests.md)

### Link
- [index](../index.md)
