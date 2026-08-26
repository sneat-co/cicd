#!/usr/bin/env node

import { createServer } from 'node:http';
import { writeFileSync } from 'node:fs';

const output = process.argv[2];
const sha = process.env.MOCK_GITHUB_SHA;
const repositories = JSON.parse(process.env.MOCK_GITHUB_REPOSITORIES || '["sneat-co/assetus"]');
if (!output || !/^[0-9a-f]{40}$/i.test(sha || '')) throw new Error('output path and MOCK_GITHUB_SHA are required');

const server = createServer((request, response) => {
  const url = new URL(request.url, 'http://127.0.0.1');
  response.setHeader('content-type', 'application/json');
  if (url.pathname === '/orgs/sneat-co/repos') {
    response.end(JSON.stringify(repositories.map((repository) => ({
      archived: false,
      default_branch: 'main',
      full_name: repository,
      owner: { login: 'sneat-co' },
    }))));
    return;
  }
  if (/^\/repos\/sneat-co\/[^/]+\/commits\/main$/.test(url.pathname)) {
    response.end(JSON.stringify({ sha }));
    return;
  }
  response.statusCode = 404;
  response.end(JSON.stringify({ message: 'not found' }));
});
server.listen(0, '127.0.0.1', () => {
  const address = server.address();
  writeFileSync(output, `http://127.0.0.1:${address.port}\n`);
});
process.on('SIGTERM', () => server.close(() => process.exit(0)));
