import { HttpClient } from './http';
import type { SandboxSpec } from './types';

export class SpecService {
  constructor(private http: HttpClient) {}

  /** Create a spec from raw YAML content. */
  async create(yamlContent: string): Promise<SandboxSpec> {
    return this.http.postRaw<SandboxSpec>('/v1/specs', yamlContent);
  }

  /** Get a spec by ID. */
  async get(id: string): Promise<SandboxSpec> {
    return this.http.get<SandboxSpec>(`/v1/specs/${enc(id)}`);
  }

  /** List all specs. */
  async list(): Promise<SandboxSpec[]> {
    return this.http.get<SandboxSpec[]>('/v1/specs');
  }

  /** Delete a spec by ID. */
  async delete(id: string): Promise<void> {
    return this.http.del(`/v1/specs/${enc(id)}`);
  }
}

function enc(s: string): string {
  return encodeURIComponent(s);
}
