import { existsSync, lstatSync, readdirSync, readFileSync } from 'node:fs';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { parseWorkflowYaml } from './workflow-yaml.mjs';
import { safeDetail } from './redact.mjs';
import { parseStrictJson } from './strict-json.mjs';

const providerWorkflows = new Map([
  ['npm-publish.yml', 'legacy'],
  ['npm-publish-strict.yml', 'strict'],
]);
const automaticEvents = new Set([
  'branch_protection_rule', 'check_run', 'create', 'delete', 'deployment',
  'deployment_status', 'discussion', 'discussion_comment', 'fork', 'gollum',
  'issue_comment', 'issues', 'label', 'merge_group', 'milestone', 'page_build',
  'project', 'project_card', 'project_column', 'public', 'pull_request',
  'pull_request_review', 'pull_request_review_comment', 'pull_request_target',
  'push', 'registry_package', 'release', 'repository_dispatch', 'schedule',
  'status', 'watch', 'workflow_run',
]);

class UnsafePathError extends Error {
  constructor(reason) {
    super(reason);
  }
}

function isObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function strings(value) {
  if (typeof value === 'string') return [value];
  if (Array.isArray(value)) return value.flatMap(strings);
  return [];
}

function isInside(root, target) {
  const pathRelative = relative(root, target);
  return pathRelative === ''
    || (!pathRelative.startsWith(`..${sep}`) && pathRelative !== '..' && !isAbsolute(pathRelative));
}

function rootRelative(root, path) {
  return relative(root, path) || '.';
}

function assertExistingPath(root, base, requested, expectedType) {
  if (typeof requested !== 'string' || requested === '' || requested.includes('\u0000')) {
    throw new UnsafePathError('path is not a static non-empty string');
  }
  if (requested.split(/[\\/]+/).includes('..')) {
    throw new UnsafePathError('path contains parent traversal');
  }
  const target = resolve(base, requested);
  if (!isInside(root, target)) throw new UnsafePathError('path resolves outside repository');
  const pathRelative = relative(root, target);
  let current = root;
  for (const segment of pathRelative === '' ? [] : pathRelative.split(sep)) {
    current = join(current, segment);
    if (!existsSync(current)) throw new UnsafePathError('path does not exist');
    const metadata = lstatSync(current);
    if (metadata.isSymbolicLink()) throw new UnsafePathError('path contains a symbolic link');
  }
  const metadata = lstatSync(target);
  if (metadata.isSymbolicLink()) throw new UnsafePathError('path is a symbolic link');
  if ((expectedType === 'directory' && !metadata.isDirectory()) || (expectedType === 'file' && !metadata.isFile())) {
    throw new UnsafePathError(`path is not a ${expectedType}`);
  }
  return target;
}

function triggerPolicy(document) {
  if (!isObject(document) || !Object.hasOwn(document, 'on')) return 'disabled';
  const value = document.on;
  const events = isObject(value) ? Object.keys(value) : strings(value);
  if (events.length === 0) return 'unknown';
  if (events.some((event) => automaticEvents.has(String(event)))) return 'armed';
  if (events.every((event) => ['workflow_dispatch', 'workflow_call'].includes(String(event)))) {
    return events.includes('workflow_dispatch') ? 'manual-only' : 'not-release-triggered';
  }
  return 'unknown';
}

function isPublisherCredentialName(name) {
  return /^(?:NPM_TOKEN|NODE_AUTH_TOKEN|(?:NPM|NODE_AUTH|REGISTRY)_[A-Z0-9_]*(?:TOKEN|AUTH))$/i.test(name || '');
}

function hasPublisherCredential(value) {
  if (typeof value === 'string') {
    if (value === 'inherit') return true;
    const expression = /\$\{\{\s*secrets\s*(?:\.\s*|\[\s*['"]?)([A-Za-z0-9_]+)/gi;
    for (const match of value.matchAll(expression)) {
      if (isPublisherCredentialName(match[1])) return true;
    }
    return false;
  }
  if (Array.isArray(value)) return value.some(hasPublisherCredential);
  if (isObject(value)) return Object.entries(value).some(([key, entry]) => (
    isPublisherCredentialName(key) || hasPublisherCredential(entry)
  ));
  return false;
}

function workingDirectory(root, value, fallback, addFinding, context) {
  const requested = value === undefined || value === null || value === '' ? fallback : value;
  if (requested === undefined) return undefined;
  if (typeof requested !== 'string' || requested.includes('${{')) {
    addFinding('DYNAMIC_WORKING_DIRECTORY', context, 'publisher working directory is not statically verifiable');
    return undefined;
  }
  try {
    return rootRelative(root, assertExistingPath(root, root, requested, 'directory'));
  } catch {
    addFinding('UNVERIFIED_WORKING_DIRECTORY', context, 'publisher working directory is outside the repository, missing, or symlinked');
    return undefined;
  }
}

function localPath(root, sourcePath, kind, expectedType, addFinding, context) {
  if (typeof sourcePath !== 'string' || !sourcePath.startsWith('./') || sourcePath.includes('${{')) {
    addFinding('UNRESOLVED_LOCAL_REFERENCE', context, `unsupported local ${kind} reference`);
    return undefined;
  }
  try {
    return assertExistingPath(root, root, sourcePath, expectedType);
  } catch {
    addFinding('UNRESOLVED_LOCAL_REFERENCE', context, `local ${kind} is outside the repository, missing, or symlinked`);
    return undefined;
  }
}

function commandWorkingDirectory(root, baseDirectory, requested, addFinding, context) {
  if (requested === undefined) return baseDirectory;
  if (baseDirectory === undefined || typeof requested !== 'string' || requested.includes('${{')) {
    addFinding('DYNAMIC_WORKING_DIRECTORY', context, 'publisher working directory is not statically verifiable');
    return undefined;
  }
  try {
    return rootRelative(root, assertExistingPath(root, resolve(root, baseDirectory), requested, 'directory'));
  } catch {
    addFinding('UNVERIFIED_WORKING_DIRECTORY', context, 'publisher working directory is outside the repository, missing, or symlinked');
    return undefined;
  }
}

function commandSegments(command) {
  return command.split(/[;&|\n]+/).map((segment) => segment.trim()).filter(Boolean);
}

function splitTokens(segment) {
  return segment.match(/(?:"[^"]*"|'[^']*'|[^\s]+)/g) || [];
}

function unquoteToken(token) {
  if (typeof token !== 'string') return token;
  if ((token.startsWith('"') && token.endsWith('"')) || (token.startsWith("'") && token.endsWith("'"))) {
    return token.slice(1, -1);
  }
  return token;
}

const packageManagers = new Set(['npm', 'pnpm', 'yarn']);
const directoryOptions = new Set(['--dir', '--prefix', '--cwd', '-C']);
const optionsWithValues = new Set([
  '--access', '--config', '--dir', '--filter', '--prefix', '--registry', '--tag', '--workspace',
  '--cwd', '-C', '-F', '-w',
]);

function optionValue(token) {
  const match = unquoteToken(token).match(/^(--(?:dir|prefix|cwd)|-C)(?:=)?(.+)$/);
  return match ? { name: match[1], value: unquoteToken(match[2]) } : undefined;
}

function packageManagerInvocation(tokens, index) {
  const manager = unquoteToken(tokens[index])?.toLowerCase();
  if (!packageManagers.has(manager)) return undefined;
  let directory;
  let cursor = index + 1;
  while (cursor < tokens.length) {
    const token = unquoteToken(tokens[cursor]);
    const inline = optionValue(token);
    if (inline) {
      directory = inline.value;
      cursor += 1;
      continue;
    }
    if (directoryOptions.has(token)) {
      directory = unquoteToken(tokens[cursor + 1]);
      cursor += 2;
      continue;
    }
    if (optionsWithValues.has(token)) {
      cursor += 2;
      continue;
    }
    if (token.startsWith('-')) {
      cursor += 1;
      continue;
    }
    break;
  }
  const subcommand = unquoteToken(tokens[cursor])?.toLowerCase();
  if (subcommand === 'publish') return { directory, kind: 'publish' };
  if (subcommand === 'run' || subcommand === 'run-script') {
    const script = unquoteToken(tokens[cursor + 1]);
    return { directory, kind: 'script', script };
  }
  const commands = new Set([
    'add', 'audit', 'cache', 'ci', 'config', 'create', 'dlx', 'exec', 'explain',
    'help', 'import', 'init', 'install', 'link', 'list', 'login', 'logout',
    'outdated', 'pack', 'prune', 'rebuild', 'remove', 'root', 'run', 'uninstall',
    'update', 'version', 'view', 'why', 'workspace', 'workspaces',
  ]);
  if (subcommand && !commands.has(subcommand) && /^[A-Za-z0-9:_./-]+$/.test(subcommand)) {
    return { directory, kind: 'script', script: subcommand };
  }
  return undefined;
}

function publishingInvocations(command) {
  const invocations = [];
  for (const segment of commandSegments(command)) {
    const tokens = splitTokens(segment);
    if (tokens.some((token, index) => unquoteToken(token).toLowerCase() === 'nx' && unquoteToken(tokens[index + 1])?.toLowerCase() === 'release')) {
      invocations.push({ directory: undefined });
    }
    for (let index = 0; index < tokens.length; index += 1) {
      const invocation = packageManagerInvocation(tokens, index);
      if (invocation?.kind === 'publish') invocations.push(invocation);
    }
  }
  return invocations;
}

function dynamicMaySelectPublish(command) {
  for (const segment of commandSegments(command)) {
    if (!segment.includes('${{')) continue;
    const tokens = splitTokens(segment).map(unquoteToken);
    // A dynamically selected executable is an unbounded shell sink: absent a
    // static command we cannot prove that it will not invoke npm publish.
    if (tokens[0]?.includes('${{')) return true;
    // Likewise a dynamic script/module passed to an interpreter can select a
    // publication path even when the interpreter name itself is static.
    if (['bash', 'sh', 'zsh', 'node', 'npx', 'tsx'].includes(tokens[0]?.toLowerCase())
      && tokens.slice(1).some((entry) => entry.includes('${{'))) return true;
    for (let index = 0; index < tokens.length; index += 1) {
      const token = tokens[index]?.toLowerCase();
      if (token === 'nx' && (tokens[index + 1]?.toLowerCase() === 'release' || tokens.slice(index + 1).some((entry) => entry.includes('${{')))) {
        return true;
      }
      if (!packageManagers.has(token)) continue;
      const argumentsAfterManager = tokens.slice(index + 1);
      if (!argumentsAfterManager.some((entry) => entry.includes('${{'))) continue;
      if (argumentsAfterManager[0]?.includes('${{')
        || argumentsAfterManager.some((entry) => ['publish', 'run', 'run-script', 'exec', 'dlx'].includes(entry.toLowerCase()))) {
        return true;
      }
    }
  }
  return false;
}

function dynamicRunIsProvenNonPublisher(command) {
  const dynamicSegments = commandSegments(command).filter((segment) => segment.includes('${{'));
  if (dynamicSegments.length === 0) return true;
  return dynamicSegments.every((segment) => {
    const tokens = splitTokens(segment).map(unquoteToken);
    const executable = tokens[0]?.toLowerCase();
    if (['echo', 'printf'].includes(executable)) return true;
    // Package installation with no npm credential is deliberately diagnostic:
    // it cannot itself select an npm publish subcommand. Keep the allowance
    // narrow so an unknown package-manager subcommand remains inconclusive.
    return /^(?:npm|pnpm|yarn)\s+(?:ci|install)(?:\s|$)/i.test(segment);
  });
}

function packageScriptInvocations(command) {
  const scripts = new Set();
  for (const segment of commandSegments(command)) {
    const tokens = splitTokens(segment);
    for (let index = 0; index < tokens.length; index += 1) {
      const invocation = packageManagerInvocation(tokens, index);
      if (invocation?.kind !== 'script') continue;
      if (typeof invocation.script === 'string' && /^[A-Za-z0-9:_./-]+$/.test(invocation.script)) {
        scripts.add(JSON.stringify({ directory: invocation.directory, script: invocation.script }));
      }
    }
  }
  return [...scripts].sort().map((entry) => JSON.parse(entry));
}

function localScriptReferences(command) {
  const references = [];
  const expression = /(?:^|[;&|]\s*|\b(?:bash|sh|zsh|node|tsx|npx)\s+)(\.\/?[A-Za-z0-9_./-]+\.(?:sh|mjs|cjs|js)|scripts\/[A-Za-z0-9_./-]+\.(?:sh|mjs|cjs|js))/g;
  for (const match of command.matchAll(expression)) references.push(match[1]);
  return [...new Set(references)].sort();
}

function providerContract(uses) {
  if (typeof uses !== 'string') return undefined;
  const match = uses.match(/^sneat-co\/cicd\/\.github\/workflows\/([^@/]+)@[^\s]+$/i);
  return match ? providerWorkflows.get(match[1]) : undefined;
}

export function analyzePublisherWorkflows(repositoryRoot) {
  let root;
  try {
    root = resolve(repositoryRoot);
    root = assertExistingPath(root, root, '.', 'directory');
  } catch {
    return {
      findings: [{ code: 'INVALID_REPOSITORY_ROOT', detail: 'repository root is unavailable or symlinked', path: '.' }],
      records: [],
    };
  }
  const findings = [];
  const records = [];
  const relevantRoots = new Set();
  const documentCache = new Map();
  const packageScriptStack = new Set();
  const scriptStack = new Set();

  function addFinding(code, context, detail) {
    const trigger = context?.trigger;
    findings.push({
      armed: trigger === 'armed' ? true : (['disabled', 'manual-only', 'not-release-triggered'].includes(trigger) ? false : undefined),
      code,
      detail: safeDetail(detail),
      path: context?.rootPath || '.',
    });
  }

  function markRelevant(context) {
    if (context?.rootPath) relevantRoots.add(context.rootPath);
  }

  function parseDocument(path, kind, context) {
    const absolute = resolve(path);
    const cached = documentCache.get(absolute);
    if (cached?.document) return cached;
    if (cached?.error) {
      markRelevant(context);
      addFinding('UNPARSEABLE_WORKFLOW', context, `${kind} cannot be structurally parsed`);
      return cached;
    }
    try {
      const parsed = parseWorkflowYaml(readFileSync(absolute, 'utf8'));
      if (!isObject(parsed)) throw new Error('top-level YAML value must be a mapping');
      const result = { document: parsed };
      documentCache.set(absolute, result);
      return result;
    } catch {
      const result = { error: true };
      documentCache.set(absolute, result);
      markRelevant(context);
      addFinding('UNPARSEABLE_WORKFLOW', context, `${kind} cannot be structurally parsed`);
      return result;
    }
  }

  function register(kind, provider, context, directory) {
    markRelevant(context);
    records.push({
      chain: [...context.chain],
      credential_reference: context.credentialReference,
      kind,
      path: context.rootPath,
      provider_contract: provider,
      trigger: context.trigger,
      armed: context.trigger === 'armed',
      working_directories: directory === undefined ? [] : [directory],
    });
  }

  function inspectPackageScript(directory, scriptName, context) {
    markRelevant(context);
    if (!directory) {
      markRelevant(context);
      addFinding('UNRESOLVED_PACKAGE_SCRIPT', context, 'package script has no statically known working directory');
      return;
    }
    let manifestPath;
    try {
      manifestPath = assertExistingPath(root, root, join(directory, 'package.json'), 'file');
    } catch {
      markRelevant(context);
      addFinding('UNRESOLVED_PACKAGE_SCRIPT', context, 'package script manifest is unavailable, outside the repository, or symlinked');
      return;
    }
    let manifest;
    try {
      manifest = parseStrictJson(readFileSync(manifestPath, 'utf8'));
    } catch {
      markRelevant(context);
      addFinding('INVALID_PACKAGE_SCRIPT_JSON', context, 'package script manifest is invalid or has duplicate JSON keys');
      return;
    }
    const key = `${manifestPath}\u0000${scriptName}\u0000${context.rootPath}`;
    if (packageScriptStack.has(key)) {
      addFinding('PACKAGE_SCRIPT_CALL_CYCLE', context, 'package script call graph contains a cycle');
      return;
    }
    const script = manifest?.scripts?.[scriptName];
    if (typeof script !== 'string') {
      markRelevant(context);
      addFinding('UNRESOLVED_PACKAGE_SCRIPT', context, 'package script is not statically available');
      return;
    }
    packageScriptStack.add(key);
    try {
      inspectRun(script, resolve(root, directory), directory, context);
    } finally {
      packageScriptStack.delete(key);
    }
  }

  function inspectScript(path, scriptBase, directory, context) {
    let target;
    try {
      target = assertExistingPath(root, scriptBase, path, 'file');
    } catch {
      markRelevant(context);
      addFinding('UNRESOLVED_LOCAL_SCRIPT', context, 'local publish script is unavailable, outside the repository, or symlinked');
      return;
    }
    const key = `${target}\u0000${context.rootPath}`;
    if (scriptStack.has(key)) {
      markRelevant(context);
      addFinding('SCRIPT_CALL_CYCLE', context, 'local script call graph contains a cycle');
      return;
    }
    scriptStack.add(key);
    try {
      inspectRun(readFileSync(target, 'utf8'), dirname(target), directory, context);
    } catch {
      markRelevant(context);
      addFinding('UNRESOLVED_LOCAL_SCRIPT', context, 'local script cannot be structurally inspected');
    } finally {
      scriptStack.delete(key);
    }
  }

  function inspectRun(command, scriptBase, directory, context) {
    if (typeof command !== 'string') {
      markRelevant(context);
      addFinding('UNVERIFIED_RUN_STEP', context, 'run step is not a static string');
      return;
    }
    if (command.includes('${{')) {
      if (dynamicMaySelectPublish(command)
        || context.credentialReference
        || context.potential
        || !dynamicRunIsProvenNonPublisher(command)) markRelevant(context);
      addFinding('DYNAMIC_RUN_COMMAND', context, 'run command contains an expression');
    }
    for (const invocation of publishingInvocations(command)) {
      const publishDirectory = commandWorkingDirectory(root, directory, invocation.directory, addFinding, context);
      register('direct-armed', undefined, context, publishDirectory);
    }
    for (const script of localScriptReferences(command)) inspectScript(script, scriptBase, directory, context);
    for (const script of packageScriptInvocations(command)) {
      const scriptDirectory = commandWorkingDirectory(root, directory, script.directory, addFinding, context);
      inspectPackageScript(scriptDirectory, script.script, { ...context, potential: true });
    }
  }

  function inspectAction(path, directory, context) {
    let actionDirectory;
    try {
      actionDirectory = assertExistingPath(root, root, path, 'directory');
    } catch {
      markRelevant(context);
      addFinding('UNRESOLVED_LOCAL_ACTION', context, 'local action is unavailable, outside the repository, or symlinked');
      return;
    }
    let manifest;
    try {
      for (const candidate of ['action.yml', 'action.yaml']) {
        const candidatePath = join(actionDirectory, candidate);
        if (existsSync(candidatePath)) {
          manifest = assertExistingPath(root, root, rootRelative(root, candidatePath), 'file');
          break;
        }
      }
    } catch {
      markRelevant(context);
      addFinding('UNRESOLVED_LOCAL_ACTION', context, 'local action manifest is unavailable, outside the repository, or symlinked');
      return;
    }
    if (!manifest) {
      markRelevant(context);
      addFinding('UNRESOLVED_LOCAL_ACTION', context, 'local action manifest is unavailable');
      return;
    }
    const parsed = parseDocument(manifest, 'action', context);
    if (!parsed.document) return;
    const runs = parsed.document.runs;
    if (!isObject(runs) || runs.using !== 'composite' || !Array.isArray(runs.steps)) {
      markRelevant(context);
      addFinding('UNVERIFIED_LOCAL_ACTION', context, 'local non-composite action cannot be statically verified');
      return;
    }
    for (const step of runs.steps) inspectStep(step, directory, context);
  }

  function inspectStep(step, inheritedDirectory, context) {
    if (!isObject(step)) {
      markRelevant(context);
      addFinding('UNVERIFIED_WORKFLOW_STEP', context, 'workflow step is not a mapping');
      return;
    }
    const stepContext = {
      ...context,
      credentialReference: context.credentialReference || hasPublisherCredential(step.env) || hasPublisherCredential(step.with),
    };
    const directory = workingDirectory(root, step['working-directory'], inheritedDirectory, addFinding, stepContext);
    if (directory === undefined && (stepContext.credentialReference || stepContext.potential)) markRelevant(stepContext);
    if (Object.hasOwn(step, 'run')) {
      inspectRun(step.run, directory === undefined ? root : resolve(root, directory), directory, stepContext);
    }
    if (!Object.hasOwn(step, 'uses')) return;
    if (typeof step.uses !== 'string') {
      markRelevant(context);
      addFinding('UNVERIFIED_ACTION_REFERENCE', context, 'action reference is not a static string');
      return;
    }
    if (step.uses.includes('${{')) {
      markRelevant(stepContext);
      addFinding('UNVERIFIED_ACTION_REFERENCE', stepContext, 'action reference contains an expression');
      return;
    }
    if (step.uses.startsWith('./')) {
      const action = localPath(root, step.uses, 'action', 'directory', addFinding, stepContext);
      if (action) inspectAction(rootRelative(root, action), directory, stepContext);
      else markRelevant(stepContext);
      return;
    }
    if (stepContext.credentialReference || /publish|release/i.test(step.uses)) {
      markRelevant(stepContext);
      addFinding('UNVERIFIED_EXTERNAL_ACTION', stepContext, 'external action can reach publishing or receives a credential and cannot be structurally inspected');
    }
  }

  function inspectWorkflow(path, rootPath, trigger, inheritedDirectory, chain, stack, inheritedCredentialReference = false) {
    const context = { chain, credentialReference: inheritedCredentialReference, rootPath, trigger };
    let absolute;
    try {
      absolute = assertExistingPath(root, root, path, 'file');
    } catch {
      markRelevant(context);
      addFinding('UNRESOLVED_LOCAL_WORKFLOW', context, 'local reusable workflow is unavailable, outside the repository, or symlinked');
      return;
    }
    if (stack.has(absolute)) {
      markRelevant(context);
      addFinding('WORKFLOW_CALL_CYCLE', context, 'local reusable workflow call graph contains a cycle');
      return;
    }
    const parsed = parseDocument(absolute, 'workflow', context);
    if (!parsed.document) return;
    const workflowDefaults = workingDirectory(root, parsed.document?.defaults?.run?.['working-directory'], inheritedDirectory, addFinding, context);
    const jobs = parsed.document.jobs;
    if (!isObject(jobs)) {
      markRelevant(context);
      addFinding('UNVERIFIED_WORKFLOW_JOBS', context, 'workflow jobs are not a mapping');
      return;
    }
    const nextStack = new Set(stack).add(absolute);
    for (const job of Object.values(jobs)) {
      if (!isObject(job)) {
        markRelevant(context);
        addFinding('UNVERIFIED_WORKFLOW_JOB', context, 'workflow job is not a mapping');
        continue;
      }
      const jobContext = {
        chain,
        credentialReference: inheritedCredentialReference
          || hasPublisherCredential(parsed.document.env)
          || hasPublisherCredential(job.env)
          || hasPublisherCredential(job.secrets)
          || hasPublisherCredential(job.with),
        potential: false,
        rootPath,
        trigger,
      };
      const directory = workingDirectory(root, job?.defaults?.run?.['working-directory'], workflowDefaults, addFinding, jobContext);
      if (directory === undefined && jobContext.credentialReference) markRelevant(jobContext);
      if (Object.hasOwn(job, 'uses')) {
        if (typeof job.uses !== 'string') {
          markRelevant(jobContext);
          addFinding('UNVERIFIED_WORKFLOW_CALL', jobContext, 'reusable workflow reference is not a static string');
        } else if (job.uses.includes('${{')) {
          markRelevant(jobContext);
          addFinding('UNVERIFIED_WORKFLOW_CALL', jobContext, 'reusable workflow reference contains an expression');
        } else {
          const provider = providerContract(job.uses);
          if (provider) {
            const fallback = provider === 'legacy' && (directory === '.' || directory === undefined) ? 'frontend' : directory;
            const declaredDirectory = workingDirectory(
              root,
              provider === 'strict' ? job.with?.['package-directory'] : job.with?.['working-directory'],
              fallback,
              addFinding,
              jobContext,
            );
            register('shared-provider', provider, jobContext, declaredDirectory);
          } else if (job.uses.startsWith('./')) {
            const local = localPath(root, job.uses, 'workflow', 'file', addFinding, jobContext);
            if (local) inspectWorkflow(local, rootPath, trigger, directory, [...chain, rootRelative(root, local)], nextStack, jobContext.credentialReference);
            else markRelevant(jobContext);
          } else if (jobContext.credentialReference || /publish|release/i.test(job.uses)) {
            markRelevant(jobContext);
            addFinding('UNVERIFIED_EXTERNAL_WORKFLOW', jobContext, 'external reusable workflow can reach publishing or receives a credential and cannot be structurally inspected');
          }
        }
      }
      if (job.steps === undefined) continue;
      if (!Array.isArray(job.steps)) {
        markRelevant(jobContext);
        addFinding('UNVERIFIED_WORKFLOW_STEPS', jobContext, 'job steps are not a sequence');
        continue;
      }
      for (const step of job.steps) inspectStep(step, directory, jobContext);
    }
  }

  const workflowDirectory = join(root, '.github', 'workflows');
  if (!existsSync(workflowDirectory)) return { findings: [], records: [] };
  try {
    assertExistingPath(root, root, '.github/workflows', 'directory');
  } catch {
    return { findings: [{ code: 'UNREADABLE_WORKFLOW_DIRECTORY', detail: 'workflow directory is outside the repository or symlinked', path: '.github/workflows' }], records: [] };
  }
  let files;
  try {
    files = readdirSync(workflowDirectory, { withFileTypes: true })
      .filter((entry) => (entry.isFile() || entry.isSymbolicLink()) && /\.ya?ml$/i.test(entry.name))
      .sort((left, right) => left.name.localeCompare(right.name));
  } catch {
    return { findings: [{ code: 'UNREADABLE_WORKFLOW_DIRECTORY', detail: 'workflow directory cannot be structurally read', path: '.github/workflows' }], records: [] };
  }
  for (const entry of files) {
    const path = join(workflowDirectory, entry.name);
    const rootPath = rootRelative(root, path);
    if (/(?:^|[-_.])publish(?:[-_.]|$)/i.test(entry.name)) relevantRoots.add(rootPath);
    if (entry.isSymbolicLink()) {
      findings.push({ armed: undefined, code: 'UNRESOLVED_LOCAL_REFERENCE', detail: 'workflow file is a symbolic link', path: rootPath, relevant: true });
      continue;
    }
    const topLevel = { chain: [rootPath], credentialReference: false, rootPath, trigger: 'unknown' };
    const parsed = parseDocument(path, 'workflow', topLevel);
    if (!parsed.document) continue;
    inspectWorkflow(path, rootPath, triggerPolicy(parsed.document), '.', [rootPath], new Set(), false);
  }
  return {
    findings: dedupe(findings.map((finding) => ({ ...finding, relevant: finding.relevant === true || relevantRoots.has(finding.path) }))),
    records: dedupe(records),
  };
}

function dedupe(entries) {
  const values = new Map();
  for (const entry of entries) values.set(JSON.stringify(entry), entry);
  return [...values.values()].sort((left, right) => JSON.stringify(left).localeCompare(JSON.stringify(right)));
}
