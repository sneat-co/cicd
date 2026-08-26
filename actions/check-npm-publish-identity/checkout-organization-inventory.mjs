#!/usr/bin/env node

import { existsSync, mkdirSync, readFileSync } from 'node:fs';
import { basename, join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { schema } from './create-organization-inventory.mjs';
import { safeError } from './redact.mjs';
import { parseStrictJson } from './strict-json.mjs';

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

function inventoryFrom(path) {
  let inventory;
  try {
    inventory = parseStrictJson(readFileSync(path, 'utf8'));
  } catch {
    throw new Error('invalid organization inventory');
  }
  if (inventory.schema !== schema
    || inventory.source !== 'github-api'
    || !/^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$/.test(inventory.organization || '')
    || !['exclude', 'include'].includes(inventory.archive_policy)
    || !Array.isArray(inventory.repositories)) {
    throw new Error('invalid organization inventory');
  }
  const seen = new Set();
  for (const entry of inventory.repositories) {
    const expectedPrefix = `${inventory.organization}/`;
    const repositoryName = typeof entry.repository === 'string' && entry.repository.startsWith(expectedPrefix)
      ? entry.repository.slice(expectedPrefix.length)
      : '';
    if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(repositoryName)
      || !/^[0-9a-f]{40}$/.test(entry.default_sha || '')
      || typeof entry.default_branch !== 'string'
      || entry.default_branch.trim() === ''
      || seen.has(entry.repository)) {
      throw new Error('invalid organization inventory repository');
    }
    seen.add(entry.repository);
  }
  return inventory;
}

function childEnvironment(overrides) {
  const environment = { ...process.env };
  // The inventory credential is only an input to the provider's `gh repo
  // clone` invocation. Do not pass it, an ambient GitHub token, or npm
  // credentials into checkout commands that have no legitimate use for them.
  for (const name of ['SNEAT_ORGANIZATION_AUDIT_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN', 'NPM_TOKEN', 'NODE_AUTH_TOKEN']) {
    delete environment[name];
  }
  return { ...environment, ...overrides };
}

function run(command, args, env) {
  const result = spawnSync(command, args, { encoding: 'utf8', env: childEnvironment(env), stdio: 'inherit' });
  if (result.status !== 0) throw new Error(`${command} failed while checking out an immutable inventory revision`);
}

function gitSHA(directory) {
  const result = spawnSync('git', ['-C', directory, 'rev-parse', 'HEAD'], {
    encoding: 'utf8',
    env: childEnvironment(),
  });
  return result.status === 0 ? result.stdout.trim() : undefined;
}

function main() {
  try {
    const args = parseArgs(process.argv.slice(2));
    if (!args.inventory || !args.directory) throw new Error('--inventory and --directory are required');
    const inventory = inventoryFrom(resolve(args.inventory));
    const destination = resolve(args.directory);
    mkdirSync(destination, { recursive: true });
    for (const entry of inventory.repositories) {
      const target = join(destination, basename(entry.repository));
      if (existsSync(target)) throw new Error(`refusing to replace existing checkout: ${target}`);
      run('gh', ['repo', 'clone', entry.repository, target, '--', '--depth', '1', '--filter=blob:none', '--no-checkout'],
        process.env.SNEAT_ORGANIZATION_AUDIT_TOKEN ? { GH_TOKEN: process.env.SNEAT_ORGANIZATION_AUDIT_TOKEN } : undefined);
      run('git', ['-C', target, 'fetch', '--depth', '1', 'origin', entry.default_sha]);
      run('git', ['-C', target, 'checkout', '--detach', '--force', entry.default_sha]);
      const checkedOutSHA = gitSHA(target);
      if (checkedOutSHA !== entry.default_sha) {
        throw new Error('immutable inventory revision did not match the checked-out commit');
      }
    }
    console.log(`npm-publish-inventory-checkout: ${JSON.stringify({ organization: inventory.organization, repository_count: inventory.repositories.length, source: inventory.source })}`);
  } catch (error) {
    console.error(`npm-publish-inventory-checkout: ERROR ${safeError(error)}`);
    process.exit(2);
  }
}

main();
