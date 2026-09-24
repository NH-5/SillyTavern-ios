import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const iosDirectory = path.dirname(fileURLToPath(import.meta.url));
const bundle = path.join(iosDirectory, 'Bundle', 'STServer');
await fs.access(path.join(bundle, 'public', 'lib.ios.js'));

const temporary = await fs.mkdtemp(path.join(os.tmpdir(), 'sillytavern-ios-smoke-'));
const socket = net.createServer();
await new Promise((resolve) => socket.listen(0, '127.0.0.1', resolve));
const port = socket.address().port;
await new Promise((resolve) => socket.close(resolve));

const child = spawn(process.execPath, [
    path.join(bundle, 'server.js'),
    '--configPath', path.join(temporary, 'config.yaml'),
    '--dataRoot', path.join(temporary, 'data'),
    '--port', String(port),
    '--listen', 'false',
    '--enableIPv6', 'false',
    '--browserLaunchEnabled', 'false',
], {
    cwd: bundle,
    env: { ...process.env, SILLYTAVERN_IOS: '1' },
    stdio: ['ignore', 'pipe', 'pipe'],
});

let output = '';
for (const stream of [child.stdout, child.stderr]) {
    stream.on('data', (chunk) => { output = (output + chunk.toString()).slice(-20000); });
}

try {
    const base = `http://127.0.0.1:${port}`;
    let ready = false;
    const deadline = Date.now() + 90000;
    while (Date.now() < deadline) {
        if (child.exitCode !== null) throw new Error(`Server exited with ${child.exitCode}\n${output}`);
        try {
            const response = await fetch(`${base}/api/ios/health`);
            const body = await response.json();
            ready = response.ok && body.app === 'SillyTavern' && body.platform === 'ios';
            if (ready) break;
        } catch { /* still starting */ }
        await new Promise((resolve) => setTimeout(resolve, 250));
    }
    assert.ok(ready, `Server did not become ready.\n${output}`);

    const page = await fetch(base);
    assert.equal(page.status, 200);
    assert.match(await page.text(), /SillyTavern/);
    const library = await fetch(`${base}/lib.js`);
    assert.equal(library.status, 200);
    assert.ok((await library.arrayBuffer()).byteLength > 100000);
    const csrf = await fetch(`${base}/csrf-token`);
    assert.equal(csrf.status, 200);
    const token = (await csrf.json()).token;
    assert.ok(token);
    const cookies = csrf.headers.getSetCookie().map((cookie) => cookie.split(';', 1)[0]).join('; ');
    const settings = await fetch(`${base}/api/settings/get`, {
        method: 'POST',
        headers: { 'content-type': 'application/json', 'x-csrf-token': token, cookie: cookies },
        body: '{}',
    });
    assert.equal(settings.status, 200);
    assert.ok((await settings.json()).settings);
    console.log('iOS bundle smoke test passed: health, page, library, CSRF, settings.');
} finally {
    child.kill('SIGTERM');
    await Promise.race([
        new Promise((resolve) => child.once('exit', resolve)),
        new Promise((resolve) => setTimeout(resolve, 5000)),
    ]);
    if (child.exitCode === null) child.kill('SIGKILL');
    await fs.rm(temporary, { recursive: true, force: true });
}
