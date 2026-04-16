/**
 * Nomad job builder for Keystone sandboxes.
 *
 * Generates Nomad job JSON from sandbox specs — the API server uses this
 * to dispatch the right task group based on what services a spec declares.
 *
 * Usage (server-side):
 *   const spec = await ks.specs.get('eval-v2');
 *   const job = buildSandboxJob('sb-xxx', spec, { apiKey: 'ks_live_...' });
 *   await fetch('http://nomad:4646/v1/jobs', {
 *     method: 'POST',
 *     body: JSON.stringify({ Job: job }),
 *   });
 */

import { MAX_VCPUS, MAX_MEMORY_GIB } from './usage';

// ── Spec service definition ──

export interface SpecService {
  /** Container image, e.g. "postgres:16-alpine" */
  image: string;
  /** Port the service listens on inside the container. */
  port: number;
  /** Environment variables to pass to the container. */
  env?: Record<string, string>;
  /** CPU in MHz (default 100). */
  cpu?: number;
  /** Memory in MB (default 128). */
  memory?: number;
  /** Health check type: "tcp" (default) or "http". */
  health_check?: 'tcp' | 'http';
  /** HTTP health check path (only if health_check is "http"). */
  health_path?: string;
}

export interface SandboxJobOptions {
  /** Nomad datacenter (default "dc1"). */
  datacenter?: string;
  /** Nomad node class constraint (default "worker"). */
  nodeClass?: string;
  /** Container image for the agent task. */
  agentImage?: string;
  /** Agent CPU in MHz (default 2000 = 2 vCPU). */
  agentCpu?: number;
  /** Agent memory in MB (default 4096 = 4 GiB). */
  agentMemory?: number;
  /** Keystone API base URL for the agent env. */
  apiBaseUrl?: string;
  /** API key injected into the agent env. */
  apiKey?: string;
}

// ── Nomad JSON types (subset) ──

interface NomadPort {
  Label: string;
  To?: number;
}

interface NomadNetwork {
  Mode?: string;
  DynamicPorts: NomadPort[];
}

interface NomadServiceCheck {
  Name: string;
  Type: string;
  Port: string;
  Path?: string;
  Interval: number;
  Timeout: number;
}

interface NomadService {
  Name: string;
  PortLabel: string;
  Meta?: Record<string, string>;
  Tags?: string[];
  Checks: NomadServiceCheck[];
}

interface NomadEnv {
  [key: string]: string;
}

interface NomadResources {
  CPU: number;
  MemoryMB: number;
}

interface NomadTaskConfig {
  image: string;
  force_pull?: boolean;
  ports?: string[];
  args?: string[];
}

interface NomadLifecycle {
  Hook: string;
  Sidecar: boolean;
}

interface NomadTask {
  Name: string;
  Driver: string;
  Config: NomadTaskConfig;
  Env?: NomadEnv;
  Resources: NomadResources;
  Lifecycle?: NomadLifecycle;
}

interface NomadGroup {
  Name: string;
  Count: number;
  Networks: NomadNetwork[];
  Services: NomadService[];
  Tasks: NomadTask[];
  RestartPolicy: { Attempts: number; Mode: string };
}

interface NomadParameterized {
  MetaRequired: string[];
  MetaOptional: string[];
}

export interface NomadJob {
  ID: string;
  Name: string;
  Type: string;
  Datacenters: string[];
  ParameterizedJob: NomadParameterized;
  TaskGroups: NomadGroup[];
  Meta?: Record<string, string>;
}

// ── Builder ──

/**
 * Build a Nomad job spec for a sandbox with the given services.
 *
 * @param sandboxId  - Unique sandbox identifier (e.g. "sb-xxx").
 * @param specId     - The spec ID this sandbox was created from.
 * @param services   - Map of service name to service config from the spec.
 * @param opts       - Optional overrides for resources, images, etc.
 * @returns A Nomad job object ready to POST to `/v1/jobs`.
 */
export function buildSandboxJob(
  sandboxId: string,
  specId: string,
  services: Record<string, SpecService>,
  opts?: SandboxJobOptions,
): NomadJob {
  const dc = opts?.datacenter ?? 'dc1';
  const agentCpu = opts?.agentCpu ?? 2000;
  const agentMemory = opts?.agentMemory ?? 4096;
  const agentImage = opts?.agentImage ?? 'keystone-agent-runner:latest';
  const apiBaseUrl = opts?.apiBaseUrl ?? 'http://keystone-api.service.consul:8080';

  // Sum total resources across agent + all services and validate against limits.
  let totalCpuMhz = agentCpu;
  let totalMemoryMb = agentMemory;
  for (const svc of Object.values(services)) {
    totalCpuMhz += svc.cpu ?? 100;
    totalMemoryMb += svc.memory ?? 128;
  }
  const totalVcpus = totalCpuMhz / 1000;
  const totalGib = totalMemoryMb / 1024;
  if (totalVcpus > MAX_VCPUS) {
    throw new Error(
      `Total sandbox vCPUs (${totalVcpus}) exceeds max ${MAX_VCPUS}. ` +
      `Agent: ${agentCpu / 1000} vCPU + services: ${(totalCpuMhz - agentCpu) / 1000} vCPU`,
    );
  }
  if (totalGib > MAX_MEMORY_GIB) {
    throw new Error(
      `Total sandbox memory (${totalGib.toFixed(2)} GiB) exceeds max ${MAX_MEMORY_GIB} GiB. ` +
      `Agent: ${(agentMemory / 1024).toFixed(2)} GiB + services: ${((totalMemoryMb - agentMemory) / 1024).toFixed(2)} GiB`,
    );
  }

  const ports: NomadPort[] = [{ Label: 'agent' }];
  const svcTasks: NomadTask[] = [];
  const svcServices: NomadService[] = [];
  const agentEnv: NomadEnv = {
    PORT: '${NOMAD_PORT_agent}',
    KEYSTONE_SANDBOX_ID: sandboxId,
    KEYSTONE_BASE_URL: apiBaseUrl,
    WORKSPACE: '${NOMAD_ALLOC_DIR}/workspace',
  };

  if (opts?.apiKey) {
    agentEnv['KEYSTONE_API_KEY'] = opts.apiKey;
  }

  // Build a task + port + service for each spec service.
  for (const [name, svc] of Object.entries(services)) {
    const portLabel = `svc_${name}`;
    const cpu = svc.cpu ?? 100;
    const memory = svc.memory ?? 128;

    // Add dynamic port.
    ports.push({ Label: portLabel });

    // Inject service address into agent env so it can find the service.
    const envName = name.toUpperCase();
    agentEnv[`${envName}_HOST`] = 'localhost';
    agentEnv[`${envName}_PORT`] = `\${NOMAD_PORT_${portLabel}}`;

    // Build the sidecar task.
    const taskEnv: NomadEnv = { ...svc.env };

    // For well-known images, auto-configure the port env var.
    if (svc.image.includes('postgres')) {
      taskEnv['PGPORT'] = `\${NOMAD_PORT_${portLabel}}`;
      taskEnv['POSTGRES_PASSWORD'] ??= 'keystone';
      taskEnv['POSTGRES_DB'] ??= 'sandbox';
    } else if (svc.image.includes('redis')) {
      // Redis needs --port passed as an arg.
    } else if (svc.image.includes('mysql') || svc.image.includes('mariadb')) {
      taskEnv['MYSQL_TCP_PORT'] = `\${NOMAD_PORT_${portLabel}}`;
      taskEnv['MYSQL_ROOT_PASSWORD'] ??= 'keystone';
    }

    const taskConfig: NomadTaskConfig = {
      image: svc.image.includes('/') ? svc.image : `docker.io/library/${svc.image}`,
      force_pull: false,
      ports: [portLabel],
    };

    // Redis needs the port passed as an arg.
    if (svc.image.includes('redis')) {
      taskConfig.args = ['redis-server', '--port', `\${NOMAD_PORT_${portLabel}}`];
    }

    svcTasks.push({
      Name: `svc-${name}`,
      Driver: 'podman',
      Config: taskConfig,
      Env: taskEnv,
      Resources: { CPU: cpu, MemoryMB: memory },
      Lifecycle: { Hook: 'prestart', Sidecar: true },
    });

    // Consul service registration for this service.
    const checkType = svc.health_check ?? 'tcp';
    const check: NomadServiceCheck = {
      Name: `${name}-health`,
      Type: checkType,
      Port: portLabel,
      Interval: 5_000_000_000, // 5s in nanoseconds
      Timeout: 2_000_000_000,
    };
    if (checkType === 'http' && svc.health_path) {
      check.Path = svc.health_path;
    }

    svcServices.push({
      Name: `keystone-sandbox-${name}`,
      PortLabel: portLabel,
      Meta: {
        sandbox_id: sandboxId,
        service_name: name,
      },
      Tags: ['sandbox-service', `sandbox_id:${sandboxId}`],
      Checks: [check],
    });
  }

  // Agent task.
  const agentTask: NomadTask = {
    Name: 'agent',
    Driver: 'podman',
    Config: {
      image: agentImage,
      force_pull: false,
      ports: ['agent'],
    },
    Env: agentEnv,
    Resources: { CPU: agentCpu, MemoryMB: agentMemory },
  };

  // Agent Consul service.
  const agentService: NomadService = {
    Name: 'keystone-sandbox',
    PortLabel: 'agent',
    Meta: {
      sandbox_id: sandboxId,
      spec_id: specId,
    },
    Tags: [
      'sandbox',
      `sandbox_id:${sandboxId}`,
      `spec_id:${specId}`,
    ],
    Checks: [{
      Name: 'sandbox-health',
      Type: 'http',
      Port: 'agent',
      Path: '/healthz',
      Interval: 5_000_000_000,
      Timeout: 2_000_000_000,
    }],
  };

  return {
    ID: `keystone-sandbox-${sandboxId}`,
    Name: `keystone-sandbox-${sandboxId}`,
    Type: 'batch',
    Datacenters: [dc],
    ParameterizedJob: {
      MetaRequired: ['sandbox_id', 'spec_id'],
      MetaOptional: ['timeout_seconds'],
    },
    TaskGroups: [{
      Name: 'sandbox',
      Count: 1,
      Networks: [{ DynamicPorts: ports }],
      Services: [agentService, ...svcServices],
      Tasks: [agentTask, ...svcTasks],
      RestartPolicy: { Attempts: 0, Mode: 'fail' },
    }],
    Meta: {
      sandbox_id: sandboxId,
      spec_id: specId,
    },
  };
}
