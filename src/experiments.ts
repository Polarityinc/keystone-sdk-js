import { HttpClient } from './http';
import type {
  Experiment,
  CreateExperimentRequest,
  RunResults,
  Comparison,
  ExperimentMetrics,
} from './types';

export class ExperimentService {
  constructor(private http: HttpClient) {}

  /** Create a new experiment. */
  async create(opts: CreateExperimentRequest): Promise<Experiment> {
    return this.http.post<Experiment>('/v1/experiments', opts);
  }

  /** Get experiment results by ID. */
  async get(id: string): Promise<RunResults> {
    return this.http.get<RunResults>(`/v1/experiments/${enc(id)}`);
  }

  /** List all experiments. */
  async list(): Promise<Experiment[]> {
    return this.http.get<Experiment[]>('/v1/experiments');
  }

  /** Trigger an experiment run (async on the server). */
  async run(id: string): Promise<void> {
    await this.http.post(`/v1/experiments/${enc(id)}/run`);
  }

  /**
   * Run an experiment and poll until it completes.
   *
   * @param id           - Experiment ID.
   * @param opts.pollInterval - Milliseconds between polls (default: 2000).
   * @param opts.timeout      - Maximum milliseconds to wait (default: 300000 = 5 min).
   * @returns The final RunResults once the experiment completes.
   */
  async runAndWait(
    id: string,
    opts?: { pollInterval?: number; timeout?: number },
  ): Promise<RunResults> {
    const pollInterval = opts?.pollInterval ?? 2000;
    const timeout = opts?.timeout ?? 300_000;

    await this.run(id);

    const deadline = Date.now() + timeout;

    while (Date.now() < deadline) {
      await sleep(pollInterval);
      const results = await this.get(id);
      // The server sets experiment status to "completed" when all jobs finish.
      // We detect completion when total_scenarios > 0 and all are accounted for.
      const total = results.total_scenarios;
      const done = results.passed + results.failed + results.flaky + results.errors;
      if (total > 0 && done >= total) {
        return results;
      }
    }

    throw new Error(`Experiment ${id} did not complete within ${timeout}ms`);
  }

  /** Compare two experiment runs side-by-side. */
  async compare(baselineId: string, candidateId: string): Promise<Comparison> {
    return this.http.post<Comparison>('/v1/experiments/compare', {
      baseline_id: baselineId,
      candidate_id: candidateId,
    });
  }

  /** Get detailed metrics for an experiment. */
  async metrics(id: string): Promise<ExperimentMetrics> {
    return this.http.get<ExperimentMetrics>(`/v1/metrics/experiments/${enc(id)}`);
  }
}

function enc(s: string): string {
  return encodeURIComponent(s);
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
