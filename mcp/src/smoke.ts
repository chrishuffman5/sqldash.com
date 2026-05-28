/**
 * Minimal MCP stdio client smoke test: spawns the server, lists tools, and calls a few.
 * Run from the mcp/ dir:  npm run smoke
 */
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

const transport = new StdioClientTransport({ command: 'npx', args: ['tsx', 'src/server.ts'] });
const client = new Client({ name: 'sqldash-smoke', version: '0.1.0' });
await client.connect(transport);

const tools = await client.listTools();
console.log('TOOLS:', tools.tools.map((t) => t.name).join(', '));

async function call(name: string, args: Record<string, unknown>): Promise<void> {
  const r: any = await client.callTool({ name, arguments: args });
  const text = (r.content ?? []).map((c: any) => c.text).join('\n');
  console.log(`\n=== ${name}(${JSON.stringify(args)})${r.isError ? ' [error]' : ''} ===\n${text}`);
}

await call('list_instances', {});
await call('instance_detail', { instance_fqn: 'localhost' });
await call('metric_history', { instance_fqn: 'localhost', metric: 'cpu', hours: 24 });
await call('problematic_instances', { limit: 10 });

await client.close();
process.exit(0);
