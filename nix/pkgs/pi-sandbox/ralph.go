package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

func mainRalph() int {
	args := os.Args[2:]
	if len(args) >= 1 && args[0] == "spec" {
		return mainRalphSpec(args[1:])
	}

	fs := flag.NewFlagSet("ralph", flag.ExitOnError)
	maxIter := fs.Int("max-iter", 10, "maximum iterations before giving up")
	workDir := fs.String("work-dir", "", "resume a previous run (path to existing work dir)")

	fs.Usage = func() {
		fmt.Fprintln(os.Stderr, "usage: pi-sandbox ralph <model> <spec-file> [flags]")
		fmt.Fprintln(os.Stderr, "       pi-sandbox ralph spec <model> <description> [-o spec.md]")
		fmt.Fprintln(os.Stderr, "")
		fmt.Fprintln(os.Stderr, "flags:")
		fs.PrintDefaults()
	}

	if len(args) < 2 {
		fs.Usage()
		return 2
	}
	model := args[0]
	specFile := args[1]
	fs.Parse(args[2:])

	provider, err := resolveProvider(model)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[ralph] error: %v\n", err)
		return 1
	}

	if provider == "ollama" {
		if err := ensureModel(model); err != nil {
			fmt.Fprintf(os.Stderr, "[ralph] error: %v\n", err)
			return 1
		}
	}

	dir := *workDir
	if dir == "" {
		d, err := createRalphWorkDir()
		if err != nil {
			fmt.Fprintf(os.Stderr, "[ralph] error: %v\n", err)
			return 1
		}
		dir = d

		if err := copySpecFile(specFile, dir); err != nil {
			fmt.Fprintf(os.Stderr, "[ralph] error: %v\n", err)
			return 1
		}
	} else {
		if err := validateWorkDir(dir); err != nil {
			fmt.Fprintf(os.Stderr, "[ralph] error: %v\n", err)
			return 1
		}
	}

	startIter := nextIteration(dir)

	for i := startIter; i < startIter+*maxIter; i++ {
		fmt.Fprintf(os.Stderr, "\n[ralph] === iteration %d (max %d from start) ===\n", i, *maxIter)

		prompt, err := buildIterationPrompt(dir, i)
		if err != nil {
			fmt.Fprintf(os.Stderr, "[ralph] error building prompt: %v\n", err)
			return 1
		}

		exitCode, err := runOnce(model, provider, prompt, dir, i)
		if err != nil {
			fmt.Fprintf(os.Stderr, "[ralph] iteration %d error: %v\n", i, err)
		} else if exitCode != 0 {
			fmt.Fprintf(os.Stderr, "[ralph] iteration %d exited with code %d, continuing\n", i, exitCode)
		}

		if _, err := os.Stat(filepath.Join(dir, "DONE")); err == nil {
			fmt.Fprintf(os.Stderr, "\n[ralph] DONE marker found after iteration %d\n", i)
			fmt.Fprintf(os.Stderr, "[ralph] work dir: %s\n", dir)
			return 0
		}
	}

	fmt.Fprintf(os.Stderr, "\n[ralph] max iterations reached without completion\n")
	fmt.Fprintf(os.Stderr, "[ralph] work dir: %s\n", dir)
	return 1
}

func copySpecFile(src, workDir string) error {
	data, err := os.ReadFile(src)
	if err != nil {
		return fmt.Errorf("read spec file %s: %w", src, err)
	}
	dst := filepath.Join(workDir, "SPEC.md")
	if err := os.WriteFile(dst, data, 0644); err != nil {
		return fmt.Errorf("write SPEC.md: %w", err)
	}
	return nil
}

func nextIteration(workDir string) int {
	matches, _ := filepath.Glob(filepath.Join(workDir, "events.*.jsonl"))
	return len(matches) + 1
}

func mainRalphSpec(args []string) int {
	fs := flag.NewFlagSet("ralph spec", flag.ExitOnError)
	outFile := fs.String("o", "spec.md", "output file for generated spec")

	fs.Usage = func() {
		fmt.Fprintln(os.Stderr, "usage: pi-sandbox ralph spec <model> <description> [-o spec.md]")
		fmt.Fprintln(os.Stderr, "")
		fmt.Fprintln(os.Stderr, "flags:")
		fs.PrintDefaults()
	}

	if len(args) < 2 {
		fs.Usage()
		return 2
	}
	model := args[0]
	description := args[1]
	fs.Parse(args[2:])

	provider, err := resolveProvider(model)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[ralph spec] error: %v\n", err)
		return 1
	}

	if provider == "ollama" {
		if err := ensureModel(model); err != nil {
			fmt.Fprintf(os.Stderr, "[ralph spec] error: %v\n", err)
			return 1
		}
	}

	workDir, err := os.MkdirTemp("/tmp", "pi-ralph-spec-")
	if err != nil {
		fmt.Fprintf(os.Stderr, "[ralph spec] error: %v\n", err)
		return 1
	}
	defer os.RemoveAll(workDir)

	prompt := buildSpecPrompt(description)

	exitCode, err := runOnce(model, provider, prompt, workDir, 0)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[ralph spec] error: %v\n", err)
		return 1
	}
	if exitCode != 0 {
		fmt.Fprintf(os.Stderr, "[ralph spec] agent exited with code %d\n", exitCode)
		return exitCode
	}

	specPath := filepath.Join(workDir, "spec.md")
	data, err := os.ReadFile(specPath)
	if err != nil {
		// Agent output text instead of writing a file. Extract from event log.
		text, extractErr := extractTextFromEvents(filepath.Join(workDir, "events.jsonl"))
		if extractErr != nil || strings.TrimSpace(text) == "" {
			fmt.Fprintf(os.Stderr, "[ralph spec] agent did not write spec.md and no text output found\n")
			return 1
		}
		data = []byte(text)
		fmt.Fprintf(os.Stderr, "[ralph spec] captured spec from agent text output\n")
	}

	if dir := filepath.Dir(*outFile); dir != "." {
		os.MkdirAll(dir, 0755)
	}
	if err := os.WriteFile(*outFile, data, 0644); err != nil {
		fmt.Fprintf(os.Stderr, "[ralph spec] error writing %s: %v\n", *outFile, err)
		return 1
	}

	fmt.Fprintf(os.Stderr, "[ralph spec] wrote %s\n", *outFile)
	return 0
}

func extractTextFromEvents(eventsPath string) (string, error) {
	f, err := os.Open(eventsPath)
	if err != nil {
		return "", err
	}
	defer f.Close()

	var text strings.Builder
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 0, 256*1024), 256*1024)

	for scanner.Scan() {
		var ev piEvent
		if err := json.Unmarshal(scanner.Bytes(), &ev); err != nil {
			continue
		}
		if ev.Type == "message_update" && ev.AssistantMessageEvent != nil && ev.AssistantMessageEvent.Type == "text_delta" {
			text.WriteString(ev.AssistantMessageEvent.Delta)
		}
	}
	return text.String(), scanner.Err()
}

func buildSpecPrompt(description string) string {
	return `Generate a task specification for an autonomous coding agent.
The agent works through tasks one at a time in separate iterations with
no memory between iterations except files on disk.

Based on this description:

` + description + `

Write a file called spec.md with this structure:

# {Project Title}

## Tasks

Number each task in dependency order. Each task should be completable
in a single agent iteration. Be specific about what to build, what
files to create, and what the expected behavior is.

1. First task
2. Second task
...

## Constraints

- Technology constraints, patterns to follow, etc.

## Verification

- How to verify the complete project works (commands to run, expected output)

Write ONLY the spec.md file. No explanation, no other files.`
}

func buildIterationPrompt(workDir string, iteration int) (string, error) {
	spec, err := os.ReadFile(filepath.Join(workDir, "SPEC.md"))
	if err != nil {
		return "", fmt.Errorf("read SPEC.md: %w", err)
	}

	progress := "No progress yet."
	if data, err := os.ReadFile(filepath.Join(workDir, "PROGRESS.md")); err == nil && len(data) > 0 {
		progress = string(data)
	}

	iterStr := strconv.Itoa(iteration)

	var b strings.Builder
	b.WriteString("You are an autonomous coding agent working in a sandboxed environment.\n")
	b.WriteString("This is session " + iterStr + ". Each session starts fresh with no memory\n")
	b.WriteString("of previous sessions. Your only knowledge comes from reading files on disk.\n")
	b.WriteString("After you complete your work, this session ends. A new session will start\n")
	b.WriteString("with a clean context and can only see what you wrote to files.\n")
	b.WriteString("\nYou MUST write all output to files on disk using your tools.\n")
	b.WriteString("Do not describe what you would do. Do the work.\n")
	b.WriteString("\n## Task Specification\n\n")
	b.Write(spec)
	b.WriteString("\n\n## Progress So Far\n\n")
	b.WriteString(progress)
	b.WriteString("\n\n## Workflow\n\n")
	b.WriteString("Follow these steps in order. Every step is a file operation.\n\n")
	b.WriteString("1. Read PROGRESS.md in your working directory (if it exists).\n")
	b.WriteString("2. Read the task specification above. Pick the highest priority incomplete task.\n")
	b.WriteString("3. Implement that single task. Write code to files on disk.\n")
	b.WriteString("   Do NOT write placeholder or stub implementations. Write the full implementation.\n")
	b.WriteString("4. Verify your work by running the code (use bash to run tests, scripts, etc.).\n")
	b.WriteString("5. APPEND to the file PROGRESS.md with what you did (see format below).\n")
	b.WriteString("   If PROGRESS.md does not exist, create it.\n")
	b.WriteString("6. If ALL tasks in the spec are now complete and verified, create a file\n")
	b.WriteString("   called DONE containing a brief summary. Otherwise, stop here.\n")
	b.WriteString("\n## PROGRESS.md Format\n\n")
	b.WriteString("APPEND this block to PROGRESS.md (never overwrite existing content):\n\n")
	b.WriteString("```\n")
	b.WriteString("### Session " + iterStr + " - {what you worked on}\n")
	b.WriteString("- What was implemented\n")
	b.WriteString("- Files created or changed\n")
	b.WriteString("- Verification: what you ran, did it pass\n")
	b.WriteString("- Learnings: patterns, gotchas, or context the next session needs\n")
	b.WriteString("```\n\n")
	b.WriteString("If you discover a reusable pattern, also add it to a ## Codebase Patterns\n")
	b.WriteString("section at the TOP of PROGRESS.md.\n")
	b.WriteString("\n## Rules\n\n")
	b.WriteString("- Work on ONE task per session. Do not rush to complete everything.\n")
	b.WriteString("- Do NOT create DONE until every task is genuinely complete and verified.\n")
	b.WriteString("- Do NOT write placeholder code. Build it properly.\n")
	b.WriteString("- If you hit a blocker, document it in PROGRESS.md so the next session\n")
	b.WriteString("  can pick up. The next session has zero context except files on disk.\n")
	b.WriteString("- Limit testing to ~20% of your effort. Prioritize implementation.\n")

	return b.String(), nil
}
