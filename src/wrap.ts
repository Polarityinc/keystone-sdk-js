import { HttpClient } from './http';
import type { TraceEvent, CostInfo } from './types';

// ---------------------------------------------------------------------------
// Types for LLM client shapes. We use `any` deliberately so the SDK does not
// depend on @anthropic-ai/sdk or openai as peer dependencies.
// ---------------------------------------------------------------------------

/* eslint-disable @typescript-eslint/no-explicit-any */

interface AnthropicToolUseBlock {
  type: 'tool_use';
  id: string;
  name: string;
  [key: string]: any;
}

interface AnthropicResponse {
  id?: string;
  model?: string;
  content?: Array<AnthropicToolUseBlock | { type: string; [key: string]: any }>;
  usage?: { input_tokens?: number; output_tokens?: number };
  [key: string]: any;
}

interface OpenAIToolCall {
  id: string;
  type: 'function';
  function: { name: string; arguments?: string };
}

interface OpenAIResponse {
  id?: string;
  model?: string;
  choices?: Array<{
    message?: {
      tool_calls?: OpenAIToolCall[];
      [key: string]: any;
    };
    [key: string]: any;
  }>;
  usage?: { prompt_tokens?: number; completion_tokens?: number; total_tokens?: number };
  [key: string]: any;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function enc(s: string): string {
  return encodeURIComponent(s);
}

function nowISO(): string {
  return new Date().toISOString();
}

/**
 * Fire-and-forget trace ingestion. Never throws.
 */
function sendTrace(http: HttpClient, sandboxId: string, events: TraceEvent[]): void {
  if (events.length === 0) return;
  http
    .post(`/v1/sandboxes/${enc(sandboxId)}/trace`, { events })
    .catch(() => {
      // Silently swallow — never break the caller.
    });
}

// ---------------------------------------------------------------------------
// Anthropic extraction
// ---------------------------------------------------------------------------

function extractAnthropicTraces(response: AnthropicResponse, latencyMs: number): TraceEvent[] {
  const events: TraceEvent[] = [];
  const ts = nowISO();
  const model = response.model ?? 'unknown';
  const inputTokens = response.usage?.input_tokens ?? 0;
  const outputTokens = response.usage?.output_tokens ?? 0;

  const cost: CostInfo = {
    input_tokens: inputTokens,
    output_tokens: outputTokens,
    model,
    estimated_usd: 0,
  };

  // Overall LLM call event
  events.push({
    ts,
    event_type: 'llm_call',
    tool: model,
    phase: 'end',
    duration_ms: latencyMs,
    status: 'ok',
    cost,
  });

  // Individual tool_use blocks
  if (Array.isArray(response.content)) {
    for (const block of response.content) {
      if (block.type === 'tool_use') {
        const tu = block as AnthropicToolUseBlock;
        events.push({
          ts,
          event_type: 'tool_call',
          tool: tu.name,
          phase: 'end',
          status: 'ok',
        });
      }
    }
  }

  return events;
}

// ---------------------------------------------------------------------------
// OpenAI extraction
// ---------------------------------------------------------------------------

function extractOpenAITraces(response: OpenAIResponse, latencyMs: number): TraceEvent[] {
  const events: TraceEvent[] = [];
  const ts = nowISO();
  const model = response.model ?? 'unknown';
  const inputTokens = response.usage?.prompt_tokens ?? 0;
  const outputTokens = response.usage?.completion_tokens ?? 0;

  const cost: CostInfo = {
    input_tokens: inputTokens,
    output_tokens: outputTokens,
    model,
    estimated_usd: 0,
  };

  // Overall LLM call event
  events.push({
    ts,
    event_type: 'llm_call',
    tool: model,
    phase: 'end',
    duration_ms: latencyMs,
    status: 'ok',
    cost,
  });

  // Individual tool_calls
  const toolCalls = response.choices?.[0]?.message?.tool_calls;
  if (Array.isArray(toolCalls)) {
    for (const tc of toolCalls) {
      events.push({
        ts,
        event_type: 'tool_call',
        tool: tc.function?.name ?? 'unknown',
        phase: 'end',
        status: 'ok',
      });
    }
  }

  return events;
}

// ---------------------------------------------------------------------------
// Stream wrapping helpers
// ---------------------------------------------------------------------------

/**
 * Wraps an async-iterable stream to accumulate chunks, then fires a single
 * trace when iteration completes. The wrapper preserves the original object's
 * shape — it copies all own properties and the async iterator protocol.
 */
function wrapAsyncIterableStream(
  stream: any,
  extractFn: (accumulated: any[], latencyMs: number) => TraceEvent[],
  http: HttpClient,
  sandboxId: string,
  startTime: number,
): any {
  const chunks: any[] = [];

  // Create a wrapper that looks like the original stream
  const wrapper: any = {};

  // Copy all enumerable own properties from the original stream
  // (e.g. controller, response, etc.)
  for (const key of Object.getOwnPropertyNames(stream)) {
    if (key === Symbol.asyncIterator.toString()) continue;
    const desc = Object.getOwnPropertyDescriptor(stream, key);
    if (desc) {
      Object.defineProperty(wrapper, key, desc);
    }
  }

  // Proxy method calls to the original
  const proto = Object.getPrototypeOf(stream);
  if (proto && proto !== Object.prototype) {
    for (const key of Object.getOwnPropertyNames(proto)) {
      if (key === 'constructor') continue;
      if (typeof (stream as any)[key] === 'function') {
        wrapper[key] = (...args: any[]) => (stream as any)[key](...args);
      }
    }
  }

  // Override the async iterator to intercept chunks
  wrapper[Symbol.asyncIterator] = () => {
    const iterator = stream[Symbol.asyncIterator]();
    return {
      async next(): Promise<IteratorResult<any>> {
        const result = await iterator.next();
        if (!result.done) {
          chunks.push(result.value);
        } else {
          // Stream finished — fire traces
          try {
            const latencyMs = Date.now() - startTime;
            const events = extractFn(chunks, latencyMs);
            sendTrace(http, sandboxId, events);
          } catch {
            // Never break
          }
        }
        return result;
      },
      async return(value?: any): Promise<IteratorResult<any>> {
        if (iterator.return) return iterator.return(value);
        return { done: true, value };
      },
      async throw(err?: any): Promise<IteratorResult<any>> {
        if (iterator.throw) return iterator.throw(err);
        throw err;
      },
    };
  };

  return wrapper;
}

/**
 * Extract traces from accumulated Anthropic stream events.
 * The final "message" event or the "message_stop" event contains the full message.
 */
function extractAnthropicStreamTraces(chunks: any[], latencyMs: number): TraceEvent[] {
  // Anthropic streaming: look for message_start, content_block_start, message_delta, etc.
  const events: TraceEvent[] = [];
  const ts = nowISO();
  let model = 'unknown';
  let inputTokens = 0;
  let outputTokens = 0;
  const toolNames: string[] = [];

  for (const chunk of chunks) {
    // Anthropic SDK stream events have a `type` field
    const eventType = chunk?.type ?? chunk?.event;

    if (eventType === 'message_start' && chunk?.message) {
      model = chunk.message.model ?? model;
      inputTokens = chunk.message.usage?.input_tokens ?? inputTokens;
    }

    if (eventType === 'message_delta' && chunk?.usage) {
      outputTokens = chunk.usage.output_tokens ?? outputTokens;
    }

    if (eventType === 'content_block_start' && chunk?.content_block?.type === 'tool_use') {
      toolNames.push(chunk.content_block.name ?? 'unknown');
    }
  }

  const cost: CostInfo = {
    input_tokens: inputTokens,
    output_tokens: outputTokens,
    model,
    estimated_usd: 0,
  };

  events.push({
    ts,
    event_type: 'llm_call',
    tool: model,
    phase: 'end',
    duration_ms: latencyMs,
    status: 'ok',
    cost,
  });

  for (const name of toolNames) {
    events.push({
      ts,
      event_type: 'tool_call',
      tool: name,
      phase: 'end',
      status: 'ok',
    });
  }

  return events;
}

/**
 * Extract traces from accumulated OpenAI stream chunks.
 */
function extractOpenAIStreamTraces(chunks: any[], latencyMs: number): TraceEvent[] {
  const events: TraceEvent[] = [];
  const ts = nowISO();
  let model = 'unknown';
  let inputTokens = 0;
  let outputTokens = 0;
  const toolNames: Map<number, string> = new Map();

  for (const chunk of chunks) {
    if (chunk?.model) model = chunk.model;

    // OpenAI usage appears in the final chunk when stream_options.include_usage is set
    if (chunk?.usage) {
      inputTokens = chunk.usage.prompt_tokens ?? inputTokens;
      outputTokens = chunk.usage.completion_tokens ?? outputTokens;
    }

    // Tool call deltas appear in choices[0].delta.tool_calls
    const toolCallDeltas = chunk?.choices?.[0]?.delta?.tool_calls;
    if (Array.isArray(toolCallDeltas)) {
      for (const tc of toolCallDeltas) {
        if (tc.index != null && tc.function?.name) {
          toolNames.set(tc.index, tc.function.name);
        }
      }
    }
  }

  const cost: CostInfo = {
    input_tokens: inputTokens,
    output_tokens: outputTokens,
    model,
    estimated_usd: 0,
  };

  events.push({
    ts,
    event_type: 'llm_call',
    tool: model,
    phase: 'end',
    duration_ms: latencyMs,
    status: 'ok',
    cost,
  });

  for (const [, name] of toolNames) {
    events.push({
      ts,
      event_type: 'tool_call',
      tool: name,
      phase: 'end',
      status: 'ok',
    });
  }

  return events;
}

// ---------------------------------------------------------------------------
// Detect & check for streaming
// ---------------------------------------------------------------------------

function isAsyncIterable(obj: any): boolean {
  return obj != null && typeof obj[Symbol.asyncIterator] === 'function';
}

// ---------------------------------------------------------------------------
// Client detection & wrapping
// ---------------------------------------------------------------------------

type ClientKind = 'anthropic' | 'openai' | 'unknown';

function detectClient(client: any): ClientKind {
  // Anthropic: client.messages.create exists
  if (client?.messages && typeof client.messages.create === 'function') {
    return 'anthropic';
  }
  // OpenAI: client.chat.completions.create exists
  if (client?.chat?.completions && typeof client.chat.completions.create === 'function') {
    return 'openai';
  }
  return 'unknown';
}

function wrapAnthropicCreate(
  originalCreate: (...args: any[]) => any,
  messagesObj: any,
  sandboxId: string,
  http: HttpClient,
): (...args: any[]) => any {
  return function wrappedCreate(this: any, ...args: any[]): any {
    const startTime = Date.now();
    let result: any;
    try {
      result = originalCreate.apply(messagesObj, args);
    } catch (err) {
      throw err;
    }

    // Check if result is a promise (non-streaming) or something else
    if (result && typeof result.then === 'function') {
      // Could be a Promise that resolves to a response OR to a stream
      const traced = result.then((resolved: any) => {
        try {
          const latencyMs = Date.now() - startTime;

          if (isAsyncIterable(resolved)) {
            // Streaming response — wrap the async iterable
            return wrapAsyncIterableStream(
              resolved,
              extractAnthropicStreamTraces,
              http,
              sandboxId,
              startTime,
            );
          }

          // Non-streaming response
          const events = extractAnthropicTraces(resolved as AnthropicResponse, latencyMs);
          sendTrace(http, sandboxId, events);
        } catch {
          // Never break
        }
        return resolved;
      });

      // If the original promise has additional properties/methods (e.g. Anthropic's
      // Stream object that is also thenable), copy them over.
      if (typeof result[Symbol.asyncIterator] === 'function') {
        // The result itself is an async iterable AND thenable (Anthropic's Stream).
        // Wrap at the async-iterator level instead.
        return wrapAsyncIterableStream(
          result,
          extractAnthropicStreamTraces,
          http,
          sandboxId,
          startTime,
        );
      }

      return traced;
    }

    // Synchronous or async-iterable result (unlikely, but handle gracefully)
    if (isAsyncIterable(result)) {
      return wrapAsyncIterableStream(
        result,
        extractAnthropicStreamTraces,
        http,
        sandboxId,
        startTime,
      );
    }

    return result;
  };
}

function wrapOpenAICreate(
  originalCreate: (...args: any[]) => any,
  completionsObj: any,
  sandboxId: string,
  http: HttpClient,
): (...args: any[]) => any {
  return function wrappedCreate(this: any, ...args: any[]): any {
    const startTime = Date.now();
    let result: any;
    try {
      result = originalCreate.apply(completionsObj, args);
    } catch (err) {
      throw err;
    }

    if (result && typeof result.then === 'function') {
      const traced = result.then((resolved: any) => {
        try {
          const latencyMs = Date.now() - startTime;

          if (isAsyncIterable(resolved)) {
            return wrapAsyncIterableStream(
              resolved,
              extractOpenAIStreamTraces,
              http,
              sandboxId,
              startTime,
            );
          }

          const events = extractOpenAITraces(resolved as OpenAIResponse, latencyMs);
          sendTrace(http, sandboxId, events);
        } catch {
          // Never break
        }
        return resolved;
      });

      if (typeof result[Symbol.asyncIterator] === 'function') {
        return wrapAsyncIterableStream(
          result,
          extractOpenAIStreamTraces,
          http,
          sandboxId,
          startTime,
        );
      }

      return traced;
    }

    if (isAsyncIterable(result)) {
      return wrapAsyncIterableStream(
        result,
        extractOpenAIStreamTraces,
        http,
        sandboxId,
        startTime,
      );
    }

    return result;
  };
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/**
 * Wrap an LLM client (Anthropic or OpenAI) to automatically capture tool
 * calls and usage as trace events in Keystone.
 *
 * The wrapper **never** alters the client's return values. If trace reporting
 * fails, the error is silently swallowed.
 *
 * @param client  - An Anthropic or OpenAI client instance.
 * @param sandboxId - The Keystone sandbox ID to report traces to.
 * @param http - The Keystone HttpClient used for trace ingestion.
 * @returns The same client reference, with its `.create()` method monkey-patched.
 */
export function wrapClient<T>(client: T, sandboxId: string, http: HttpClient): T {
  const c = client as any;
  const kind = detectClient(c);

  if (kind === 'anthropic') {
    const messagesObj = c.messages;
    const originalCreate = messagesObj.create;
    messagesObj.create = wrapAnthropicCreate(originalCreate, messagesObj, sandboxId, http);
  } else if (kind === 'openai') {
    const completionsObj = c.chat.completions;
    const originalCreate = completionsObj.create;
    completionsObj.create = wrapOpenAICreate(originalCreate, completionsObj, sandboxId, http);
  }

  // If client kind is unknown, return it unmodified — never break.
  return client;
}
