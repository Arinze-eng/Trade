//go:build linux && android
// +build linux,android

package anywherelan

import (
  "fmt"
  "sync"

  "github.com/xjasonlyu/tun2socks/v2/engine"
  tlog "github.com/xjasonlyu/tun2socks/v2/log"
)

var (
  vpnMu       sync.Mutex
  vpnRunning  bool
  vpnLastErr  string
)

// StartVPN starts a full-tunnel (TUN->SOCKS5) forwarder.
// It expects `tunFD` to be an already-established Android VpnService TUN fd.
// `socks5ProxyAddr` example: "127.0.0.1:10808".
func StartVPN(tunFD int32, socks5ProxyAddr string, mtu int32) (err error) {
  vpnMu.Lock()
  defer vpnMu.Unlock()

  if vpnRunning {
    return nil
  }
  if tunFD == 0 {
    return fmt.Errorf("invalid tun fd")
  }
  if socks5ProxyAddr == "" {
    return fmt.Errorf("empty socks5 proxy address")
  }
  if mtu <= 0 {
    mtu = 1500
  }

  // Keep logs quiet by default; Android UI can surface errors.
  tlog.SetLevel(tlog.Silent)

  key := &engine.Key{}
  key.Device = fmt.Sprintf("fd://%d", tunFD)
  key.Proxy = fmt.Sprintf("socks5://%s", socks5ProxyAddr)
  key.MTU = int(mtu)

  // Insert config and start engine.
  // NOTE: engine is global singleton; StopVPN() must be called before starting again.
  engine.Insert(key)

  vpnLastErr = ""
  vpnRunning = true

  // engine.Start() returns immediately and runs in background.
  // If it panics internally, gomobile will crash the process; so keep it minimal.
  engine.Start()

  return nil
}

func StopVPN() {
  vpnMu.Lock()
  defer vpnMu.Unlock()

  if !vpnRunning {
    return
  }
  engine.Stop()
  vpnRunning = false
}

func IsVPNRunning() bool {
  vpnMu.Lock()
  defer vpnMu.Unlock()
  return vpnRunning
}
