import { HttpClient } from './http';
import { SandboxService } from './sandboxes';
import { SpecService } from './specs';
import { ExperimentService } from './experiments';
import { AlertService } from './alerts';
import { AgentService } from './agents';
import { DatasetService } from './datasets';
import { ScoringService } from './scoring';
import { UsageService } from './usage';
import { wrapClient } from './wrap';
import { initTracing } from './tracing';
import type { Sandbox } from './types';
import { KeystoneError } from './types';

export interface KeystoneConfig {
  /** API key. Falls back to KEYSTONE_API_KEY environment variable. */
  apiKey?: string;
  /** Base URL of the Keystone server. Default: https://keystone.ngrok-free.dev */
  baseUrl?: string;
  /** Request timeout in milliseconds. Default: 30000 */
  timeout?: number;
}

export interface WrapOptions {
  /** The sandbox ID to report traces to. */
  sandboxId: string;
}

export class Keystone {
  sandboxes: SandboxService;
  specs: SpecService;
  experiments: ExperimentService;
  alerts: AlertService;
  agents: AgentService;
  datasets: DatasetService;
  scoring: ScoringService;
  usage: UsageService;

  /** @internal — exposed for the wrap() helper. Not part of the public API. */
  readonly _http: HttpClient;

  constructor(config?: KeystoneConfig) {
    const apiKey = config?.apiKey ?? process.env.KEYSTONE_API_KEY;
    const baseUrl = config?.baseUrl ?? 'https://keystone.ngrok-free.dev';
    const timeout = config?.timeout ?? 30_000;

    const http = new HttpClient({ baseUrl, apiKey, timeout });
    this._http = http;

    this.sandboxes = new SandboxService(http);
    this.specs = new SpecService(http);
    this.experiments = new ExperimentService(http);
    this.alerts = new AlertService(http);
    this.agents = new AgentService(http);
    this.datasets = new DatasetService(http);
    this.scoring = new ScoringService(http);
    this.usage = new UsageService(http);
  }

  /**
   * Initialize tracing for `traced()`. After calling this, any `traced()`
   * call will auto-report spans (start, end, duration, errors) to the
   * specified sandbox.
   *
   * @example
   * ```ts
   * import { Keystone, traced } from '@polarity/keystone';
   *
   * const ks = new Keystone();
   * ks.initTracing('sb-xxx');
   *
   * const result = await traced('write_file', async () => {
   *   await fs.writeFile(path, content);
   * });
   * ```
   */
  initTracing(sandboxId: string): void {
    initTracing(this._http, sandboxId);
  }

  /**
   * Wrap an LLM client (Anthropic or OpenAI) so that every `.create()` call
   * automatically reports tool calls, usage, and latency as trace events to
   * the specified Keystone sandbox.
   *
   * The wrapper never alters response values. If trace reporting fails, the
   * error is silently swallowed.
   *
   * @example
   * ```ts
   * const ks = new Keystone({ apiKey: 'ks_live_...' });
   * const anthropic = ks.wrap(new Anthropic(), { sandboxId: 'sb-xxx' });
   * // anthropic.messages.create() now auto-reports to Keystone
   * ```
   */
  wrap<T>(client: T, opts: WrapOptions): T {
    return wrapClient(client, opts.sandboxId, this._http);
  }

  /**
   * Create a client from the environment variables that Keystone injects into
   * agent processes and return the current sandbox with its services.
   *
   * Reads `KEYSTONE_BASE_URL`, `KEYSTONE_API_KEY`, and `KEYSTONE_SANDBOX_ID`
   * from the environment.
   *
   * @example
   * ```ts
   * const { client, sandbox } = await Keystone.fromSandbox();
   * const db = sandbox.services?.['db']; // { host, port, ready }
   * ```
   */
  static async fromSandbox(): Promise<{ client: Keystone; sandbox: Sandbox }> {
    const sandboxId = process.env.KEYSTONE_SANDBOX_ID;
    if (!sandboxId) {
      throw new KeystoneError(0, 'KEYSTONE_SANDBOX_ID not set — not running inside a sandbox');
    }
    const client = new Keystone({
      baseUrl: process.env.KEYSTONE_BASE_URL,
    });
    const sandbox = await client.sandboxes.get(sandboxId);
    return { client, sandbox };
  }
}
