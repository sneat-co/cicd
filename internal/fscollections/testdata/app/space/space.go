// Package space builds through the spaceless wrapper, whose guard alone is exempt.
package space

import (
	"github.com/dal-go/record"
	"github.com/sneat-co/sneat-go-core/coretypes"
)

// ItemKey passes its own parameter to the guard: the guard moves to ItemKey.
func ItemKey(spaceID coretypes.SpaceID, id string) *record.Key {
	return record.NewKeyWithParentAndID(coretypes.NewSpaceModuleKey(spaceID, "demo"), "items", id)
}

func lookup() coretypes.SpaceID { return "s" }

// Looked passes a variable: the guard stays, as a caller guard.
func Looked(id string) *record.Key {
	return record.NewKeyWithParentAndID(coretypes.NewSpaceModuleKey(lookup(), "demo"), "looked", id)
}

// below builds under a key parameter: a guarded parent passes its guard on.
func below(k *record.Key) *record.Key { return record.NewKeyWithParentAndID(k, "below", "b") }

func Uses(spaceID coretypes.SpaceID, id string) {
	_ = ItemKey("s1", id) // only spaces/s1/ext/demo/items/{id}
	_ = ItemKey("", id)   // only ext/demo/items/{id}, unguarded
	_ = ItemKey(spaceID, id)
	_ = Looked(id)
	_ = record.NewKeyWithParentAndID(Looked(id), "deeper", "d")
	_ = below(coretypes.NewSpaceModuleKey(spaceID, "z"))
}
