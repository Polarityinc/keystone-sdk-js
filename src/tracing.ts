import type { HttpClient } from './http';
import type { TraceEvent } from './types';

let _http: HttpClient | null = null;
let _sandboxId: string | null = null;
let _currentSpanId: string | null = null;

/**
 * Initialize tracing. After calling this, `traced()` will auto-report
 * spans to the Keystone sandbox.
 */
export function initTracing(http: HttpClient, sandboxId: string): void {
  _http = http;
  _sandboxId = sandboxId;
}

function makeSpanId(): string {
  return Math.random().toString(36).slice(2) + Date.now().toString(36);
}

function postEvent(event: TraceEvent): void {
  if (!_http || !_sandboxId) return;
  const id = _sandboxId;
  _http.post(`/v1/sandboxes/${encodeURIComponent(id)}/trace`, { events: [event] }).catch(() => {});
}

/**
 * Execute an async function inside a traced span. Auto-captures start,
 * end, duration, and errors. Nested calls create parent-child spans.
 *
 * @example
 * ```ts
 * const ks = new Keystone();
 * ks.initTracing('sb-xxx');
 *
 * const result = await traced('write_file', async () => {
 *   await fs.writeFile(path, content);
 *   return 'ok';
 * });
 * ```
 */
export async function traced<T>(name: string, fn: () => T | Promise<T>): Promise<T> {
  const spanId = makeSpanId();
  const parentSpanId = _currentSpanId;
  _currentSpanId = spanId;

  postEvent({
    ts: new Date().toISOString(),
    event_type: 'tool_call',
    tool: name,
    phase: 'start',
    status: 'ok',
  });

  const start = Date.now();
  let status: 'ok' | 'error' = 'ok';
  let output: string | undefined;

  try {
    const result = await fn();
    if (result !== undefined && result !== null) {
      try {
        output = typeof result === 'string' ? result : JSON.stringify(result);
      } catch {
        output = String(result);
      }
    }
    return result;
  } catch (err: unknown) {
    status = 'error';
    output = err instanceof Error ? `${err.name}: ${err.message}` : String(err);
    throw err;
  } finally {
    _currentSpanId = parentSpanId;
    postEvent({
      ts: new Date().toISOString(),
      event_type: 'tool_call',
      tool: name,
      phase: 'end',
      duration_ms: Date.now() - start,
      status,
    });
  }
}
