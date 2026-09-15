# Shared SSH host definitions
# This file contains all SSH hosts that can be used across different profiles

{ lib, ... }:
with lib;
{
  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;

    matchBlocks = {
      "*" = {
        extraOptions = {
          IdentitiesOnly = "yes";
          SendEnv = "LANG LC_*";
          # Apple's ssh resolves through getaddrinfo, and so honours
          # /etc/resolver/1ella.com, only when a timeout or retry count is
          # set (openssh/ssh.c, __APPLE_NW_CONNECTION__). Otherwise the bare
          # hostname goes to Network.framework, which under iCloud Private
          # Relay cannot place split-horizon LAN names and fails every
          # connect with "Undefined error: 0". Covers nix copy and deploy-rs,
          # which spawn ssh with no timeout of their own.
          ConnectTimeout = "10";
        };
      };
      "*.amazonaws.com" = {
        extraOptions = {
          UserKnownHostsFile = "/dev/null";
          StrictHostKeyChecking = "no";
        };
      };
      "tiger tiger.dmz.1ella.com" = {
        hostname = "tiger.dmz.1ella.com";
        user = "kyle";
        port = 2332;
        identityFile = "~/.ssh/id_ed25519";
      };
      # The FQDN is not cosmetic. sandbox-runtime refuses a single-label name
      # as a domain pattern, so "cogsworth" can never appear in the pi
      # sandbox's network allowlist; mapping it here is what lets `ssh
      # cogsworth` and cogsworth's own `make HOST=cogsworth` keep working
      # inside that sandbox. HostKeyAlias keeps the short-name known_hosts
      # entry valid so the rename costs no re-verification.
      "cogsworth cogsworth.lan.1ella.com" = {
        hostname = "cogsworth.lan.1ella.com";
        extraOptions.HostKeyAlias = "cogsworth";
      };
      # Inside the pi sandbox every outbound TCP connection has to go through
      # sandbox-runtime's proxy mux; a direct connect() is refused by seatbelt,
      # which surfaces as an unresolvable hostname. srt does inject an ssh
      # ProxyCommand of its own via GIT_SSH_COMMAND, but it is built around BSD
      # `nc -X 5`, which speaks no SOCKS5 auth, and srt always mints a proxy
      # credential -- so that path dies at the SOCKS handshake. ncat carries the
      # credential; CLOUDSDK_PROXY_* holds it already decoded, where the
      # userinfo in ALL_PROXY is percent-encoded and its %3D trips ssh's own
      # percent-expansion. -4 because localhost resolves to ::1 first and the
      # proxy only listens on 127.0.0.1.
      #
      # RSYNC_PROXY is set only by srt, so this block is inert outside the
      # sandbox and the whole file stays usable on a host without ncat. The
      # mux is off because its socket path under ~/.ssh is not a granted
      # socket, and OpenSSH treats that bind failure as fatal.
      "pi-sandbox-proxy" = {
        match = ''exec "test -n \"$RSYNC_PROXY\""'';
        extraOptions = {
          ProxyCommand =
            "ncat -4 --proxy 127.0.0.1:\${RSYNC_PROXY##*:} --proxy-type socks5"
            + " --proxy-auth \${CLOUDSDK_PROXY_USERNAME}:\${CLOUDSDK_PROXY_PASSWORD} %h %p";
          ControlMaster = "no";
          ControlPath = "none";
        };
      };
    };
  };
}
