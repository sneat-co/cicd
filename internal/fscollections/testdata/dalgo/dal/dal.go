// Package dal is a minimal stand-in for github.com/dal-go/dalgo/dal.
package dal

import "github.com/dal-go/record"

type CollectionRef struct {
	name   string
	parent *record.Key
}

type CollectionGroupRef struct{ name string }

func NewCollectionRef(name, alias string, parent *record.Key) CollectionRef {
	return CollectionRef{name: name, parent: parent}
}

func NewRootCollectionRef(name, alias string) CollectionRef { return CollectionRef{name: name} }

func NewCollectionGroupRef(name, alias string) CollectionGroupRef {
	return CollectionGroupRef{name: name}
}
