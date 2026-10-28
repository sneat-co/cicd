# Native Firestore import-site consistency

The opt-in job in `go-storage-driver-boundary.yml` checks every Git-tracked Go
file, including tests, generated source, build-tag/OS files and nested modules.
It does not build the target or download its module graph. Full parsing, missing
source, source/directory/broken symlinks and submodules fail closed. A non-Go
link resolving to a regular non-source file (such as an instruction document) is
permitted. Actual `vendor` dependency trees
are excluded; dot/underscore and testdata directories are scanned. Untracked
files are outside the check: CI must use its clean checked-out commit.

```yaml
jobs:
  native-storage:
    uses: sneat-co/cicd/.github/workflows/go-storage-driver-boundary.yml@<reviewed-commit>
    with:
      native-sites: true
      native-sites-manifest: .native-firestore-sites.json
      native-sites-only: true
```

`native-sites-only` is explicit new adoption for deliberate native owners. It
requires `native-sites: true` and a manifest. It does not run or claim dependency
layer validation. Never remove or skip an existing required dependency gate to
adopt it. Defaults preserve the existing WB import job. Include the new native
job in the consumer's required CI/deployment aggregate; an unconfigured consumer
has no coverage from this job.

The central implementation is checked out at `policy-ref`; its resolved Git SHA
is logged with the target SHA and manifest SHA256. The manifest must be a tracked
nonsymlink path inside the target repository. Consumer ownership keeps private
source filenames/hashes out of public cicd. Illustrative schema only:

```json
{
  "version": 1,
  "repositories": {
    "example/product": {
      "sites": [{
        "file": "storage/native.go",
        "import": "cloud.google.com/go/firestore",
        "sha256": "<64 lowercase hex characters of the complete file>",
        "class": "deliberate-native-owner",
        "owner": "owning module/team",
        "rationale": "why this exact native boundary is intentional",
        "review": "https://github.com/example/product/pull/123",
        "test": "https://github.com/example/product/blob/<commit>/storage/native_test.go"
      }]
    }
  }
}
```

Classes: `secured-factory`, `deliberate-native-owner`, `read-only-native-owner`,
`test-only`. The last requires `_test.go`; it does not imply emulator execution.
Rows need owner/rationale and GitHub review/test references. No wildcard paths,
duplicate/stale rows or blanket test exemptions. An explicitly empty sites array
permits a Go repository with no classified imports; a missing repository fails.

Import literals cover cloud Firestore and descendants, Firebase App roots
(`firebase.google.com/go` or `/vN`), dalgo2firestore, Google API Firestore and the
known trakhimenok Firestore fork. Firebase auth/AppCheck-only subpackages are not
Firestore client factories. Alias/dot/blank imports are classified identically.
Complete-file hashes catch new constructors or writes inside an already
classified file, including constructors stored as function values. Comment and
format edits intentionally require updated classification too.

**CI proves consistency, not approval.** A PR can change unsafe code and its
manifest hash together. Independent review bound to the final source head remains
mandatory through the owning repository's WB landing governance. A reference
string is not machine-verified review authority. Only claim server-enforced
review if actual branch policy enforces it. Do not autoapprove a scan baseline.
Native exceptions remain outside DALgo policy; owner behavior tests must verify
their approved paths/failure cases. Preserve Core mutation-matrix/host tests and
QueryDock emulator coverage.

Exit 1: new/changed/unclassified or stale sites. Exit 2: malformed/missing
manifest, options, source or coverage. Both block CI. No runtime credentials are
needed. This direct-import check cannot establish universal writer protection:
existing capability-passing interfaces, unchanged approved bugs, dynamic calls,
REST/net/http, other languages/scripts, unknown SDK forks, administrative clients
and undiscovered writers remain outside its proof. Retain mandatory runtime
policy, independent owner tests and daily root detection.

The checker compiles in the central module (`go 1.26.0`, toolchain `go1.27.0`),
independently of the target modules. Parser fixtures include target Go 1.27.3
and generic type aliases. Patch releases do not add Go language syntax. Target
syntax newer than the central parser can support fails as a parse error; update
the central toolchain before adopting such a language version rather than
silently omitting those files. This is lexical parsing, not target type-checking.
