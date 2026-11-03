/**
 * linear: Linear ticket lookup, comments, triage edits and new tickets for
 * alamode.
 *
 * Sessions run pi with its built-in MCP off (--no-mcp, and the agent dir's
 * mcp.json is reclaimed at every start, nix/pkgs/alamode-runtime/session.py),
 * so the MCP servers this laptop already talks to are unreachable from pi and
 * the route is registerTool against Linear's GraphQL API. There is no REST
 * surface to fall back to.
 *
 * The key never enters the session. The wrapper resolves LINEAR_API_KEY
 * outside the sandbox, and only for a session holding the `linear` grant
 * (`--allow-linear`, or a profile naming it); alamode-relay holds it and
 * exports ALAMODE_LINEAR_URL and ALAMODE_LINEAR_TOKEN, a capability for its
 * /tool/linear route. Without the grant the variables are unset and this
 * extension registers nothing, rather than a tool that can only fail.
 *
 * The relay is what bounds writes, since bash in the session can reach the
 * same route with the same token. It passes any query and only the mutations
 * in LINEAR_MUTATIONS (nix/pkgs/alamode-relay/relay.py), compared whole after
 * collapsing whitespace, so COMMENT, UPDATE, CREATE and RELATE below must stay
 * token for token the same as those. The relay also holds every CREATE until
 * the user answers a dialog on the host, so the agent cannot approve its own
 * ticket from bash.
 */

import { Type } from "typebox";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const url = process.env.ALAMODE_LINEAR_URL;
const token = process.env.ALAMODE_LINEAR_TOKEN;

const COMMENT = `mutation Comment($input: CommentCreateInput!) {
  commentCreate(input: $input) { success comment { url } }
}`;

const UPDATE = `mutation Update($id: String!, $input: IssueUpdateInput!) {
  issueUpdate(id: $id, input: $input) { success issue { identifier priorityLabel state { name } assignee { displayName } } }
}`;

const CREATE = `mutation Create($input: IssueCreateInput!) {
  issueCreate(input: $input) { success issue { identifier url } }
}`;

const RELATE = `mutation Relate($input: IssueRelationCreateInput!) {
  issueRelationCreate(input: $input) { success }
}`;

// A hung request mid-ride is dead air with nothing on screen to explain it.
const REQUEST_TIMEOUT_MS = 8000;
// The host dialog gives up after 120 seconds (APPROVAL_SECONDS in
// nix/pkgs/alamode-runtime/session.py), and a name lookup precedes it.
const CREATE_TIMEOUT_MS = 150_000;

const RELATIONS = ["blocks", "related", "duplicate", "similar"] as const;

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

const PRIORITIES: Record<string, number> = {
  none: 0,
  urgent: 1,
  high: 2,
  medium: 3,
  low: 4,
};

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

function checkedIdentifier(raw: string): string {
  const id = normalizeIdentifier(raw);
  if (!IDENTIFIER.test(id)) {
    throw new Error(
      `Not a Linear identifier: ${id}. Expected a team key, a hyphen and a number, such as ENG-123.`,
    );
  }
  return id;
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
  timeoutMs = REQUEST_TIMEOUT_MS,
): Promise<GraphqlResult> {
  const signals = [AbortSignal.timeout(timeoutMs)];
  if (signal) signals.push(signal);

  let response: Response;
  try {
    response = await fetch(url!, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ query, variables }),
      signal: AbortSignal.any(signals),
    });
  } catch (err) {
    const name = err instanceof Error ? err.name : "";
    if (name === "TimeoutError") {
      throw new Error(
        `Linear did not answer within ${timeoutMs / 1000} seconds.`,
      );
    }
    if (signal?.aborted) throw new Error("Cancelled.");
    throw new Error(
      `Linear is unreachable: ${err instanceof Error ? err.message : "network error"}.`,
    );
  }

  if (!response.ok) {
    const body = (await response.text().catch(() => "")).slice(0, 200);
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
  if (!url || !token) return;

  pi.registerTool({
    name: "linear_issue",
    label: "Linear issue",
    description:
      "Read one or more Linear issues by identifier, with description, status, links and recent comments.",
    promptSnippet: "Read Linear issues by identifier, e.g. ENG-123",
    promptGuidelines: [
      "Use linear_issue whenever the user names a ticket identifier such as ENG-123, including when it appears as a git branch or worktree name.",
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

      identifiers.forEach(checkedIdentifier);

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

  pi.registerTool({
    name: "linear_comment",
    label: "Linear comment",
    description:
      "Post a comment on a Linear issue, as the user, visible to everyone who can see the issue.",
    promptSnippet: "Comment on a Linear issue",
    promptGuidelines: [
      "Use linear_comment only when the user asks for a comment on that ticket, and read the body back to them first when it is more than a sentence.",
      "A linear_comment cannot be edited or deleted from here, so post once rather than correcting with a second comment.",
    ],
    parameters: Type.Object({
      identifier: Type.String({
        description: "Issue identifier such as ENG-123.",
      }),
      body: Type.String({
        minLength: 1,
        description: "Comment text in Markdown.",
      }),
    }),
    async execute(_toolCallId, params, signal) {
      const id = checkedIdentifier(params.identifier);
      const { data } = await graphql(
        COMMENT,
        { input: { issueId: id, body: params.body } },
        signal,
      );
      const result = data.commentCreate as {
        success?: boolean;
        comment?: { url?: string } | null;
      } | null;
      if (!result?.success)
        throw new Error(`Linear did not post the comment on ${id}.`);
      return {
        content: [
          {
            type: "text",
            text: `Commented on ${id}: ${result.comment?.url ?? "no url returned"}`,
          },
        ],
        details: { identifier: id },
      };
    },
  });

  pi.registerTool({
    name: "linear_update",
    label: "Linear update",
    description:
      "Change a Linear issue's workflow state, assignee or priority. Nothing else on the issue can be changed from here.",
    promptSnippet: "Move, assign or reprioritize a Linear issue",
    promptGuidelines: [
      "Use linear_update only when the user asks for that change to that ticket.",
      "linear_update takes the state by its name on the issue's team, such as In Progress or Done, and reports the names it accepts when one does not match.",
      "linear_update can assign an issue only to the user or to nobody.",
    ],
    parameters: Type.Object({
      identifier: Type.String({
        description: "Issue identifier such as ENG-123.",
      }),
      state: Type.Optional(
        Type.String({
          description: "Workflow state name, such as In Progress.",
        }),
      ),
      assignee: Type.Optional(
        Type.Union([Type.Literal("me"), Type.Literal("nobody")], {
          description: "me assigns the issue to the user, nobody unassigns it.",
        }),
      ),
      priority: Type.Optional(
        Type.Union(
          Object.keys(PRIORITIES).map((name) => Type.Literal(name)),
          { description: "none, urgent, high, medium or low." },
        ),
      ),
    }),
    async execute(_toolCallId, params, signal) {
      const id = checkedIdentifier(params.identifier);
      if (!params.state && !params.assignee && !params.priority) {
        throw new Error(
          "linear_update needs a state, an assignee or a priority to change.",
        );
      }

      const input: Record<string, unknown> = {};
      if (params.priority) input.priority = PRIORITIES[params.priority];
      if (params.assignee === "nobody") input.assigneeId = null;

      if (params.state || params.assignee === "me") {
        const { data } = await graphql(
          `
            query Target($id: String!) {
              viewer {
                id
              }
              issue(id: $id) {
                team {
                  states {
                    nodes {
                      id
                      name
                    }
                  }
                }
              }
            }
          `,
          { id },
          signal,
        );
        if (params.assignee === "me") {
          const viewer = data.viewer as { id?: string } | null;
          if (!viewer?.id)
            throw new Error("Linear did not say who the user is.");
          input.assigneeId = viewer.id;
        }
        if (params.state) {
          const issue = data.issue as {
            team?: { states?: { nodes?: Array<{ id: string; name: string }> } };
          } | null;
          if (!issue) throw new Error(`No Linear issue found for ${id}.`);
          const states = issue.team?.states?.nodes ?? [];
          const wanted = params.state.trim().toLowerCase();
          const state = states.find((s) => s.name.toLowerCase() === wanted);
          if (!state) {
            throw new Error(
              `${id}'s team has no state named "${params.state}". It has: ${states.map((s) => s.name).join(", ")}.`,
            );
          }
          input.stateId = state.id;
        }
      }

      const { data } = await graphql(UPDATE, { id, input }, signal);
      const result = data.issueUpdate as {
        success?: boolean;
        issue?: Issue | null;
      } | null;
      if (!result?.success || !result.issue) {
        throw new Error(`Linear did not update ${id}.`);
      }
      const issue = result.issue;
      return {
        content: [
          {
            type: "text",
            text: [
              issue.identifier,
              issue.state?.name ?? "unknown state",
              issue.priorityLabel ?? "no priority",
              `assignee ${issue.assignee?.displayName ?? "nobody"}`,
            ].join("  "),
          },
        ],
        details: { identifier: id, changed: Object.keys(input) },
      };
    },
  });

  pi.registerTool({
    name: "linear_create",
    label: "Linear create",
    description:
      "Create a Linear issue as the user. Each create waits on a dialog on the user's screen, and only their click lets it through.",
    promptSnippet: "Create a Linear issue",
    promptGuidelines: [
      "Use linear_create only when the user asks for a new ticket, and show them the title, team, project and description first.",
      "A refused or timed-out linear_create is the user's answer. Do not retry it unless they ask.",
      "linear_create takes the team by key such as ENG, the project and state by name, and the parent by identifier.",
    ],
    parameters: Type.Object({
      team: Type.String({ description: "Team key, such as ENG." }),
      title: Type.String({ minLength: 1, description: "One-line title." }),
      description: Type.Optional(
        Type.String({ description: "Issue body in Markdown." }),
      ),
      project: Type.Optional(
        Type.String({
          description: "Project name on that team, matched ignoring case.",
        }),
      ),
      parent: Type.Optional(
        Type.String({
          description:
            "Parent issue identifier such as ENG-123, which makes this a sub-issue.",
        }),
      ),
      state: Type.Optional(
        Type.String({
          description:
            "Workflow state name, such as Triage or Done. Omit for the team's default.",
        }),
      ),
      assignee: Type.Optional(
        Type.Literal("me", {
          description: "me assigns the issue to the user. Omit for nobody.",
        }),
      ),
      priority: Type.Optional(
        Type.Union(
          Object.keys(PRIORITIES).map((name) => Type.Literal(name)),
          { description: "none, urgent, high, medium or low." },
        ),
      ),
    }),
    async execute(_toolCallId, params, signal) {
      const team = params.team.trim().toUpperCase();
      const project = params.project?.trim();
      const parent = params.parent
        ? checkedIdentifier(params.parent)
        : undefined;

      const declarations = ["$team: String!"];
      const variables: Record<string, unknown> = { team };
      if (project) {
        declarations.push("$project: String!");
        variables.project = project;
      }
      if (parent) {
        declarations.push("$parent: String!");
        variables.parent = parent;
      }
      // Two matches means the name is ambiguous, not that the first is right.
      const { data } = await graphql(
        `query Target(${declarations.join(", ")}) {
          viewer { id }
          team(id: $team) {
            id
            states { nodes { id name } }
            ${project ? "projects(filter: { name: { eqIgnoreCase: $project } }, first: 2) { nodes { id name } }" : ""}
          }
          ${parent ? "parent: issue(id: $parent) { id }" : ""}
        }`,
        variables,
        signal,
      );

      const found = data.team as {
        id?: string;
        states?: { nodes?: Array<{ id: string; name: string }> };
        projects?: { nodes?: Array<{ id: string; name: string }> };
      } | null;
      if (!found?.id) throw new Error(`No Linear team with key ${team}.`);
      const input: Record<string, unknown> = {
        teamId: found.id,
        title: oneLine(params.title),
      };
      if (params.description) input.description = params.description;
      if (params.priority) input.priority = PRIORITIES[params.priority];

      if (project) {
        const matches = found.projects?.nodes ?? [];
        if (matches.length !== 1) {
          throw new Error(
            matches.length === 0
              ? `${team} has no project named "${project}".`
              : `More than one ${team} project is named "${project}".`,
          );
        }
        input.projectId = matches[0].id;
      }
      if (parent) {
        const issue = data.parent as { id?: string } | null;
        if (!issue?.id) throw new Error(`No Linear issue found for ${parent}.`);
        input.parentId = issue.id;
      }
      if (params.state) {
        const states = found.states?.nodes ?? [];
        const wanted = params.state.trim().toLowerCase();
        const state = states.find((s) => s.name.toLowerCase() === wanted);
        if (!state) {
          throw new Error(
            `${team} has no state named "${params.state}". It has: ${states.map((s) => s.name).join(", ")}.`,
          );
        }
        input.stateId = state.id;
      }
      if (params.assignee === "me") {
        const viewer = data.viewer as { id?: string } | null;
        if (!viewer?.id) throw new Error("Linear did not say who the user is.");
        input.assigneeId = viewer.id;
      }

      const { data: created } = await graphql(
        CREATE,
        { input },
        signal,
        CREATE_TIMEOUT_MS,
      );
      const result = created.issueCreate as {
        success?: boolean;
        issue?: { identifier?: string; url?: string } | null;
      } | null;
      if (!result?.success || !result.issue?.identifier) {
        throw new Error(`Linear did not create the ${team} issue.`);
      }
      return {
        content: [
          {
            type: "text",
            text: `Created ${result.issue.identifier}: ${result.issue.url ?? "no url returned"}`,
          },
        ],
        details: { identifier: result.issue.identifier },
      };
    },
  });

  pi.registerTool({
    name: "linear_relate",
    label: "Linear relate",
    description:
      "Link two Linear issues: one blocks the other, or they are related, duplicates or similar.",
    promptSnippet: "Link two Linear issues",
    promptGuidelines: [
      "Use linear_relate only when the user asks for the link, or as part of filing a ticket they approved.",
      "With type blocks, issue is the one doing the blocking and related is the one it blocks.",
    ],
    parameters: Type.Object({
      issue: Type.String({ description: "Issue identifier such as ENG-123." }),
      related: Type.String({
        description: "The other issue's identifier, such as ENG-124.",
      }),
      type: Type.Union(
        RELATIONS.map((name) => Type.Literal(name)),
        { description: "blocks, related, duplicate or similar." },
      ),
    }),
    async execute(_toolCallId, params, signal) {
      const a = checkedIdentifier(params.issue);
      const b = checkedIdentifier(params.related);
      if (a === b) throw new Error("An issue cannot be related to itself.");
      const { data } = await graphql(
        `
          query Pair($a: String!, $b: String!) {
            a: issue(id: $a) {
              id
            }
            b: issue(id: $b) {
              id
            }
          }
        `,
        { a, b },
        signal,
      );
      const ids = [data.a, data.b].map(
        (i) => (i as { id?: string } | null)?.id,
      );
      const missing = [a, b].filter((_, i) => !ids[i]);
      if (missing.length > 0) {
        throw new Error(`No Linear issue found for ${missing.join(", ")}.`);
      }

      const { data: linked } = await graphql(
        RELATE,
        {
          input: { issueId: ids[0], relatedIssueId: ids[1], type: params.type },
        },
        signal,
      );
      const result = linked.issueRelationCreate as { success?: boolean } | null;
      if (!result?.success) {
        throw new Error(`Linear did not link ${a} and ${b}.`);
      }
      return {
        content: [{ type: "text", text: `${a} ${params.type} ${b}.` }],
        details: { issue: a, related: b, type: params.type },
      };
    },
  });
}
