# pi-herdr-mentions

A pi extension that adds `@` autocomplete for herdr workspaces, tabs and agents, and swaps
the inserted readable names for `@herdr:<id>` on submit. Published as a pi package
(`pi install git:...`); pi loads the TypeScript source directly, so there is no build step.

## Commands

`npm run typecheck` and `npm test` (Node's built-in runner with type stripping, so Node
22.19 or newer). To try a change live, run `pi -e ./extensions/herdr-mentions.ts` inside a
herdr pane.

## Gotchas

### pi's packages are peers, never dependencies

`@earendil-works/pi-coding-agent` and `@earendil-works/pi-tui` stay in `peerDependencies`
with `"*"`; the pinned devDependency copies exist only for type-checking and tests. pi
supplies the runtime copy, and a bundled one breaks its module mapping. `renovate.json`
disables peer updates so it never pins that range.

### Keep the extension one file

pi resolves an extension's relative imports from where the file is linked, not where it
lives, so a symlinked install breaks on `../anything`. Pure helpers are exported from the
extension file itself for the tests.

### Wrap the built-in autocomplete provider explicitly

pi's built-in provider is a class instance. Spreading it (`{ ...current }`) drops its
prototype methods and crashes pi on the first accepted completion; delegate each method.

## Conventions

The herdr CLI's JSON output is the contract (`herdr workspace list`, `tab list`,
`agent list`); check a real response before changing field names.
