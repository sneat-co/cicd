// Package depmod is another module whose key helpers cannot all be followed.
package depmod

import "github.com/dal-go/record"

// Dyn builds its collection name at run time.
func Dyn(coll, id string) *record.Key { return record.NewKeyWithID(coll+"x", id) }

// Store builds keys from a field.
type Store struct{ Coll string }

func (s Store) Key(id string) *record.Key { return record.NewKeyWithID(s.Coll, id) }

// Fixed is a helper that can be followed.
func Fixed(id string) *record.Key { return record.NewKeyWithID("depFixed", id) }
