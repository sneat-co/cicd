package main

import (
	"os"
	"testing"
)

func TestMainUsage(t *testing.T) {
	code := -1
	exit = func(c int) { code = c }
	defer func() { exit = os.Exit }()
	os.Args = []string{"firestore-collections"}
	main()
	if code != 2 {
		t.Fatalf("exit code %d, want 2", code)
	}
}
