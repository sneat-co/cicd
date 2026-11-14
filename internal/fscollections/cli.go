package fscollections

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"path/filepath"
	"sort"
	"strings"

	"golang.org/x/tools/go/analysis"
	"golang.org/x/tools/go/analysis/checker"
	"golang.org/x/tools/go/packages"
)

// PrinciplesURL is the page every failure links to.
const PrinciplesURL = "https://github.com/sneat-co/sneat-specs/blob/main/standards/data-storage-design.md"

// EmitFormat is the format line of the emit output.
const EmitFormat = "firestore-collections-emit/v1"

// Emitted is the machine-readable list of paths a module builds.
type Emitted struct {
	Format     string           `json:"format"`
	Paths      []EmittedPath    `json:"paths"`
	Unresolved []EmittedProblem `json:"unresolved"`
}

// EmittedPath is one path and every place that builds it.
type EmittedPath struct {
	Path     string   `json:"path"`
	Kind     string   `json:"kind"`
	Guard    string   `json:"guard,omitempty"`
	Declared bool     `json:"declared,omitempty"`
	Sites    []string `json:"sites"`
}

// EmittedProblem is one place whose path cannot be worked out.
type EmittedProblem struct {
	Site     string `json:"site"`
	Function string `json:"function,omitempty"`
	Reason   string `json:"reason"`
}

// analyze is replaced in tests.
var analyze = checker.Analyze

// load loads the packages; any package error fails the check closed.
// A Go file that build constraints exclude is not analyzed, so it fails the
// check closed unless -tags (or GOOS/GOARCH) brings it in.
func load(dir, tags string, patterns []string) ([]*packages.Package, error) {
	cfg := &packages.Config{Mode: packages.LoadAllSyntax, Dir: dir, Tests: false, BuildFlags: []string{"-tags=" + tags}}
	pkgs, err := packages.Load(cfg, patterns...)
	if err != nil {
		return nil, err
	}
	var msgs []string
	for _, p := range pkgs {
		for _, f := range p.IgnoredFiles {
			if strings.HasSuffix(f, ".go") && !strings.HasSuffix(f, "_test.go") {
				msgs = append(msgs, f+": excluded by build constraints, so not analyzed; pass -tags (or set GOOS/GOARCH) to include it")
			}
		}
	}
	packages.Visit(pkgs, nil, func(p *packages.Package) {
		for _, e := range p.Errors {
			msgs = append(msgs, e.Error())
		}
	})
	if len(msgs) > 0 {
		return nil, errors.New(strings.Join(msgs, "\n"))
	}
	return pkgs, nil
}

// Analyze loads the packages and returns the paths they build, with file
// names relative to root.
func Analyze(dir, root, tags string, patterns []string) (*Emitted, error) {
	pkgs, err := load(dir, tags, patterns)
	if err != nil {
		return nil, err
	}
	graph, err := analyze([]*analysis.Analyzer{Analyzer}, pkgs, nil)
	if err != nil {
		return nil, err
	}
	absRoot, _ := filepath.Abs(root) // fails only when the working directory is gone
	rel := func(file string, line int) string {
		if r, err := filepath.Rel(absRoot, file); err == nil && !strings.HasPrefix(r, "..") {
			file = filepath.ToSlash(r)
		}
		return fmt.Sprintf("%s:%d", file, line)
	}
	byPath := map[string]*EmittedPath{}
	seen := map[EmittedProblem]bool{}
	out := &Emitted{Format: EmitFormat, Paths: []EmittedPath{}, Unresolved: []EmittedProblem{}}
	for _, act := range graph.Roots {
		res := act.Result.(*Result)
		for _, s := range res.Sites {
			k := s.Kind + " " + s.Path + " " + s.Guard
			p := byPath[k]
			if p == nil {
				p = &EmittedPath{Path: s.Path, Kind: s.Kind, Guard: s.Guard, Declared: s.Declared}
				byPath[k] = p
			}
			p.Sites = append(p.Sites, rel(s.Pos.Filename, s.Pos.Line))
		}
		for _, u := range res.Unresolved {
			p := EmittedProblem{Site: rel(u.Pos.Filename, u.Pos.Line), Function: u.Func, Reason: u.Reason}
			if !seen[p] { // a nested call can fail for the same reason as its outer call
				seen[p] = true
				out.Unresolved = append(out.Unresolved, p)
			}
		}
	}
	for _, p := range byPath {
		p.Sites = uniqueSorted(p.Sites)
		out.Paths = append(out.Paths, *p)
	}
	sort.Slice(out.Paths, func(i, j int) bool {
		a, b := out.Paths[i], out.Paths[j]
		if a.Path != b.Path {
			return a.Path < b.Path
		}
		if a.Kind != b.Kind {
			return a.Kind < b.Kind
		}
		return a.Guard < b.Guard
	})
	sort.Slice(out.Unresolved, func(i, j int) bool { return out.Unresolved[i].Site < out.Unresolved[j].Site })
	return out, nil
}

func uniqueSorted(s []string) []string {
	sort.Strings(s)
	out := s[:0]
	for i, v := range s {
		if i == 0 || v != s[i-1] {
			out = append(out, v)
		}
	}
	return out
}

func splitSite(s string) (string, string) {
	i := strings.LastIndex(s, ":")
	return s[:i], s[i+1:]
}

// Check compares emitted paths with a snapshot and writes one GitHub
// annotation per finding. It returns the number of failures.
func Check(e *Emitted, snap *Snapshot, snapshotName string, w io.Writer) int {
	failures, guarded := 0, 0
	for _, p := range e.Paths {
		if snap.Defined(p.Kind, p.Path) {
			continue
		}
		if p.Guard != "" && strings.HasPrefix(p.Path, "ext/") {
			// Built only by the spaceless ext/{extension} branch of
			// coretypes.NewSpaceModuleKey (an empty space id); counted, not failed.
			guarded += len(p.Sites)
			continue
		}
		shown := p.Path
		if p.Kind == KindGroup {
			shown = "**/" + p.Path
		}
		for _, s := range p.Sites {
			file, line := splitSite(s)
			failures++
			fmt.Fprintf(w, "::error file=%s,line=%s::Firestore path %q is not defined in sneat-co/sneat-datatug. Add its definition there, get the owner's approval of the layout, then regenerate %s. Read first: %s\n", file, line, shown, snapshotName, PrinciplesURL)
		}
	}
	for _, u := range e.Unresolved {
		failures++
		file, line := splitSite(u.Site)
		fmt.Fprintf(w, "::error file=%s,line=%s::Cannot tell which Firestore path this builds (%s). The check fails closed: build the path from constants, or name it on a %s<path> -- <reason> comment; the path must be defined in sneat-co/sneat-datatug. Read first: %s\n", file, line, u.Reason, DirectivePrefix, PrinciplesURL)
	}
	if guarded > 0 {
		fmt.Fprintf(w, "firestore-collections: %d sites build an undefined spaceless ext/ path only when the space id is empty (emit lists them with their guard); not counted as findings\n", guarded)
	}
	return failures
}

// Main runs the command line and returns the exit code: 0 clean, 1 findings,
// 2 usage or load errors.
func Main(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 || (args[0] != "emit" && args[0] != "check") {
		fmt.Fprintln(stderr, "usage: firestore-collections emit|check [-C dir] [-repo-root dir] [-tags list] [-snapshot file] [packages]")
		return 2
	}
	fs := flag.NewFlagSet(args[0], flag.ContinueOnError)
	fs.SetOutput(stderr)
	dir := fs.String("C", ".", "directory of the Go module to analyze")
	root := fs.String("repo-root", "", "directory that reported file names are relative to (default: -C)")
	snapshot := fs.String("snapshot", "", "check: the generated snapshot of defined collections")
	tags := fs.String("tags", "", "build tags, comma-separated, as the module's own CI builds with")
	if err := fs.Parse(args[1:]); err != nil {
		return 2
	}
	if *root == "" {
		*root = *dir
	}
	patterns := fs.Args()
	if len(patterns) == 0 {
		patterns = []string{"./..."}
	}
	var snap *Snapshot
	if args[0] == "check" {
		if *snapshot == "" {
			fmt.Fprintln(stderr, "check needs -snapshot")
			return 2
		}
		var err error
		if snap, err = LoadSnapshot(*snapshot); err != nil {
			fmt.Fprintln(stderr, err)
			return 2
		}
	}
	e, err := Analyze(*dir, *root, *tags, patterns)
	if err != nil {
		fmt.Fprintf(stderr, "firestore-collections: cannot analyze (the check fails closed): %v\n", err)
		return 2
	}
	if snap == nil {
		enc := json.NewEncoder(stdout)
		enc.SetIndent("", " ")
		_ = enc.Encode(e)
		return 0
	}
	sites := 0
	for _, p := range e.Paths {
		sites += len(p.Sites)
	}
	failures := Check(e, snap, filepath.Base(*snapshot), stdout)
	fmt.Fprintf(stdout, "firestore-collections: %d paths at %d sites, %d unresolved, checked against %s (%s): %d findings\n",
		len(e.Paths), sites, len(e.Unresolved), filepath.Base(*snapshot), snap.Source, failures)
	if failures > 0 {
		return 1
	}
	return 0
}
