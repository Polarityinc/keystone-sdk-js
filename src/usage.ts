/**
 * Per-API-key usage tracking for sandbox resources and time.
 *
 * The API server calls these methods to record sandbox lifecycle events.
 * Usage data is stored via the Keystone API and can be queried for
 * billing, rate limiting, and monitoring.
 *
 * Usage (server-side):
 *   const usage = new UsageService(http);
 *
 *   // When a sandbox is created:
 *   await usage.recordStart(apiKey, sandboxId, specId, { vcpus: 0.35, memoryGib: 0.44 });
 *
 *   // When a sandbox is destroyed:
 *   await usage.recordStop(apiKey, sandboxId);
 *
 *   // Query usage:
 *   const summary = await usage.getSummary(apiKey, { from: '2026-04-01', to: '2026-04-30' });
 *   // summary.totalVcpuSeconds = 1260   (0.35 vCPU * 3600s)
 *   // summary.totalGibSeconds  = 1584   (0.44 GiB * 3600s)
 */

import { HttpClient } from './http';

// ── Types ──

/** Maximum sandbox resources per sandbox. */
export const MAX_VCPUS = 8;
export const MAX_MEMORY_GIB = 16;

/** Maximum concurrent sandboxes per API key. */
export const MAX_CONCURRENT_SANDBOXES = 20;

export interface SandboxResources {
  /** Total vCPUs allocated across all tasks (e.g. 0.5 = half a core). Max: 8. */
  vcpus: number;
  /** Total memory allocated in GiB across all tasks (e.g. 0.5 = 512 MiB). Max: 16. */
  memoryGib: number;
  /** Number of service tasks (db, cache, etc.). */
  serviceCount?: number;
}

/** Convert Nomad resource units to billing units. */
export function fromNomadResources(cpuMhz: number, memoryMb: number): SandboxResources {
  return {
    vcpus: cpuMhz / 1000,
    memoryGib: memoryMb / 1024,
  };
}

/** Validate that resources are within allowed limits. Throws if exceeded. */
export function validateResources(resources: SandboxResources): void {
  if (resources.vcpus > MAX_VCPUS) {
    throw new Error(`vcpus ${resources.vcpus} exceeds max ${MAX_VCPUS}`);
  }
  if (resources.memoryGib > MAX_MEMORY_GIB) {
    throw new Error(`memoryGib ${resources.memoryGib} exceeds max ${MAX_MEMORY_GIB}`);
  }
  if (resources.vcpus <= 0) {
    throw new Error('vcpus must be positive');
  }
  if (resources.memoryGib <= 0) {
    throw new Error('memoryGib must be positive');
  }
}

export interface UsageEvent {
  /** API key that created the sandbox. */
  apiKey: string;
  /** Sandbox ID. */
  sandboxId: string;
  /** Spec ID the sandbox was created from. */
  specId: string;
  /** Event type. */
  event: 'start' | 'stop';
  /** ISO timestamp. */
  ts: string;
  /** Resources allocated (only on start events). */
  resources?: SandboxResources;
}

export interface SandboxUsageRecord {
  /** Sandbox ID. */
  sandboxId: string;
  /** Spec ID. */
  specId: string;
  /** When the sandbox was created. */
  startedAt: string;
  /** When the sandbox was destroyed (null if still running). */
  stoppedAt: string | null;
  /** Duration in seconds (up to now if still running). */
  durationSec: number;
  /** Resources allocated. */
  resources: SandboxResources;
}

export interface UsageSummary {
  /** API key this summary is for. */
  apiKey: string;
  /** Time range start (ISO). */
  from: string;
  /** Time range end (ISO). */
  to: string;
  /** Total sandboxes created in the period. */
  totalSandboxes: number;
  /** Sandboxes currently running. */
  activeSandboxes: number;
  /** Total sandbox-seconds consumed (wall clock). */
  totalSandboxSeconds: number;
  /** Total vCPU-seconds (vCPUs * seconds). e.g. 0.5 vCPU for 60s = 30. */
  totalVcpuSeconds: number;
  /** Total GiB-seconds (GiB * seconds). e.g. 1 GiB for 60s = 60. */
  totalGibSeconds: number;
  /** Breakdown by spec. */
  bySpec: Record<string, {
    count: number;
    totalSeconds: number;
  }>;
  /** Individual sandbox records. */
  sandboxes: SandboxUsageRecord[];
}

export interface UsageQueryOptions {
  /** Start of time range (ISO date string). */
  from?: string;
  /** End of time range (ISO date string). */
  to?: string;
  /** Only include sandboxes from this spec. */
  specId?: string;
  /** Max records to return. */
  limit?: number;
}

// ── Service ──

export class UsageService {
  constructor(private http: HttpClient) {}

  /**
   * Check if the API key can create another sandbox.
   * Throws if the concurrency limit would be exceeded.
   */
  async checkConcurrencyLimit(apiKey: string): Promise<void> {
    const active = await this.getActive(apiKey);
    if (active.length >= MAX_CONCURRENT_SANDBOXES) {
      throw new Error(
        `Concurrency limit reached: ${active.length}/${MAX_CONCURRENT_SANDBOXES} sandboxes running. ` +
        `Destroy existing sandboxes before creating new ones.`,
      );
    }
  }

  /** Record that a sandbox was started for the given API key. */
  async recordStart(
    apiKey: string,
    sandboxId: string,
    specId: string,
    resources: SandboxResources,
  ): Promise<void> {
    // Send snake_case to match Go JSON tags.
    await this.http.post('/v1/usage/events', {
      api_key: apiKey,
      sandbox_id: sandboxId,
      spec_id: specId,
      event: 'start',
      ts: new Date().toISOString(),
      resources: { vcpus: resources.vcpus, memory_gib: resources.memoryGib, service_count: resources.serviceCount },
    });
  }

  /** Record that a sandbox was stopped/destroyed. */
  async recordStop(apiKey: string, sandboxId: string): Promise<void> {
    await this.http.post('/v1/usage/events', {
      api_key: apiKey,
      sandbox_id: sandboxId,
      spec_id: '',
      event: 'stop',
      ts: new Date().toISOString(),
    });
  }

  /** Get usage summary for an API key over a time range. */
  async getSummary(apiKey: string, opts?: UsageQueryOptions): Promise<UsageSummary> {
    const params = new URLSearchParams();
    if (opts?.from) params.set('from', opts.from);
    if (opts?.to) params.set('to', opts.to);
    if (opts?.specId) params.set('spec_id', opts.specId);
    if (opts?.limit) params.set('limit', String(opts.limit));

    const query = params.toString();
    const path = `/v1/usage/${encodeURIComponent(apiKey)}${query ? `?${query}` : ''}`;
    const raw = await this.http.get<any>(path);
    return mapSummary(raw);
  }

  /** List currently active sandboxes for an API key. */
  async getActive(apiKey: string): Promise<SandboxUsageRecord[]> {
    const raw = await this.http.get<any[]>(
      `/v1/usage/${encodeURIComponent(apiKey)}/active`,
    );
    return raw.map(mapRecord);
  }
}

// ── Wire format mappers (Go snake_case -> TS camelCase) ──

/* eslint-disable @typescript-eslint/no-explicit-any */
function mapRecord(r: any): SandboxUsageRecord {
  return {
    sandboxId: r.sandbox_id ?? r.sandboxId,
    specId: r.spec_id ?? r.specId,
    startedAt: r.started_at ?? r.startedAt,
    stoppedAt: r.stopped_at ?? r.stoppedAt ?? null,
    durationSec: r.duration_sec ?? r.durationSec ?? 0,
    resources: {
      vcpus: r.resources?.vcpus ?? 0,
      memoryGib: r.resources?.memory_gib ?? r.resources?.memoryGib ?? 0,
      serviceCount: r.resources?.service_count ?? r.resources?.serviceCount,
    },
  };
}

function mapSummary(r: any): UsageSummary {
  const bySpec: Record<string, { count: number; totalSeconds: number }> = {};
  const rawBySpec = r.by_spec ?? r.bySpec ?? {};
  for (const [k, v] of Object.entries(rawBySpec) as [string, any][]) {
    bySpec[k] = { count: v.count, totalSeconds: v.total_seconds ?? v.totalSeconds ?? 0 };
  }

  return {
    apiKey: r.api_key ?? r.apiKey,
    from: r.from,
    to: r.to,
    totalSandboxes: r.total_sandboxes ?? r.totalSandboxes ?? 0,
    activeSandboxes: r.active_sandboxes ?? r.activeSandboxes ?? 0,
    totalSandboxSeconds: r.total_sandbox_seconds ?? r.totalSandboxSeconds ?? 0,
    totalVcpuSeconds: r.total_vcpu_seconds ?? r.totalVcpuSeconds ?? 0,
    totalGibSeconds: r.total_gib_seconds ?? r.totalGibSeconds ?? 0,
    bySpec,
    sandboxes: (r.sandboxes ?? []).map(mapRecord),
  };
}
