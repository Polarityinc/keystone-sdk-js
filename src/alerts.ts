import { HttpClient } from './http';
import type { AlertRule } from './types';

export class AlertService {
  constructor(private http: HttpClient) {}

  /** Create a new alert rule. */
  async create(rule: AlertRule): Promise<AlertRule> {
    return this.http.post<AlertRule>('/v1/alerts', rule);
  }

  /** List all alert rules. */
  async list(): Promise<AlertRule[]> {
    return this.http.get<AlertRule[]>('/v1/alerts');
  }

  /** Delete an alert rule by ID. */
  async delete(id: string): Promise<void> {
    return this.http.del(`/v1/alerts/${enc(id)}`);
  }
}

function enc(s: string): string {
  return encodeURIComponent(s);
}
