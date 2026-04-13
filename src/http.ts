import { KeystoneError } from './types';

export interface HttpClientConfig {
  baseUrl: string;
  apiKey?: string;
  timeout: number;
}

export class HttpClient {
  private baseUrl: string;
  private apiKey?: string;
  private timeout: number;

  constructor(config: HttpClientConfig) {
    this.baseUrl = config.baseUrl.replace(/\/+$/, '');
    this.apiKey = config.apiKey;
    this.timeout = config.timeout;
  }

  async request<T>(
    method: string,
    path: string,
    opts?: { body?: unknown; rawBody?: string; expectEmpty?: boolean },
  ): Promise<T> {
    const url = `${this.baseUrl}${path}`;

    const headers: Record<string, string> = {};
    if (this.apiKey) {
      headers['Authorization'] = `Bearer ${this.apiKey}`;
    }

    let bodyStr: string | undefined;
    if (opts?.rawBody !== undefined) {
      headers['Content-Type'] = 'text/yaml';
      bodyStr = opts.rawBody;
    } else if (opts?.body !== undefined) {
      headers['Content-Type'] = 'application/json';
      bodyStr = JSON.stringify(opts.body);
    }

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeout);

    let res: Response;
    try {
      res = await fetch(url, {
        method,
        headers,
        body: bodyStr,
        signal: controller.signal,
      });
    } catch (err: unknown) {
      if (err instanceof DOMException && err.name === 'AbortError') {
        throw new KeystoneError(0, `Request timed out after ${this.timeout}ms`);
      }
      throw err;
    } finally {
      clearTimeout(timer);
    }

    if (!res.ok) {
      let message = res.statusText;
      try {
        const errBody = (await res.json()) as { error?: string };
        if (errBody.error) {
          message = errBody.error;
        }
      } catch {
        // use statusText
      }
      throw new KeystoneError(res.status, message);
    }

    if (opts?.expectEmpty || res.status === 204) {
      return undefined as T;
    }

    return (await res.json()) as T;
  }

  get<T>(path: string): Promise<T> {
    return this.request<T>('GET', path);
  }

  post<T>(path: string, body?: unknown): Promise<T> {
    return this.request<T>('POST', path, { body });
  }

  postRaw<T>(path: string, rawBody: string): Promise<T> {
    return this.request<T>('POST', path, { rawBody });
  }

  del(path: string): Promise<void> {
    return this.request<void>('DELETE', path, { expectEmpty: true });
  }

  /**
   * POST with multipart/form-data. Accepts string fields and binary file fields.
   */
  async postMultipart<T>(
    path: string,
    parts: Record<string, string | { filename: string; data: Uint8Array; contentType: string }>,
  ): Promise<T> {
    const boundary = `----keystone${Date.now()}${Math.random().toString(36).slice(2)}`;
    const chunks: Uint8Array[] = [];
    const encoder = new TextEncoder();

    for (const [name, value] of Object.entries(parts)) {
      if (typeof value === 'string') {
        chunks.push(encoder.encode(`--${boundary}\r\nContent-Disposition: form-data; name="${name}"\r\n\r\n${value}\r\n`));
      } else {
        chunks.push(encoder.encode(
          `--${boundary}\r\nContent-Disposition: form-data; name="${name}"; filename="${value.filename}"\r\nContent-Type: ${value.contentType}\r\n\r\n`,
        ));
        chunks.push(value.data);
        chunks.push(encoder.encode('\r\n'));
      }
    }
    chunks.push(encoder.encode(`--${boundary}--\r\n`));

    // Concat chunks into a single Uint8Array.
    const totalLen = chunks.reduce((n, c) => n + c.length, 0);
    const body = new Uint8Array(totalLen);
    let offset = 0;
    for (const chunk of chunks) {
      body.set(chunk, offset);
      offset += chunk.length;
    }

    const url = `${this.baseUrl}${path}`;
    const headers: Record<string, string> = {
      'Content-Type': `multipart/form-data; boundary=${boundary}`,
    };
    if (this.apiKey) {
      headers['Authorization'] = `Bearer ${this.apiKey}`;
    }

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeout);

    let res: Response;
    try {
      res = await fetch(url, { method: 'POST', headers, body, signal: controller.signal });
    } catch (err: unknown) {
      if (err instanceof DOMException && err.name === 'AbortError') {
        throw new KeystoneError(0, `Request timed out after ${this.timeout}ms`);
      }
      throw err;
    } finally {
      clearTimeout(timer);
    }

    if (!res.ok) {
      let message = res.statusText;
      try {
        const errBody = (await res.json()) as { error?: string };
        if (errBody.error) message = errBody.error;
      } catch { /* use statusText */ }
      throw new KeystoneError(res.status, message);
    }

    return (await res.json()) as T;
  }

  getText(path: string): Promise<string> {
    return this.requestText('GET', path);
  }

  private async requestText(method: string, path: string): Promise<string> {
    const url = `${this.baseUrl}${path}`;

    const headers: Record<string, string> = {};
    if (this.apiKey) {
      headers['Authorization'] = `Bearer ${this.apiKey}`;
    }

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeout);

    let res: Response;
    try {
      res = await fetch(url, {
        method,
        headers,
        signal: controller.signal,
      });
    } catch (err: unknown) {
      if (err instanceof DOMException && err.name === 'AbortError') {
        throw new KeystoneError(0, `Request timed out after ${this.timeout}ms`);
      }
      throw err;
    } finally {
      clearTimeout(timer);
    }

    if (!res.ok) {
      let message = res.statusText;
      try {
        const errBody = (await res.json()) as { error?: string };
        if (errBody.error) {
          message = errBody.error;
        }
      } catch {
        // use statusText
      }
      throw new KeystoneError(res.status, message);
    }

    return res.text();
  }
}
