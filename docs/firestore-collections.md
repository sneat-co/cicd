# Firestore collections check

`cmd/firestore-collections` finds every Firestore path a Go module builds with
dalgo and fails when one is not defined. It is the reverse of the
definitions-to-code check in the private `sneat-co/sneat-datatug`, where the
storage definitions live (`firestore/**/.collection/**/storage.yaml`: owner,
id rule, review status).

## What it reads

A `go/analysis` analyzer (`internal/fscollections`) follows the key
constructors of `github.com/dal-go/record` (`NewKeyWithID`,
`NewKeyWithParentAndID`, `NewIncompleteKey`, `NewKeyWithFields`,
`NewKeyWithOptions`, `NewRecordWithIncompleteKey`, and the wrappers
`NewRecord`, `NewRecordWithData`, `NewDataWithID`, `NewWithID`) and the query
references of `github.com/dal-go/dalgo/dal` (`NewCollectionRef`,
`NewRootCollectionRef`, `NewCollectionGroupRef`). Through facts it follows
helpers in any package or module: a function that returns a key, or builds one
from its parameters, is filled in at each call. Test files are not read.

- Collection names must be constants. Anything else is **unresolved** and fails
  (fail closed). A reviewed dynamic site names its paths on the call line or
  the line above: `//firestore:path <path>... -- <reason>`; those paths are
  checked like any other.
- A call that only wraps a key built elsewhere (`NewRecordWithData(rec.Key(), d)`)
  adds nothing: the constructor that built the key is checked where it is called.
- Paths built only when an argument is empty (the spaceless `ext/{extension}`
  branch of `NewSpaceModuleKey`, Decision 0002) are listed with their guard by
  `emit` and counted, not failed, by `check`.

## Commands

```sh
firestore-collections emit  [-C dir] [-repo-root dir] [packages]   # JSON: paths with file:line, unresolved places
firestore-collections check -snapshot .firestore-collections.yaml [-C dir] [-repo-root dir] [packages]
```

Exit 0 clean, 1 findings, 2 usage or load errors (a package that does not
type-check fails the check closed).

## Matching

By path shape. Collection names must be equal. An id that is `{name}` in the
definition matches any id; a fixed id in the definition (`ext/calendarius`)
matches only the same fixed id in code. A collection-group reference matches a
definition with that last collection name. sneat-datatug
`tools/collections/collections.py` uses the same rule.

## In a product repository

Commit the generated snapshot (`python3 tools/collections/collections.py
snapshot --target <name> --out <file>` in sneat-datatug) and call
`.github/workflows/firestore-collections.yml`, pinned to a reviewed commit. A
new collection fails with:

```
::error file=backend/x.go,line=12::Firestore path "spaces/{spaceID}/ext/calendarius/fooBars/{id}" is not defined in sneat-co/sneat-datatug. Add its definition there, get the owner's approval of the layout, then regenerate .firestore-collections.yaml. Read first: https://github.com/sneat-co/sneat-specs/blob/main/standards/data-storage-design.md
```
