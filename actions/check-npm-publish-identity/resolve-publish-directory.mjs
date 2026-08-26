#!/usr/bin/env node

import { existsSync, realpathSync } from 'node:fs';
import { relative, resolve, sep } from 'node:path';

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
  return pathRelative === '' || (!pathRelative.startsWith(`..${sep}`) && pathRelative !== '..' && !pathRelative.startsWith('..'));
}

function main() {
  try {
    const args = parseArgs(process.argv.slice(2));
    if (!args.workspace || args.directory === undefined) throw new Error('--workspace and --directory are required');
    const workspace = realpathSync(resolve(args.workspace));
    const requested = resolve(workspace, args.directory);
    const directory = existsSync(requested) ? realpathSync(requested) : requested;
    if (!isInside(workspace, directory)) throw new Error(`PUBLISH_DIRECTORY_OUTSIDE_WORKSPACE ${args.directory}`);
    process.stdout.write(`${directory}\n`);
  } catch (error) {
    console.error(`npm-publish-identity: ${error.message}`);
    process.exit(2);
  }
}

main();
