package cicd

import "testing"

func TestVersion(t *testing.T) {
	if got := Version(); got != "cicd" {
		t.Errorf("Version() = %q, want %q", got, "cicd")
	}
}
