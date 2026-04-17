package main

import (
	"io"
	"net"
	"net/http"
	"strings"
	"sync/atomic"
)

// allowlistProxy is an HTTP CONNECT proxy that only tunnels connections to
// explicitly allowed host:port pairs. Runs in the parent network namespace;
// the child is directed to it via HTTP_PROXY/HTTPS_PROXY.
//
// This is a soft control: programs that ignore proxy env vars can bypass it.
// Hard network isolation (slirp4netns) is planned for phase 2.
type allowlistProxy struct {
	allowed map[string]bool
	server  *http.Server
	addr    string
	up      atomic.Int64
	down    atomic.Int64
}

func newProxy(hosts []string) *allowlistProxy {
	allowed := make(map[string]bool, len(hosts))
	for _, h := range hosts {
		allowed[normalizeTarget(h)] = true
	}
	return &allowlistProxy{allowed: allowed}
}

func (p *allowlistProxy) start() error {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return err
	}
	p.addr = ln.Addr().String()
	p.server = &http.Server{Handler: http.HandlerFunc(p.handle)}
	go p.server.Serve(ln) //nolint:errcheck
	return nil
}

func (p *allowlistProxy) stop() {
	if p.server != nil {
		p.server.Close()
	}
}

func (p *allowlistProxy) byteCounts() (up, down int64) {
	return p.up.Load(), p.down.Load()
}

func (p *allowlistProxy) handle(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodConnect {
		http.Error(w, "only CONNECT supported", http.StatusMethodNotAllowed)
		return
	}

	target := normalizeTarget(r.Host)
	if !p.allowed[target] {
		http.Error(w, "blocked: "+target, http.StatusForbidden)
		return
	}

	dst, err := net.Dial("tcp", target)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}

	hijacker, ok := w.(http.Hijacker)
	if !ok {
		dst.Close()
		http.Error(w, "hijacking not supported", http.StatusInternalServerError)
		return
	}
	src, _, err := hijacker.Hijack()
	if err != nil {
		dst.Close()
		return
	}

	// Signal tunnel established.
	src.Write([]byte("HTTP/1.1 200 Connection Established\r\n\r\n")) //nolint:errcheck

	done := make(chan int64, 2)
	go func() {
		n, _ := io.Copy(dst, src)
		done <- n
	}()
	go func() {
		n, _ := io.Copy(src, dst)
		done <- n
	}()

	// Close both connections when the first goroutine finishes; the other
	// goroutine will receive a read/write error and return promptly.
	upBytes := <-done
	src.Close()
	dst.Close()
	downBytes := <-done

	p.up.Add(upBytes)
	p.down.Add(downBytes)
}

// normalizeTarget ensures host:port form; defaults to :443 if no port.
func normalizeTarget(target string) string {
	if !strings.Contains(target, ":") {
		return target + ":443"
	}
	return target
}
