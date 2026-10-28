// Command check-go-native-firestore-sites checks reviewed native storage import sites.
package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"go/parser"
	"go/token"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

type manifest struct {
	Version      int                   `json:"version"`
	Repositories map[string]repository `json:"repositories"`
}
type repository struct {
	Sites []site `json:"sites"`
}
type site struct {
	File      string `json:"file"`
	Import    string `json:"import"`
	SHA256    string `json:"sha256"`
	Class     string `json:"class"`
	Owner     string `json:"owner"`
	Rationale string `json:"rationale"`
	Review    string `json:"review"`
	Test      string `json:"test"`
}

var repositoryName = regexp.MustCompile(`^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$`)
var digest = regexp.MustCompile(`^[a-f0-9]{64}$`)

var firebaseApp = regexp.MustCompile(`^firebase\.google\.com/go(/v[0-9]+)?$`)

func nativeImport(p string) bool {
	if firebaseApp.MatchString(p) {
		return true
	}
	for _, prefix := range []string{"cloud.google.com/go/firestore", "github.com/dal-go/dalgo2firestore", "google.golang.org/api/firestore", "github.com/trakhimenok/google-cloud-go/firestore"} {
		if p == prefix || strings.HasPrefix(p, prefix+"/") {
			return true
		}
	}
	return false
}
func safePath(p string) bool {
	return p != "" && p != "." && filepath.ToSlash(filepath.Clean(p)) == p && !filepath.IsAbs(p) && !strings.HasPrefix(p, "../") && !strings.ContainsAny(p, "\\*?[]{}\x00\r\n\t")
}

// encoding/json silently overwrites duplicate keys; reject them first.
func uniqueJSON(d *json.Decoder) error {
	t, err := d.Token()
	if err != nil {
		return err
	}
	delimiter, ok := t.(json.Delim)
	if !ok {
		return nil
	}
	switch delimiter {
	case '{':
		seen := map[string]bool{}
		for d.More() {
			k, err := d.Token()
			if err != nil {
				return err
			}
			key, ok := k.(string)
			if !ok {
				return fmt.Errorf("invalid object key")
			}
			if seen[key] {
				return fmt.Errorf("duplicate JSON key %q", key)
			}
			seen[key] = true
			if err := uniqueJSON(d); err != nil {
				return err
			}
		}
	case '[':
		for d.More() {
			if err := uniqueJSON(d); err != nil {
				return err
			}
		}
	default:
		return fmt.Errorf("unexpected JSON delimiter")
	}
	_, err = d.Token()
	return err
}
func loadManifest(data []byte) (manifest, error) {
	var m manifest
	d := json.NewDecoder(bytes.NewReader(data))
	if err := uniqueJSON(d); err != nil {
		return m, err
	}
	if _, err := d.Token(); err != io.EOF {
		return m, fmt.Errorf("manifest must contain one JSON value")
	}
	d = json.NewDecoder(bytes.NewReader(data))
	d.DisallowUnknownFields()
	if err := d.Decode(&m); err != nil {
		return m, err
	}
	if m.Version != 1 || m.Repositories == nil {
		return m, fmt.Errorf("manifest requires version 1 and repositories object")
	}
	for name, r := range m.Repositories {
		if !repositoryName.MatchString(name) || strings.Contains(name, "..") {
			return m, fmt.Errorf("invalid repository %q", name)
		}
		if r.Sites == nil {
			return m, fmt.Errorf("%s requires explicit sites array", name)
		}
		seen := map[string]bool{}
		for _, s := range r.Sites {
			if !safePath(s.File) || !strings.HasSuffix(s.File, ".go") || !nativeImport(s.Import) || !digest.MatchString(s.SHA256) {
				return m, fmt.Errorf("invalid native site in %s: %q", name, s.File)
			}
			switch s.Class {
			case "secured-factory", "deliberate-native-owner", "read-only-native-owner", "test-only":
			default:
				return m, fmt.Errorf("invalid class for %s", s.File)
			}
			if s.Class == "test-only" && !strings.HasSuffix(s.File, "_test.go") {
				return m, fmt.Errorf("test-only must name a test file: %s", s.File)
			}
			if strings.TrimSpace(s.Owner) == "" || strings.TrimSpace(s.Rationale) == "" || !strings.HasPrefix(s.Review, "https://github.com/") || !strings.HasPrefix(s.Test, "https://github.com/") {
				return m, fmt.Errorf("site %s requires owner, rationale, GitHub review and test references", s.File)
			}
			key := s.File + "\x00" + s.Import
			if seen[key] {
				return m, fmt.Errorf("duplicate site: %s", s.File)
			}
			seen[key] = true
		}
	}
	return m, nil
}

// Document links do not add executable source. Directory, broken and source
// links fail closed because their contents are not enumerated by the Git index.
func validateNonSourceLink(root, name string) error {
	source := func(path string) bool {
		base := filepath.Base(path)
		return strings.EqualFold(filepath.Ext(path), ".go") || base == "go.mod" || base == "go.work"
	}
	if source(name) {
		return fmt.Errorf("source symlink requires separate coverage: %s", name)
	}
	real, err := filepath.EvalSymlinks(filepath.Join(root, filepath.FromSlash(name)))
	if err != nil {
		return fmt.Errorf("unresolved symlink %s: %w", name, err)
	}
	info, err := os.Stat(real)
	if err != nil {
		return fmt.Errorf("stat symlink target %s: %w", name, err)
	}
	if !info.Mode().IsRegular() || source(real) {
		return fmt.Errorf("symlink target is not a regular non-source file: %s", name)
	}
	return nil
}

func check(root, repo string, m manifest) ([]string, error) {
	r, ok := m.Repositories[repo]
	if !ok {
		return nil, fmt.Errorf("repository %q has no manifest entry", repo)
	}
	root, err := filepath.Abs(root)
	if err != nil {
		return nil, err
	}
	root, err = filepath.EvalSymlinks(root)
	if err != nil {
		return nil, err
	}
	out, err := exec.Command("git", "-C", root, "ls-files", "--stage", "-z").Output()
	if err != nil {
		return nil, fmt.Errorf("enumerate tracked source: %w", err)
	}
	entries := map[string]site{}
	remaining := map[string]bool{}
	for _, s := range r.Sites {
		k := s.File + "\x00" + s.Import
		entries[k] = s
		remaining[k] = true
	}
	var findings []string
	count := 0
	for _, raw := range bytes.Split(out, []byte{0}) {
		if len(raw) == 0 {
			continue
		}
		parts := strings.SplitN(string(raw), "\t", 2)
		if len(parts) != 2 {
			return nil, fmt.Errorf("invalid git index entry")
		}
		meta := strings.Fields(parts[0])
		if len(meta) != 3 || meta[2] != "0" {
			return nil, fmt.Errorf("invalid or unmerged index entry")
		}
		name := parts[1]
		if !safePath(name) {
			return nil, fmt.Errorf("unsafe tracked path %q", name)
		}
		if meta[0] == "160000" {
			return nil, fmt.Errorf("submodule requires separate coverage: %s", name)
		}
		if meta[0] == "120000" {
			if err := validateNonSourceLink(root, name); err != nil {
				return nil, err
			}
			continue
		}
		if !strings.HasSuffix(name, ".go") || strings.Contains("/"+name, "/vendor/") {
			continue
		}
		path := filepath.Join(root, filepath.FromSlash(name))
		real, err := filepath.EvalSymlinks(path)
		if err != nil {
			return nil, fmt.Errorf("resolve %s: %w", name, err)
		}
		if real != path {
			return nil, fmt.Errorf("source symlink: %s", name)
		}
		info, err := os.Lstat(path)
		if err != nil {
			return nil, err
		}
		if !info.Mode().IsRegular() {
			return nil, fmt.Errorf("nonregular source %s", name)
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return nil, fmt.Errorf("read %s: %w", name, err)
		}
		fs := token.NewFileSet()
		f, err := parser.ParseFile(fs, name, data, parser.AllErrors)
		if err != nil {
			return nil, fmt.Errorf("parse %s: %w", name, err)
		}
		count++
		hash := sha256.Sum256(data)
		sum := hex.EncodeToString(hash[:])
		for _, imp := range f.Imports {
			p, err := strconv.Unquote(imp.Path.Value)
			if err != nil {
				return nil, err
			}
			if !nativeImport(p) {
				continue
			}
			k := name + "\x00" + p
			expected, ok := entries[k]
			delete(remaining, k)
			if !ok {
				findings = append(findings, fmt.Sprintf("%s:%d: unclassified native import %s", name, fs.Position(imp.Pos()).Line, p))
			} else if expected.SHA256 != sum {
				findings = append(findings, fmt.Sprintf("%s:%d: privileged file changed since %s classification", name, fs.Position(imp.Pos()).Line, expected.Class))
			}
		}
	}
	if count == 0 {
		return nil, fmt.Errorf("no tracked Go source found; cannot certify repository")
	}
	for key := range remaining {
		findings = append(findings, "stale site: "+strings.ReplaceAll(key, "\x00", " imports "))
	}
	sort.Strings(findings)
	return findings, nil
}
func run(args []string, stdout, stderr io.Writer) int {
	flags := flag.NewFlagSet("check-go-native-firestore-sites", flag.ContinueOnError)
	flags.SetOutput(stderr)
	root := flags.String("root", "", "target repository root")
	repo := flags.String("repository", "", "trusted owner/repository")
	policy := flags.String("manifest", "", "tracked manifest path relative to target root")
	if err := flags.Parse(args); err != nil {
		return 2
	}
	if flags.NArg() != 0 || *root == "" || !repositoryName.MatchString(*repo) || !safePath(*policy) {
		fmt.Fprintln(stderr, "require --root, --repository and safe relative --manifest")
		return 2
	}
	absolute, err := filepath.Abs(*root)
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 2
	}
	absolute, err = filepath.EvalSymlinks(absolute)
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 2
	}
	top, err := exec.Command("git", "-C", absolute, "rev-parse", "--show-toplevel").Output()
	if err != nil || strings.TrimSpace(string(top)) != absolute {
		fmt.Fprintln(stderr, "--root must be the Git repository root")
		return 2
	}
	path := filepath.Join(absolute, filepath.FromSlash(*policy))
	real, err := filepath.EvalSymlinks(path)
	if err != nil || real != path {
		fmt.Fprintln(stderr, "manifest must be a readable nonsymlink inside target root")
		return 2
	}
	if err := exec.Command("git", "-C", absolute, "ls-files", "--error-unmatch", "--", *policy).Run(); err != nil {
		fmt.Fprintln(stderr, "manifest must be tracked")
		return 2
	}
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() {
		fmt.Fprintln(stderr, "manifest must be a regular file")
		return 2
	}
	data, err := os.ReadFile(path)
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 2
	}
	m, err := loadManifest(data)
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 2
	}
	findings, err := check(absolute, *repo, m)
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 2
	}
	hash := sha256.Sum256(data)
	fmt.Fprintf(stdout, "Manifest SHA256: %x\n", hash)
	if len(findings) > 0 {
		for _, f := range findings {
			fmt.Fprintln(stderr, f)
		}
		return 1
	}
	fmt.Fprintf(stdout, "Native Firestore import-site consistency passed for %s; independent exact-head review remains required. This is not universal runtime write protection.\n", *repo)
	return 0
}
func main() { os.Exit(run(os.Args[1:], os.Stdout, os.Stderr)) }
