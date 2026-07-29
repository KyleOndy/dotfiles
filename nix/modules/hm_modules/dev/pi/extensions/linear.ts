/**
 * linear: read-only Linear ticket lookup for the pi coding agent.
 *
 * pi 0.82.1 has no MCP support, so the MCP servers this laptop already talks
 * to are unreachable from pi and the route is registerTool against Linear's
 * GraphQL API. There is no REST surface to fall back to.
 *
 * The call goes out from inside the sandbox with a plain fetch. pi ships as a
 * Bun binary and srt injects HTTP_PROXY / HTTPS_PROXY plus the CA-trust
 * variables into the sandboxed child, so fetch traverses srt's filtering proxy
 * and the domain allowlist applies to it. Under seatbelt the child has loopback
 * and nothing else, which is also why the domain has to be granted explicitly:
 * `--allow-linear`, from the networkBundles entry on the host that holds the
 * credential. domestique passes it on every ride.
 *
 * Read-only describes this tool surface, not the session. The credential is a
 * personal API key carrying write scope, so a bash call to the same domain can
 * mutate. The egress bundle is the control that binds; without the domain the
 * key is inert.
 *
 * LINEAR_API_KEY arrives through the wrapper's envFromCommands, which resolves
 * it from the Keychain outside the sandbox. The wrapper scrubs anything
 * matching *_API_KEY that merely leaked in from the caller's shell, so a plain
 * shell export does not reach here. It is read once at registration and
 * dropped from process.env, which under Bun is a reduction rather than a
 * boundary: process.env is a view, and a child that inherits the environment
 * still carries the key.
 */

import { Type } from "typebox";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const ENDPOINT = "https://api.linear.app/graphql";

// A hung request mid-ride is dead air with nothing on screen to explain it.
const REQUEST_TIMEOUT_MS = 8000;

// Caps live here rather than in the ride system prompt: a real ticket runs
// several thousand characters, and every one of them slows later turns.
const DESCRIPTION_CHARS = 1200;
const COMMENT_CHARS = 300;
const COMMENTS_SHOWN = 5;

// An epic carries more sub-issues than are worth reading back, and a cap that
// truncates in silence reads as a complete list. So the query asks for one past
// the display limit, and the extra node is what reports the rest exist.
const CHILDREN_SHOWN = 5;

const SEARCH_RESULTS = 10;
const MAX_IDENTIFIERS = 5;

const IDENTIFIER = /^[A-Za-z][A-Za-z0-9]*-\d+$/;

let apiKey = "";

const DETAIL_FRAGMENT = `
  fragment Detail on Issue {
    identifier
    title
    url
    branchName
    priorityLabel
    updatedAt
    description
    state { name }
    assignee { displayName }
    team { key }
    project { name }
    labels(first: 10) { nodes { name } }
    parent { identifier title }
    children(first: ${CHILDREN_SHOWN + 1}) { nodes { identifier title } }
    attachments(first: 10) { nodes { title url } }
    comments(last: ${COMMENTS_SHOWN}) {
      nodes { body createdAt user { displayName } }
    }
  }`;

const SUMMARY_FRAGMENT = `
  fragment Summary on Issue {
    identifier
    title
    priorityLabel
    updatedAt
    state { name }
    assignee { displayName }
    team { key }
  }`;

interface Issue {
  identifier: string;
  title: string;
  url?: string;
  branchName?: string;
  priorityLabel?: string;
  updatedAt?: string;
  description?: string | null;
  state?: { name?: string } | null;
  assignee?: { displayName?: string } | null;
  team?: { key?: string } | null;
  project?: { name?: string } | null;
  labels?: { nodes?: Array<{ name?: string }> } | null;
  parent?: { identifier?: string; title?: string } | null;
  children?: { nodes?: Array<{ identifier?: string; title?: string }> } | null;
  attachments?: { nodes?: Array<{ title?: string; url?: string }> } | null;
  comments?: {
    nodes?: Array<{
      body?: string;
      createdAt?: string;
      user?: { displayName?: string } | null;
    }>;
  } | null;
}

/** Models pass "#ENG-123" and "eng-123:" often enough to be worth it. */
function normalizeIdentifier(raw: string): string {
  return raw
    .trim()
    .replace(/^#/, "")
    .replace(/[:,.]$/, "")
    .toUpperCase();
}

/** Ticket prose, quoted so it cannot pose as this tool's own output. Anyone
 * with ticket access writes it, and it lands in the channel that also carries
 * the section separator and the `not found:` line. */
function quote(text: string): string {
  return text.replace(/^/gm, "| ");
}

/** Ticket text for a field this renderer puts on one line. */
function oneLine(text: string): string {
  return text.replace(/\s+/g, " ").trim();
}

function clamp(text: string, limit: number): string {
  const trimmed = text.trim();
  if (trimmed.length <= limit) return trimmed;
  return `${trimmed.slice(0, limit)}\n[truncated at ${limit} characters, full text is in Linear]`;
}

function day(iso: string | undefined): string {
  return iso ? iso.slice(0, 10) : "unknown";
}

interface GraphqlResult {
  data: Record<string, unknown>;
  errors: string[];
}

async function graphql(
  query: string,
  variables: Record<string, unknown>,
  signal: AbortSignal | undefined,
): Promise<GraphqlResult> {
  const signals = [AbortSignal.timeout(REQUEST_TIMEOUT_MS)];
  if (signal) signals.push(signal);

  let response: Response;
  try {
    response = await fetch(ENDPOINT, {
      method: "POST",
      headers: {
        // Linear's personal API keys go in Authorization bare. A Bearer prefix
        // is not what the docs specify.
        Authorization: apiKey,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ query, variables }),
      signal: AbortSignal.any(signals),
    });
  } catch (err) {
    const name = err instanceof Error ? err.name : "";
    if (name === "TimeoutError") {
      throw new Error(
        `Linear did not answer within ${REQUEST_TIMEOUT_MS / 1000} seconds.`,
      );
    }
    if (signal?.aborted) throw new Error("Cancelled.");
    throw new Error(
      `Linear is unreachable: ${err instanceof Error ? err.message : "network error"}.`,
    );
  }

  if (!response.ok) {
    const body = (await response.text().catch(() => "")).slice(0, 200);
    // A domain outside the allowlist comes back as an ordinary 403 from srt's
    // filtering proxy rather than as a refused connection, so the denied case
    // lands here and never reaches the catch above. Linear's own 403 is JSON,
    // which is what keeps the two apart.
    if (/network allowlist/i.test(body)) {
      throw new Error(
        "api.linear.app is not in this session's network allowlist. Pass --allow-linear, which ride mode does by default.",
      );
    }
    throw new Error(
      `Linear returned HTTP ${response.status}. ${body || "No body."}`,
    );
  }

  const payload = (await response.json()) as {
    data?: Record<string, unknown>;
    errors?: Array<{ message?: string }>;
  };

  // GraphQL reports failure inside a 200, and a partial result carries both
  // data and errors. Reading only the status would make a failed lookup look
  // like an empty one, which is the class of bug that keeps biting this project.
  const errors = (payload.errors ?? [])
    .map((e) => e.message)
    .filter((m): m is string => typeof m === "string" && m.length > 0);
  if (!payload.data) {
    throw new Error(
      `Linear rejected the query. ${errors.join("; ") || "No message."}`,
    );
  }
  return { data: payload.data, errors };
}

function renderDetail(issue: Issue): string {
  const lines: string[] = [];

  lines.push(
    [
      issue.identifier,
      issue.state?.name ?? "unknown state",
      issue.priorityLabel ?? "no priority",
      `assignee ${issue.assignee?.displayName ?? "nobody"}`,
      `updated ${day(issue.updatedAt)}`,
    ].join("  "),
  );
  lines.push(`title: ${oneLine(issue.title)}`);

  if (issue.project?.name)
    lines.push(`project: ${oneLine(issue.project.name)}`);

  const labels = (issue.labels?.nodes ?? [])
    .map((l) => (l.name ? oneLine(l.name) : ""))
    .filter(Boolean);
  if (labels.length > 0) lines.push(`labels: ${labels.join(", ")}`);

  if (issue.parent?.identifier) {
    lines.push(
      `parent: ${issue.parent.identifier} ${oneLine(issue.parent.title ?? "")}`,
    );
  }

  const children = (issue.children?.nodes ?? []).filter((c) => c.identifier);
  if (children.length > 0) {
    const shown = children
      .slice(0, CHILDREN_SHOWN)
      .map((c) => `${c.identifier} ${oneLine(c.title ?? "")}`)
      .join("; ");
    const more =
      children.length > CHILDREN_SHOWN ? "; more sub-issues not shown" : "";
    lines.push(`sub-issues: ${shown}${more}`);
  }

  if (issue.branchName) lines.push(`branch: ${issue.branchName}`);
  if (issue.url) lines.push(`url: ${issue.url}`);

  // The attachments are the pull request links, which is what answers "what is
  // on that branch" without a second tool.
  const links = (issue.attachments?.nodes ?? []).filter((a) => a.url);
  if (links.length > 0) {
    lines.push("links:");
    for (const link of links) {
      lines.push(
        `  ${link.title ? oneLine(link.title) : "untitled"}: ${link.url}`,
      );
    }
  }

  const description = issue.description?.trim();
  lines.push("description, as written on the ticket:");
  lines.push(
    description ? quote(clamp(description, DESCRIPTION_CHARS)) : "  (empty)",
  );

  const comments = issue.comments?.nodes ?? [];
  if (comments.length > 0) {
    lines.push(`comments (${comments.length} most recent):`);
    for (const comment of comments) {
      const who = oneLine(comment.user?.displayName ?? "unknown");
      lines.push(`  ${who}, ${day(comment.createdAt)}:`);
      lines.push(quote(clamp(comment.body ?? "", COMMENT_CHARS)));
    }
  }

  return lines.join("\n");
}

function renderSummary(issue: Issue): string {
  return [
    issue.identifier,
    issue.state?.name ?? "unknown state",
    issue.priorityLabel ?? "no priority",
    oneLine(issue.assignee?.displayName ?? "nobody"),
    day(issue.updatedAt),
    oneLine(issue.title),
  ].join("  ");
}

export default function (pi: ExtensionAPI) {
  // A host without the credential shows no tool at all, rather than a tool the
  // model will reach for and that can only fail.
  const resolved = process.env.LINEAR_API_KEY;
  if (!resolved) return;
  apiKey = resolved;
  delete process.env.LINEAR_API_KEY;

  pi.registerTool({
    name: "linear_issue",
    label: "Linear issue",
    description:
      "Read one or more Linear issues by identifier, with description, status, links and recent comments.",
    promptSnippet: "Read Linear issues by identifier, e.g. ENG-123",
    promptGuidelines: [
      "Use linear_issue whenever the user names a ticket identifier such as ENG-123, including when it appears as a git branch or worktree name.",
      "linear_issue is read-only. There is no way to comment on or modify a Linear issue from here.",
      "linear_issue truncates long descriptions and returns only the newest comments, so do not treat its output as the complete ticket.",
    ],
    parameters: Type.Object({
      identifiers: Type.Array(Type.String(), {
        minItems: 1,
        maxItems: MAX_IDENTIFIERS,
        description:
          "Linear issue identifiers such as ENG-123. Team key, hyphen, number.",
      }),
    }),
    async execute(_toolCallId, params, signal) {
      const identifiers = [
        ...new Set(params.identifiers.map(normalizeIdentifier)),
      ];

      const malformed = identifiers.filter((id) => !IDENTIFIER.test(id));
      if (malformed.length > 0) {
        throw new Error(
          `Not Linear identifiers: ${malformed.join(", ")}. Expected a team key, a hyphen and a number, such as ENG-123.`,
        );
      }

      // Aliases keep a multi-ticket question to one round trip. Identifiers ride
      // as variables rather than interpolated query text.
      const declarations = identifiers
        .map((_, i) => `$id${i}: String!`)
        .join(", ");
      const selections = identifiers
        .map((_, i) => `i${i}: issue(id: $id${i}) { ...Detail }`)
        .join("\n    ");
      const { data, errors } = await graphql(
        `query Issues(${declarations}) {\n    ${selections}\n  }\n  ${DETAIL_FRAGMENT}`,
        Object.fromEntries(identifiers.map((id, i) => [`id${i}`, id])),
        signal,
      );

      const found: Issue[] = [];
      const missing: string[] = [];
      identifiers.forEach((id, i) => {
        const issue = data[`i${i}`] as Issue | null | undefined;
        if (issue?.identifier) found.push(issue);
        else missing.push(id);
      });

      if (found.length === 0) {
        const why = errors.join("; ");
        throw new Error(
          `No Linear issue found for ${identifiers.join(", ")}.${why ? ` ${why}` : ""}`,
        );
      }

      // One typo among several identifiers still answers the rest, which on a
      // ride is the difference between an answer and starting over.
      const sections = found.map(renderDetail);
      if (missing.length > 0) {
        // A null alias is as often a permission or rate-limit error as a typo,
        // and reporting only "not found" tells the rider a ticket does not
        // exist when the key simply cannot see it.
        const why = errors.length > 0 ? ` (${errors.join("; ")})` : "";
        sections.push(`not found: ${missing.join(", ")}${why}`);
      }

      return {
        content: [{ type: "text", text: sections.join("\n\n---\n\n") }],
        details: { found: found.length, missing },
      };
    },
  });

  pi.registerTool({
    name: "linear_search",
    label: "Linear search",
    description:
      "Find Linear issues by words in the title or description, or list the issues assigned to the current user.",
    promptSnippet:
      "Search Linear issues by text, or list what is assigned to the user",
    promptGuidelines: [
      "Use linear_search when the user describes a ticket by topic rather than by identifier, then linear_issue on the identifier it returns for detail.",
      "Call linear_search with assignedToMe and no query to answer what the user is currently working on.",
      "linear_search returns one line per issue and no description, so it cannot answer what a ticket is about on its own.",
    ],
    parameters: Type.Object({
      query: Type.Optional(
        Type.String({
          description:
            "Words to match against issue titles and descriptions. Omit to list without filtering.",
        }),
      ),
      assignedToMe: Type.Optional(
        Type.Boolean({
          description:
            "Restrict to issues assigned to the API key's own user. Defaults to false.",
        }),
      ),
    }),
    async execute(_toolCallId, params, signal) {
      const term = params.query?.trim();
      if (!term && !params.assignedToMe) {
        throw new Error(
          "linear_search needs either a query or assignedToMe, otherwise it would return arbitrary issues.",
        );
      }

      // containsIgnoreCase over title and description rather than a search
      // endpoint: the filter syntax is the stable part of Linear's API.
      const filter = term
        ? `filter: { or: [ { title: { containsIgnoreCase: $term } }, { description: { containsIgnoreCase: $term } } ] },`
        : "";
      const declarations = term ? "($term: String!)" : "";
      const connection = `(${filter} first: ${SEARCH_RESULTS}, orderBy: updatedAt) { nodes { ...Summary } }`;

      const { data } = await graphql(
        params.assignedToMe
          ? `query Search${declarations} {\n    viewer { assignedIssues${connection} }\n  }\n  ${SUMMARY_FRAGMENT}`
          : `query Search${declarations} {\n    issues${connection}\n  }\n  ${SUMMARY_FRAGMENT}`,
        term ? { term } : {},
        signal,
      );

      const root = params.assignedToMe
        ? (data.viewer as { assignedIssues?: { nodes?: Issue[] } } | null)
            ?.assignedIssues
        : (data.issues as { nodes?: Issue[] } | null);
      const issues = root?.nodes ?? [];

      if (issues.length === 0) {
        return {
          content: [
            {
              type: "text",
              text: term
                ? `No Linear issues matching "${term}".`
                : "No Linear issues assigned.",
            },
          ],
          details: { count: 0 },
        };
      }

      const header = `${issues.length} issue(s), newest first. Columns: identifier, state, priority, assignee, updated, title.`;
      return {
        content: [
          {
            type: "text",
            text: [header, ...issues.map(renderSummary)].join("\n"),
          },
        ],
        details: { count: issues.length },
      };
    },
  });
}
