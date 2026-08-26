#!/usr/bin/env node

import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { analyzePublisherWorkflows } from '../actions/check-npm-publish-identity/workflow-analysis.mjs';
import { inspectPackageIdentity } from '../actions/check-npm-publish-identity/check.mjs';
import { readPackedManifest } from '../actions/check-npm-publish-identity/pack-package.mjs';

const fixture = mkdtempSync(join(tmpdir(), 'npm-publish-json-safety-'));

function requireFinding(findings, code, label) {
  if (!findings.some((finding) => finding.code === code)) {
    throw new Error(`${label} must reject duplicate JSON keys with ${code}`);
  }
}
try {
  const manifestRoot = join(fixture, 'manifest');
  mkdirSync(manifestRoot, { recursive: true });
  writeFileSync(join(manifestRoot, 'package.json'), `{
    "name": "@sneat/extension-assetus",
    "name": "@sneat/extension-evil",
    "version": "0.1.0"
  }\n`);
  requireFinding(
    inspectPackageIdentity({ repository: 'sneat-co/assetus', directory: manifestRoot }).findings,
    'INVALID_PACKAGE_JSON',
    'package identity inspection',
  );

  const scriptRoot = join(fixture, 'package-script');
  mkdirSync(join(scriptRoot, '.github', 'workflows'), { recursive: true });
  writeFileSync(join(scriptRoot, 'package.json'), `{
    "name": "@sneat/extension-assetus",
    "version": "0.1.0",
    "scripts": {"release": "echo harmless"},
    "scripts": {"release": "pnpm publish"}
  }\n`);
  writeFileSync(join(scriptRoot, '.github', 'workflows', 'publish.yml'), `on: [push]
jobs:
  publish:
    runs-on: ubuntu-latest
    steps:
      - run: npm run release
`);
  requireFinding(
    analyzePublisherWorkflows(scriptRoot).findings,
    'INVALID_PACKAGE_SCRIPT_JSON',
    'package-script inspection',
  );

  const packedRoot = join(fixture, 'packed');
  mkdirSync(join(packedRoot, 'package'), { recursive: true });
  writeFileSync(join(packedRoot, 'package', 'package.json'), `{
    "name": "@sneat/extension-assetus",
    "name": "@sneat/extension-evil",
    "version": "0.1.0"
  }\n`);
  const artifact = join(fixture, 'duplicate-package-json.tgz');
  execFileSync('tar', ['-czf', artifact, '-C', packedRoot, 'package']);
  let packedRejected = false;
  try {
    readPackedManifest(artifact);
  } catch (error) {
    packedRejected = String(error?.message || error).includes('JSON_DUPLICATE_KEY');
  }
  if (!packedRejected) throw new Error('packed manifest inspection must reject duplicate JSON keys');

  console.log('npm publish JSON safety tests passed');
} finally {
  rmSync(fixture, { force: true, recursive: true });
}
