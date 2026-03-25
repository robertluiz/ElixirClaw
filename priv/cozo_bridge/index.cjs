const readline = require('node:readline');
const { CozoDb } = require('cozo-node');

const engine = process.argv[2] || 'mem';
const path = process.argv[3] || 'data.db';
const db = new CozoDb(engine, path, {});

function writeResponse(message) {
  process.stdout.write(`${JSON.stringify(message)}\n`);
}

async function existingRelations() {
  const result = await db.run('::relations', {});
  const nameIndex = result.headers.indexOf('name');

  if (nameIndex === -1) {
    return new Set();
  }

  return new Set(result.rows.map((row) => row[nameIndex]));
}

async function ensureRelations(relations) {
  const existing = await existingRelations();

  for (const relation of relations) {
    if (!existing.has(relation.name)) {
      await db.run(`:create ${relation.name} { ${relation.spec} }`, {});
    }
  }

  return { ok: true };
}

async function removeRelations(names) {
  const existing = await existingRelations();

  for (const name of names) {
    if (existing.has(name)) {
      await db.run(`::remove ${name}`, {});
    }
  }

  return { ok: true };
}

async function resetRelations(relations) {
  await removeRelations(relations.map((relation) => relation.name));
  return await ensureRelations(relations);
}

async function handleMessage(message) {
  switch (message.cmd) {
    case 'ensure_relations':
      return await ensureRelations(message.relations || []);

    case 'remove_relations':
      return await removeRelations(message.names || []);

    case 'reset_relations':
      return await resetRelations(message.relations || []);

    case 'export_relations':
      return { ok: true, data: await db.exportRelations(message.names || []) };

    case 'import_relations':
      await db.importRelations(message.data || {});
      return { ok: true };

    case 'close':
      db.close();
      return { ok: true };

    default:
      return { ok: false, error: `unknown_command:${message.cmd}` };
  }
}

const rl = readline.createInterface({
  input: process.stdin,
  crlfDelay: Infinity
});

rl.on('line', async (line) => {
  if (!line.trim()) {
    return;
  }

  try {
    const message = JSON.parse(line);
    const result = await handleMessage(message);
    writeResponse({ id: message.id, ...result });
  } catch (error) {
    writeResponse({
      id: null,
      ok: false,
      error: error && (error.display || error.message || String(error))
    });
  }
});

process.on('SIGTERM', () => {
  try {
    db.close();
  } finally {
    process.exit(0);
  }
});
