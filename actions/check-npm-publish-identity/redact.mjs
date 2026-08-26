const secretEnvironmentNames = [
  'GITHUB_TOKEN',
  'GH_TOKEN',
  'NODE_AUTH_TOKEN',
  'NPM_TOKEN',
  'SNEAT_ORGANIZATION_AUDIT_TOKEN',
];

function knownSecretValues() {
  return secretEnvironmentNames
    .map((name) => process.env[name])
    .filter((value) => typeof value === 'string' && value.length > 0)
    .sort((left, right) => right.length - left.length);
}

export function redact(value) {
  let text = String(value ?? '');
  for (const secret of knownSecretValues()) text = text.split(secret).join('[REDACTED]');
  return text
    .replace(/(https?:\/\/)[^\s/@:]+:[^\s/@]+@/gi, '$1[REDACTED]@')
    .replace(/\b(?:ghp_|gho_|github_pat_|npm_)[A-Za-z0-9_\-]{8,}\b/g, '[REDACTED]')
    .replace(/\$\{\{\s*secrets(?:\.[^}]+|\[[^}]+\])\s*}}/gi, '[SECRET_REFERENCE]');
}

export function safeError(error) {
  return redact(error instanceof Error ? error.message : error).slice(0, 500);
}

export function safeDetail(value) {
  return redact(value).slice(0, 240);
}
