{
  lib,
  writeShellApplication,
  python3,
  git,
  forge,
  maxAgents ? 8,
  maxWorkers ? 2 * maxAgents,
  maxRetainedWorkers ? 4 * maxWorkers,
  withForge ? true,
  memoryBudgetGib ? 32,
}:
writeShellApplication {
  name = "pi-broker";
  runtimeInputs = [
    python3
    git
  ]
  ++ lib.optional withForge forge;
  text = ''
    export PYTHONPATH=${../pi-session}
    export PI_BROKER_MAX_AGENTS=${toString maxAgents}
    export PI_BROKER_MAX_WORKERS=${toString maxWorkers}
    export PI_BROKER_MAX_RETAINED_WORKERS=${toString maxRetainedWorkers}
    export PI_BROKER_FORGE=${lib.boolToString withForge}
    export PI_BROKER_MEMORY_GIB=${toString memoryBudgetGib}
    exec ${python3}/bin/python3 ${./.}/broker.py "$@"
  '';
}
