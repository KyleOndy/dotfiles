// Package manifest holds vendored Kubernetes manifests and Dockerfiles that
// are compiled into the forge binary via go:embed. Callers request the bytes
// by name; no filesystem hit at runtime.
package manifest

import _ "embed"

// MetalLBNativeV0_15_3 is the full upstream MetalLB manifest pinned at the
// version forge ships. Applied via `kubectl apply -f -` on each workload
// cluster by the lab bring-up.
//
//go:embed vendor/metallb-native-v0.15.3.yaml
var MetalLBNativeV0_15_3 []byte

// DnsmasqDockerfile is the Dockerfile for the forge-dns container image.
// Built on-demand with `docker build` when the image is not already
// present on the host. Alpine + dnsmasq, ~10 MB.
//
//go:embed vendor/dnsmasq.Dockerfile
var DnsmasqDockerfile []byte

// IngressNginxV4_12_0 is the ingress-nginx controller manifest (upstream
// helm-chart output) pinned at the version forge ships.
//
//go:embed vendor/ingress-nginx-4.12.0.yaml
var IngressNginxV4_12_0 []byte

// MetalLBVersion is the version tag of the embedded MetalLB manifest.
// Matches the filename in vendor/.
const MetalLBVersion = "0.15.3"

// IngressNginxVersion is the version tag of the embedded ingress-nginx
// manifest.
const IngressNginxVersion = "4.12.0"
