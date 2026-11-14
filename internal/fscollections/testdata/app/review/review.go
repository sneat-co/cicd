// Package review holds one case per finding of the independent review.
package review

import (
	"example.com/depmod"

	"github.com/dal-go/dalgo/dal"
	"github.com/dal-go/record"
	"github.com/sneat-co/sneat-go-core/coretypes"
)

type keyer interface{ Key(coll string) *record.Key }

type holder struct{}

func (*holder) Key(coll string) *record.Key { return record.NewKeyWithID(coll, "h") }

// B1: constructors called through a func, method or interface value fail closed.
func b1FuncValues(id string, k keyer) {
	f := record.NewKeyWithID[string]
	_ = f("viaFuncValue", id) // unresolved
	m := (&holder{}).Key
	_ = m("viaMethodValue")   // unresolved
	_ = k.Key("viaInterface") // unresolved
	_ = new(record.Key)       // a builtin: not a path
	_ = (*record.Key)(nil)    // a conversion: not a path
	g := record.NewKeyWithOptions
	_, _ = g("viaFuncTuple") // unresolved
	h := func() (int, error) { return 0, nil }
	_, _ = h() // no key: not a path
}

// B2: helpers in another module that cannot be followed fail closed.
func b2OtherModule(id string) {
	_ = depmod.Dyn("viaDep", id)                           // unresolved
	_ = depmod.Store{Coll: "viaField"}.Key(id)             // unresolved
	_ = depmod.Fixed(id)                                   // depFixed/{id}
	_ = record.NewRecordWithData(depmod.Dyn("w", id), nil) // unresolved (the inner call)
}

// M1: only the coretypes.NewSpaceModuleKey spaceless branch is exempt.
func m1Guards(spaceID coretypes.SpaceID, id string) {
	if id == "" {
		_ = record.NewKeyWithID("sneakyNew", "x") // a path like any other
	}
	_ = record.NewKeyWithParentAndID(coretypes.NewSpaceModuleKey(spaceID, "demo"), "items", id)
}

// M2: key options are followed; options the check cannot read fail closed.
func m2Options(id string, opts []record.KeyOption, o record.KeyOption) {
	_, _ = record.NewKeyWithOptions("opt", record.WithParentKey(record.NewKeyWithID("p", id)), record.WithKeyID(id))
	_, _ = record.NewKeyWithOptions("optString", record.WithStringID("s1"))
	_, _ = record.NewKeyWithOptions("optInt", record.WithIntID(3))
	_, _ = record.NewKeyWithOptions("optFields", record.WithFields(nil))
	_, _ = record.NewKeyWithOptions("optSpread", opts...)                                   // unresolved
	_, _ = record.NewKeyWithOptions("optUnknown", o)                                        // unresolved
	_, _ = record.NewKeyWithOptions("optParent", record.WithParentKey(depmod.Dyn("q", id))) // unresolved
	_ = record.NewKeyWithFields("fieldsOnly", record.FieldVal{Name: "a", Value: 1})
}

// m1: dal constructors the check does not model fail closed.
func m1Unsupported() {
	_ = dal.NewQualifiedRootCollectionRef("s", "qualified", "") // unresolved
	_ = dal.NewDatabaseCollectionRef("d", "s", "database", "")  // unresolved
	_ = dal.CollectionAt[string, int]("typed")                  // unresolved
	_ = record.NewRecordWithoutKey(nil)                         // no key: not a path
}

// from passes a collection reference on; it keeps its kind.
func from(c dal.CollectionRef) dal.CollectionRef { return c }

func m2PassThrough() {
	_ = from(dal.NewRootCollectionRef("viaFrom", "")) // collection viaFrom only
}

// Entries built by field assignment or a composite literal carry their key.
type entry = record.DataWithID[string, int]

func newEntry(id string) (e entry) {
	e.ID = id
	e.Key = record.NewKeyWithID("entries", id)
	return
}

func newLit(id string) entry { return entry{ID: id, Key: record.NewKeyWithID("lits", id)} }

func newNoKey(id string) entry { return entry{ID: id} }

func useEntries(id string) {
	_ = newEntry(id) // entries/{id}
	_ = newLit(id)   // lits/{id}
	_ = newNoKey(id) // unresolved
	e := newEntry(id)
	_ = record.NewRecordWithData(e.Key, nil)
}

type box struct{ e entry }

// boxed sets a key in a nested field: built here, not followed through the box.
func boxed(id string) (b box) {
	b.e.Key = record.NewKeyWithID("boxed", id)
	return
}

// fromRecord takes a method value named Key, which is not a key field.
func fromRecord(r record.Record) func() *record.Key { return r.Key }
