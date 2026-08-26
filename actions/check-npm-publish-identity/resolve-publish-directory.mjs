#!/usr/bin/env node

import { existsSync, lstatSync, realpathSync } from 'node:fs';
import { isAbsolute, join, relative, resolve, sep } from 'node:path';
import { safeError } from './redact.mjs';

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

function isInside(workspace, directory) {
  const pathRelative = relative(workspace, directory);
  return pathRelative === '' || (!pathRelative.startsWith(`..${sep}`) && pathRelative !== '..' && !isAbsolute(pathRelative));
}

function safeDirectory(workspace, requestedDirectory) {
  if (typeof requestedDirectory !== 'string' || requestedDirectory.includes('\u0000') || requestedDirectory.split(/[\\/]+/).includes('..')) {
    throw new Error('PUBLISH_DIRECTORY_OUTSIDE_WORKSPACE');
  }
  const requested = resolve(workspace, requestedDirectory);
  if (!isInside(workspace, requested)) throw new Error('PUBLISH_DIRECTORY_OUTSIDE_WORKSPACE');
  const pathRelative = relative(workspace, requested);
  let current = workspace;
  for (const segment of pathRelative === '' ? [] : pathRelative.split(sep)) {
    current = join(current, segment);
    if (!existsSync(current)) break;
    const metadata = lstatSync(current);
    if (metadata.isSymbolicLink()) throw new Error('PUBLISH_DIRECTORY_OUTSIDE_WORKSPACE');
    if (current !== requested && !metadata.isDirectory()) throw new Error('PUBLISH_DIRECTORY_OUTSIDE_WORKSPACE');
  }
  if (existsSync(requested) && !lstatSync(requested).isDirectory()) throw new Error('PUBLISH_DIRECTORY_OUTSIDE_WORKSPACE');
  return requested;
}

function main() {
  try {
    const args = parseArgs(process.argv.slice(2));
    if (!args.workspace || args.directory === undefined) throw new Error('--workspace and --directory are required');
    const workspace = realpathSync(resolve(args.workspace));
    const directory = safeDirectory(workspace, args.directory);
    process.stdout.write(`${directory}\n`);
  } catch (error) {
    console.error(`npm-publish-identity: ${safeError(error)}`);
    process.exit(2);
  }
}

main();
