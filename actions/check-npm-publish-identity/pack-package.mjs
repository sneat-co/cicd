#!/usr/bin/env node

import { appendFileSync, existsSync, mkdirSync, readFileSync } from 'node:fs';
import { basename, join, resolve } from 'node:path';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { inspectPackageIdentity, policy } from './check.mjs';
import { redact, safeDetail, safeError } from './redact.mjs';
import { StrictJsonError, parseStrictJson } from './strict-json.mjs';

function parseArgs(argv) {
  const result = {};
  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index];
    if (!flag.startsWith('--')) continue;
    const value = argv[index + 1];
    if (!value || value.startsWith('--')) throw new Error(`missing value for ${flag}`);
    result[flag.slice(2)] = value;
    index += 1;
  }
  return result;
}

function sha256(buffer) {
  return createHash('sha256').update(buffer).digest('hex');
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, { cwd: options.cwd, encoding: 'utf8', env: options.env });
  if (result.status !== 0) throw new Error(`${command} failed while preparing the provider-owned package artifact`);
  return result.stdout;
}

function reportFailure(result) {
  for (const finding of result.findings) {
    console.error(`npm-publish-artifact: [${finding.code}] ${safeDetail(finding.path)}: ${safeDetail(finding.detail)}`);
  }
  process.exit(1);
}

function writeOutput(path, output) {
  if (!path) return;
  appendFileSync(path, `artifact=${output.artifact}\n`);
  appendFileSync(path, `receipt=${JSON.stringify(output.receipt)}\n`);
}

function printableReceipt(receipt) {
  return Object.fromEntries(Object.entries(receipt).map(([key, value]) => [
    key,
    typeof value === 'string' ? redact(value) : value,
  ]));
}

export function readPackedManifest(artifact) {
  const output = run('tar', ['-xOf', artifact, 'package/package.json']);
  try {
    return { bytes: Buffer.from(output), manifest: parseStrictJson(output) };
  } catch (error) {
    if (error instanceof StrictJsonError && error.code === 'JSON_DUPLICATE_KEY') {
      throw new Error('JSON_DUPLICATE_KEY in packed package manifest');
    }
    throw new Error('packed artifact does not contain a valid package/package.json manifest');
  }
}

function main() {
  try {
    const args = parseArgs(process.argv.slice(2));
    if (!args.repository || !args.directory || !args.package || !args['artifact-directory']) {
      throw new Error('--repository, --directory, --package, and --artifact-directory are required');
    }
    const directory = resolve(args.directory);
    const artifactDirectory = resolve(args['artifact-directory']);
    const inspection = inspectPackageIdentity({
      repository: args.repository,
      directory,
      expectedPackage: args.package,
      manifestOnly: true,
    });
    if (inspection.findings.length > 0) reportFailure(inspection);

    const sourceManifestPath = join(directory, 'package.json');
    const sourceManifest = readFileSync(sourceManifestPath);
    mkdirSync(artifactDirectory, { recursive: true });
    const packed = parseStrictJson(run('npm', [
      'pack',
      '--ignore-scripts',
      '--json',
      '--pack-destination',
      artifactDirectory,
    ], { cwd: directory }));
    if (!Array.isArray(packed) || packed.length !== 1 || typeof packed[0]?.filename !== 'string') {
      throw new Error('npm pack did not return exactly one provider-owned artifact');
    }
    const artifact = join(artifactDirectory, basename(packed[0].filename));
    if (!existsSync(artifact)) throw new Error('npm pack reported an artifact that was not created');
    const packedManifest = readPackedManifest(artifact);
    if (packedManifest.manifest?.name !== args.package) {
      throw new Error('PACKED_ARTIFACT_PACKAGE_MISMATCH');
    }
    if (packedManifest.manifest?.private === true) {
      throw new Error('PACKED_ARTIFACT_IS_PRIVATE');
    }
    const artifactBytes = readFileSync(artifact);
    if (sha256(sourceManifest) !== sha256(packedManifest.bytes)) {
      throw new Error('PACKED_MANIFEST_MISMATCH');
    }
    const receipt = {
      artifact: basename(artifact),
      artifact_sha256: sha256(artifactBytes),
      package: args.package,
      packed_manifest_sha256: sha256(packedManifest.bytes),
      policy_version: policy.policy_version,
      repository: args.repository,
      source_manifest_sha256: sha256(sourceManifest),
      version: packedManifest.manifest.version,
    };
    writeOutput(args['github-output'], { artifact, receipt });
    console.log(`npm-publish-artifact: ${JSON.stringify(printableReceipt(receipt))}`);
  } catch (error) {
    console.error(`npm-publish-artifact: ERROR ${safeError(error)}`);
    process.exit(2);
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
