// ── Errors ──

export class KeystoneError extends Error {
  statusCode: number;

  constructor(statusCode: number, message: string) {
    super(message);
    this.name = 'KeystoneError';
    this.statusCode = statusCode;
  }
}

// ── Sandboxes ──

export type SandboxState = 'creating' | 'ready' | 'running' | 'stopped' | 'error';

export interface ServiceInfo {
  host: string;
  port: number;
  ready: boolean;
}

export interface Sandbox {
  id: string;
  spec_id: string;
  state: SandboxState;
  path: string;
  url: string;
  created_at: string;
  metadata?: Record<string, string>;
  services?: Record<string, ServiceInfo>;
}

export interface CreateSandboxRequest {
  spec_id: string;
  timeout?: string;
  metadata?: Record<string, string>;
}

export interface CommandRequest {
  command: string;
  background?: boolean;
  timeout?: string;
}

export interface CommandResult {
  command: string;
  stdout: string;
  stderr?: string;
  exit_code: number;
  duration_ms: number;
}

export interface FileState {
  size: number;
  mode: string;
  checksum: string;
}

export interface StateSnapshot {
  captured_at: string;
  files: Record<string, FileState>;
}

export interface StateDiff {
  added: string[];
  removed: string[];
  modified: string[];
}

// ── Agent Snapshots ──

export interface ConfigFile {
  path: string;
  template: string;
}

export interface AgentAuth {
  required_env?: string[];
  config_files?: ConfigFile[];
  egress?: Record<string, string[]>;
}

export interface AgentSnapshot {
  id: string;
  name: string;
  version: number;
  tag?: string;
  digest: string;
  size_bytes: number;
  storage_path?: string;
  runtime?: string;
  entrypoint: string[];
  auth?: AgentAuth;
  created_at: string;
}

export interface UploadSnapshotRequest {
  name: string;
  entrypoint: string[];
  runtime?: string;
  auth?: AgentAuth;
  tag?: string;
  /** The tarball as a Uint8Array. */
  bundle: Uint8Array;
}

export interface AgentPage {
  items: AgentSnapshot[];
  next_cursor?: string;
}

// ── Specs ──

/**
 * SandboxSpec is a complex YAML-driven structure. The SDK treats it as a
 * loosely-typed Record so callers are not forced to model every nested field.
 * The server returns the full parsed spec as JSON.
 */
export interface SandboxSpec extends Record<string, unknown> {
  version: number;
  id: string;
  description: string;
}

// ── Experiments ──

export interface Experiment {
  id: string;
  name: string;
  spec_id: string;
  status: string;
  created_at: string;
}

export interface CreateExperimentRequest {
  name: string;
  spec_id: string;
}

export interface CostInfo {
  input_tokens: number;
  output_tokens: number;
  cache_read_tokens?: number;
  model: string;
  estimated_usd: number;
}

export interface InvariantResult {
  name: string;
  passed: boolean;
  gate?: boolean;
  weight: number;
  score?: number;
  message?: string;
  reason?: string;
}

export interface ForbiddenCheckResult {
  rule: string;
  violated: boolean;
  details?: string;
}

export interface Reproducer {
  spec_file: string;
  seed: number;
  scenario_id: string;
  parameters?: Record<string, unknown>;
  command: string;
}

export interface ScenarioResult {
  scenario_id: string;
  sandbox_id: string;
  status: 'pass' | 'fail' | 'flaky' | 'error';
  parameters?: Record<string, unknown>;
  wall_ms: number;
  exit_code: number;
  tool_calls: number;
  composite_score: number;
  invariants: InvariantResult[];
  forbidden_checks?: ForbiddenCheckResult[];
  trace_file?: string;
  reproducer?: Reproducer;
  error?: string;
  cost?: CostInfo;
}

export interface RunMetrics {
  pass_rate: number;
  mean_wall_ms: number;
  p95_wall_ms: number;
  mean_tool_calls: number;
  mean_tokens: number;
  total_cost_usd: number;
  mean_cost_per_run_usd: number;
  tool_success_rate: number;
  side_effect_violations: number;
}

export interface RunResults {
  ran_at: string;
  spec_id: string;
  experiment_id: string;
  seed: number;
  total_scenarios: number;
  passed: number;
  failed: number;
  flaky: number;
  errors: number;
  metrics: RunMetrics;
  scenarios: ScenarioResult[];
}

// ── Comparison ──

export interface MetricComparison {
  name: string;
  baseline: number;
  candidate: number;
  delta: number;
  direction: 'better' | 'worse' | 'same';
}

export interface Comparison {
  baseline_id: string;
  candidate_id: string;
  metrics: MetricComparison[];
  regressed: boolean;
  regressions?: string[];
}

// ── Metrics ──

export interface ToolMetric {
  count: number;
  mean_ms: number;
  error_rate: number;
}

export interface MetricsSummary {
  total_runs: number;
  pass_rate: number;
  total_cost_usd: number;
  mean_cost_per_run_usd: number;
  mean_wall_ms: number;
  p95_wall_ms: number;
  total_tool_calls: number;
  tool_success_rate: number;
}

export interface CostDataPoint {
  run_id: string;
  cost_usd: number;
  ts: string;
}

export interface PassRateDataPoint {
  run_id: string;
  pass_rate: number;
  ts: string;
}

export interface ExperimentMetrics {
  experiment_id: string;
  summary: MetricsSummary;
  tool_breakdown: Record<string, ToolMetric>;
  cost_trend: CostDataPoint[];
  pass_rate_trend: PassRateDataPoint[];
}

// ── Alerts ──

export interface AlertRule {
  id?: string;
  name: string;
  eval_id?: string;
  condition: string;
  window?: string;
  notify: string;
  webhook_url?: string;
}

// ── Traces ──

/** A single tool call or action captured during agent execution. */
export interface TraceEvent {
  ts?: string;
  event_type?: string;  // tool_call, command, file_op, http_call
  tool?: string;
  phase?: string;       // start, end
  duration_ms?: number;
  status?: string;      // ok, error
  input_bytes?: number;
  output_bytes?: number;
  cost?: CostInfo;
}

export interface TraceMetrics {
  total_tool_calls: number;
  tool_success_rate: number;
  mean_duration_ms: number;
  p95_duration_ms: number;
  tool_breakdown: Record<string, ToolMetric>;
}

export interface TraceResponse {
  events: TraceEvent[];
  metrics: TraceMetrics;
}
