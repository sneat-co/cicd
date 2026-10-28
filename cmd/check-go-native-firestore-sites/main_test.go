package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

const repo = "example/product"

func git(t *testing.T, root string, args ...string) string {
	t.Helper()
	out, err := exec.Command("git", append([]string{"-C", root}, args...)...).CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v %s", args, err, out)
	}
	return strings.TrimSpace(string(out))
}
func fixture(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	git(t, dir, "init", "-q")
	write(t, dir, "main.go", "package main\n")
	return dir
}
func write(t *testing.T, root, name, data string) {
	t.Helper()
	path := filepath.Join(root, name)
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(data), 0600); err != nil {
		t.Fatal(err)
	}
	git(t, root, "add", "--", name)
}
func policy(sites ...site) manifest {
	return manifest{Version: 1, Repositories: map[string]repository{repo: {Sites: append([]site{}, sites...)}}}
}
func approved(t *testing.T, root, name, imp, class string) site {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(root, name))
	if err != nil {
		t.Fatal(err)
	}
	h := sha256.Sum256(b)
	return site{File: name, Import: imp, SHA256: hex.EncodeToString(h[:]), Class: class, Owner: "storage owner", Rationale: "Reviewed bounded fixture", Review: "https://github.com/example/product/pull/1", Test: "https://github.com/example/product/blob/main/path_test.go"}
}
func verify(t *testing.T, root string, m manifest, want string) {
	t.Helper()
	findings, err := check(root, repo, m)
	if err != nil {
		t.Fatal(err)
	}
	got := strings.Join(findings, "\n")
	if want == "" && len(findings) > 0 {
		t.Fatal(got)
	}
	if want != "" && !strings.Contains(got, want) {
		t.Fatalf("want %q, got %q", want, got)
	}
}
func TestClassifiesOnlyNativeStorageCapabilities(t *testing.T) {
	for _, p := range []string{"cloud.google.com/go/firestore", "cloud.google.com/go/firestore/apiv1", "firebase.google.com/go", "firebase.google.com/go/v4", "github.com/dal-go/dalgo2firestore", "google.golang.org/api/firestore/v1", "github.com/trakhimenok/google-cloud-go/firestore"} {
		if !nativeImport(p) {
			t.Error(p)
		}
	}
	for _, p := range []string{"firebase.google.com/go/v4/auth", "firebase.google.com/go/v4/appcheck", "cloud.google.com/go/firestorex", "github.com/dal-go/dalgo/dal"} {
		if nativeImport(p) {
			t.Error(p)
		}
	}
}
func TestOrdinaryDALgoAndReviewedSites(t *testing.T) {
	for _, c := range []string{"secured-factory", "deliberate-native-owner", "read-only-native-owner", "test-only"} {
		t.Run(c, func(t *testing.T) {
			root := fixture(t)
			write(t, root, "ordinary.go", "package x\nimport _ \"github.com/dal-go/dalgo/dal\"\n")
			verify(t, root, policy(), "")
			name := "site.go"
			if c == "test-only" {
				name = "site_test.go"
			}
			write(t, root, name, "package x\nimport fs \"cloud.google.com/go/firestore\"\nvar newClient = fs.NewClient\n")
			verify(t, root, policy(approved(t, root, name, "cloud.google.com/go/firestore", c)), "")
		})
	}
}
func TestAllTrackedSourceIncludesAliasesBuildTagsAndNestedModules(t *testing.T) {
	for _, name := range []string{"alias.go", "dot.go", "blank_test.go", "tools/tagged_windows.go", "backend/nested/go.go", "_tools/main.go", "testdata/module/main.go", ".tools/main.go"} {
		t.Run(name, func(t *testing.T) {
			root := fixture(t)
			alias := "f"
			expr := "var factory = f.NewClient"
			if name == "dot.go" {
				alias = "."
				expr = "var factory = NewClient"
			}
			if name == "blank_test.go" {
				alias = "_"
				expr = ""
			}
			write(t, root, name, "//go:build impossible\n\npackage x\nimport "+alias+" \"cloud.google.com/go/firestore\"\n"+expr+"\n")
			write(t, root, filepath.Dir(name)+"/go.mod", "module example/nested\n")
			verify(t, root, policy(), name+":")
		})
	}
}
func TestExistingNativeOwnerChangesAndCopiesFail(t *testing.T) {
	root := fixture(t)
	imp := "cloud.google.com/go/firestore"
	original := "package x\nimport fs \"" + imp + "\"\nfunc owner(c *fs.Client) {}\n"
	write(t, root, "owner.go", original)
	s := approved(t, root, "owner.go", imp, "deliberate-native-owner")
	verify(t, root, policy(s), "")
	for _, extra := range []string{"var aliasFactory = fs.NewClient\n", "func mutate(c *fs.Client) { c.Collection(\"badRoot\").Doc(\"x\").Set(nil,nil) }\n"} {
		write(t, root, "owner.go", original+extra)
		verify(t, root, policy(s), "privileged file changed")
	}
	write(t, root, "owner.go", original)
	write(t, root, "copied.go", original)
	verify(t, root, policy(s), "unclassified native import")
	git(t, root, "rm", "-f", "--", "owner.go")
	verify(t, root, policy(s), "stale site")
}
func TestFailsClosedOnSourceHoles(t *testing.T) {
	for _, kind := range []string{"parse", "deleted", "symlink", "submodule", "missing-repo", "empty"} {
		t.Run(kind, func(t *testing.T) {
			root := fixture(t)
			m := policy()
			switch kind {
			case "parse":
				write(t, root, "broken.go", "package x\nimport _ \"cloud.google.com/go/firestore\"\nfunc {\n")
			case "deleted":
				if err := os.Remove(filepath.Join(root, "main.go")); err != nil {
					t.Fatal(err)
				}
			case "symlink":
				if err := os.Symlink("main.go", filepath.Join(root, "alias.go")); err != nil {
					t.Fatal(err)
				}
				git(t, root, "add", "alias.go")
			case "submodule":
				git(t, root, "update-index", "--add", "--cacheinfo", "160000,"+strings.Repeat("a", 40)+",module")
			case "missing-repo":
				m.Repositories = map[string]repository{}
			case "empty":
				git(t, root, "rm", "-f", "main.go")
			}
			if _, err := check(root, repo, m); err == nil {
				t.Fatal("source hole passed")
			}
		})
	}
}
func TestManifestRejectsMalformedAndUnclassifiedMetadata(t *testing.T) {
	root := fixture(t)
	write(t, root, "owner.go", "package x\nimport _ \"cloud.google.com/go/firestore\"\n")
	s := approved(t, root, "owner.go", "cloud.google.com/go/firestore", "secured-factory")
	b, _ := json.Marshal(policy(s))
	if _, err := loadManifest(b); err != nil {
		t.Fatal(err)
	}
	for _, bad := range []string{`{}`, `null`, `{"version":1,"version":1,"repositories":{}}`, `{"version":1,"repositories":{},"unknown":true}`, string(b) + ` {}`, strings.Replace(string(b), `"sites":[`, `"sites":null,"other":[`, 1)} {
		if _, err := loadManifest([]byte(bad)); err == nil {
			t.Fatalf("accepted %s", bad)
		}
	}
	for _, field := range []string{"file", "import", "sha256", "class", "owner", "rationale", "review", "test", "duplicate"} {
		t.Run(field, func(t *testing.T) {
			v := s
			switch field {
			case "file":
				v.File = "../escape.go"
			case "import":
				v.Import = "example/other"
			case "sha256":
				v.SHA256 = "abc"
			case "class":
				v.Class = "wildcard"
			case "owner":
				v.Owner = ""
			case "rationale":
				v.Rationale = ""
			case "review":
				v.Review = "file:///local"
			case "test":
				v.Test = ""
			}
			m := policy(v)
			if field == "duplicate" {
				m = policy(v, v)
			}
			data, _ := json.Marshal(m)
			if _, err := loadManifest(data); err == nil {
				t.Fatal("bad manifest passed")
			}
		})
	}
}
func TestCommandRequiresTrackedManifestAndReturnsFindings(t *testing.T) {
	root := fixture(t)
	var out bytes.Buffer
	if run(nil, &out, &out) != 2 {
		t.Fatal("empty arguments passed")
	}
	args := []string{"--root", root, "--repository", repo, "--manifest", "sites.json"}
	if run(args, &out, &out) != 2 {
		t.Fatal("missing manifest passed")
	}
	b, _ := json.Marshal(policy())
	write(t, root, "sites.json", string(b))
	if code := run(args, &out, &out); code != 0 {
		t.Fatalf("clean: %d %s", code, out.String())
	}
	write(t, root, "native.go", "package x\nimport _ \"cloud.google.com/go/firestore\"\n")
	if run(args, &out, &out) != 1 {
		t.Fatal("unclassified import passed")
	}
	write(t, root, "sites.json", "{")
	if run(args, &out, &out) != 2 {
		t.Fatal("malformed manifest passed")
	}
}

func TestCommandRejectsEscapesWrongRootAndUntrackedManifest(t *testing.T) {
	root := fixture(t)
	var out bytes.Buffer
	valid, _ := json.Marshal(policy())
	path := filepath.Join(root, "sites.json")
	if err := os.WriteFile(path, valid, 0600); err != nil {
		t.Fatal(err)
	}
	args := []string{"--root", root, "--repository", repo, "--manifest", "sites.json"}
	if run(args, &out, &out) != 2 {
		t.Fatal("untracked manifest passed")
	}
	git(t, root, "add", "sites.json")
	for _, name := range []string{"../sites.json", "/tmp/sites.json", "sites*.json", ""} {
		bad := append([]string{}, args...)
		bad[len(bad)-1] = name
		if run(bad, &out, &out) != 2 {
			t.Fatal("unsafe manifest passed", name)
		}
	}
	if err := os.Mkdir(filepath.Join(root, "sub"), 0700); err != nil {
		t.Fatal(err)
	}
	bad := append([]string{}, args...)
	bad[1] = filepath.Join(root, "sub")
	if run(bad, &out, &out) != 2 {
		t.Fatal("subdirectory root passed")
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("main.go", path); err != nil {
		t.Fatal(err)
	}
	if run(args, &out, &out) != 2 {
		t.Fatal("symlink manifest passed")
	}
}
func TestStaleRemovedImportAndVendorExclusion(t *testing.T) {
	root := fixture(t)
	write(t, root, "site.go", "package x\nimport _ \"cloud.google.com/go/firestore\"\n")
	s := approved(t, root, "site.go", "cloud.google.com/go/firestore", "secured-factory")
	write(t, root, "site.go", "package x\n")
	verify(t, root, policy(s), "stale site")
	write(t, root, "vendor/native.go", "package x\nimport _ \"cloud.google.com/go/firestore\"\n")
	verify(t, root, policy(), "")
}
