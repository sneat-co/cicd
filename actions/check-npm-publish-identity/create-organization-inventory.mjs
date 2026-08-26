#!/usr/bin/env node

import { mkdirSync, renameSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { safeError } from './redact.mjs';

const schema = 'npm-publish-organization-inventory/v1';

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

function apiURL(baseURL, path) {
  return new URL(path, `${baseURL.replace(/\/$/, '')}/`).toString();
}

async function getJSON(baseURL, token, path) {
  const response = await fetch(apiURL(baseURL, path), {
    headers: {
      Accept: 'application/vnd.github+json',
      Authorization: `Bearer ${token}`,
      'X-GitHub-Api-Version': '2026-03-10',
    },
  });
  if (!response.ok) throw new Error(`GitHub API ${response.status} request was refused`);
  return { headers: response.headers, value: await response.json() };
}

function auditEntitlementError() {
  return new Error('AUDIT_TOKEN_ENTITLEMENT_REQUIRED: active Sneat Co. organization-owner classic token with repo scope and clear SSO status is required');
}

async function assertOrganizationAuditEntitlement(baseURL, token, organization) {
  const user = await getJSON(baseURL, token, '/user');
  const scopes = user.headers.get('x-oauth-scopes');
  const sso = user.headers.get('x-github-sso');
  if (user.value?.type !== 'User' || !scopes || !scopes.split(',').map((scope) => scope.trim()).includes('repo') || sso) {
    throw auditEntitlementError();
  }
  const membership = await getJSON(baseURL, token, `/user/memberships/orgs/${encodeURIComponent(organization)}`);
  if (membership.value?.state !== 'active' || membership.value?.role !== 'admin' || membership.headers.get('x-github-sso')) {
    throw auditEntitlementError();
  }
  return {
    kind: 'classic-user-token',
    organization_role: 'admin',
    repository_visibility: 'all',
    sso: 'clear',
    verification: 'GitHub API current-user scope and active organization-owner membership',
  };
}

async function organizationRepositories(baseURL, token, organization) {
  const repositories = [];
  for (let page = 1; ; page += 1) {
    const result = await getJSON(baseURL, token, `/orgs/${encodeURIComponent(organization)}/repos?type=all&per_page=100&page=${page}`);
    repositories.push(...result.value);
    if (result.value.length < 100) break;
  }
  return repositories;
}

async function createInventory({ archivePolicy, baseURL, organization, token }) {
  if (!['exclude', 'include'].includes(archivePolicy)) throw new Error(`unsupported archive policy: ${archivePolicy}`);
  const credentialEntitlement = await assertOrganizationAuditEntitlement(baseURL, token, organization);
  const discovered = await organizationRepositories(baseURL, token, organization);
  const selected = discovered
    .filter((repository) => archivePolicy === 'include' || !repository.archived)
    .filter((repository) => repository.owner?.login?.toLowerCase() === organization.toLowerCase())
    .sort((left, right) => left.full_name.localeCompare(right.full_name));
  const repositories = [];
  for (const repository of selected) {
    if (!repository.default_branch) throw new Error('a discovered organization repository has no default branch');
    const commit = await getJSON(baseURL, token, `/repos/${repository.full_name}/commits/${encodeURIComponent(repository.default_branch)}`);
    repositories.push({
      archived: Boolean(repository.archived),
      default_branch: repository.default_branch,
      default_sha: commit.value.sha,
      repository: repository.full_name,
    });
  }
  return {
    archive_policy: archivePolicy,
    credential_entitlement: credentialEntitlement,
    fetched_at: new Date().toISOString(),
    filters: ['GitHub organization repositories', archivePolicy === 'exclude' ? 'archived repositories excluded' : 'archived repositories included'],
    organization,
    repositories,
    schema,
    source: 'github-api',
  };
}

function writeInventory(output, inventory) {
  const absoluteOutput = resolve(output);
  mkdirSync(dirname(absoluteOutput), { recursive: true });
  const temporaryOutput = `${absoluteOutput}.tmp`;
  writeFileSync(temporaryOutput, `${JSON.stringify(inventory)}\n`, { mode: 0o600 });
  renameSync(temporaryOutput, absoluteOutput);
}

async function main() {
  let args;
  try {
    args = parseArgs(process.argv.slice(2));
    if (!args.organization || !args.output) throw new Error('--organization and --output are required');
    const token = process.env.SNEAT_ORGANIZATION_AUDIT_TOKEN;
    if (!token) throw new Error('SNEAT_ORGANIZATION_AUDIT_TOKEN is required and is never printed');
    const inventory = await createInventory({
      archivePolicy: args['archive-policy'] || 'exclude',
      baseURL: process.env.GITHUB_API_URL || 'https://api.github.com',
      organization: args.organization,
      token,
    });
    writeInventory(args.output, inventory);
    console.log(`npm-publish-inventory: ${JSON.stringify({ archive_policy: inventory.archive_policy, credential_entitlement: inventory.credential_entitlement, fetched_at: inventory.fetched_at, organization: inventory.organization, repository_count: inventory.repositories.length, schema: inventory.schema, source: inventory.source })}`);
  } catch (error) {
    console.error(`npm-publish-inventory: ERROR ${safeError(error)}`);
    process.exit(2);
  }
}

export { assertOrganizationAuditEntitlement, createInventory, schema };

if (process.argv[1] && resolve(process.argv[1]) === new URL(import.meta.url).pathname) main();
