import { HttpClient } from './http';
import type { AgentSnapshot, AgentPage, UploadSnapshotRequest } from './types';

export class AgentService {
  constructor(private http: HttpClient) {}

  /**
   * Upload an agent snapshot. Version is auto-assigned by the server.
   * Pass the tarball as `opts.bundle` (Uint8Array).
   */
  async upload(opts: UploadSnapshotRequest): Promise<AgentSnapshot> {
    const metadata = JSON.stringify({
      name: opts.name,
      entrypoint: opts.entrypoint,
      runtime: opts.runtime,
      auth: opts.auth,
      tag: opts.tag,
    });

    return this.http.postMultipart<AgentSnapshot>('/v1/agents', {
      metadata,
      bundle: { filename: opts.name + '.tar.gz', data: opts.bundle, contentType: 'application/gzip' },
    });
  }

  /**
   * Resolve a snapshot by name. Without version or tag, returns the latest.
   */
  async get(name: string, opts?: { version?: number; tag?: string }): Promise<AgentSnapshot> {
    if (opts?.tag) {
      return this.http.get<AgentSnapshot>(`/v1/agents/${enc(name)}/tags/${enc(opts.tag)}`);
    }
    if (opts?.version !== undefined) {
      return this.http.get<AgentSnapshot>(`/v1/agents/${enc(name)}/versions/${opts.version}`);
    }
    return this.http.get<AgentSnapshot>(`/v1/agents/${enc(name)}/latest`);
  }

  /** Get a snapshot by its immutable content-addressed ID. */
  async getById(id: string): Promise<AgentSnapshot> {
    return this.http.get<AgentSnapshot>(`/v1/snapshots/${enc(id)}`);
  }

  /** List all agent snapshots with cursor pagination. */
  async list(opts?: { limit?: number; cursor?: string }): Promise<AgentPage> {
    const limit = opts?.limit ?? 100;
    let path = `/v1/agents?limit=${limit}`;
    if (opts?.cursor) {
      path += `&cursor=${encodeURIComponent(opts.cursor)}`;
    }
    return this.http.get<AgentPage>(path);
  }

  /** List all versions of a named agent with cursor pagination. */
  async listVersions(name: string, opts?: { limit?: number; cursor?: string }): Promise<AgentPage> {
    const limit = opts?.limit ?? 100;
    let path = `/v1/agents/${enc(name)}/versions?limit=${limit}`;
    if (opts?.cursor) {
      path += `&cursor=${encodeURIComponent(opts.cursor)}`;
    }
    return this.http.get<AgentPage>(path);
  }

  /** Delete a snapshot. Pass the AgentSnapshot object, not raw strings. */
  async delete(snapshot: AgentSnapshot): Promise<void> {
    return this.http.del(`/v1/snapshots/${enc(snapshot.id)}`);
  }
}

function enc(s: string): string {
  return encodeURIComponent(s);
}
