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

func NewQualifiedRootCollectionRef(schema, name, alias string) CollectionRef {
	return CollectionRef{name: name}
}

func NewDatabaseCollectionRef(database, schema, name, alias string) CollectionRef {
	return CollectionRef{name: name}
}

// Collection is a typed collection; its methods build keys from its name.
type Collection[K comparable, T any] interface{ Name() string }

type collection[K comparable, T any] struct{ name string }

func (c collection[K, T]) Name() string { return c.name }

func CollectionAt[K comparable, T any](name string) Collection[K, T] {
	return collection[K, T]{name: name}
}
