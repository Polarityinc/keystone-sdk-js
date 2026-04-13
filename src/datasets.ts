import { HttpClient } from './http';

export interface DatasetInfo {
  id: string;
  user_id: string;
  name: string;
  description?: string;
  version: number;
  created_at: string;
}

export interface DatasetRecord {
  id?: string;
  dataset_id?: string;
  input: Record<string, unknown>;
  expected?: Record<string, unknown>;
  metadata?: Record<string, unknown>;
  tags?: string[];
  version?: number;
}

export class DatasetService {
  constructor(private http: HttpClient) {}

  /** Create a new dataset. */
  async create(name: string, description = ''): Promise<DatasetInfo> {
    return this.http.post<DatasetInfo>('/v1/datasets', { name, description });
  }

  /** List all datasets. */
  async list(): Promise<DatasetInfo[]> {
    return this.http.get<DatasetInfo[]>('/v1/datasets');
  }

  /** Get a dataset by ID. */
  async get(id: string): Promise<DatasetInfo> {
    return this.http.get<DatasetInfo>(`/v1/datasets/${enc(id)}`);
  }

  /** Delete a dataset and all its records. */
  async delete(id: string): Promise<void> {
    return this.http.del(`/v1/datasets/${enc(id)}`);
  }

  /** Add records to a dataset. Auto-increments version. */
  async addRecords(datasetId: string, records: DatasetRecord[]): Promise<{ added: number }> {
    return this.http.post<{ added: number }>(`/v1/datasets/${enc(datasetId)}/records`, { records });
  }

  /** Get records from a dataset, optionally filtered. */
  async getRecords(
    datasetId: string,
    opts?: { version?: number; tags?: string[] },
  ): Promise<DatasetRecord[]> {
    const params: string[] = [];
    if (opts?.version !== undefined) params.push(`version=${opts.version}`);
    if (opts?.tags?.length) params.push(`tags=${opts.tags.join(',')}`);
    const qs = params.length ? `?${params.join('&')}` : '';
    return this.http.get<DatasetRecord[]>(`/v1/datasets/${enc(datasetId)}/records${qs}`);
  }
}

function enc(s: string): string {
  return encodeURIComponent(s);
}
