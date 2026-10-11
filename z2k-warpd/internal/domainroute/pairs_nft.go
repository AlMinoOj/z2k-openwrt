package domainroute

// OPENWRT: пары «клиент -> адрес» на nftables (z2k-openwrt).
//
// В апстриме на каждого клиента — свой ipset z2kd_<ip> и своё правило
// PREROUTING (на Keenetic нет сетов с составным ключом). На OpenWrt — один
// сет inet z2k_warp pairs { ipv4_addr . ipv4_addr; timeout } и одно
// статичное правило `ip saddr . ip daddr @pairs jump warp_policy`, которые ставит
// z2k-warp.sh (openwrt/lib/warp-openwrt.sh). Демон только добавляет и
// удаляет элементы.

import (
	"fmt"
	"os/exec"
	"strings"
	"time"
)

const (
	NFTTable   = "z2k_warp"
	NFTPairSet = "pairs"
)

var nftAvailable = func() bool { _, err := exec.LookPath("nft"); return err == nil }

// useNFT — nft есть и тест не подменил бинарники ipset/iptables.
func (s PairSet) useNFT() bool {
	return s.Binary == "" && s.IPTablesBinary == "" && nftAvailable()
}

func nft(cmd string) error {
	out, err := exec.Command("nft", cmd).CombinedOutput()
	if err != nil {
		return fmt.Errorf("nft: %v: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

func pairElem(ch Change) string {
	return ch.Client.String() + " . " + ch.Dest.String()
}

// pairTimeout — секунды до истечения, 1..3600 (как у ipset-пути апстрима).
func pairTimeout(ch Change, now time.Time) int {
	seconds := int(ch.Expiry.Sub(now).Seconds())
	if ch.Expiry.After(now.Add(time.Duration(seconds) * time.Second)) {
		seconds++
	}
	if seconds < 1 {
		seconds = 1
	}
	if seconds > 3600 {
		seconds = 3600
	}
	return seconds
}

func (s PairSet) applyNFT(changes []Change, now time.Time) error {
	var adds []string
	for _, ch := range changes {
		if _, err := clientSet(ch.Client); err != nil || !EligibleDestination(ch.Dest) {
			return fmt.Errorf("invalid WARP DNS pair")
		}
		// delete отсутствующего элемента — ошибка nft; по одному и молча.
		// Перед add — тоже: add существующего элемента не продлевает таймаут.
		_ = nft(fmt.Sprintf("delete element inet %s %s { %s }", NFTTable, NFTPairSet, pairElem(ch)))
		if ch.Delete {
			continue
		}
		adds = append(adds, fmt.Sprintf("%s timeout %ds", pairElem(ch), pairTimeout(ch, now)))
	}
	if len(adds) == 0 {
		return nil
	}
	return nft(fmt.Sprintf("add element inet %s %s { %s }", NFTTable, NFTPairSet, strings.Join(adds, ", ")))
}

func (s PairSet) replaceAllNFT(changes []Change, now time.Time) error {
	if err := nft(fmt.Sprintf("flush set inet %s %s", NFTTable, NFTPairSet)); err != nil {
		return fmt.Errorf("flush WARP DNS pairs: %w", err)
	}
	return s.applyNFT(changes, now)
}
