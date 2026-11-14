package fscollections

import (
	"fmt"
	"os"
	"strings"

	"gopkg.in/yaml.v3"
)

// SnapshotFormat is the format line of a generated snapshot.
const SnapshotFormat = "firestore-collections/v1"

// Snapshot is the generated list of defined collections a repository commits.
type Snapshot struct {
	Format      string          `yaml:"format"`
	Source      string          `yaml:"source"`
	Collections []SnapshotEntry `yaml:"collections"`
}

// SnapshotEntry is one defined collection.
type SnapshotEntry struct {
	Path   string `yaml:"path"`
	Owner  string `yaml:"owner"`
	Review string `yaml:"review"`
}

type pseg struct {
	wild bool
	v    string
}

// parsePath splits a path; a {name} segment matches any value.
func parsePath(p string) []pseg {
	parts := strings.Split(p, "/")
	out := make([]pseg, len(parts))
	for i, s := range parts {
		if strings.HasPrefix(s, "{") && strings.HasSuffix(s, "}") {
			out[i] = pseg{wild: true, v: s}
		} else {
			out[i] = pseg{v: s}
		}
	}
	return out
}

// validPath reports why a defined document path is malformed, or "".
func validPath(p string) string {
	segs := parsePath(p)
	if len(segs)%2 != 0 {
		return "is not a document path (it needs collection/id pairs)"
	}
	for i := 0; i < len(segs); i += 2 {
		if segs[i].wild || segs[i].v == "" {
			return fmt.Sprintf("has no fixed collection name at segment %d", i+1)
		}
	}
	return ""
}

// LoadSnapshot reads and validates a snapshot file.
func LoadSnapshot(path string) (*Snapshot, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var s Snapshot
	if err := yaml.Unmarshal(data, &s); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	if s.Format != SnapshotFormat {
		return nil, fmt.Errorf("%s: format is %q, want %q", path, s.Format, SnapshotFormat)
	}
	if len(s.Collections) == 0 {
		return nil, fmt.Errorf("%s: no collections", path)
	}
	for _, c := range s.Collections {
		if why := validPath(c.Path); why != "" {
			return nil, fmt.Errorf("%s: path %q %s", path, c.Path, why)
		}
	}
	return &s, nil
}

// Defines reports whether a defined document path covers a path built by code.
// Collection names must be equal; an id segment that is {name} in the
// definition matches any id, and a fixed id in the definition matches only
// the same fixed id in code.
func Defines(def, kind, code string) bool {
	d := parsePath(def)
	c := parsePath(code)
	switch kind {
	case KindGroup:
		return len(d) >= 2 && d[len(d)-2].v == code
	case KindCollection:
		c = append(c, pseg{wild: true, v: "{id}"})
	}
	if len(d) != len(c) {
		return false
	}
	for i := range d {
		fixed := i%2 == 0 || !d[i].wild
		if fixed && (c[i].wild || c[i].v != d[i].v) {
			return false
		}
	}
	return true
}

// Defined reports whether any snapshot entry covers a path built by code.
func (s *Snapshot) Defined(kind, code string) bool {
	for _, c := range s.Collections {
		if Defines(c.Path, kind, code) {
			return true
		}
	}
	return false
}
