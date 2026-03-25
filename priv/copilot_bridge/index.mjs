import readline from 'node:readline';
import { CopilotClient, approveAll } from '@github/copilot-sdk';

function write(message) {
  return new Promise((resolve, reject) => {
    process.stdout.write(`${JSON.stringify(message)}\n`, (error) => {
      if (error) {
        reject(error);
      } else {
        resolve();
      }
    });
  });
}

function extractContent(result) {
  if (!result) return '';

  if (typeof result.data?.content === 'string') {
    return result.data.content;
  }

  if (typeof result.content === 'string') {
    return result.content;
  }

  return '';
}

function systemPromptFromMessages(messages) {
  return messages
    .filter((message) => message?.role === 'system' && typeof message?.content === 'string')
    .map((message) => message.content)
    .join('\n\n');
}

function promptFromMessages(messages) {
  return messages
    .filter((message) => message?.role !== 'system')
    .map((message) => {
      const role = typeof message?.role === 'string' ? message.role : 'user';
      const content = typeof message?.content === 'string' ? message.content : '';
      return `${role}: ${content}`;
    })
    .join('\n\n');
}

async function withClient(githubToken, fn) {
  const client = new CopilotClient({
    githubToken: githubToken || undefined,
    useStdio: true,
    autoStart: true,
    logLevel: 'error'
  });

  try {
    await client.start();
    return await fn(client);
  } finally {
    try {
      await client.stop();
    } catch {
      // ignore shutdown errors on bridge exit
    }
  }
}

async function handleChat(request) {
  if (!request.githubToken) {
    return { ok: false, error: 'no_token' };
  }

  const messages = Array.isArray(request.messages) ? request.messages : [];
  const prompt = promptFromMessages(messages);

  if (!prompt.trim()) {
    return { ok: false, error: 'missing_prompt' };
  }

  const model = typeof request.model === 'string' && request.model.trim() !== ''
    ? request.model
    : (process.env.COPILOT_BRIDGE_MODEL || 'gpt-4o-mini');

  return withClient(request.githubToken, async (client) => {
    const session = await client.createSession({
      model,
      onPermissionRequest: approveAll,
      systemMessage: {
        mode: 'replace',
        content: systemPromptFromMessages(messages) || 'You are GitHub Copilot.'
      }
    });

    try {
      const event = await session.sendAndWait({ prompt }, 120000);

      return {
        ok: true,
        content: extractContent(event),
        finish_reason: 'stop',
        model,
        token_usage: null,
        tool_calls: []
      };
    } finally {
      await session.disconnect();
    }
  });
}

async function handleRequest(request) {
  switch (request?.action) {
    case 'chat':
      return handleChat(request);
    default:
      return { ok: false, error: `unsupported_action:${request?.action || 'unknown'}` };
  }
}

async function main() {
  const rl = readline.createInterface({
    input: process.stdin,
    crlfDelay: Infinity
  });

  rl.once('line', async (line) => {
    if (!line.trim()) {
      await write({ ok: false, error: 'empty_request' });
      rl.close();
      process.exit(0);
      return;
    }

    try {
      const request = JSON.parse(line);
      const response = await handleRequest(request);
      await write(response);
    } catch (error) {
      await write({
        ok: false,
        error: error?.message || String(error)
      });
    } finally {
      rl.close();
      process.exit(0);
    }
  });
}

main().catch(async (error) => {
  try {
    await write({ ok: false, error: error?.message || String(error) });
  } finally {
    process.exit(1);
  }
});
