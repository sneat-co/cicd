#!/usr/bin/env node
// Fails when a package we publish (@sneat/* or @sneat-team/*) declares a
// bare ^0.0.x (or ~0.0.x) range in its peerDependencies.
//
// WHY THIS EXISTS
// Under semver, a caret on a 0.0.x version permits nothing but that exact
// patch: ^0.0.5 means 0.0.5, full stop (~0.0.x is the same trap). So when an
// app moves @sneat/extension-sizeus-contract to 0.0.6 while a consuming
// library's peerDependencies still say ^0.0.5, pnpm correctly installs TWO
// physical copies of that package. Two copies means two distinct
// InjectionToken objects, and Angular's DI matches providers by object
// identity -- so the app provides one token and the library asks for the
// other. Twenty specs failed with "NG0201: No provider found for
// InjectionToken SizeusApiService". TypeScript stayed green throughout,
// because both copies declare structurally identical types -- the mismatch
// is invisible to the type checker and only surfaces when something
// resolves the token at runtime.
//
// The fix is to widen the range so both patches resolve to a single
// installed copy: an explicit union (^0.0.5 || ^0.0.6) or an interval
// (>=0.0.5 <0.1.0). An exact pin (no ^ or ~) is fine too -- it can only ever
// resolve to one version. Only the bare single ^0.0.x / ~0.0.x shape is the
// trap, because it silently tolerates a second copy the moment either side
// moves.
//
// Usage:
//   node check.mjs [directory]
// `directory` defaults to the current working directory and is scanned
// recursively for package.json files (node_modules, dist, .nx/cache, .wb,
// .claude, .worktrees and .git are skipped).
//
// Exit code: 1 if any bare ^0.0.x / ~0.0.x peerDependencies range is found
// on an @sneat/* or @sneat-team/* package, 0 otherwise. Silent on success.

import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, relative, sep } from 'node:path';

const EXCLUDED_DIR_NAMES = new Set([
  'node_modules',
  'dist',
  '.wb',
  '.claude',
  '.worktrees',
  '.git',
]);

const SNEAT_SCOPES = ['@sneat/', '@sneat-team/'];

// Packages that legitimately need a bare ^0.0.x / ~0.0.x peer range go here,
// one entry per (file, package, range), each with a comment explaining why.
// Do NOT loosen the detection below to make an entry pass -- add it here
// instead, with a reason a reviewer can check.
//
//   'relative/path/to/package.json::@sneat/example::^0.0.3', // why
const ALLOWLIST = new Set([]);

// A bare caret/tilde range pinned inside 0.0.x, e.g. ^0.0.5 or ~0.0.12,
// optionally with a pre-release/build suffix.
const BARE_ZERO_RANGE =
  /^[~^]0\.0\.(?:0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/;

function isNxCache(relPath) {
  const normalized = relPath.split(sep).join('/');
  return normalized === '.nx/cache' || normalized.startsWith('.nx/cache/');
}

function findPackageJsonFiles(root) {
  const results = [];
  function walk(dir) {
    let entries;
    try {
      entries = readdirSync(dir, { withFileTypes: true });
    } catch {
      return; // unreadable directory (permissions, broken symlink, ...): skip
    }
    for (const entry of entries) {
      const full = join(dir, entry.name);
      if (entry.isDirectory()) {
        if (EXCLUDED_DIR_NAMES.has(entry.name)) continue;
        const rel = relative(root, full);
        if (isNxCache(rel)) continue;
        walk(full);
      } else if (entry.isFile() && entry.name === 'package.json') {
        results.push(full);
      }
    }
  }
  walk(root);
  return results;
}

// True only for the specific trap: a single bare ^0.0.x / ~0.0.x range.
// A union (contains "||"), an interval (uses >=, <=, >, <, or is otherwise
// a multi-token comparator set), or an exact pin (no ^ / ~) all pass.
function isBareZeroTrap(range) {
  const trimmed = range.trim();
  if (trimmed.includes('||')) return false; // explicit union, e.g. "^0.0.1 || ^0.0.2"
  if (/[<>]=?/.test(trimmed)) return false; // interval, e.g. ">=0.0.5 <0.1.0"
  if (/\s/.test(trimmed)) return false; // any other multi-token comparator set
  return BARE_ZERO_RANGE.test(trimmed);
}

function isPublishedByUs(packageName) {
  return SNEAT_SCOPES.some((scope) => packageName.startsWith(scope));
}

function main() {
  const root = process.argv[2] || process.cwd();
  try {
    if (!statSync(root).isDirectory()) throw new Error('not a directory');
  } catch {
    console.error(`check-peer-ranges: directory not found: ${root}`);
    process.exit(1);
  }

  const files = findPackageJsonFiles(root);
  const findings = [];

  for (const file of files) {
    const relFile = relative(root, file) || file;
    let pkg;
    try {
      pkg = JSON.parse(readFileSync(file, 'utf8'));
    } catch (err) {
      console.error(
        `::warning file=${relFile}::could not parse as JSON, skipping peer-range check (${err.message})`,
      );
      continue;
    }
    const peerDeps = pkg && typeof pkg === 'object' ? pkg.peerDependencies : undefined;
    if (!peerDeps || typeof peerDeps !== 'object') continue;

    for (const [depName, range] of Object.entries(peerDeps)) {
      if (typeof range !== 'string') continue;
      if (!isPublishedByUs(depName)) continue;
      if (!isBareZeroTrap(range)) continue;
      if (ALLOWLIST.has(`${relFile}::${depName}::${range}`)) continue;
      findings.push({ file: relFile, name: depName, range });
    }
  }

  if (findings.length === 0) {
    process.exit(0);
  }

  for (const { file, name, range } of findings) {
    const operator = range.trim().startsWith('~') ? '~' : '^';
    console.error(
      `::error file=${file}::${file}: peerDependencies["${name}"] = "${range}" is a bare ${operator}0.0.x range`,
    );
    console.error(
      [
        '',
        `  ${file}`,
        `    peerDependencies["${name}"] = "${range}"`,
        '',
        `  Under semver, a "${operator}" on a 0.0.x version permits nothing but that exact`,
        `  patch: "${range}" means ${range.trim().slice(1)}, full stop. The moment ${name}`,
        '  publishes a new 0.0.x patch while something else in the install still asks for',
        '  this exact one, pnpm will correctly install TWO physical copies of it. Two',
        '  copies means two distinct InjectionToken objects, and Angular DI matches',
        '  providers by object identity -- so the app provides one token and this package',
        '  asks for the other, and specs fail with:',
        '    NG0201: No provider found for InjectionToken ...',
        '  TypeScript stays green throughout because both copies are structurally',
        '  identical -- the mismatch is invisible to the type checker and only surfaces',
        '  when something resolves the token at runtime.',
        '',
        '  Fix by widening the range so both patches resolve to one installed copy:',
        `    "${name}": "^0.0.5 || ^0.0.6"     (explicit union)`,
        `    "${name}": ">=0.0.5 <0.1.0"       (interval)`,
        '',
        '  If a bare 0.0.x range is genuinely required, add an ALLOWLIST entry with a',
        '  reason in actions/check-peer-ranges/check.mjs -- do not loosen this check.',
        '',
      ].join('\n'),
    );
  }

  console.error(
    `check-peer-ranges: ${findings.length} bare ^0.0.x/~0.0.x peerDependencies range(s) on @sneat/*/@sneat-team/* packages (see above).`,
  );
  process.exit(1);
}

main();
