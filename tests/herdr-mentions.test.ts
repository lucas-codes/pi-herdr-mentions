import assert from "node:assert/strict";
import { test } from "node:test";

import { buildTargets, displayName, mentionQuery, resolveMentions } from "../extensions/herdr-mentions.ts";

const workspaceOf = (id: string) => id.slice(0, id.indexOf(":"));
const ws = (workspace_id: string, number: number, label: string) => ({ workspace_id, number, label, agent_status: "idle" });
const tab = (tab_id: string, label: string) => ({ tab_id, workspace_id: workspaceOf(tab_id), label, agent_status: "idle" });
const agent = (pane_id: string, kind: string, title: string) => ({
	pane_id,
	workspace_id: workspaceOf(pane_id),
	agent: kind,
	agent_status: "idle",
	terminal_title_stripped: title,
});

test("displayName drops herdr worktree chrome", () => {
	assert.equal(displayName("└ ED-20911__codex-review-spike · p:F9-jDqSvFd_Srld0BqIoOw"), "ED-20911__codex-review-spike");
	assert.equal(displayName("firstmate"), "firstmate");
});

test("buildTargets lists tabs and agents only for workspaces that have several", () => {
	const targets = buildTargets(
		{
			workspaces: [ws("w1", 1, "solo"), ws("w2", 2, "multi")],
			tabs: [tab("w1:t1", "only"), tab("w2:t1", "1 · pi › π - BIG BRAINS"), tab("w2:t2", "notes")],
			agents: [agent("w1:p1", "pi", "π - solo"), agent("w2:p1", "pi", "π - firstmate"), agent("w2:p2", "claude", "review")],
		},
		undefined,
	);
	assert.deepEqual(
		targets.map((t) => [t.name, t.id]),
		[
			["solo", "w1"],
			["multi", "w2"],
			["multi / π - BIG BRAINS", "w2:t1"],
			["multi / notes", "w2:t2"],
			["multi / pi · π - firstmate", "w2:p1"],
			["multi / claude · review", "w2:p2"],
		],
	);
});

test("buildTargets leaves out the sender's own pane", () => {
	const targets = buildTargets(
		{
			workspaces: [ws("w1", 1, "home")],
			tabs: [tab("w1:t1", "main")],
			agents: [agent("w1:p1", "pi", "π - dev"), agent("w1:p2", "claude", "me"), agent("w1:p3", "pi", "π - api")],
		},
		"w1:p2",
	);
	assert.deepEqual(
		targets.filter((t) => t.kind === "agent").map((t) => t.id),
		["w1:p1", "w1:p3"],
	);
});

test("clashing names get a short id suffix that does not depend on list order", () => {
	const data = {
		workspaces: [ws("w1", 1, "home"), ws("w2", 2, "dup"), ws("w3", 3, "└ dup · p:abc")],
		tabs: [],
		agents: [agent("w1:p5H", "pi", "π - dev"), agent("w1:p5K", "pi", "π - dev")],
	};
	const names = (d: typeof data) => Object.fromEntries(buildTargets(d, undefined).map((t) => [t.id, t.name]));
	const forward = names(data);
	assert.deepEqual(forward, {
		w1: "home",
		w2: "dup · w2",
		w3: "dup · w3",
		"w1:p5H": "home / pi · π - dev · p5H",
		"w1:p5K": "home / pi · π - dev · p5K",
	});
	assert.deepEqual(names({ ...data, agents: [...data.agents].reverse(), workspaces: [...data.workspaces].reverse() }), forward);
});

test("mentionQuery finds the @token being typed", () => {
	assert.deepEqual(mentionQuery("Dispatch to @fooz"), { prefix: "@fooz", query: "fooz" });
	assert.deepEqual(mentionQuery("@"), { prefix: "@", query: "" });
	assert.deepEqual(mentionQuery('ask @"fooz-barz / pi'), { prefix: '@"fooz-barz / pi', query: "fooz-barz / pi" });
	assert.equal(mentionQuery("mail me@example"), undefined);
	assert.equal(mentionQuery("@done and more"), undefined);
});

test("resolveMentions swaps herdr names for namespaced ids and leaves other @tokens alone", () => {
	const targets = buildTargets(
		{
			workspaces: [ws("w3V", 1, "fooz-barz")],
			tabs: [],
			agents: [agent("w3V:p5H", "pi", "π - dev"), agent("w3V:p5K", "pi", "π - api")],
		},
		undefined,
	);
	assert.equal(
		resolveMentions('Dispatch to @fooz-barz and @"fooz-barz / pi · π - dev", see @src/index.ts', targets),
		"Dispatch to @herdr:w3V and @herdr:w3V:p5H, see @src/index.ts",
	);
	assert.equal(resolveMentions("Hand this to @fooz-barz.", targets), "Hand this to @herdr:w3V.");
	assert.equal(resolveMentions("no mentions here", targets), "no mentions here");
});
