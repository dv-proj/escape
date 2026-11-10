package main

import (
	"fmt"
	"os/exec"
	"testing"
)

// TestGeneratedPagesParse runs gen/login.py for several seeds and checks that
// every page is accepted by parsePage (renders for all states). Skipped when
// python3 is not available.
func TestGeneratedPagesParse(t *testing.T) {
	py, err := exec.LookPath("python3")
	if err != nil {
		t.Skip("python3 not found")
	}
	for i := range 20 {
		seed := fmt.Sprintf("%032x", uint64(i)*0x9e3779b97f4a7c15+1)
		out, err := exec.Command(py, "gen/login.py", "--seed", seed).Output()
		if err != nil {
			t.Fatalf("seed %s: gen/login.py: %v", seed, err)
		}
		if _, err := parsePage(string(out)); err != nil {
			t.Errorf("seed %s: %v", seed, err)
		}
	}
}
