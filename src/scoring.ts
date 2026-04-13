import { HttpClient } from './http';

export interface ScoreRuleInfo {
  id: string;
  user_id: string;
  name: string;
  type: string;
  config: Record<string, unknown>;
  created_at?: string;
}

export interface TraceScoreInfo {
  id?: number;
  rule_id: string;
  trace_id: number;
  experiment_id?: string;
  score: number;
  passed: boolean;
  message?: string;
}

export class ScoringService {
  constructor(private http: HttpClient) {}

  /** Create a score rule. */
  async createRule(name: string, type: string, config: Record<string, unknown>): Promise<ScoreRuleInfo> {
    return this.http.post<ScoreRuleInfo>('/v1/score-rules', { name, type, config });
  }

  /** List all score rules. */
  async listRules(): Promise<ScoreRuleInfo[]> {
    return this.http.get<ScoreRuleInfo[]>('/v1/score-rules');
  }

  /** Delete a score rule. */
  async deleteRule(id: string): Promise<void> {
    return this.http.del(`/v1/score-rules/${encodeURIComponent(id)}`);
  }

  /** Trigger offline scoring for an experiment. */
  async scoreExperiment(experimentId: string, ruleIds: string[]): Promise<{ status: string }> {
    return this.http.post<{ status: string }>(
      `/v1/experiments/${encodeURIComponent(experimentId)}/score`,
      { rule_ids: ruleIds },
    );
  }

  /** Fetch offline scores for an experiment. */
  async getScores(experimentId: string): Promise<TraceScoreInfo[]> {
    return this.http.get<TraceScoreInfo[]>(
      `/v1/experiments/${encodeURIComponent(experimentId)}/scores`,
    );
  }
}
