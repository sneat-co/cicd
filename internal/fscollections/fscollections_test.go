package fscollections

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/tools/go/analysis"
	"golang.org/x/tools/go/analysis/checker"
	"golang.org/x/tools/go/packages"
)

// The fixture module resolves its dalgo stand-ins through local replace
// directives, so no test touches the network.
func offline(t *testing.T) {
	t.Helper()
	t.Setenv("GOWORK", "off")
	t.Setenv("GOPROXY", "off")
	t.Setenv("GOFLAGS", "-mod=mod")
}

func runMain(t *testing.T, args ...string) (int, string, string) {
	t.Helper()
	var out, errOut bytes.Buffer
	code := Main(args, &out, &errOut)
	return code, out.String(), errOut.String()
}

func writeFile(t *testing.T, dir, name, text string) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte(text), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestEmitMatchesGolden(t *testing.T) {
	offline(t)
	code, out, errOut := runMain(t, "emit", "-C", "testdata/app")
	if code != 0 {
		t.Fatalf("exit %d: %s", code, errOut)
	}
	want, err := os.ReadFile("testdata/app.golden.json")
	if err != nil {
		t.Fatal(err)
	}
	if out != string(want) {
		t.Fatalf("emit output differs from testdata/app.golden.json:\n%s", out)
	}
}

const header = "# generated — do not edit\nformat: firestore-collections/v1\nsource: sneat-co/sneat-datatug@abc\ncollections:\n"

func TestCheckPasses(t *testing.T) {
	offline(t)
	snap := writeFile(t, t.TempDir(), ".firestore-collections.yaml", header+
		"  - {path: \"spaces/{space}\", owner: spaceus, review: existing — not reviewed}\n"+
		"  - {path: \"spaces/{space}/ext/{extension}\", owner: spaceus}\n")
	code, out, errOut := runMain(t, "check", "-C", "testdata/app", "-snapshot", snap, "./keys")
	if code != 0 {
		t.Fatalf("exit %d: %s %s", code, out, errOut)
	}
	for _, want := range []string{
		"firestore-collections: 2 sites build an undefined path only when an argument is empty",
		"firestore-collections: 4 paths at 7 sites, 0 unresolved, checked against .firestore-collections.yaml (sneat-co/sneat-datatug@abc): 0 findings",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in:\n%s", want, out)
		}
	}
}

func TestCheckFails(t *testing.T) {
	offline(t)
	snap := writeFile(t, t.TempDir(), "snap.yaml", header+"  - {path: \"plain/{id}\"}\n  - {path: \"spaces/{space}/ext/demo/happenings/{id}\"}\n")
	code, out, _ := runMain(t, "check", "-C", "testdata/app", "-repo-root", "testdata", "-snapshot", snap)
	if code != 1 {
		t.Fatalf("exit %d, want 1:\n%s", code, out)
	}
	for _, want := range []string{
		`::error file=app/app/app.go,line=27::Firestore path "rootColl" is not defined in sneat-co/sneat-datatug. Add its definition there, get the owner's approval of the layout, then regenerate snap.yaml. Read first: ` + PrinciplesURL,
		`::error file=app/app/app.go,line=28::Firestore path "**/grouped" is not defined`,
		`::error file=app/app/app.go,line=64::Cannot tell which Firestore path this builds (the key comes from a dynamic call f). The check fails closed: build the path from constants, or name it on a //firestore:path <path> -- <reason> comment; the path must be defined in sneat-co/sneat-datatug. Read first: ` + PrinciplesURL,
	} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in:\n%s", want, out)
		}
	}
	for _, unwanted := range []string{`"plain/7" is not defined`, `"spaces/s1/ext/demo/happenings/h1" is not defined`} {
		if strings.Contains(out, unwanted) {
			t.Errorf("defined path reported: %s", unwanted)
		}
	}
}

func TestUsageAndLoadErrors(t *testing.T) {
	offline(t)
	dir := t.TempDir()
	bad := map[string]string{
		"missing.yaml": "",
		"syntax.yaml":  "format: [",
		"format.yaml":  "format: other/v1\n",
		"empty.yaml":   "format: firestore-collections/v1\n",
		"odd.yaml":     header + "  - {path: \"spaces\"}\n",
		"wild.yaml":    header + "  - {path: \"{x}/{id}\"}\n",
		"good.yaml":    header + "  - {path: \"a/{id}\"}\n",
	}
	broken := filepath.Join(dir, "broken")
	if err := os.Mkdir(broken, 0o700); err != nil {
		t.Fatal(err)
	}
	writeFile(t, broken, "go.mod", "module example.com/broken\n\ngo 1.26\n")
	writeFile(t, broken, "broken.go", "package broken\n\nvar x int = \"not an int\"\n")
	for name, text := range bad {
		if name != "missing.yaml" {
			writeFile(t, dir, name, text)
		}
	}
	cases := []struct {
		args []string
		want string
	}{
		{nil, "usage:"},
		{[]string{"list"}, "usage:"},
		{[]string{"emit", "-nope"}, "flag provided but not defined"},
		{[]string{"check"}, "check needs -snapshot"},
		{[]string{"check", "-snapshot", filepath.Join(dir, "missing.yaml")}, "no such file"},
		{[]string{"check", "-snapshot", filepath.Join(dir, "syntax.yaml")}, "syntax.yaml: yaml:"},
		{[]string{"check", "-snapshot", filepath.Join(dir, "format.yaml")}, `format is "other/v1"`},
		{[]string{"check", "-snapshot", filepath.Join(dir, "empty.yaml")}, "no collections"},
		{[]string{"check", "-snapshot", filepath.Join(dir, "odd.yaml")}, "is not a document path"},
		{[]string{"check", "-snapshot", filepath.Join(dir, "wild.yaml")}, "has no fixed collection name at segment 1"},
		{[]string{"check", "-snapshot", filepath.Join(dir, "good.yaml"), "-C", filepath.Join(dir, "nowhere")}, "cannot analyze (the check fails closed)"},
		{[]string{"emit", "-C", broken}, "cannot use"},
	}
	for _, c := range cases {
		code, _, errOut := runMain(t, c.args...)
		if code != 2 || !strings.Contains(errOut, c.want) {
			t.Errorf("%v: exit %d, stderr %q, want 2 and %q", c.args, code, errOut, c.want)
		}
	}
}

func TestAnalyzeError(t *testing.T) {
	offline(t)
	defer func(f func([]*analysis.Analyzer, []*packages.Package, *checker.Options) (*checker.Graph, error)) {
		analyze = f
	}(analyze)
	analyze = func([]*analysis.Analyzer, []*packages.Package, *checker.Options) (*checker.Graph, error) {
		return nil, errors.New("boom")
	}
	if _, err := Analyze("testdata/app", "testdata/app", []string{"./keys"}); err == nil || err.Error() != "boom" {
		t.Fatalf("err %v, want boom", err)
	}
}

func TestDefines(t *testing.T) {
	cases := []struct {
		def, kind, code string
		want            bool
	}{
		{"spaces/{space}/ext/{extension}", KindDocument, "spaces/{spaceID}/ext/{ext}", true},
		{"spaces/{space}/ext/calendarius/days/{date}", KindDocument, "spaces/{spaceID}/ext/calendarius/days/{date}", true},
		{"spaces/{space}/ext/calendarius/days/{date}", KindDocument, "spaces/{spaceID}/ext/{ext}/days/{date}", false},
		{"spaces/{space}/ext/calendarius/days/{date}", KindDocument, "spaces/{s}/ext/other/days/{date}", false},
		{"spaces/{space}/ext/calendarius/days/{date}", KindDocument, "spaces/{s}/ext/calendarius/dayz/{date}", false},
		{"spaces/{space}/ext/calendarius/happenings/{id}", KindCollection, "spaces/{s}/ext/calendarius/happenings", true},
		{"spaces/{space}/ext/calendarius/happenings/{id}", KindGroup, "happenings", true},
		{"spaces/{space}", KindGroup, "happenings", false},
		{"spaces/{space}", KindDocument, "spaces/{s}/ext/{e}", false},
	}
	for _, c := range cases {
		if got := Defines(c.def, c.kind, c.code); got != c.want {
			t.Errorf("Defines(%q, %s, %q) = %v, want %v", c.def, c.kind, c.code, got, c.want)
		}
	}
	(&keyFact{}).AFact()
	if s := (&keyFact{}).String(); s != "keyTemplates(0 results, 0 uses)" {
		t.Errorf("String() = %q", s)
	}
}
