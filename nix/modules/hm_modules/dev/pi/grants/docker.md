# docker daemon access

The docker socket of the forge lima instance is granted, and that VM is the
real boundary: anything a container can reach, this session can reach through
it. The instance declares no host mounts, so $HOME is out of reach, but a
privileged container still runs outside pi's policy. Build and run what the
task needs, not more.

`~/.docker` is masked and `DOCKER_CONFIG` points at a sandbox-local dir, so
stored registry credentials are not available and private image pulls fail.
That is deliberate: the grant buys a daemon, not the tokens to use one.
