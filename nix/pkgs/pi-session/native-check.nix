{ pkgs }:
pkgs.writeShellApplication {
  name = "pi-check-native";
  runtimeInputs = [
    pkgs.python3
    pkgs.git
    pkgs.coreutils
    pkgs.nodejs
    pkgs.bashInteractive
    # Parity with the deployed wrapper's PATH: the native probes assert
    # pi's structured find falls back to these when its agent bin dir is
    # write-denied.
    pkgs.fd
    pkgs.ripgrep
  ];
  text = ''
    export PI_NATIVE_TESTS=1
    export PI_TEST_BIN=${pkgs.lib.getExe pkgs.llm-agents.pi}
    export PI_NODE=${pkgs.lib.getExe pkgs.nodejs}
    export PI_BASH=${pkgs.lib.getExe pkgs.bashInteractive}
    export PI_SESSION_MODULE=${pkgs.pi-session}/libexec/pi-session/session.py
    export PI_RELAY_MODULE=${pkgs.pi-provider-relay}/libexec/pi-provider-relay/relay.py
    export PI_SANDBOX_RUNTIME=${pkgs.llm-agents.sandbox-runtime}/lib/node_modules/@anthropic-ai/sandbox-runtime/dist/index.js
    export PI_SANDBOX_RUNNER_SOURCE=${./sandbox.mjs}
    export PI_BROKER_BIN=${pkgs.lib.getExe (pkgs.pi-broker.override { withForge = false; })}
    export PI_COORDINATOR_EXTENSION=${../../modules/hm_modules/dev/pi/extensions/coordinator.ts}
    export PI_SOFTNET_INSTALLER=${pkgs.lib.getExe pkgs.pi-builder.softnetInstaller}
    export PYTHONPATH=${pkgs.pi-session}/libexec/pi-session
    python3 ${./.}/test_session.py
    python3 ${../pi-builder}/test_softnet_install.py
    exec python3 ${./.}/test_build_service.py
  '';
}
