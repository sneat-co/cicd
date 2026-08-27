#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import { resolve } from 'node:path';

function fail(code, message) {
  console.error(`check-zonejs-resolvability: [${code}] ${message}`);
  process.exit(1);
}

function main() {
  const directory = resolve(process.argv[2] || '.');
  const result = spawnSync('pnpm', ['why', '-r', 'zone.js', '--json'], {
    cwd: directory,
    encoding: 'utf8',
  });
  if (result.error || result.status !== 0 || result.signal) {
    fail('PNPM_WHY_COMMAND_FAILED', 'pnpm why could not prove the dependency graph is Zone.js-free');
  }

  let matches;
  try {
    matches = JSON.parse(result.stdout);
  } catch {
    fail('PNPM_WHY_INVALID_JSON', 'pnpm why did not emit one valid JSON array');
  }
  if (!Array.isArray(matches)) {
    fail('PNPM_WHY_EXPECTED_ARRAY', 'pnpm why output is ambiguous; expected one JSON array');
  }
  if (matches.length > 0) {
    console.error(
      `::error::zone.js is resolvable in this pnpm dependency graph (${matches.length} match(es)). zone.js was eliminated fleet-wide on 2026-08-25 (Backstage lesson L2026-08-25-2038). @angular/build chooses its zone-based vs zoneless test strategy by checking whether zone.js is resolvable, including pnpm's hoist mirror. Fix the package graph, or set nx-ci check-zonejs: false only as a deliberate, reviewed opt-out.`,
    );
    fail('ZONEJS_RESOLVABLE', 'pnpm why returned one or more Zone.js matches');
  }

  console.log('zone.js guard: clean — zone.js is not resolvable anywhere in the pnpm dependency graph.');
}

main();
