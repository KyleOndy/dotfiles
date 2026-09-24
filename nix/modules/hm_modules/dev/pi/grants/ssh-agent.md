# ssh agent access

The ssh-agent socket is granted, so plain `ssh` authenticates as the human,
to anything the network allowlist reaches, through the ProxyCommand in
`nix/profiles/common/ssh-hosts.nix`. git over ssh does not: srt's
`GIT_SSH_COMMAND` cannot authenticate to its own proxy, so fetch and push
need https. Private keys are never readable; only their public halves.
`known_hosts` is read-only, so an unknown host fails loudly rather than being
trusted silently. Recording a new host key is a decision for the human,
outside this session.

Pushing and rewriting history still need the human's confirmation, per the
working agreement. The grant changes what ssh can do, not what git should.
