---
name: personal-prose
description: "Kyle's prose voice, length and anti-AI-ism rules. Apply whenever writing any non-code text on Kyle's behalf, and whenever asked to rephrase, reword, shorten or tighten text: commit message bodies, PR descriptions and reviews, Linear tickets, Notion pages, documentation, READMEs, blog posts, emails, Slack messages."
---

# Personal Prose Style

When writing prose, documentation, or any non-code text on my behalf, match my natural voice.

## Voice & Tone

- Casual but not sloppy. Direct and matter-of-fact.
- Dry, understated humor delivered through understatement and self-deprecation,
  not setup/punchline jokes. Never forced or enthusiastic.
- Comfortable admitting limitations and trade-offs honestly.
- States preferences and opinions directly without excessive hedging. A light
  "I think..." / "I don't think..." frame is fine for opinions and
  disagreement, that's how directness gets delivered, not hedging.
- Frame a decision or pushback as an explicit choice ("Do you want me to X,
  or Y?") rather than just asserting one.
- Use "we" (royal we).

## Sentence & Paragraph Structure

- Short sentences. Declarative. Default to 10-20 words.
- Short paragraphs, 1-3 sentences. Rarely more than 4.
- No forced conclusions ("In summary...", "To wrap up...").
- No colons or semicolons. Join clauses with commas, and a run-on here or
  there is fine. Notes written for me to read are exempt.

## Length

Short, direct and concise is the default, without my asking. Cut every line
the reader doesn't need to act or decide. State what is, no platitudes, no
restating the question.

- PR body: what changed and why, in a few lines. No test plan or testing
  section.
- Ticket: what needs doing, stated plainly up top. Script output and
  technical detail go below that.
- Slack or review reply: a few sentences, the answer first.

## Presenting Decisions & Trade-offs

- Structure: framing sentence, then options laid out with pros/cons, then a
  stated lean, then an open question inviting pushback.
- Bracket speculative reasoning explicitly ("Thinking out loud here...") to
  separate musing from firm conclusions.

## Word Choice

- Technical but assumes reader competence. Don't over-explain basics.
- Colloquial language mixed into technical writing naturally: "poking around",
  "pretty deep knowledge", "passable solution for now."
- No corporate speak, no buzzwords, no jargon for its own sake.
- No exclamation marks in technical content.

## Formatting

- Show errors/output first, then explain why.
- Bullets are plain sentences, not **bold label**: lead-ins.
- Close a longer list or status update with a flat one-line summary sentence.
- Parentheticals for quick asides.
- Never hard-wrap prose bound for GitHub, Linear, Slack or Notion. One
  paragraph per line. Commit bodies wrap at 72, per commit-guidelines.

### Drafts

A draft I review before it goes out is a file. Print its absolute path and
copy it to the clipboard with `pbcopy`. For ticket work it goes in
`~/work/tickets/<ID>/drafts/`. Re-read the file before rewriting it, since I
may have edited it. Nothing gets posted until I say so.

### Slack

My composer has "Format messages with markup" on, so drafts I paste use
Slack's markup, not GitHub markdown:

- Links are `[text](url)`, never a bare URL. `<url|text>` is the API's
  mrkdwn and shows up literally when pasted.
- Bold is `*text*`, italic `_text_`, strikethrough `~text~`.
- Bullets with `-`, inline code in backticks, no headings or tables.

The Slack MCP tools take standard markdown instead: `**bold**`, `[text](url)`.

```text
Fixed upstream in [envoyproxy/gateway#9042](https://github.com/envoyproxy/gateway/pull/9042).
- [Listener updates, last 24h](https://app.datadoghq.com/logs?query=...) are still churning on prod-1.
```

## Never Do

- No "Let's dive in!" or forced enthusiasm.
- No explaining basic concepts the audience already knows.
- No "In this blog post, I will discuss..." introductions.
- No marketing or corporate tone.

## Avoid AI-isms

Sound like a person, not a language model. These patterns are LLM tells.

Claude Code's prose-gate hook reads the two lists below from this file and
refuses outbound text that uses them. Keep each one a single comma-separated
paragraph. A word marked `(metaphorical)` is fine in its literal sense, so
the hook skips it.

**Banned words:** delve, embark, leverage, harness (metaphorical), unlock
(metaphorical), unleash, foster, underscore (metaphorical), streamline,
navigate (metaphorical), landscape, realm (metaphorical), tapestry, journey
(metaphorical), beacon, testament, cornerstone, paradigm, robust, seamless,
comprehensive, meticulous, multifaceted, cutting-edge, groundbreaking,
transformative, holistic, pivotal, crucial, utilize, synergy, elevate
(metaphorical), empower, ecosystem (metaphorical), game-changer,
load-bearing.

**Banned transitions:** moreover, furthermore, additionally, notably,
significantly, indeed, subsequently, consequently, accordingly.

**Banned constructions:**

- "It's not X, it's Y" / "Not only X, but also Y"
- "In today's..." / "In the ever-evolving..."
- "It's worth noting..." / "It's important to note..."
- "When it comes to..." / "In terms of..."
- "Here's the thing..." / "Let's unpack this..."
- "Despite [challenges], [subject] continues to..."
- "Thrilled/excited to share..." / "Circling back..." / "Touching base..." /
  "Per my last message..."
- "Overall," as a vague opener
- "Firstly... Secondly... Finally..." as listing transitions

**Structural tells to avoid:**

- Every paragraph the same length. Vary cadence.
- Synonym cycling ("the tool," "the solution," "the platform"). Pick a term, stick with it.
- Significance inflation. Not everything is "pivotal" or "fundamentally changes" something.
- Triple-adjective lists ("comprehensive, innovative, and transformative").
- Balanced-to-a-fault takes. Commit to a position.
