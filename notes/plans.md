# End State

This is the goal I am trending towards.

## Networks

### Lan (wifi: The Ondy's)

Standard home network. Glorified guest network at this point. Friends and
family all have access. This network _needs_ to stay up for family sanity. Any
services on this network should be secured.

- Personal devices
- Media devices
- Media management
- Media storage

### DMZ / Homelab

Network for learning, exposed to internet. Lan can reach into DMZ, but DMZ can
not go into any other system. Must be ok with anything on this network
completely disappearing or being powned at any time.

There is a reverse proxy (`rp-#.dmz.509ely.com`) that sits between the gateway and all other boxes, simply forwarding the domains `*.apps.dmz.509ely.com` and `*.lab.dmz.509ely.com`.

#### Apps (apps.dmz.509ely.com)

Stable services I choose to expose to the internet.

#### Lab (lab.dmz.509ely.com)

Anything under this subdomain make disappear at any moment. Purely to learn and
build and break.

### Work

Zero extra service, just straight internet. Zero connectivity to other networks
