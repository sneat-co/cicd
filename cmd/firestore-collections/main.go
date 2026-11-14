// Command firestore-collections lists the Firestore paths a Go module builds
// with dalgo, and checks them against a generated snapshot of the defined
// collections. See internal/fscollections and docs/firestore-collections.md.
package main

import (
	"os"

	"github.com/sneat-co/cicd/internal/fscollections"
)

var exit = os.Exit

func main() { exit(fscollections.Main(os.Args[1:], os.Stdout, os.Stderr)) }
