#!/usr/bin/env node

import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { basename, dirname, join, relative, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { inspectPackageIdentity } from './check.mjs';
import { createInventory, schema as inventorySchema } from './create-organization-inventory.mjs';

const actionDirectory = dirname(fileURLToPath(import.meta.url));
void actionDirectory;

function parseArgs(argv) {
  const result = { flags: new Set() };
  for (let i = 0; i < argv.length; i += 1) {
    const flag = argv[i];
    if (!flag.startsWith('--')) continue;
    if (['--github-api', '--require-authoritative', '--require-no-direct-publisher', '--require-publish-identities', '--require-unique-owners'].includes(flag)) {
      result.flags.add(flag);
      continue;
    }
    const value = argv[i + 1];
    if (!value || value.startsWith('--')) throw new Error(`missing value for ${flag}`);
    result[flag.slice(2)] = value;
    i += 1;
  }
  return result;
}

function isRepositorySlug(value) {
  return typeof value === 'string'
    && /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})\/[A-Za-z0-9][A-Za-z0-9._-]*$/.test(value);
}

function withoutYamlComments(source) {
  return source.split('\n').filter((line) => !/^\s*#/.test(line)).join('\n');
}

function workflowDirectories(source, fallbackDirectory) {
  const directories = new Set();
  for (const match of source.matchAll(/^[ \t]*working-directory:[ \t]*['"]?([^#\n'"]+)/gmi)) {
    const directory = match[1].trim();
    if (directory !== '' && !directory.includes('${{')) directories.add(directory);
  }
  return directories.size > 0 ? [...directories].sort() : [fallbackDirectory];
}

function indentation(line) {
  return (line.match(/^[ \t]*/) || [''])[0].length;
}

function sharedProviderCalls(source) {
  const lines = source.split('\n');
  const calls = [];
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    if (!/^[ \t]*uses:[ \t]*['"]?sneat-co\/cicd\/\.github\/workflows\/npm-publish\.yml@/i.test(line)) continue;
    const usesIndentation = indentation(line);
    const callLines = [line];
    for (let next = index + 1; next < lines.length; next += 1) {
      const candidate = lines[next];
      if (candidate !== '' && indentation(candidate) < usesIndentation) break;
      callLines.push(candidate);
    }
    calls.push({ working_directories: workflowDirectories(callLines.join('\n'), 'frontend') });
  }
  return calls;
}

function topLevelOnBlock(source) {
  const lines = source.split('\n');
  const onIndex = lines.findIndex((line) => /^(?:on|['"]on['"]):[ \t]*(?:#.*)?$/.test(line) || /^(?:on|['"]on['"]):[ \t]*\S/.test(line));
  if (onIndex < 0) return undefined;
  const block = [lines[onIndex]];
  for (let i = onIndex + 1; i < lines.length; i += 1) {
    const line = lines[i];
    if (line !== '' && !/^[ \t]/.test(line)) break;
    block.push(line);
  }
  return block.join('\n');
}

function triggerPolicy(source) {
  const onBlock = topLevelOnBlock(source);
  if (!onBlock) return 'disabled';
  const hasAutomaticReleaseTrigger = /(?:^(?:on|['"]on['"]):[^\n]*(?:\bpush\b|\brelease\b|\bworkflow_run\b|\bcreate\b)|^[ \t]+(?:push|release|workflow_run|create)[ \t]*:)/mi.test(onBlock);
  if (hasAutomaticReleaseTrigger) return 'armed';
  if (/(?:^(?:on|['"]on['"]):[^\n]*\bworkflow_dispatch\b|^[ \t]+workflow_dispatch[ \t]*:)/mi.test(onBlock)) return 'manual-only';
  return 'not-release-triggered';
}

function jobBlocks(source) {
  const lines = source.split('\n');
  const jobsIndex = lines.findIndex((line) => /^jobs:[ \t]*(?:#.*)?$/.test(line));
  if (jobsIndex < 0) return [];
  const jobsIndentation = indentation(lines[jobsIndex]);
  const firstJob = lines.slice(jobsIndex + 1).find((line) => line !== '' && !/^\s*#/.test(line));
  if (!firstJob || indentation(firstJob) <= jobsIndentation) return [];
  const jobIndentation = indentation(firstJob);
  const isJobHeader = (line) => indentation(line) === jobIndentation && /^[ \t]*[^ \t#][^:]*:[ \t]*(?:#.*)?$/.test(line);
  const blocks = [];
  for (let index = jobsIndex + 1; index < lines.length; index += 1) {
    const line = lines[index];
    if (line !== '' && indentation(line) <= jobsIndentation) break;
    if (!isJobHeader(line)) continue;
    const block = [line];
    for (let next = index + 1; next < lines.length; next += 1) {
      const candidate = lines[next];
      if (candidate !== '' && indentation(candidate) <= jobsIndentation) break;
      if (isJobHeader(candidate)) break;
      block.push(candidate);
    }
    blocks.push(block.join('\n'));
  }
  return blocks;
}

function directPublisherCalls(source) {
  return jobBlocks(source)
    .filter((job) => /(?:NPM_TOKEN|NODE_AUTH_TOKEN)\s*:\s*\$\{\{\s*secrets\.[A-Za-z0-9_]+\s*}}/i.test(job))
    .filter((job) => /\b(?:npm|pnpm)\s+publish\b|\bnx(?:\s+|\s+\w+\s+)release\b/i.test(job))
    .map((job) => ({ working_directories: workflowDirectories(job, '.') }));
}

function publishWorkflows(repositoryRoot) {
  const workflowDirectory = join(repositoryRoot, '.github', 'workflows');
  if (!existsSync(workflowDirectory)) return [];
  return readdirSync(workflowDirectory, { withFileTypes: true })
    .filter((entry) => entry.isFile() && /\.ya?ml$/i.test(entry.name))
    .sort((a, b) => a.name.localeCompare(b.name))
    .flatMap((entry) => {
      const path = join(workflowDirectory, entry.name);
      const source = withoutYamlComments(readFileSync(path, 'utf8'));
      const sharedProviderCallsInWorkflow = sharedProviderCalls(source);
      const directPublisherCallsInWorkflow = directPublisherCalls(source);
      const relativePath = relative(repositoryRoot, path);
      const trigger = triggerPolicy(source);
      const records = [];
      for (const call of sharedProviderCallsInWorkflow) {
        records.push({ path: relativePath, kind: 'shared-provider', armed: trigger === 'armed', trigger, working_directories: call.working_directories });
      }
      for (const call of directPublisherCallsInWorkflow) {
        records.push({ path: relativePath, kind: 'direct-armed', armed: trigger === 'armed', trigger, working_directories: call.working_directories });
      }
      return records;
    });
}

function gitRef(repositoryRoot) {
  const result = spawnSync('git', ['-C', repositoryRoot, 'rev-parse', 'HEAD'], { encoding: 'utf8' });
  return result.status === 0 ? result.stdout.trim() : 'unavailable';
}

function gitOriginRepository(repositoryRoot) {
  const result = spawnSync('git', ['-C', repositoryRoot, 'remote', 'get-url', 'origin'], { encoding: 'utf8' });
  if (result.status !== 0) return undefined;
  const value = result.stdout.trim().replace(/^git\+/, '').replace(/\.git$/, '').replace(/\/$/, '');
  const match = value.match(/github\.com[/:]([^/\s]+)\/([^/\s]+)/i);
  return match ? `${match[1]}/${match[2]}` : undefined;
}

function authority(repositoryRoot, inventoryEntry, trustedInventory) {
  const head = gitRef(repositoryRoot);
  if (inventoryEntry && trustedInventory) {
    if (head !== inventoryEntry.default_sha) {
      return {
        default_ref: `origin/${inventoryEntry.default_branch}`,
        fetched_at: inventoryEntry.fetched_at,
        head,
        origin_default_sha: inventoryEntry.default_sha,
        source: 'github-api-inventory',
        state: 'non-authoritative',
        reason: 'local HEAD differs from authoritative inventory default SHA',
      };
    }
    return {
      default_ref: `origin/${inventoryEntry.default_branch}`,
      fetched_at: inventoryEntry.fetched_at,
      head,
      origin_default_sha: inventoryEntry.default_sha,
      source: 'github-api-inventory',
      state: 'authoritative',
    };
  }
  const symbolic = spawnSync('git', ['-C', repositoryRoot, 'symbolic-ref', '--quiet', '--short', 'refs/remotes/origin/HEAD'], { encoding: 'utf8' });
  if (symbolic.status !== 0) {
    return { head, state: 'non-authoritative', reason: 'authoritative GitHub inventory receipt is required; cached origin default ref is unavailable' };
  }
  const defaultRef = symbolic.stdout.trim();
  const defaultSHA = spawnSync('git', ['-C', repositoryRoot, 'rev-parse', '--verify', defaultRef], { encoding: 'utf8' });
  if (defaultSHA.status !== 0) {
    return { default_ref: defaultRef, head, state: 'non-authoritative', reason: 'authoritative GitHub inventory receipt is required; cached origin default SHA is unavailable' };
  }
  const originSHA = defaultSHA.stdout.trim();
  return {
    cached_origin_default_sha: originSHA,
    default_ref: defaultRef,
    head,
    state: 'non-authoritative',
    reason: 'authoritative GitHub inventory receipt is required; cached origin default ref is diagnostic only',
  };
}

function packageEvidence(repository, repositoryRoot, workingDirectories) {
  const packageEntries = new Map();
  const findings = [];
  const directories = workingDirectories.length > 0 ? workingDirectories : ['.'];
  for (const workingDirectory of directories) {
    const inspected = inspectPackageIdentity({ repository, directory: join(repositoryRoot, workingDirectory) });
    for (const finding of inspected.findings) {
      findings.push({ ...finding, path: relative(repositoryRoot, join(repositoryRoot, workingDirectory, finding.path)) });
    }
    for (const pkg of inspected.packages) {
      const path = relative(repositoryRoot, join(repositoryRoot, workingDirectory, pkg.path));
      packageEntries.set(`${pkg.name}\u0000${path}`, { name: pkg.name, path });
    }
  }
  return {
    findings: findings.sort((a, b) => a.code.localeCompare(b.code) || a.path.localeCompare(b.path) || a.detail.localeCompare(b.detail)),
    packages: [...packageEntries.values()].sort((a, b) => a.name.localeCompare(b.name) || a.path.localeCompare(b.path)),
  };
}

function auditRepository(repository, repositoryRoot, inventoryEntry, trustedInventory) {
  const workflows = publishWorkflows(repositoryRoot);
  for (const workflow of workflows) {
    const evidence = packageEvidence(repository, repositoryRoot, workflow.working_directories);
    workflow.identity_findings = evidence.findings;
    workflow.packages = evidence.packages;
  }
  const packages = new Map();
  for (const workflow of workflows) {
    for (const pkg of workflow.packages) packages.set(`${pkg.name}\u0000${pkg.path}`, pkg);
  }
  return {
    authority: authority(repositoryRoot, inventoryEntry, trustedInventory),
    packages: [...packages.values()].sort((a, b) => a.name.localeCompare(b.name) || a.path.localeCompare(b.path)),
    ref: gitRef(repositoryRoot),
    repository,
    workflows,
  };
}

function ownerEvidence(report) {
  const owners = new Map();
  for (const repository of report.repositories) {
    for (const workflow of repository.workflows) {
      if (!workflow.armed) continue;
      for (const pkg of workflow.packages) {
        const record = {
          package: pkg.name,
          package_path: pkg.path,
          ref: repository.ref,
          repository: repository.repository,
          workflow: workflow.path,
          workflow_kind: workflow.kind,
        };
        const existing = owners.get(pkg.name) || [];
        existing.push(record);
        owners.set(pkg.name, existing);
      }
    }
  }
  return [...owners.entries()]
    .filter(([, entries]) => new Set(entries.map((entry) => entry.repository)).size > 1)
    .map(([packageName, entries]) => ({
      package: packageName,
      owners: entries.sort((a, b) => (
        a.repository.localeCompare(b.repository)
        || a.workflow.localeCompare(b.workflow)
        || a.package_path.localeCompare(b.package_path)
      )),
    }))
    .sort((a, b) => a.package.localeCompare(b.package));
}

function directDuplicates(report) {
  const duplicates = [];
  for (const repository of report.repositories) {
    const shared = repository.workflows.filter((workflow) => workflow.kind === 'shared-provider' && workflow.armed);
    const direct = repository.workflows.filter((workflow) => workflow.kind === 'direct-armed' && workflow.armed);
    if (shared.length === 0 || direct.length === 0) continue;
    for (const workflow of direct) {
      duplicates.push({
        packages: workflow.packages,
        ref: repository.ref,
        repository: repository.repository,
        shared_workflows: shared.map((entry) => entry.path),
        workflow: workflow.path,
      });
    }
  }
  return duplicates.sort((a, b) => a.repository.localeCompare(b.repository) || a.workflow.localeCompare(b.workflow));
}

function identityFindings(report, armedOnly) {
  const failures = [];
  for (const repository of report.repositories) {
    for (const workflow of repository.workflows) {
      if (armedOnly && !workflow.armed) continue;
      for (const finding of workflow.identity_findings) {
        failures.push({
          ...finding,
          armed: workflow.armed,
          ref: repository.ref,
          repository: repository.repository,
          workflow: workflow.path,
        });
      }
    }
  }
  const unique = new Map();
  for (const finding of failures) {
    unique.set([finding.repository, finding.ref, finding.workflow, finding.code, finding.path, finding.detail].join('\u0000'), finding);
  }
  return [...unique.values()].sort((a, b) => a.repository.localeCompare(b.repository) || a.workflow.localeCompare(b.workflow) || a.code.localeCompare(b.code) || a.path.localeCompare(b.path));
}

function organizationRepositories(root, organization) {
  return readdirSync(root, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && !entry.name.startsWith('.') && !entry.isSymbolicLink())
    .sort((a, b) => a.name.localeCompare(b.name))
    .map((entry) => ({ repository: `${organization}/${entry.name}`, root: join(root, entry.name) }))
    .filter((entry) => gitOriginRepository(entry.root) === entry.repository);
}

function loadInventory(path, organization, maximumAgeSeconds) {
  let inventory;
  try {
    inventory = JSON.parse(readFileSync(resolve(path), 'utf8'));
  } catch (error) {
    throw new Error(`cannot read --inventory: ${error.message}`);
  }
  if (inventory.schema !== inventorySchema || inventory.source !== 'github-api' || inventory.organization !== organization || !Array.isArray(inventory.repositories)) {
    throw new Error('--inventory does not have the required GitHub API inventory schema, source, organization, and repositories');
  }
  const fetchedAt = Date.parse(inventory.fetched_at || '');
  if (Number.isNaN(fetchedAt)) throw new Error('--inventory has no valid fetched_at');
  if (maximumAgeSeconds !== undefined && Date.now() - fetchedAt > maximumAgeSeconds * 1000) {
    throw new Error(`--inventory is older than ${maximumAgeSeconds} seconds`);
  }
  if (!['exclude', 'include'].includes(inventory.archive_policy)) throw new Error('--inventory has an unsupported archive policy');
  const repositories = [...inventory.repositories].sort((left, right) => left.repository.localeCompare(right.repository));
  const seen = new Set();
  for (const entry of repositories) {
    if (entry.archived && inventory.archive_policy === 'exclude') throw new Error(`--inventory includes archived repository despite exclude policy: ${entry.repository}`);
    if (!isRepositorySlug(entry.repository) || !entry.repository.startsWith(`${organization}/`) || !entry.default_branch || !/^[0-9a-f]{40}$/i.test(entry.default_sha || '') || seen.has(entry.repository)) {
      throw new Error(`--inventory has invalid repository evidence: ${entry.repository || '(empty)'}`);
    }
    seen.add(entry.repository);
  }
  return { ...inventory, repositories };
}

async function main() {
  let args;
  try {
    args = parseArgs(process.argv.slice(2));
  } catch (error) {
    console.error(`npm-publish-audit: ARGUMENT_ERROR ${error.message}`);
    process.exit(2);
  }

  const organization = args.organization || 'sneat-co';
  const organizationScan = Boolean(args['organization-root']);
  const requireAuthoritative = args.flags.has('--require-authoritative');
  let inventory;
  let trustedInventory = false;
  try {
    if (requireAuthoritative && organizationScan) {
      if (!args.flags.has('--github-api')) throw new Error('--require-authoritative organization scans require --github-api; a supplied inventory file is not a trusted receipt');
      if (args.inventory) throw new Error('--inventory cannot be used with --require-authoritative; the provider must fetch GitHub API evidence in this process');
      const token = process.env.SNEAT_ORGANIZATION_AUDIT_TOKEN;
      if (!token) throw new Error('SNEAT_ORGANIZATION_AUDIT_TOKEN with complete organization repository visibility is required and is never printed');
      inventory = await createInventory({
        archivePolicy: args['archive-policy'] || 'exclude',
        baseURL: process.env.GITHUB_API_URL || 'https://api.github.com',
        organization,
        token,
      });
      trustedInventory = true;
    } else if (args.inventory) {
      inventory = loadInventory(args.inventory, organization, undefined);
    }
  } catch (error) {
    console.error(`npm-publish-audit: ARGUMENT_ERROR ${error.message}`);
    process.exit(2);
  }

  const localRepositoryEntries = organizationScan
    ? organizationRepositories(resolve(args['organization-root']), organization)
    : [{ repository: args.repository, root: resolve(args['repository-root'] || '.') }];
  let repositoryEntries = localRepositoryEntries;
  const inventoryFindings = [];
  if (organizationScan && inventory) {
    const localByRepository = new Map(localRepositoryEntries.map((entry) => [entry.repository, entry]));
    const inventoryByRepository = new Map(inventory.repositories.map((entry) => [entry.repository, { ...entry, fetched_at: inventory.fetched_at }]));
    for (const entry of inventory.repositories) {
      if (!localByRepository.has(entry.repository)) {
        inventoryFindings.push({ code: 'MISSING_INVENTORY_REPOSITORY', detail: 'authoritative inventory repository was not checked out', repository: entry.repository });
      }
    }
    for (const entry of localRepositoryEntries) {
      if (!inventoryByRepository.has(entry.repository)) {
        inventoryFindings.push({ code: 'UNEXPECTED_LOCAL_REPOSITORY', detail: 'local repository is absent from authoritative inventory', repository: entry.repository });
      }
    }
    repositoryEntries = inventory.repositories
      .filter((entry) => localByRepository.has(entry.repository))
      .map((entry) => ({ ...localByRepository.get(entry.repository), inventory: inventoryByRepository.get(entry.repository) }));
  } else if (organizationScan && !inventory) {
    inventoryFindings.push({ code: 'AUTHORITATIVE_GITHUB_API_REQUIRED', detail: 'local checkout set and cached origin refs are diagnostic only', repository: organization });
  }
  if (repositoryEntries.some((entry) => !isRepositorySlug(entry.repository))) {
    console.error('npm-publish-audit: ARGUMENT_ERROR --repository is required unless --organization-root is used');
    process.exit(2);
  }

  const report = {
    repository_source: organizationScan ? 'canonical immediate children only; hidden and symlinked directories excluded' : 'one checked-out caller repository',
    scope: organizationScan ? {
      archive_policy: inventory?.archive_policy || 'local-snapshot: archived remotes are not queried or included unless checked out',
      filters: [...(inventory?.filters || ['local snapshot only']), 'immediate children only', 'hidden directories excluded', 'symlinked directories excluded', 'origin repository must match directory name'],
      inventory_fetched_at: inventory?.fetched_at,
      organization,
      owner_set: inventory ? inventory.repositories.map((entry) => entry.repository) : repositoryEntries.map((entry) => entry.repository),
    } : {
      archive_policy: 'not applicable to one checked-out repository',
      filters: ['one explicit repository root'],
      owner_set: repositoryEntries.map((entry) => entry.repository),
    },
    repositories: repositoryEntries.map((entry) => auditRepository(entry.repository, entry.root, entry.inventory, trustedInventory)),
  };
  const duplicateOwners = ownerEvidence(report);
  const directArmedDuplicates = directDuplicates(report);
  const allIdentityFindings = identityFindings(report, false);
  const armedIdentityFindings = identityFindings(report, true);
  const nonAuthoritative = report.repositories
    .filter((repository) => repository.authority.state !== 'authoritative')
    .map((repository) => ({ authority: repository.authority, repository: repository.repository }));
  report.direct_armed_duplicates = directArmedDuplicates;
  report.duplicate_package_owners = duplicateOwners;
  report.identity_findings = allIdentityFindings;
  report.armed_identity_findings = armedIdentityFindings;
  report.inventory_findings = inventoryFindings;
  report.non_authoritative_repositories = nonAuthoritative;
  report.status = duplicateOwners.length === 0 && directArmedDuplicates.length === 0 && armedIdentityFindings.length === 0 && inventoryFindings.length === 0
    ? (nonAuthoritative.length === 0 ? 'passed' : 'non-authoritative')
    : 'failed';
  console.log(`npm-publish-audit: ${JSON.stringify(report)}`);

  const requireUniqueOwners = args.flags.has('--require-unique-owners');
  const requireNoDirectPublisher = args.flags.has('--require-no-direct-publisher');
  const requirePublishIdentities = args.flags.has('--require-publish-identities');
  for (const duplicate of directArmedDuplicates) {
    if (requireNoDirectPublisher || requireUniqueOwners) {
      console.error(`npm-publish-audit: [DUPLICATE_ARMED_PUBLISHER] ${duplicate.repository}@${duplicate.ref} ${duplicate.workflow} duplicates ${duplicate.shared_workflows.join(', ')} for ${duplicate.packages.map((pkg) => pkg.name).join(', ') || '(no public package manifest found)'}`);
    }
  }
  for (const duplicate of duplicateOwners) {
    if (requireUniqueOwners) {
      const evidence = duplicate.owners.map((owner) => `${owner.repository}@${owner.ref}:${owner.workflow}:${owner.package_path}`).join(' | ');
      console.error(`npm-publish-audit: [DUPLICATE_PACKAGE_OWNER] ${duplicate.package}: ${evidence}`);
    }
  }
  for (const finding of allIdentityFindings) {
    if (requireUniqueOwners ? finding.armed !== false : requirePublishIdentities) {
      console.error(`npm-publish-audit: [${finding.code}] ${finding.repository}@${finding.ref} ${finding.workflow} ${finding.path}: ${finding.detail}`);
    }
  }
  for (const stale of nonAuthoritative) {
    if (requireAuthoritative) {
      console.error(`npm-publish-audit: [NON_AUTHORITATIVE_LOCAL_REF] ${stale.repository}: ${stale.authority.reason}`);
    }
  }
  for (const finding of inventoryFindings) {
    if (requireAuthoritative) {
      console.error(`npm-publish-audit: [${finding.code}] ${finding.repository}: ${finding.detail}`);
    }
  }
  if ((requireNoDirectPublisher && directArmedDuplicates.length > 0)
    || (requireUniqueOwners && (duplicateOwners.length > 0 || directArmedDuplicates.length > 0 || armedIdentityFindings.length > 0))
    || (requirePublishIdentities && allIdentityFindings.length > 0)
    || (requireAuthoritative && (nonAuthoritative.length > 0 || inventoryFindings.length > 0))) {
    process.exit(1);
  }
}

main().catch((error) => {
  console.error(`npm-publish-audit: ERROR ${error.message}`);
  process.exit(2);
});
