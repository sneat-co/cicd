// Package keys holds key helpers whose facts other packages use.
package keys

import "github.com/dal-go/record"

const Ext = "demo"

type ExtID string

func SpaceKey(spaceID string) *record.Key { return record.NewKeyWithID("spaces", spaceID) }

// ModuleKey has a spaceless branch, as coretypes.NewSpaceModuleKey does.
func ModuleKey(spaceID string, ext ExtID) *record.Key {
	if spaceID == "" {
		return record.NewKeyWithID("ext", string(ext))
	}
	return record.NewKeyWithParentAndID(SpaceKey(spaceID), "ext", string(ext))
}

func ItemKey(spaceID string, ext ExtID, collection, id string) *record.Key {
	k := ModuleKey(spaceID, ext)
	return record.NewKeyWithParentAndID(k, collection, id)
}

// Generate returns the key among other results, with named results.
func Generate(spaceID string, collection string) (id string, key *record.Key, err error) {
	id = "x"
	key = ItemKey(spaceID, Ext, collection, id)
	return
}

// Get uses a collection parameter without returning the key.
func Get(collection, id string) error {
	_ = record.NewRecordWithData(record.NewKeyWithParentAndID(SpaceKey("s1"), collection, id), nil)
	return nil
}
