// Package nftfw — правила детектора на nftables (z2k-openwrt).
//
// OPENWRT: на OpenWrt 22.03+ межсетевой экран — nftables (fw4), iptables в
// базовой прошивке нет. Детектор ставит два вида правил:
//
//   - на время зонда — «не выпускать RST от собственного ядра» с порта зонда
//     (raw-сокет шлёт SYN мимо стека, и ядро отвечает RST на SYN-ACK);
//   - постоянное — «соединения зондов (SO_MARK 0x40000000) помечать
//     ct-меткой исключения 0x20000000», чтобы обход их не трогал.
//
// Всё в своей таблице inet z2k_detect: порты зондов — элементы сета, правило
// одно на все зонды. Снятие порта — удаление элемента; хвосты после SIGKILL
// подметаются очисткой сета на старте процесса (порты в сете — только наши).
//
// Если nft нет (Keenetic), вызывающий код остаётся на iptables, как в апстриме.
package nftfw

import (
	"fmt"
	"os/exec"
	"strings"
	"sync"
)

const (
	Table      = "z2k_detect"
	RSTSet     = "rst_ports"
	ProbeMark  = 0x40000000
	BypassMark = 0x20000000
)

// Script — описание таблицы целиком (идемпотентно: add table/set/chain, flush
// цепочек, правила заново). Отдельной функцией — её проверяет тест.
func Script() string {
	return strings.Join([]string{
		"add table inet " + Table,
		"add set inet " + Table + " " + RSTSet + " { type inet_service; }",
		"add chain inet " + Table + " rst_out { type filter hook output priority filter - 10; policy accept; }",
		"flush chain inet " + Table + " rst_out",
		"add rule inet " + Table + " rst_out tcp sport @" + RSTSet + " tcp flags & rst == rst drop comment \"z2k-detect: kernel RST\"",
		"add chain inet " + Table + " mark_out { type route hook output priority mangle; policy accept; }",
		"flush chain inet " + Table + " mark_out",
		fmt.Sprintf("add rule inet %s mark_out meta mark & 0x%x == 0x%x ct mark set ct mark | 0x%x comment \"z2k-detect: probe bypass\"",
			Table, ProbeMark, ProbeMark, BypassMark),
		"",
	}, "\n")
}

var (
	availOnce sync.Once
	avail     bool
	tableOnce sync.Once
	tableErr  error
)

// Available — есть ли nft в системе.
func Available() bool {
	availOnce.Do(func() {
		_, err := exec.LookPath("nft")
		avail = err == nil
	})
	return avail
}

func run(script string) error {
	cmd := exec.Command("nft", "-f", "-")
	cmd.Stdin = strings.NewReader(script)
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("nft: %v: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

// EnsureTable ставит таблицу один раз за процесс.
func EnsureTable() error {
	tableOnce.Do(func() { tableErr = run(Script()) })
	return tableErr
}

// SweepRSTPorts — очистить сет портов зондов (хвосты прошлых прогонов).
func SweepRSTPorts() {
	if EnsureTable() != nil {
		return
	}
	_ = run("flush set inet " + Table + " " + RSTSet + "\n")
}

// SuppressRST — не выпускать RST ядра с порта зонда; возвращает уборщика.
func SuppressRST(sport uint16) (func(), error) {
	if err := EnsureTable(); err != nil {
		return func() {}, err
	}
	if err := run(fmt.Sprintf("add element inet %s %s { %d }\n", Table, RSTSet, sport)); err != nil {
		return func() {}, err
	}
	return func() {
		_ = run(fmt.Sprintf("delete element inet %s %s { %d }\n", Table, RSTSet, sport))
	}, nil
}
