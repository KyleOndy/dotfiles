{
  lib,
  writeShellApplication,
  python3,
  git,
  forge,
  maxAgents ? 8,
  maxWorkers ? 2 * maxAgents,
  maxRetainedAgents ? 4 * maxWorkers,
  withForge ? true,
  memoryBudgetGib ? 32,
}:
writeShellApplication {
  name = "alamode-coordinator";
  runtimeInputs = [
    python3
    git
  ]
  ++ lib.optional withForge forge;
  text = ''
    export PYTHONPATH=${../alamode-runtime}
    export ALAMODE_COORD_MAX_AGENTS=${toString maxAgents}
    export ALAMODE_COORD_MAX_WORKERS=${toString maxWorkers}
    export ALAMODE_COORD_MAX_RETAINED_AGENTS=${toString maxRetainedAgents}
    export ALAMODE_COORD_FORGE=${lib.boolToString withForge}
    export ALAMODE_COORD_MEMORY_GIB=${toString memoryBudgetGib}
    exec ${python3}/bin/python3 ${./.}/broker.py "$@"
  '';
}
