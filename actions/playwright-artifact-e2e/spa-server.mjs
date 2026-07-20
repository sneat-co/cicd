import { createReadStream, existsSync, statSync } from 'node:fs';
import { createServer } from 'node:http';
import { extname, normalize, resolve, sep } from 'node:path';

const root = resolve(process.argv[2] || 'dist');
const port = Number(process.argv[3] || 4200);
const mime = {
  '.css': 'text/css; charset=utf-8',
  '.html': 'text/html; charset=utf-8',
  '.ico': 'image/x-icon',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.map': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.svg': 'image/svg+xml',
  '.webp': 'image/webp',
};

createServer((request, response) => {
  const pathname = decodeURIComponent(new URL(request.url || '/', 'http://localhost').pathname);
  const relative = normalize(pathname).replace(/^[/\\]+/, '');
  let file = resolve(root, relative);
  if (file !== root && !file.startsWith(root + sep)) {
    response.writeHead(400).end('invalid path');
    return;
  }
  if (!existsSync(file) || statSync(file).isDirectory()) {
    file = resolve(root, 'index.html');
  }
  response.writeHead(200, {
    'cache-control': 'no-store',
    'content-type': mime[extname(file)] || 'application/octet-stream',
  });
  createReadStream(file).pipe(response);
}).listen(port, '127.0.0.1', () => {
  console.log(`SPA artifact server: ${root} → http://127.0.0.1:${port}`);
});
