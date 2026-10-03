# pi-herdr-mentions

`@`-mention [herdr](https://herdr.dev) workspaces, tabs and agents from the
[pi](https://pi.dev) prompt.

Type `@` and herdr targets appear above pi's file suggestions. Picking one inserts its
readable name, and on submit the name is swapped for the herdr id the agent can act on:

```text
you type:       Dispatch sonnet agents to @ED-20911__codex-review-spike
agent receives: Dispatch sonnet agents to @herdr:w87
```

```text
@fooz
→ fooz-barz                       herdr workspace #1 · working
  fooz-barz / notes               herdr tab #1 · idle
  fooz-barz / pi · π - firstmate  herdr agent #1 · idle
  fooz-barz / claude · review     herdr agent #1 · working
```

## Install

```sh
pi install git:github.com/lucas-codes/pi-herdr-mentions
```

The extension only translates names into ids. Acting on `@herdr:<id>` comes from herdr's
own agent skill, so install that too:

```sh
npx skills add herdrdev/herdr --skill herdr -g
```

Run pi inside a herdr pane. Outside herdr (`HERDR_ENV` unset) the extension does nothing.

## How targets are named

- **Workspaces** use their sidebar label, minus worktree decoration
  (`└ ED-20911__codex-review-spike · p:F9-…` becomes `ED-20911__codex-review-spike`).
- **Tabs** appear only when a workspace has more than one, as `<workspace> / <tab>`.
  Auto-numbered titles drop their prefix (`1 · pi › π - BIG BRAINS` becomes `π - BIG BRAINS`).
- **Agents** appear only when a workspace has more than one, as
  `<workspace> / <agent> · <terminal title>`. Your own pane is left out.
- **Clashing names** all get a short id appended (`home / pi · π - dev · p5H`), so a name
  never changes meaning between lookups.
- Names with spaces are inserted quoted (`@"fooz-barz / notes"`), the same way pi quotes
  file paths. Unquoted mentions end at the first space.
- Any `@token` that isn't a herdr name, such as a file mention, is left as typed.

Mentions resolve to `@herdr:<workspace_id>`, `@herdr:<tab_id>` or `@herdr:<pane_id>`.
`herdr agent prompt` takes an agent pane id, so mentioning an agent saves the model a
lookup.

## Development

```sh
npm install
npm run typecheck
npm test
```

## License

MIT
