#!/usr/bin/env node

import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { basename, dirname, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const actionDirectory = dirname(fileURLToPath(import.meta.url));
const policy = JSON.parse(readFileSync(join(actionDirectory, 'policy.json'), 'utf8'));
const skippedDirectories = new Set([
  '.git', '.nx', '.angular', '.wb', '.worktrees', 'coverage', 'dist', 'node_modules',
]);

function parseArgs(argv) {
  const result = {};
  for (let i = 0; i < argv.length; i += 1) {
    const flag = argv[i];
    if (!flag.startsWith('--')) continue;
    const value = argv[i + 1];
    if (!value || value.startsWith('--')) throw new Error(`missing value for ${flag}`);
    result[flag.slice(2)] = value;
    i += 1;
  }
  return result;
}

function collectNamedFiles(root, wantedNames) {
  const files = [];
  function walk(directory) {
    for (const entry of readdirSync(directory, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
      if (entry.isDirectory()) {
        if (!skippedDirectories.has(entry.name)) walk(join(directory, entry.name));
      } else if (entry.isFile() && wantedNames.has(entry.name)) {
        files.push(join(directory, entry.name));
      }
    }
  }
  walk(root);
  return files.sort();
}

function readJson(path, findings, code) {
  try {
    return JSON.parse(readFileSync(path, 'utf8'));
  } catch (error) {
    findings.push({ code, path, detail: error.message });
    return undefined;
  }
}

function isRepositorySlug(value) {
  return typeof value === 'string'
    && /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})\/[A-Za-z0-9][A-Za-z0-9._-]*$/.test(value);
}

function normalizeRepository(value) {
  if (typeof value === 'object' && value !== null) value = value.url;
  if (typeof value !== 'string' || value.trim() === '') return undefined;
  const trimmed = value.trim();
  const patterns = [
    /^(?:git\+)?https:\/\/github\.com\/([^/\s]+)\/([^/\s]+?)(?:\.git)?\/?$/i,
    /^(?:git\+)?ssh:\/\/git@github\.com\/([^/\s]+)\/([^/\s]+?)(?:\.git)?\/?$/i,
    /^git@github\.com:([^/\s]+)\/([^/\s]+?)(?:\.git)?$/i,
    /^github:([^/\s]+)\/([^/\s]+)$/i,
    /^([^/\s]+)\/([^/\s]+)$/,
  ];
  for (const pattern of patterns) {
    const match = trimmed.match(pattern);
    if (match) {
      const repository = `${match[1]}/${match[2]}`;
      return isRepositorySlug(repository) ? repository : undefined;
    }
  }
  return undefined;
}

function hasPackageBoundary(value, prefix) {
  return value === prefix || value.startsWith(`${prefix}-`);
}

function conventionOwnsPackage(repository, packageName) {
  const [owner, repo] = repository.split('/');
  if (owner !== 'sneat-co' || !repo) return false;

  if (repo.startsWith('ext-')) {
    const extensionID = repo.slice('ext-'.length);
    return packageName === `@sneat/extension-${extensionID}-contract`;
  }

  if (hasPackageBoundary(packageName, `@sneat/extension-${repo}`)) return true;
  if (packageName === `@sneat/${repo}`) return true;
  if (repo.startsWith('sneat-') && packageName === `@sneat/${repo.slice('sneat-'.length)}`) return true;
  return false;
}

function policyOwnsPackage(repository, packageName) {
  const packages = policy.repository_packages[repository] || [];
  if (packages.includes(packageName)) return true;
  const prefixes = policy.repository_package_prefixes[repository] || [];
  return prefixes.some((prefix) => hasPackageBoundary(packageName, prefix));
}

function isCanonicalTemplateRepository(repository) {
  return repository === policy.template_exception.repository;
}

function sortedFindings(findings) {
  return findings.sort((a, b) => (
    a.code.localeCompare(b.code)
    || a.path.localeCompare(b.path)
    || a.detail.localeCompare(b.detail)
  ));
}

export function inspectPackageIdentity({ repository, directory }) {
  const findings = [];
  const absoluteDirectory = resolve(directory);
  if (!isRepositorySlug(repository)) {
    findings.push({ code: 'INVALID_REPOSITORY', path: '.', detail: repository || '(empty)' });
    return { findings, packages: [], directory: absoluteDirectory };
  }
  if (!existsSync(absoluteDirectory) || !statSync(absoluteDirectory).isDirectory()) {
    findings.push({ code: 'MISSING_DIRECTORY', path: absoluteDirectory, detail: 'publish workspace does not exist' });
    return { findings, packages: [], directory: absoluteDirectory };
  }

  const packagePaths = collectNamedFiles(absoluteDirectory, new Set(['package.json']));
  const projectPaths = collectNamedFiles(absoluteDirectory, new Set(['project.json']));
  const packages = [];
  const canonicalTemplate = isCanonicalTemplateRepository(repository);

  for (const path of packagePaths) {
    const manifest = readJson(path, findings, 'INVALID_PACKAGE_JSON');
    if (!manifest) continue;
    const packageName = manifest.name;
    const pathRelative = relative(absoluteDirectory, path) || basename(path);
    if (typeof packageName === 'string' && packageName.toLowerCase().includes('template') && !canonicalTemplate) {
      findings.push({
        code: packageName === policy.template_exception.package
          ? 'TEMPLATE_PACKAGE_REQUIRES_CANONICAL_REPOSITORY'
          : 'UNREBRANDED_TEMPLATE_PACKAGE',
        path: pathRelative,
        detail: packageName,
      });
    }
    if (!canonicalTemplate) {
      for (const section of ['dependencies', 'devDependencies', 'optionalDependencies', 'peerDependencies']) {
        const dependencies = manifest[section];
        if (!dependencies || typeof dependencies !== 'object') continue;
        for (const [dependency, range] of Object.entries(dependencies)) {
          if (dependency.startsWith('@sneat/') && dependency.toLowerCase().includes('template')) {
            findings.push({
              code: 'UNREBRANDED_TEMPLATE_DEPENDENCY',
              path: pathRelative,
              detail: `${section}.${dependency}=${range}`,
            });
          }
        }
      }
    }
    if (manifest.private === true) continue;
    if (typeof packageName !== 'string' || packageName.trim() === '') {
      findings.push({ code: 'INVALID_PUBLIC_PACKAGE_NAME', path: pathRelative, detail: String(packageName) });
      continue;
    }
    if (!packageName.startsWith('@') && !policyOwnsPackage(repository, packageName)) {
      findings.push({ code: 'UNSCOPED_PUBLIC_PACKAGE', path: pathRelative, detail: packageName });
      continue;
    }
    packages.push({ manifest, name: packageName, path, pathRelative });
  }

  for (const path of projectPaths) {
    const project = readJson(path, findings, 'INVALID_PROJECT_JSON');
    if (!project || canonicalTemplate) continue;
    const pathRelative = relative(absoluteDirectory, path) || basename(path);
    if (typeof project.name === 'string' && project.name.toLowerCase().includes('template')) {
      findings.push({ code: 'UNREBRANDED_TEMPLATE_PROJECT', path: pathRelative, detail: project.name });
    }
    if (pathRelative.split(sep).some((segment) => segment.toLowerCase().includes('template'))) {
      findings.push({ code: 'UNREBRANDED_TEMPLATE_PATH', path: pathRelative, detail: 'template remains in project path' });
    }
  }

  for (const candidate of packages) {
    const declaredRepository = candidate.manifest.repository;
    const normalizedDeclaredRepository = normalizeRepository(declaredRepository);
    if (declaredRepository !== undefined && !normalizedDeclaredRepository) {
      findings.push({ code: 'INVALID_PACKAGE_REPOSITORY', path: candidate.pathRelative, detail: String(declaredRepository) });
      continue;
    }
    if (normalizedDeclaredRepository && normalizedDeclaredRepository !== repository) {
      findings.push({
        code: 'PACKAGE_REPOSITORY_MISMATCH',
        path: candidate.pathRelative,
        detail: `${candidate.name} declares ${normalizedDeclaredRepository}, not ${repository}`,
      });
      continue;
    }

    if (candidate.name === policy.template_exception.package) {
      if (!canonicalTemplate) {
        // The template-name finding above is the actionable diagnostic; avoid a
        // second generic mismatch that obscures the copied-scaffold fix.
        continue;
      }
      continue;
    }
    if (candidate.name.toLowerCase().includes('template')) continue;
    if (conventionOwnsPackage(repository, candidate.name)) continue;
    if (policyOwnsPackage(repository, candidate.name)) continue;
    findings.push({
      code: 'UNKNOWN_PACKAGE_IDENTITY',
      path: candidate.pathRelative,
      detail: `${candidate.name} has no provider-owned ownership mapping for ${repository}`,
    });
  }

  if (canonicalTemplate) {
    for (const candidate of packages) {
      if (candidate.name !== policy.template_exception.package) {
        findings.push({
          code: 'TEMPLATE_REPOSITORY_MAY_ONLY_PUBLISH_TEMPLATE_PACKAGE',
          path: candidate.pathRelative,
          detail: candidate.name,
        });
      }
    }
  }

  if (packages.length === 0) {
    findings.push({
      code: 'NO_PUBLISHABLE_PACKAGE_IDENTITY',
      path: '.',
      detail: 'publisher inputs must contain at least one approved, source-visible public package identity',
    });
  }

  return {
    directory: absoluteDirectory,
    findings: sortedFindings(findings),
    packages: packages.map(({ name, pathRelative }) => ({ name, path: pathRelative })).sort((a, b) => a.name.localeCompare(b.name) || a.path.localeCompare(b.path)),
  };
}

function main() {
  let args;
  try {
    args = parseArgs(process.argv.slice(2));
  } catch (error) {
    console.error(`npm-publish-identity: ARGUMENT_ERROR ${error.message}`);
    process.exit(2);
  }
  const result = inspectPackageIdentity({ repository: args.repository, directory: args.directory || '.' });
  const report = {
    directory: result.directory,
    package_count: result.packages.length,
    packages: result.packages,
    policy_version: policy.policy_version,
    repository: args.repository || '',
    status: result.findings.length === 0 ? 'passed' : 'failed',
  };
  console.log(`npm-publish-identity: ${JSON.stringify(report)}`);
  for (const finding of result.findings) {
    console.error(`npm-publish-identity: [${finding.code}] ${finding.path}: ${finding.detail}`);
  }
  if (result.findings.length > 0) process.exit(1);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
