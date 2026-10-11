package nat

import (
	"strings"
	"testing"
)

func TestNFTScript(t *testing.T) {
	s := NFTScript("z2ktun0", 1240)
	for _, want := range []string{
		"delete table inet z2k_warpd",
		`post oifname "z2ktun0" masquerade`,
		`mss oifname "z2ktun0" tcp flags & (syn|rst) == syn tcp option maxseg size set rt mtu`,
		`mss iifname "z2ktun0" tcp flags & (syn|rst) == syn tcp option maxseg size set 1240`,
	} {
		if !strings.Contains(s, want) {
			t.Errorf("нет %q в\n%s", want, s)
		}
	}
}

func TestEnsureUsesNFT(t *testing.T) {
	old := nftAvailable
	nftAvailable = func() bool { return true }
	defer func() { nftAvailable = old }()
	var calls []string
	run := func(name string, a ...string) (string, error) { calls = append(calls, name); return "", nil }
	if err := Ensure(run, "z2ktun1", 1240); err != nil {
		t.Fatal(err)
	}
	_ = Remove(run, "z2ktun1", 1240)
	if len(calls) != 2 || calls[0] != "nft" || calls[1] != "nft" {
		t.Fatalf("ожидались два вызова nft, получено %v", calls)
	}
}
