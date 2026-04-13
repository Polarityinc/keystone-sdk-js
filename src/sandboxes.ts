import { HttpClient } from './http';
import type {
  Sandbox,
  CreateSandboxRequest,
  CommandRequest,
  CommandResult,
  StateSnapshot,
  StateDiff,
  TraceEvent,
  TraceResponse,
} from './types';

export class SandboxService {
  constructor(private http: HttpClient) {}

  /** Create a new sandbox from a spec. */
  async create(opts: CreateSandboxRequest): Promise<Sandbox> {
    return this.http.post<Sandbox>('/v1/sandboxes', opts);
  }

  /** Get a sandbox by ID. */
  async get(id: string): Promise<Sandbox> {
    return this.http.get<Sandbox>(`/v1/sandboxes/${enc(id)}`);
  }

  /** List all active sandboxes. */
  async list(): Promise<Sandbox[]> {
    return this.http.get<Sandbox[]>('/v1/sandboxes');
  }

  /** Destroy a sandbox and clean up all resources. */
  async destroy(id: string): Promise<void> {
    return this.http.del(`/v1/sandboxes/${enc(id)}`);
  }

  /** Run a shell command inside the sandbox. */
  async runCommand(id: string, opts: CommandRequest): Promise<CommandResult> {
    return this.http.post<CommandResult>(`/v1/sandboxes/${enc(id)}/commands`, opts);
  }

  /** Read a file from the sandbox workspace. Returns the file content as a string. */
  async readFile(id: string, path: string): Promise<string> {
    return this.http.getText(`/v1/sandboxes/${enc(id)}/files/${path}`);
  }

  /** Write a file to the sandbox workspace. */
  async writeFile(id: string, path: string, content: string): Promise<void> {
    return this.http.request<void>('POST', `/v1/sandboxes/${enc(id)}/files`, {
      body: { path, content },
      expectEmpty: true,
    });
  }

  /** Delete a file from the sandbox workspace. */
  async deleteFile(id: string, path: string): Promise<void> {
    return this.http.del(`/v1/sandboxes/${enc(id)}/files/${path}`);
  }

  /** Capture the current filesystem state of the sandbox. */
  async state(id: string): Promise<StateSnapshot> {
    return this.http.get<StateSnapshot>(`/v1/sandboxes/${enc(id)}/state`);
  }

  /** Get the diff between the baseline snapshot and the current state. */
  async diff(id: string): Promise<StateDiff> {
    return this.http.get<StateDiff>(`/v1/sandboxes/${enc(id)}/diff`);
  }

  /**
   * Post tool call trace events to a sandbox. Any agent can use this
   * to report what it did — Keystone uses these for scoring, metrics,
   * and observability.
   */
  async ingestTrace(id: string, events: TraceEvent[]): Promise<{ ingested: number }> {
    return this.http.post<{ ingested: number }>(`/v1/sandboxes/${enc(id)}/trace`, { events });
  }

  /** Get trace events and computed metrics for a sandbox. */
  async getTrace(id: string): Promise<TraceResponse> {
    return this.http.get<TraceResponse>(`/v1/sandboxes/${enc(id)}/trace`);
  }
}

function enc(s: string): string {
  return encodeURIComponent(s);
}
