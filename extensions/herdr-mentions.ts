// `@` autocomplete for herdr workspaces, tabs and agents. Picking one inserts its readable
// name; on submit the name becomes `@herdr:<id>`, which the herdr skill knows how to act on.
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { type AutocompleteItem, type AutocompleteProvider, fuzzyFilter } from "@earendil-works/pi-tui";

type Workspace = { workspace_id: string; number: number; label: string; agent_status: string };
type Tab = { tab_id: string; workspace_id: string; label: string; agent_status: string };
type Agent = { pane_id: string; workspace_id: string; agent: string; agent_status: string; terminal_title_stripped?: string };
type HerdrState = { workspaces: Workspace[]; tabs: Tab[]; agents: Agent[] };

export type Target = { name: string; id: string; kind: "workspace" | "tab" | "agent"; number: number; status: string };

const CACHE_TTL_MS = 2_000;
const MAX_SUGGESTIONS = 10;

// Worktree workspaces are labelled "└ <branch> · p:<project-id>"; the glyph and suffix are herdr chrome.
export const displayName = (label: string) =>
	label.replace(/^[└├│\s]+/, "").replace(/\s*·\s*p:\S+$/, "").trim();

// Auto-titled tabs read "<n> · <agent> › <title>"; only the title is worth typing.
const tabName = (label: string) => displayName(label).replace(/^\d+\s*·\s*(?:[^›]+›\s*)?/, "");

const mentionFor = (name: string) => (/\s/.test(name) ? `@"${name}"` : `@${name}`);

const shortId = (id: string) => id.slice(id.indexOf(":") + 1);

export function buildTargets(state: HerdrState, selfPane: string | undefined): Target[] {
	const targets: Target[] = [];
	for (const ws of state.workspaces) {
		const wsName = displayName(ws.label);
		targets.push({ name: wsName, id: ws.workspace_id, kind: "workspace", number: ws.number, status: ws.agent_status });

		const tabs = state.tabs.filter((t) => t.workspace_id === ws.workspace_id);
		if (tabs.length > 1)
			for (const t of tabs)
				targets.push({ name: `${wsName} / ${tabName(t.label)}`, id: t.tab_id, kind: "tab", number: ws.number, status: t.agent_status });

		const agents = state.agents.filter((a) => a.workspace_id === ws.workspace_id && a.pane_id !== selfPane);
		if (agents.length > 1)
			for (const a of agents) {
				const title = a.terminal_title_stripped ? ` · ${a.terminal_title_stripped}` : "";
				targets.push({ name: `${wsName} / ${a.agent}${title}`, id: a.pane_id, kind: "agent", number: ws.number, status: a.agent_status });
			}
	}

	// Suffix every member of a clash, not just the later ones, so a name never shifts between lookups.
	const counts = new Map<string, number>();
	for (const t of targets) counts.set(t.name, (counts.get(t.name) ?? 0) + 1);
	return targets.map((t) => ((counts.get(t.name) ?? 0) > 1 ? { ...t, name: `${t.name} · ${shortId(t.id)}` } : t));
}

export function mentionQuery(textBeforeCursor: string): { prefix: string; query: string } | undefined {
	const match = textBeforeCursor.match(/(?:^|\s)(?:@"[^"]*|@[^\s@"]*)$/);
	if (!match) return undefined;
	const prefix = match[0].trimStart();
	return { prefix, query: prefix.slice(prefix.startsWith('@"') ? 2 : 1) };
}

// Bare mentions stop before trailing punctuation so "to @foo." still resolves `foo`.
const MENTION = /(^|\s)(?:@"([^"]+)"|@([^\s"]+?))(?=[.,;:!?)]*(?:\s|$))/g;

export function resolveMentions(text: string, targets: Target[]): string {
	const ids = new Map(targets.map((t) => [t.name, t.id]));
	// Unmatched @tokens are file mentions or prose; leave them to pi.
	return text.replace(MENTION, (whole, lead: string, quoted?: string, bare?: string) => {
		const id = ids.get(quoted ?? bare ?? "");
		return id ? `${lead}@herdr:${id}` : whole;
	});
}

export default function herdrMentions(pi: ExtensionAPI): void {
	if (process.env.HERDR_ENV !== "1") return;
	const selfPane = process.env.HERDR_PANE_ID;

	let cache: { at: number; targets: Target[] } | undefined;
	let lastError: string | undefined;

	const herdrResult = async <T>(args: string[]): Promise<T> => {
		const r = await pi.exec("herdr", args, { timeout: 3_000 });
		if (r.code !== 0) throw new Error(`herdr ${args.join(" ")} exited ${r.code}: ${r.stderr.trim()}`);
		return JSON.parse(r.stdout).result as T;
	};

	const loadTargets = async (): Promise<Target[]> => {
		if (cache && Date.now() - cache.at < CACHE_TTL_MS) return cache.targets;
		const [{ workspaces }, { tabs }, { agents }] = await Promise.all([
			herdrResult<{ workspaces: Workspace[] }>(["workspace", "list"]),
			herdrResult<{ tabs: Tab[] }>(["tab", "list"]),
			herdrResult<{ agents: Agent[] }>(["agent", "list"]),
		]);
		cache = { at: Date.now(), targets: buildTargets({ workspaces, tabs, agents }, selfPane) };
		lastError = undefined;
		return cache.targets;
	};

	// Autocomplete runs on every keystroke; report a herdr failure once, not per keypress.
	const reportOnce = (ctx: ExtensionContext, error: unknown) => {
		const message = error instanceof Error ? error.message : String(error);
		if (message === lastError) return;
		lastError = message;
		ctx.ui.notify(`herdr-mentions: ${message}`, "error");
	};

	const toItem = (t: Target): AutocompleteItem => ({
		value: mentionFor(t.name),
		label: t.name,
		description: `herdr ${t.kind} #${t.number} · ${t.status}`,
	});

	// Delegate explicitly: the built-in provider is a class instance, so spreading it drops its methods.
	const wrap =
		(ctx: ExtensionContext) =>
		(current: AutocompleteProvider): AutocompleteProvider => ({
			triggerCharacters: current.triggerCharacters,
			applyCompletion: (...args) => current.applyCompletion(...args),
			shouldTriggerFileCompletion: (...args) => current.shouldTriggerFileCompletion?.(...args) ?? true,
			async getSuggestions(lines, cursorLine, cursorCol, options) {
				const base = await current.getSuggestions(lines, cursorLine, cursorCol, options);
				const mention = mentionQuery((lines[cursorLine] ?? "").slice(0, cursorCol));
				if (!mention) return base;
				let targets: Target[];
				try {
					targets = await loadTargets();
				} catch (error) {
					reportOnce(ctx, error);
					return base;
				}
				if (options.signal.aborted) return base;
				const hits = fuzzyFilter(targets, mention.query, (t) => t.name).slice(0, MAX_SUGGESTIONS).map(toItem);
				if (hits.length === 0) return base;
				return { prefix: mention.prefix, items: [...hits, ...(base?.prefix === mention.prefix ? base.items : [])] };
			},
		});

	pi.on("session_start", async (_event, ctx) => {
		ctx.ui.addAutocompleteProvider(wrap(ctx));
	});

	pi.on("input", async (event, ctx) => {
		if (!event.text.includes("@")) return { action: "continue" };
		cache = undefined;
		let targets: Target[];
		try {
			targets = await loadTargets();
		} catch (error) {
			reportOnce(ctx, error);
			return { action: "continue" };
		}
		const text = resolveMentions(event.text, targets);
		return text === event.text ? { action: "continue" } : { action: "transform", text };
	});
}
