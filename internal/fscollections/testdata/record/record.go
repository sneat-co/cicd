// Package record is a minimal stand-in for github.com/dal-go/record.
package record

import "reflect"

type Key struct {
	collection string
	id         any
	parent     *Key
}

type Record interface{ Key() *Key }

type rec struct{ key *Key }

func (r rec) Key() *Key { return r.key }

type DataWithID[K comparable, D any] struct {
	ID   K
	Key  *Key
	Data D
}

type WithID[K comparable] struct {
	ID  K
	Key *Key
}

func NewKeyWithID[T comparable](collection string, id T) *Key {
	return &Key{collection: collection, id: id}
}

func NewKeyWithParentAndID[T comparable](parent *Key, collection string, id T) *Key {
	return &Key{collection: collection, id: id, parent: parent}
}

func NewIncompleteKey(collection string, idKind reflect.Kind, parent *Key) *Key {
	return &Key{collection: collection, parent: parent}
}

type FieldVal struct {
	Name  string
	Value any
}

type KeyOption func(*Key) error

func WithKeyID[T comparable](id T) KeyOption { return func(k *Key) error { k.id = id; return nil } }

func WithStringID(id string) KeyOption { return WithKeyID(id) }

func WithIntID(id int) KeyOption { return WithKeyID(id) }

func WithFields(fields []FieldVal) KeyOption { return func(k *Key) error { k.id = fields; return nil } }

func WithParentKey(parent *Key) KeyOption {
	return func(k *Key) error { k.parent = parent; return nil }
}

func NewKeyWithFields(collection string, fields ...FieldVal) *Key {
	return &Key{collection: collection}
}

func NewKeyWithOptions(collection string, options ...KeyOption) (*Key, error) {
	k := &Key{collection: collection}
	for _, o := range options {
		if err := o(k); err != nil {
			return nil, err
		}
	}
	return k, nil
}

func NewRecordWithoutKey(data any) Record { return rec{} }

func NewRecordWithIncompleteKey(collection string, idKind reflect.Kind, data any) Record {
	return rec{key: NewIncompleteKey(collection, idKind, nil)}
}

func NewRecord(key *Key) Record { return rec{key: key} }

func NewRecordWithData(key *Key, data any) Record { return rec{key: key} }

func NewDataWithID[K comparable, D any](id K, key *Key, data D) DataWithID[K, D] {
	return DataWithID[K, D]{ID: id, Key: key, Data: data}
}

func NewWithID[K comparable](id K, key *Key, data any) WithID[K] { return WithID[K]{ID: id, Key: key} }
