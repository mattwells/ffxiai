#!/usr/bin/env node
// FFXI-AI bridge for the Claude desktop app.
//
// Claude starts this file and talks MCP to it over stdin/stdout (one JSON-RPC message per line).
// Each message is passed to the FFXI-AI addon running in the game at http://127.0.0.1:<port>/mcp,
// and the addon's answer is written back. No dependencies: only Node's built-in modules.
//
// When the game isn't running, Claude still gets a working connection: the tool list from the
// last time the game was up, and a plain message on each call saying to start the game. Once the
// addon is reachable again, Claude is told the tool list may have changed.

'use strict';

const http = require('http');
const fs = require('fs');
const os = require('os');
const path = require('path');
const readline = require('readline');

const PORT = parseInt(process.env.FFXIAI_PORT, 10) || 19750;
const TIMEOUT_MS = 15000;
const RETRY_MS = 15000;
const VERSION = '0.2.0';
const SUPPORTED = ['2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05'];

const CACHE_FILE = path.join(os.homedir(), '.ffxiai', 'tools.json');

const NOT_RUNNING =
    "FFXI-AI isn't answering. Make sure Final Fantasy XI is running through Windower and the FFXI-AI " +
    'addon is loaded (in game: //lua load ffxiai). If you changed the port in the addon\'s settings, ' +
    'set the same port in Claude: Settings > Extensions > FFXI-AI.';

const FALLBACK_INSTRUCTIONS =
    "Read-only view of the user's Final Fantasy XI characters, through the FFXI-AI addon for Windower. " +
    'If the user plays more than one character at once, call list_characters first and pass "character" to ' +
    'the other tools (or "all").';

function log(msg) {
    process.stderr.write('[ffxiai] ' + msg + '\n');
}

function send(msg) {
    process.stdout.write(JSON.stringify(msg) + '\n');
}

// POSTs one JSON-RPC message (or batch) to the addon. Resolves to the parsed reply, or null for
// "202 Accepted" (notifications). Rejects with err.unreachable = true when the addon isn't there.
function post(message) {
    return new Promise((resolve, reject) => {
        const body = Buffer.from(JSON.stringify(message));
        const req = http.request({
            host: '127.0.0.1',
            port: PORT,
            path: '/mcp',
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                'Accept': 'application/json, text/event-stream',
                'Content-Length': body.length,
            },
            timeout: TIMEOUT_MS,
        }, (res) => {
            const chunks = [];
            res.on('data', (c) => chunks.push(c));
            res.on('end', () => {
                const text = Buffer.concat(chunks).toString('utf8');
                if (res.statusCode === 202 || text.trim() === '') {
                    return resolve(null);
                }
                try {
                    resolve(JSON.parse(text));
                } catch (e) {
                    reject(new Error('FFXI-AI sent a reply that is not JSON (HTTP ' + res.statusCode + ')'));
                }
            });
        });
        req.on('timeout', () => {
            req.destroy(Object.assign(new Error('FFXI-AI took too long to answer'), {unreachable: true}));
        });
        req.on('error', (e) => {
            if (e.code === 'ECONNREFUSED' || e.code === 'ECONNRESET' || e.code === 'EHOSTUNREACH') {
                e.unreachable = true;
            }
            reject(e);
        });
        req.end(body);
    });
}

// Tool list cache -------------------------------------------------------------------------

function readCache() {
    try {
        const tools = JSON.parse(fs.readFileSync(CACHE_FILE, 'utf8'));
        return Array.isArray(tools) ? tools : [];
    } catch (e) {
        return [];
    }
}

function writeCache(tools) {
    try {
        fs.mkdirSync(path.dirname(CACHE_FILE), {recursive: true});
        fs.writeFileSync(CACHE_FILE, JSON.stringify(tools));
    } catch (e) {
        log('could not save the tool list: ' + e.message);
    }
}

// While the game is down, check every so often; when it answers, tell Claude to fetch tools again.
let retryTimer = null;
function watchForGame() {
    if (retryTimer) return;
    retryTimer = setInterval(() => {
        post({jsonrpc: '2.0', id: 'ffxiai-bridge-ping', method: 'ping'}).then(() => {
            clearInterval(retryTimer);
            retryTimer = null;
            log('FFXI-AI is answering again');
            send({jsonrpc: '2.0', method: 'notifications/tools/list_changed'});
        }, () => {});
    }, RETRY_MS);
}

// Message handling ------------------------------------------------------------------------

function errorReply(id, message) {
    return {jsonrpc: '2.0', id, error: {code: -32603, message}};
}

async function initialize(msg) {
    const requested = msg.params && msg.params.protocolVersion;
    let instructions = FALLBACK_INSTRUCTIONS;
    let serverVersion = VERSION;
    try {
        const r = await post(msg);
        if (r && r.result) {
            instructions = r.result.instructions || instructions;
            serverVersion = (r.result.serverInfo && r.result.serverInfo.version) || serverVersion;
        }
    } catch (e) {
        log('game not reachable at start: ' + e.message);
    }
    // Answered here rather than by the addon, so Claude connects even when the game is closed,
    // and so Claude knows the tool list can change (when the game starts or stops).
    return {
        jsonrpc: '2.0',
        id: msg.id,
        result: {
            protocolVersion: SUPPORTED.includes(requested) ? requested : SUPPORTED[0],
            capabilities: {tools: {listChanged: true}},
            serverInfo: {name: 'ffxiai', title: 'FFXI-AI', version: serverVersion},
            instructions,
        },
    };
}

async function toolsList(msg) {
    try {
        const r = await post(msg);
        if (r && r.result && Array.isArray(r.result.tools)) {
            writeCache(r.result.tools);
        }
        return r;
    } catch (e) {
        if (!e.unreachable) return errorReply(msg.id, e.message);
        watchForGame();
        return {jsonrpc: '2.0', id: msg.id, result: {tools: readCache()}};
    }
}

async function forward(msg) {
    try {
        return await post(msg);
    } catch (e) {
        if (e.unreachable) watchForGame();
        if (msg.method === 'tools/call') {
            // A tool result rather than a protocol error, so Claude can tell the player what to do.
            return {
                jsonrpc: '2.0',
                id: msg.id,
                result: {content: [{type: 'text', text: e.unreachable ? NOT_RUNNING : e.message}], isError: true},
            };
        }
        return errorReply(msg.id, e.unreachable ? NOT_RUNNING : e.message);
    }
}

async function handle(msg) {
    if (!msg || typeof msg !== 'object' || Array.isArray(msg)) {
        return forward(msg); // batches and odd messages: let the addon judge them
    }
    const isNotification = msg.id === undefined || msg.id === null;
    if (isNotification) {
        post(msg).catch(() => {}); // e.g. notifications/initialized; nothing to answer
        return null;
    }
    switch (msg.method) {
        case 'initialize': return initialize(msg);
        case 'ping': return {jsonrpc: '2.0', id: msg.id, result: {}};
        case 'tools/list': return toolsList(msg);
        default: return forward(msg);
    }
}

const rl = readline.createInterface({input: process.stdin, terminal: false});
rl.on('line', (line) => {
    if (!line.trim()) return;
    let msg;
    try {
        msg = JSON.parse(line);
    } catch (e) {
        return send({jsonrpc: '2.0', id: null, error: {code: -32700, message: 'Parse error'}});
    }
    handle(msg).then((reply) => {
        if (reply) send(reply);
    }, (e) => {
        log('unexpected error: ' + (e && e.stack || e));
        if (msg && msg.id !== undefined && msg.id !== null) send(errorReply(msg.id, String(e && e.message || e)));
    });
});
rl.on('close', () => process.exit(0));

log('bridge started, talking to FFXI-AI on port ' + PORT);
