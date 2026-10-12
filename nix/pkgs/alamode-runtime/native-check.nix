{ pkgs }:
pkgs.writeShellApplication {
  name = "alamode-check-native";
  runtimeInputs = [
    pkgs.python3
    pkgs.git
    pkgs.coreutils
    pkgs.nodejs
    pkgs.bashInteractive
    # Parity with the deployed wrapper's PATH: the native probes assert
    # the engine's structured find falls back to these when its agent bin
    # dir is write-denied.
    pkgs.fd
    pkgs.ripgrep
  ];
  text = ''
    export ALAMODE_NATIVE_TESTS=1
    export ALAMODE_TEST_BIN=${pkgs.lib.getExe pkgs.llm-agents.pi}
    export ALAMODE_NODE=${pkgs.lib.getExe pkgs.nodejs}
    export ALAMODE_BASH=${pkgs.lib.getExe pkgs.bashInteractive}
    export ALAMODE_SESSION_MODULE=${pkgs.alamode-runtime}/libexec/alamode-runtime/session.py
    export ALAMODE_RELAY_MODULE=${pkgs.alamode-relay}/libexec/alamode-relay/relay.py
    export ALAMODE_SANDBOX_RUNTIME=${pkgs.llm-agents.sandbox-runtime}/lib/node_modules/@anthropic-ai/sandbox-runtime/dist/index.js
    export ALAMODE_SANDBOX_RUNNER_SOURCE=${./sandbox.mjs}
    export ALAMODE_COORDINATOR_BIN=${
      pkgs.lib.getExe (pkgs.alamode-coordinator.override { withForge = false; })
    }
    export ALAMODE_COORDINATOR_EXTENSION=${../../modules/hm_modules/dev/alamode/source/extensions/coordinator.ts}
    export ALAMODE_SOFTNET_INSTALLER=${pkgs.lib.getExe pkgs.alamode-builder.softnetInstaller}
    export PYTHONPATH=${pkgs.alamode-runtime}/libexec/alamode-runtime
    python3 ${./.}/test_session.py
    python3 ${../alamode-builder}/test_softnet_install.py
    exec python3 ${./.}/test_build_service.py
  '';
}
