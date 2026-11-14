// Package app exercises every way the analyzer follows a key.
package app

import (
	"errors"
	"fmt"
	"reflect"

	"example.com/app/keys"

	"github.com/dal-go/dalgo/dal"
	"github.com/dal-go/record"
)

const happenings = "happenings"

// A package-level key.
var rootKey = record.NewKeyWithID("roots", "r1")

func constants() {
	_ = record.NewKeyWithID("plain", 7)                                      // plain/7
	_ = record.NewKeyWithParentAndID(rootKey, "children", "c")               // rootKey is a package var: unresolved
	_ = keys.ItemKey("s1", keys.Ext, happenings, "h1")                       // spaces/s1/ext/demo/happenings/h1
	_ = keys.ItemKey("", "other", "days", "d1")                              // ext/other/days/d1 only
	_, _ = record.NewKeyWithOptions("optioned")                              // optioned/{id}
	_ = record.NewKeyWithFields("fielded")                                   // fielded/{id}
	_ = dal.NewRootCollectionRef("rootColl", "")                             // collection rootColl
	_ = dal.NewCollectionGroupRef("grouped", "")                             // group grouped
	_ = record.NewRecordWithIncompleteKey("incomplete", reflect.String, nil) // group incomplete
	_ = record.NewIncompleteKey("orphan", reflect.String, nil)               // group orphan
	_ = record.NewDataWithID("i", record.NewKeyWithID("wrapped", "w"), 1)
	_ = record.NewWithID("i", record.NewKeyWithID("withid", "w"), nil)
	_ = record.NewRecord(record.NewKeyWithID("bare", "b"))
	_ = keys.Get("gotten", "g1")                // spaces/s1/gotten/g1
	_ = dal.NewRootCollectionRef("grouped", "") // collection and group of one name
	_ = errors.New("x").Error()                 // a method with no package
}

func variables(spaceID string, n int) {
	parent := keys.SpaceKey(spaceID)
	_ = record.NewKeyWithParentAndID(parent, "kids", n) // spaces/{spaceID}/kids/{n}
	var coll = "named"
	_ = record.NewKeyWithID(coll, spaceID) // named/{spaceID}
	id := fmt.Sprint(n)
	_ = record.NewKeyWithID("sprinted", id)               // sprinted/{id}
	_ = record.NewKeyWithID("selected", rootKeyHolder.ID) // selected/{ID}
	_ = record.NewKeyWithID("called", fmt.Sprint(n))      // called/{id}
	_ = dal.NewCollectionRef(happenings, "", keys.ModuleKey(spaceID, keys.Ext))
	_, k, _ := keys.Generate(spaceID, "generated")
	_ = record.NewRecordWithData(k, nil)
	var gid, gk, gerr = keys.Generate(spaceID, "vargen")
	_, _ = gid, gerr
	_ = record.NewRecordWithData(gk, nil)
	var reassigned *record.Key
	reassigned = keys.SpaceKey("a")
	reassigned = keys.SpaceKey("b")
	_ = record.NewKeyWithParentAndID(reassigned, "twice", "t") // unresolved: assigned twice
}

var rootKeyHolder struct{ ID string }

func problems(f func() *record.Key, names []string, v any) {
	_ = record.NewKeyWithID(names[0], "x")            // unresolved: not a constant
	_ = record.NewKeyWithParentAndID(f(), "dyn", "d") // unresolved: dynamic call
	_ = record.NewRecordWithData(f(), nil)            // pass-through: ignored
	k, ok := v.(*record.Key)
	_ = ok
	_ = record.NewKeyWithParentAndID(k, "asserted", "a")                                              // unresolved: not a call
	_ = record.NewKeyWithParentAndID(rootKeyHolderKey.Key, "field", "f")                              // unresolved: selector
	_ = record.NewKeyWithParentAndID(record.NewIncompleteKey("p", reflect.String, nil), "child", "c") // group parent
	_ = record.NewKeyWithParentAndID(unknownKey(), "unknown", "u")                                    // no known template
	_ = (*holder).Key(&holder{}, "methodExpr")                                                        // methodExpr/h
	_ = (&holder{}).Key("methodCall")                                                                 // methodCall/h
	_ = record.NewKeyWithParentAndID(helperCollection(names[4], "x"), "c", "d")                       // parent from a non-constant collection
	_ = keys.ItemKey("s", keys.ExtID(names[1]), names[0], "i")                                        // collection not a constant
	for _, name := range names {
		_ = record.NewKeyWithID(name, "r") // unresolved: range variable
	}
	//firestore:path declared/{id} other/{id}/deep -- a reviewed dynamic name
	_ = record.NewKeyWithID(names[2], "x")
	_ = record.NewKeyWithID(names[3], "y") //firestore:path inline/{id}
}

var rootKeyHolderKey struct{ Key *record.Key }

func unknownKey() *record.Key { return rootKeyHolderKey.Key }

type holder struct{}

// Key is a method whose fact maps parameters without the receiver.
func (*holder) Key(coll string) *record.Key { return record.NewKeyWithID(coll, "h") }

// helperCollection returns a key built from its parameters.
func helperCollection(coll, id string) *record.Key {
	return record.NewKeyWithParentAndID(record.NewKeyWithID("ext", keys.Ext), coll, id)
}

// wrap only passes its key parameter on.
func wrap(k *record.Key) record.Record { return record.NewRecordWithData(k, nil) }

// pick returns one of two keys, the first under an empty-id guard.
func pick(spaceID string, id string) (*record.Key, error) {
	if x := 1; x > 0 {
		_ = x
	}
	if spaceID == "" {
		return helperCollection("spaceless", id), nil
	} else if "" == id {
		return nil, errors.New("no id")
	}
	if len(id) > 3 {
		return nil, nil
	}
	fn := func() *record.Key { return nil }
	_ = fn
	return keys.ItemKey(spaceID, keys.Ext, "picked", id), nil
}

// multi returns a call with several results.
func multi(spaceID string) (string, *record.Key, error) { return keys.Generate(spaceID, "multi") }

// guarded passes a variable to a guarded helper parameter: caller guard.
func guarded(id string) *record.Key {
	space := lookup()
	return keys.ModuleKey(space, keys.ExtID(id))
}

func lookup() string { return "s" }

// noReturn has a result that is not a key.
func noReturn(id string) string { return id }

// unknownResult returns a key it cannot follow; its callers fail closed.
func unknownResult() *record.Key { return rootKeyHolderKey.Key }

func helpers(id string, s fmt.Stringer) {
	_ = helperCollection("helped", id)   // ext/demo/helped/{id}
	_ = wrap(helperCollection("w2", id)) // ext/demo/w2/{id}
	_ = wrap(rootKeyHolderKey.Key)       // pass-through: ignored
	_, _ = pick("", id)                  // ext/demo/spaceless/{id}
	_, _ = pick("s9", id)                // spaces/s9/ext/demo/picked/{id}
	_, _, _ = multi(id)                  // spaces/{id}/... and guarded ext/...
	_ = guarded(id)
	_ = under(keys.ModuleKey(id, "z")) // the guard comes with the parent key
	_ = noReturn(id)
	_ = unknownResult()
	_ = s.String()
	_ = record.NewKeyWithParentAndID(guarded("x"), "below", "b")
	if id == "" {
		return
	}
}

// under builds below a key parameter.
func under(k *record.Key) *record.Key { return record.NewKeyWithParentAndID(k, "under2", "u") }

// mixed passes a key parameter and builds from a collection parameter.
func mixed(k *record.Key, coll string) {
	_ = record.NewKeyWithParentAndID(k, "under", "u")
	_ = record.NewKeyWithID(coll, "m")
}

func callsMixed() {
	mixed(record.NewKeyWithID("top", "t"), "mixedColl")
	mixed(rootKeyHolderKey.Key, "mixed2")
}
