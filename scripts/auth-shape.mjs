// Print the SHAPE of ~/.codex/auth.json — key paths and value formats only.
// Never prints a secret value. Used to confirm which field holds the ChatGPT
// OAuth token vs. an API key.
import fs from 'fs';
import os from 'os';
import path from 'path';

const file = path.join(os.homedir(), '.codex', 'auth.json');
if (!fs.existsSync(file)) {
  console.log('MISSING: ' + file);
  process.exit(0);
}

const root = JSON.parse(fs.readFileSync(file, 'utf8'));

function shape(value) {
  if (value === null || value === undefined) return 'null';
  if (typeof value === 'boolean') return 'boolean';
  if (typeof value === 'number') return 'number';
  if (Array.isArray(value)) return `array[${value.length}]`;
  if (typeof value === 'object') return 'object';
  const s = value;
  if (s.length === 0) return 'string(empty)';
  let kind = 'opaque';
  if (/^sk-/.test(s)) kind = 'sk-key';
  else if ((s.match(/\./g) || []).length === 2) kind = 'JWT';
  else if (/^acc_/.test(s)) kind = 'account-id';
  else if (/^user_/.test(s) || /\|/.test(s)) kind = 'auth0-subject';
  else if (/^[0-9a-f]{8,}$/i.test(s)) kind = 'hex';
  // show only the first 3 characters so the user can recognise the type
  return `string(len=${s.length}, ${kind}, starts="${s.slice(0, 3)}…")`;
}

function walk(node, prefix) {
  if (node === null || typeof node !== 'object' || Array.isArray(node)) {
    console.log(`${prefix} = ${shape(node)}`);
    return;
  }
  const keys = Object.keys(node);
  if (keys.length === 0) {
    console.log(`${prefix} = {}`);
    return;
  }
  for (const k of keys) {
    walk(node[k], prefix ? `${prefix}.${k}` : k);
  }
}

console.log('file: ' + file);
walk(root, '');
