#!/usr/bin/env node

import { existsSync, lstatSync, readdirSync, readFileSync, realpathSync } from 'node:fs';
import { isAbsolute, join, relative, resolve, sep } from 'node:path';
import { spawnSync } from 'node:child_process';
import { inspectPackageIdentity } from './check.mjs';
import { createInventory, schema as inventorySchema } from './create-organization-inventory.mjs';
import { analyzePublisherWorkflows } from './workflow-analysis.mjs';
import { safeDetail, safeError } from './redact.mjs';
import { parseStrictJson } from './strict-json.mjs';

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
  const packageClaims = new Map();
  const findings = [];
  const directories = workingDirectories.length > 0 ? workingDirectories : [];
  const root = realpathSync(repositoryRoot);
  for (const workingDirectory of directories) {
    let directory;
    try {
      directory = resolve(root, workingDirectory);
      const pathRelative = relative(root, directory);
      if (pathRelative === '..' || pathRelative.startsWith(`..${sep}`) || isAbsolute(pathRelative) || !existsSync(directory)) {
        throw new Error('outside or missing');
      }
      const resolvedDirectory = realpathSync(directory);
      const resolvedRelative = relative(root, resolvedDirectory);
      if (resolvedRelative === '..' || resolvedRelative.startsWith(`..${sep}`) || isAbsolute(resolvedRelative) || lstatSync(directory).isSymbolicLink()) {
        throw new Error('outside or symlinked');
      }
      directory = resolvedDirectory;
    } catch {
      findings.push({
        code: 'PUBLISH_DIRECTORY_OUTSIDE_WORKSPACE',
        detail: 'publisher working directory is outside the checked-out repository, missing, or symlinked',
        path: '.',
      });
      continue;
    }
    const inspected = inspectPackageIdentity({ repository, directory });
    for (const finding of inspected.findings) {
      findings.push({ ...finding, path: relative(root, join(directory, finding.path)) });
    }
    for (const pkg of inspected.packages) {
      const path = relative(root, join(directory, pkg.path));
      packageEntries.set(`${pkg.name}\u0000${path}`, { name: pkg.name, path });
    }
    for (const pkg of inspected.package_claims) {
      const path = relative(root, join(directory, pkg.path));
      packageClaims.set(`${pkg.name}\u0000${path}`, { name: pkg.name, path });
    }
  }
  return {
    findings: findings.sort((a, b) => a.code.localeCompare(b.code) || a.path.localeCompare(b.path) || a.detail.localeCompare(b.detail)),
    package_claims: [...packageClaims.values()].sort((a, b) => a.name.localeCompare(b.name) || a.path.localeCompare(b.path)),
    packages: [...packageEntries.values()].sort((a, b) => a.name.localeCompare(b.name) || a.path.localeCompare(b.path)),
  };
}

function auditRepository(repository, repositoryRoot, inventoryEntry, trustedInventory) {
  const analysis = analyzePublisherWorkflows(repositoryRoot);
  const workflows = analysis.records;
  for (const workflow of workflows) {
    const evidence = packageEvidence(repository, repositoryRoot, workflow.working_directories);
    workflow.identity_findings = evidence.findings;
    workflow.package_claims = evidence.package_claims;
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
    workflow_analysis_findings: analysis.findings,
    workflows,
  };
}

function ownerEvidence(report) {
  const owners = new Map();
  for (const repository of report.repositories) {
    for (const workflow of repository.workflows) {
      if (!workflow.armed) continue;
      for (const pkg of workflow.package_claims || workflow.packages) {
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
        packages: workflow.package_claims || workflow.packages,
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

function workflowAnalysisFindings(report, armedOnly) {
  const failures = [];
  for (const repository of report.repositories) {
    for (const finding of repository.workflow_analysis_findings || []) {
      if (finding.relevant !== true || (armedOnly && finding.armed === false)) continue;
      failures.push({
        ...finding,
        ref: repository.ref,
        repository: repository.repository,
        workflow: finding.path,
      });
    }
  }
  const unique = new Map();
  for (const finding of failures) {
    unique.set([finding.repository, finding.ref, finding.workflow, finding.code, finding.detail].join('\u0000'), finding);
  }
  return [...unique.values()].sort((a, b) => (
    a.repository.localeCompare(b.repository)
    || a.workflow.localeCompare(b.workflow)
    || a.code.localeCompare(b.code)
  ));
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
    inventory = parseStrictJson(readFileSync(resolve(path), 'utf8'));
  } catch {
    throw new Error('cannot read a valid --inventory');
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
    if (entry.archived && inventory.archive_policy === 'exclude') throw new Error('--inventory includes an archived repository despite exclude policy');
    if (!isRepositorySlug(entry.repository) || !entry.repository.startsWith(`${organization}/`) || !entry.default_branch || !/^[0-9a-f]{40}$/i.test(entry.default_sha || '') || seen.has(entry.repository)) {
      throw new Error('--inventory has invalid repository evidence');
    }
    seen.add(entry.repository);
  }
  return { ...inventory, repositories };
}

function redacted(value) {
  if (typeof value === 'string') return safeDetail(value);
  if (Array.isArray(value)) return value.map(redacted);
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([key, entry]) => [key, redacted(entry)]));
  return value;
}

async function main() {
  let args;
  try {
    args = parseArgs(process.argv.slice(2));
  } catch (error) {
    console.error(`npm-publish-audit: ARGUMENT_ERROR ${safeError(error)}`);
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
    console.error(`npm-publish-audit: ARGUMENT_ERROR ${safeError(error)}`);
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
      credential_entitlement: trustedInventory ? inventory?.credential_entitlement : undefined,
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
  const allWorkflowAnalysisFindings = workflowAnalysisFindings(report, false);
  const armedWorkflowAnalysisFindings = workflowAnalysisFindings(report, true);
  const nonAuthoritative = report.repositories
    .filter((repository) => repository.authority.state !== 'authoritative')
    .map((repository) => ({ authority: repository.authority, repository: repository.repository }));
  report.direct_armed_duplicates = directArmedDuplicates;
  report.duplicate_package_owners = duplicateOwners;
  report.identity_findings = allIdentityFindings;
  report.armed_identity_findings = armedIdentityFindings;
  report.workflow_analysis_findings = allWorkflowAnalysisFindings;
  report.armed_workflow_analysis_findings = armedWorkflowAnalysisFindings;
  report.inventory_findings = inventoryFindings;
  report.non_authoritative_repositories = nonAuthoritative;
  const definitiveFailure = duplicateOwners.length > 0 || directArmedDuplicates.length > 0 || armedIdentityFindings.length > 0 || inventoryFindings.length > 0;
  report.status = definitiveFailure
    ? 'failed'
    : (armedWorkflowAnalysisFindings.length > 0
      ? 'inconclusive'
      : (nonAuthoritative.length === 0 ? 'passed' : 'non-authoritative'));
  console.log(`npm-publish-audit: ${JSON.stringify(redacted(report))}`);

  const requireUniqueOwners = args.flags.has('--require-unique-owners');
  const requireNoDirectPublisher = args.flags.has('--require-no-direct-publisher');
  const requirePublishIdentities = args.flags.has('--require-publish-identities');
  for (const duplicate of directArmedDuplicates) {
    if (requireNoDirectPublisher || requireUniqueOwners) {
      console.error(`npm-publish-audit: [DUPLICATE_ARMED_PUBLISHER] ${safeDetail(duplicate.repository)}@${safeDetail(duplicate.ref)} ${safeDetail(duplicate.workflow)} duplicates ${safeDetail(duplicate.shared_workflows.join(', '))} for ${safeDetail(duplicate.packages.map((pkg) => pkg.name).join(', ') || '(no public package manifest found)')}`);
    }
  }
  for (const duplicate of duplicateOwners) {
    if (requireUniqueOwners) {
      const evidence = duplicate.owners.map((owner) => `${owner.repository}@${owner.ref}:${owner.workflow}:${owner.package_path}`).join(' | ');
      console.error(`npm-publish-audit: [DUPLICATE_PACKAGE_OWNER] ${safeDetail(duplicate.package)}: ${safeDetail(evidence)}`);
    }
  }
  for (const finding of allIdentityFindings) {
    if (requireUniqueOwners ? finding.armed !== false : requirePublishIdentities) {
      console.error(`npm-publish-audit: [${finding.code}] ${safeDetail(finding.repository)}@${safeDetail(finding.ref)} ${safeDetail(finding.workflow)} ${safeDetail(finding.path)}: ${safeDetail(finding.detail)}`);
    }
  }
  for (const finding of allWorkflowAnalysisFindings) {
    if ((requireUniqueOwners || requireNoDirectPublisher) && finding.armed !== false) {
      console.error(`npm-publish-audit: [${finding.code}] ${safeDetail(finding.repository)}@${safeDetail(finding.ref)} ${safeDetail(finding.workflow)}: ${safeDetail(finding.detail)}`);
    }
  }
  for (const stale of nonAuthoritative) {
    if (requireAuthoritative) {
      console.error(`npm-publish-audit: [NON_AUTHORITATIVE_LOCAL_REF] ${safeDetail(stale.repository)}: ${safeDetail(stale.authority.reason)}`);
    }
  }
  for (const finding of inventoryFindings) {
    if (requireAuthoritative) {
      console.error(`npm-publish-audit: [${finding.code}] ${safeDetail(finding.repository)}: ${safeDetail(finding.detail)}`);
    }
  }
  if ((requireNoDirectPublisher && (directArmedDuplicates.length > 0 || armedWorkflowAnalysisFindings.length > 0))
    || (requireUniqueOwners && (duplicateOwners.length > 0 || directArmedDuplicates.length > 0 || armedIdentityFindings.length > 0 || armedWorkflowAnalysisFindings.length > 0))
    || (requirePublishIdentities && (allIdentityFindings.length > 0 || allWorkflowAnalysisFindings.length > 0))
    || (requireAuthoritative && (nonAuthoritative.length > 0 || inventoryFindings.length > 0 || armedWorkflowAnalysisFindings.length > 0))) {
    process.exit(1);
  }
}

main().catch((error) => {
  console.error(`npm-publish-audit: ERROR ${safeError(error)}`);
  process.exit(2);
});
