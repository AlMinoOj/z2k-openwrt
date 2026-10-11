package nat

// OPENWRT: правила туннеля на nftables (z2k-openwrt).
//
// На OpenWrt (fw4) iptables нет. Маскарадинг и MSS — в своей таблице
// inet z2k_warpd; разрешение форварда LAN -> туннель ставит не демон, а
// include fw4 (/usr/share/nftables.d/chain-pre/forward/30-z2k-warp.nft):
// accept в чужой таблице не отменяет reject fw4, поэтому правило обязано
// стоять в цепочке самого fw4.

import (
	"fmt"
	"os/exec"
	"strings"
)

// NFTTable — таблица демона.
const NFTTable = "z2k_warpd"

// nftAvailable — есть ли nft. Переменная, чтобы тесты могли зафиксировать путь.
var nftAvailable = func() bool { _, err := exec.LookPath("nft"); return err == nil }

// NFTScript — таблица целиком (пересоздаётся: старое состояние не наследуется).
func NFTScript(iface string, mss int) string {
	q := fmt.Sprintf("%q", iface)
	return strings.Join([]string{
		"add table inet " + NFTTable,
		"delete table inet " + NFTTable,
		"add table inet " + NFTTable,
		"add chain inet " + NFTTable + " post { type nat hook postrouting priority srcnat; policy accept; }",
		"add rule inet " + NFTTable + " post oifname " + q + " masquerade",
		"add chain inet " + NFTTable + " mss { type filter hook forward priority mangle; policy accept; }",
		"add rule inet " + NFTTable + " mss oifname " + q + " tcp flags & (syn|rst) == syn tcp option maxseg size set rt mtu",
		fmt.Sprintf("add rule inet %s mss iifname %s tcp flags & (syn|rst) == syn tcp option maxseg size set %d", NFTTable, q, mss),
	}, "; ")
}

func ensureNFT(run Runner, iface string, mss int) error {
	if out, err := run("nft", NFTScript(iface, mss)); err != nil {
		return fmt.Errorf("nft: %v: %s", err, strings.TrimSpace(out))
	}
	return nil
}

func removeNFT(run Runner) error {
	_, _ = run("nft", "delete table inet "+NFTTable)
	return nil
}
