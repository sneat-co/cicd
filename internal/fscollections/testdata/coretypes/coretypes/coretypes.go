// Package coretypes stands in for the one wrapper whose spaceless branch is
// exempt: sneat-go-core coretypes.NewSpaceModuleKey.
package coretypes

import "github.com/dal-go/record"

type SpaceID string

type ExtID string

const none = ""

func NewSpaceModuleKey(spaceID SpaceID, moduleID ExtID) *record.Key {
	if none == spaceID {
		return record.NewKeyWithID("ext", string(moduleID))
	}
	return record.NewKeyWithParentAndID(record.NewKeyWithID("spaces", string(spaceID)), "ext", string(moduleID))
}
