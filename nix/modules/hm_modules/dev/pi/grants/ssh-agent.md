# ssh agent access

The ssh-agent socket is granted, so ssh authenticates as the human, to
anything the network allowlist reaches. Private keys are never readable;
only their public halves. `known_hosts` is read-only, so an unknown host
fails loudly rather than being trusted silently. Recording a new host key is
a decision for the human, outside this session.

Pushing and rewriting history still need the human's confirmation, per the
working agreement. The grant changes what ssh can do, not what git should.
