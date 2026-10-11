package nftfw

import (
	"strings"
	"testing"
)

func TestScriptShape(t *testing.T) {
	s := Script()
	for _, want := range []string{
		"add table inet z2k_detect",
		"add set inet z2k_detect rst_ports { type inet_service; }",
		"tcp sport @rst_ports tcp flags & rst == rst drop",
		"type route hook output priority mangle",
		"meta mark & 0x40000000 == 0x40000000 ct mark set ct mark | 0x20000000",
	} {
		if !strings.Contains(s, want) {
			t.Errorf("в скрипте нет %q\n%s", want, s)
		}
	}
	// Повторный прогон не должен плодить правила: цепочки чистятся перед add rule.
	if strings.Index(s, "flush chain inet z2k_detect rst_out") > strings.Index(s, "add rule inet z2k_detect rst_out") {
		t.Error("flush rst_out должен идти до add rule")
	}
}
