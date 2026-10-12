# alamode sandbox regression suite

Run from this checkout on Darwin with Nix installed:

```sh
python3 scripts/test-alamode.py --list
python3 scripts/test-alamode.py --report /private/tmp/alamode-regression
```

The report directory must be new. Without `--report`, the runner creates a
private temporary directory. Each check has a bounded log; `report.json`
records commands, durations, outcomes, selected checks and coverage.
Nix may reuse check results for identical sources. Native probes always run.

A full run includes Nix checks, native Seatbelt, coordinator and helper
installation tests, and native builder probes. The builder needs a provisioned VM and a trusted
configuration outside agent-writable state:

```sh
python3 scripts/test-alamode.py --builder-config /absolute/path/builder.json
```

Use `--only` repeatedly for focused runs:

```sh
python3 scripts/test-alamode.py --only session-and-git --only native-containment
```

Unselected checks remain `skip` in the report. Selected checks determine the
exit code: `0` passed, `1` failed or timed out, `2` incomplete prerequisites,
`130` interrupted. `coverage: full` means every registered command completed;
check `status` for the result. A passing subset has partial coverage.
The default timeout is 1,200 seconds per check; change it with `--timeout`.

## Adding a regression

1. Put the test beside the code it exercises. Use disposable fixtures and
   synthetic credentials. Keep native probes outside nested Nix sandboxes.
2. Add it to the relevant `nix/checks/alamode*.nix` check. For a distinct command,
   add a named entry to `CHECKS` or `checks()` in the runner.
3. Missing prerequisites must be explicit. A command can exit `2` and end
   stdout with a JSON object containing `status: "missing-prerequisite"`
   and `reason`. Use `status: "skip"` for an intentional skip. Neither is a pass.
4. Run the focused check and `python3 scripts/test_alamode.py`.

Stage new source files before Nix checks; the flake reads the Git tree.
